// =============================================================================
// generate — the server-side generation proxy (Phase D2).
// =============================================================================
// The runtime counterpart to D1's mirror. It holds the OpenAI key, transcribes
// audio + composes the prompt SERVER-SIDE, enforces input limits + credits, and
// returns the generated prompt. It must never be bypassable to spend money
// without a valid subscriber AND an available credit (§6.1 proxy principle,
// §14.1–14.2 key + dollar protection).
//
// PRIVACY (§14.5): audio, frames, transcript, and the composed prompt are
// processed IN MEMORY only. Nothing is persisted; no temp files are written.
// generation_log holds token counts + cost + success ONLY — never content.
//
// CREDIT ORDERING — CHECK-THEN-CONSUME-ON-SUCCESS (documented choice):
//   step 9  check a credit is available (no decrement)
//   step 12 call OpenAI
//   step 13 consume_credit() atomically — ONLY on a fully usable result
// Deduct only on success; an OpenAI failure never charges. The one race this
// can't see — two "last credit" requests both passing step 9 and both paying
// OpenAI before either consumes — is removed by the PER-SUBSCRIBER CONCURRENCY
// CAP of 1 (acquire_generation_slot, step 8): a single subscriber can't have two
// generations in flight. consume_credit() is still the hard double-spend guard.
//   // DEFERRED Phase G: reserve-then-commit (reserve a credit BEFORE OpenAI,
//   // commit on success / release on failure) if the concurrency cap ever
//   // proves insufficient (e.g. cap raised above 1).
//
// The handler takes its dependencies (store, OpenAI client) by injection so the
// Deno tests can drive every branch with a stub OpenAI + in-memory store, never
// spending money. index.ts wires the real service-role store + HTTP client.
// =============================================================================

import { json } from "../_shared/http.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { composedSystemPrompt } from "./prompt.ts";
import { buildInterleavedContent } from "./interleave.ts";
import { estimatedCostUsd, whisperCostUsd } from "./cost.ts";
import { validateBody } from "./limits.ts";
import { OpenAIError, type OpenAIClient } from "./openai.ts";
import type { BillingStore } from "./store.ts";
import {
  GENERATE_RATE_LIMIT_PER_SUB,
  GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  GENERATE_SLOT_STALE_SECONDS,
  MAX_AUDIO_SECONDS,
  MAX_PAYLOAD_BYTES,
} from "./config.ts";

export interface GenerateDeps {
  store: BillingStore;
  openai: OpenAIClient;
  jwtSecret: string;
  /** Injectable clock for verifying the session token in tests. */
  nowSeconds?: number;
}

function bearer(req: Request): string | null {
  const h = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!h) return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

export async function handleGenerate(req: Request, deps: GenerateDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 2. Cheapest gate first: cap the raw body before parsing (no spend, no DB).
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_PAYLOAD_BYTES) return json({ error: "payload_too_large" }, 413);

  // 3. Verify OUR session JWT. Invalid/expired → 401, nothing else happens.
  const token = bearer(req);
  if (!token) return json({ error: "missing_token" }, 401);
  const claims = await verifySessionToken(token, deps.jwtSecret, deps.nowSeconds);
  if (!claims) return json({ error: "invalid_token" }, 401);
  // Phase F adds kind === 'trial' (trial_grants). D2 handles subscriptions only.
  if (claims.kind !== "subscription") return json({ error: "unsupported_token_kind" }, 401);

  // 4. Parse the (size-capped) body.
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  // 5. Load the subscriber + status gate. cancelled/expired → 403. past_due
  //    STILL generates on remaining credits (§9.1).
  const sub = await deps.store.loadSubscription(claims.sub);
  if (!sub) return json({ error: "not_found" }, 404);
  if (sub.status !== "active" && sub.status !== "past_due") {
    return json({ error: "not_entitled" }, 403);
  }

  // 6. Server-side input fuse — BEFORE any OpenAI call or credit work. A legit
  //    recording can never trip this; only a forged/oversized payload does.
  const parsed = validateBody(body);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.status);
  const { mode, audio, frames, declaredAudioSeconds } = parsed.value;

  // 7. Coarse per-subscriber rate limit (reuses D1's check_rate_limit).
  const withinRate = await deps.store.rateLimitOk(
    `generate:sub:${sub.id}`,
    GENERATE_RATE_LIMIT_PER_SUB,
    GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!withinRate) return json({ error: "rate_limited" }, 429);

  // 8. Concurrency cap = 1. This is also what makes check-then-consume safe.
  const gotSlot = await deps.store.acquireSlot(sub.id, GENERATE_SLOT_STALE_SECONDS);
  if (!gotSlot) return json({ error: "generation_in_progress" }, 429);

  // From here we hold the slot — release it on EVERY exit path.
  try {
    // 9. Credit availability (read-only; do NOT decrement yet). Zero → 402.
    const remaining = await deps.store.creditsRemaining(sub.id, sub.credits_limit);
    if (remaining <= 0) return json({ error: "out_of_credits" }, 402);

    // 10. Transcribe with the server-held key. A failure here charges NOTHING.
    let durationSeconds: number;
    let segments;
    try {
      const tr = await deps.openai.transcribe(audio);
      segments = tr.segments;
      durationSeconds = tr.durationSeconds;
    } catch (e) {
      await deps.store.logGeneration({
        subscriptionId: sub.id,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: null, // no usable transcription → nothing billable recorded
        success: false,
      });
      return openAIErrorResponse(e);
    }

    // 11. TRUE seconds gate on Whisper's measured duration, BEFORE the expensive
    //     chat call. A forged low-bitrate long file slips the byte fuse but is
    //     caught here — chat is not called, no credit charged. Whisper was paid,
    //     so record its cost honestly (success=false).
    const measured = Number.isFinite(durationSeconds) ? durationSeconds : (declaredAudioSeconds ?? 0);
    if (measured > MAX_AUDIO_SECONDS) {
      await deps.store.logGeneration({
        subscriptionId: sub.id,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: whisperCostUsd(measured),
        success: false,
      });
      return json({ error: "audio_too_long" }, 413);
    }

    // 12. Compose the system prompt SERVER-SIDE (server owns base + mode; the
    //     client supplied only the mode enum), interleave, and call chat.
    const systemPrompt = composedSystemPrompt(mode);
    const userContent = buildInterleavedContent(frames, segments);

    let chat;
    try {
      chat = await deps.openai.chat(systemPrompt, userContent);
    } catch (e) {
      await deps.store.logGeneration({
        subscriptionId: sub.id,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: whisperCostUsd(measured), // whisper was paid; chat failed
        success: false,
      });
      return openAIErrorResponse(e);
    }

    // 13. Fully successful + usable result → consume exactly one credit.
    const afterConsume = await deps.store.consumeCredit(sub.id);
    const estCost = estimatedCostUsd(measured, chat.inputTokens, chat.outputTokens);

    if (afterConsume === null) {
      // Race edge (near-impossible under the cap=1 slot): the credit became
      // unspendable between step 9 and here — only possible via a non-generate
      // state change (e.g. a cancellation webhook landing mid-flight), since the
      // slot blocks a second concurrent generation. We've ALREADY paid OpenAI, so
      // per the locked default we return the result ONCE and log it; we just
      // couldn't charge. (Reserve-then-commit, Phase G, would avoid the pay.)
      console.warn(JSON.stringify({ fn: "generate", subscriptionId: sub.id, warn: "uncharged_result_returned" }));
      await deps.store.logGeneration({
        subscriptionId: sub.id,
        tokensIn: chat.inputTokens,
        tokensOut: chat.outputTokens,
        estCostUsd: estCost,
        success: true,
      });
      return json(
        { prompt: chat.content, usage: usageBody(chat), credits_remaining: 0 },
        200,
      );
    }

    // 14. Log token counts + cost + success ONLY (no content, §14.5).
    await deps.store.logGeneration({
      subscriptionId: sub.id,
      tokensIn: chat.inputTokens,
      tokensOut: chat.outputTokens,
      estCostUsd: estCost,
      success: true,
    });

    // 16. Return the prompt to the app.
    return json(
      { prompt: chat.content, usage: usageBody(chat), credits_remaining: afterConsume },
      200,
    );
  } finally {
    // 15. Always free the slot — success, reject, or throw.
    await deps.store.releaseSlot(sub.id);
  }
}

function usageBody(chat: { inputTokens: number; outputTokens: number; model: string }) {
  return { input_tokens: chat.inputTokens, output_tokens: chat.outputTokens, model: chat.model };
}

/** Map an OpenAI failure to a client response. Retryable → 503; else 502. */
function openAIErrorResponse(e: unknown): Response {
  if (e instanceof OpenAIError) {
    if (e.retryable) return json({ error: "openai_unavailable", retryable: true }, 503);
    return json({ error: "generation_failed", retryable: false }, 502);
  }
  // Unexpected (non-OpenAI) error — surface as a generic server error.
  console.error(JSON.stringify({ fn: "generate", error: String(e) }));
  return json({ error: "server_error" }, 500);
}
