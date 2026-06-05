// =============================================================================
// generate — the server-side generation proxy (Phase D2; Phase F trial branch).
// =============================================================================
// The runtime counterpart to D1's mirror. It holds the OpenAI key, transcribes
// audio + composes the prompt SERVER-SIDE, enforces input limits + credits, and
// returns the generated prompt. It must never be bypassable to spend money
// without a valid identity AND an available credit (§6.1 proxy principle,
// §14.1–14.2 key + dollar protection).
//
// TWO IDENTITIES, ONE PIPELINE. The session JWT's `kind` selects the credit
// ledger:
//   • kind='subscription' (D2) → usage_periods, consume_credit (subscription id)
//   • kind='trial'        (F)  → trial_grants,  consume_trial_credit (grant id)
// Everything else — input fuse, rate limit, concurrency cap, Whisper, the
// server-owned prompt, the chat call, deduct-on-success-only, logging — is
// IDENTICAL for both. The differences are captured behind the `ResolvedAccount`
// abstraction so the money-safety ordering lives in exactly one place.
//
// PRIVACY (§14.5): audio, frames, transcript, and the composed prompt are
// processed IN MEMORY only. Nothing is persisted; no temp files are written.
// generation_log holds token counts + cost + success ONLY — never content. (A
// trial generation logs with subscription_id = null; the trial cap is enforced
// on trial_grants, not via the log.)
//   ONE DOCUMENTED CARVE-OUT (M1 idempotency): when the request carries an
//   `Idempotency-Key`, a successful generation's PROMPT is cached for a short
//   TTL (IDEMPOTENCY_TTL_SECONDS, minutes) so a charged-but-dropped response is
//   replayed on retry WITHOUT a second charge — instead of re-billing the same
//   recording. That cache (idempotency_cache) is the only place generated
//   content is persisted, time-bounded by design; nothing else here persists.
//
// IDEMPOTENCY (M1): the credit decrement is check-then-consume-on-success, so a
// completed-but-lost 200 (network drop, or the client's 180s timeout firing as
// the server finishes at ~179s) leaves the credit SPENT but the client seeing a
// retryable error. The retry re-sends the SAME recording with the SAME
// Idempotency-Key; we replay the cached result rather than charging again. The
// cache check sits INSIDE the slot (cap=1) critical section and BEFORE the
// credit gate, so a replay can't be wrongly rejected as out_of_credits once the
// first charge brought the balance to zero.
//
// CREDIT ORDERING — CHECK-THEN-CONSUME-ON-SUCCESS (documented choice):
//   check a credit is available (no decrement) → call OpenAI →
//   consume the credit atomically ONLY on a fully usable result.
// Deduct only on success; an OpenAI failure never charges. The one race this
// can't see — two "last credit" requests both passing the check and both paying
// OpenAI before either consumes — is removed by the PER-IDENTITY CONCURRENCY CAP
// of 1 (acquire slot): a single identity can't have two generations in flight.
// consume_credit / consume_trial_credit remain the hard double-spend guards.
//   // DEFERRED Phase G: reserve-then-commit if the cap ever rises above 1.
// =============================================================================

import { json } from "../_shared/http.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { composedSystemPrompt } from "./prompt.ts";
import { buildInterleavedContent } from "./interleave.ts";
import { CHAT_MODEL, estimatedCostUsd, sttCostUsd } from "./cost.ts";
import { validateBody } from "./limits.ts";
import { type ChatClient, ProviderError, type SttClient } from "./providers/types.ts";
import type { BillingStore } from "./store.ts";
import {
  GENERATE_RATE_LIMIT_PER_SUB,
  GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  GENERATE_SLOT_STALE_SECONDS,
  IDEMPOTENCY_TTL_SECONDS,
  MAX_AUDIO_SECONDS,
  MAX_PAYLOAD_BYTES,
} from "./config.ts";

export interface GenerateDeps {
  store: BillingStore;
  /** Speech-to-text (Whisper) — independent of the chat provider. */
  stt: SttClient;
  /** Chat / vision generation — OpenAI or Gemini, selected by config. */
  chat: ChatClient;
  jwtSecret: string;
  /** Injectable clock for verifying the session token in tests. */
  nowSeconds?: number;
}

// A resolved, authorized identity (subscription or trial) plus the credit /
// slot / logging operations the shared pipeline drives, so the flow below never
// has to know which ledger it's spending against.
interface ResolvedAccount {
  /** Rate-limit + slot key (unique per identity). */
  key: string;
  /** generation_log.subscription_id — null for a trial identity. */
  logSubscriptionId: string | null;
  creditsRemaining(): Promise<number>;
  consume(): Promise<number | null>;
  acquireSlot(): Promise<boolean>;
  releaseSlot(): Promise<void>;
}

function bearer(req: Request): string | null {
  const h = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!h) return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

/** The client-minted idempotency key (one per recording, reused across retries),
 *  or null. Header lookup is case-insensitive (Headers normalizes). Absent →
 *  dedup is simply off for this request (backward compatible with older apps). */
function idempotencyKey(req: Request): string | null {
  const v = req.headers.get("Idempotency-Key");
  const trimmed = v?.trim();
  return trimmed ? trimmed : null;
}

export async function handleGenerate(req: Request, deps: GenerateDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 1. Cheapest gate first: cap the raw body before parsing (no spend, no DB).
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_PAYLOAD_BYTES) return json({ error: "payload_too_large" }, 413);

  // 2. Verify OUR session JWT. Invalid/expired → 401, nothing else happens.
  const token = bearer(req);
  if (!token) return json({ error: "missing_token" }, 401);
  const claims = await verifySessionToken(token, deps.jwtSecret, deps.nowSeconds);
  if (!claims) return json({ error: "invalid_token" }, 401);
  if (claims.kind !== "subscription" && claims.kind !== "trial") {
    return json({ error: "unsupported_token_kind" }, 401);
  }

  // Idempotency key (M1) — one per recording, reused across the app's retries.
  // Absent → dedup off (older app / non-managed path). Used inside the slot
  // critical section below, scoped to the resolved identity.
  const idemKey = idempotencyKey(req);

  // 3. Parse the (size-capped) body.
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  // 4. Resolve + authorize the identity (subscription status gate, or trial
  //    grant existence + verified gate). cancelled/expired/missing → 4xx here,
  //    before any input work, OpenAI call, or credit op.
  const resolved = claims.kind === "trial"
    ? await resolveTrial(deps, claims.sub)
    : await resolveSubscription(deps, claims.sub);
  if ("error" in resolved) return json({ error: resolved.error }, resolved.status);
  const account = resolved.account;

  // 5. Server-side input fuse — BEFORE any OpenAI call or credit work. A legit
  //    recording can never trip this; only a forged/oversized payload does.
  const parsed = validateBody(body);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.status);
  const { mode, audio, frames, declaredAudioSeconds } = parsed.value;

  // 6. Coarse per-identity rate limit (reuses D1's check_rate_limit).
  const withinRate = await deps.store.rateLimitOk(
    account.key,
    GENERATE_RATE_LIMIT_PER_SUB,
    GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!withinRate) return json({ error: "rate_limited" }, 429);

  // 7. Concurrency cap = 1. This is also what makes check-then-consume safe.
  const gotSlot = await account.acquireSlot();
  if (!gotSlot) return json({ error: "generation_in_progress" }, 429);

  // From here we hold the slot — release it on EVERY exit path.
  try {
    // 7.5 Idempotent replay (M1). Checked INSIDE the slot (a still-in-flight
    //     original holds the cap, so a true concurrent dup already got 429) and
    //     BEFORE the credit gate (so a retry of a charged generation isn't
    //     wrongly rejected as out_of_credits once that first charge zeroed the
    //     balance). HIT → return the cached result: no STT, no chat, no second
    //     decrement. Scoped to account.key so keys can't collide across users.
    if (idemKey) {
      const cached = await deps.store.getIdempotent(account.key, idemKey, IDEMPOTENCY_TTL_SECONDS);
      if (cached) {
        return json(
          { prompt: cached.prompt, usage: cached.usage, credits_remaining: cached.creditsRemaining },
          200,
        );
      }
    }

    // 8. Credit availability (read-only; do NOT decrement yet). Zero → 402.
    const remaining = await account.creditsRemaining();
    if (remaining <= 0) return json({ error: "out_of_credits" }, 402);

    // 9. Transcribe with the server-held key. A failure here charges NOTHING.
    let durationSeconds: number;
    let segments;
    try {
      const tr = await deps.stt.transcribe(audio);
      segments = tr.segments;
      durationSeconds = tr.durationSeconds;
    } catch (e) {
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: null, // no usable transcription → nothing billable recorded
        success: false,
      });
      return providerErrorResponse(e);
    }

    // 10. TRUE seconds gate on Whisper's measured duration, BEFORE the expensive
    //     chat call. A forged low-bitrate long file slips the byte fuse but is
    //     caught here — chat is not called, no credit charged. Whisper was paid,
    //     so record its cost honestly (success=false).
    const measured = Number.isFinite(durationSeconds) ? durationSeconds : (declaredAudioSeconds ?? 0);
    if (measured > MAX_AUDIO_SECONDS) {
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: sttCostUsd(measured),
        success: false,
      });
      return json({ error: "audio_too_long" }, 413);
    }

    // 11. Compose the system prompt SERVER-SIDE (server owns base + mode; the
    //     client supplied only the mode enum), interleave, and call chat.
    const systemPrompt = composedSystemPrompt(mode);
    const userContent = buildInterleavedContent(frames, segments);

    let chat;
    try {
      chat = await deps.chat.chat(systemPrompt, userContent);
    } catch (e) {
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: sttCostUsd(measured), // STT was paid; chat failed
        success: false,
      });
      return providerErrorResponse(e);
    }

    // 12. Fully successful + usable result → consume exactly one credit.
    const afterConsume = await account.consume();
    // Cost keys on the CONFIGURED chat model (CHAT_MODEL), not chat.model — a
    // provider may report a dated modelVersion the price table doesn't carry.
    const estCost = estimatedCostUsd(measured, chat.provider, CHAT_MODEL, chat.inputTokens, chat.outputTokens);

    if (afterConsume === null) {
      // Race edge (near-impossible under the cap=1 slot): the credit became
      // unspendable between step 8 and here. We've ALREADY paid OpenAI, so per
      // the locked default we return the result ONCE and log it; we just
      // couldn't charge. (Reserve-then-commit, Phase G, would avoid the pay.)
      console.warn(JSON.stringify({ fn: "generate", key: account.key, warn: "uncharged_result_returned" }));
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: chat.inputTokens,
        tokensOut: chat.outputTokens,
        estCostUsd: estCost,
        success: true,
      });
      // Cache this (uncharged) result too: a retry should replay it, not re-run.
      if (idemKey) {
        await deps.store.putIdempotent(account.key, idemKey, {
          prompt: chat.content,
          usage: usageBody(chat),
          creditsRemaining: 0,
        }, IDEMPOTENCY_TTL_SECONDS);
      }
      return json(
        { prompt: chat.content, usage: usageBody(chat), credits_remaining: 0 },
        200,
      );
    }

    // 13. Log token counts + cost + success ONLY (no content, §14.5).
    await deps.store.logGeneration({
      subscriptionId: account.logSubscriptionId,
      tokensIn: chat.inputTokens,
      tokensOut: chat.outputTokens,
      estCostUsd: estCost,
      success: true,
    });

    // 13b. Cache the result for an idempotent retry (M1) — BEFORE the finally
    //      releases the slot, so a retry arriving after this request returns
    //      sees the populated cache (and a concurrent dup is held off by the
    //      slot until then). Best-effort; a failed write never fails the (now
    //      charged) generation — it just leaves the rare pre-M1 re-charge open.
    if (idemKey) {
      await deps.store.putIdempotent(account.key, idemKey, {
        prompt: chat.content,
        usage: usageBody(chat),
        creditsRemaining: afterConsume,
      }, IDEMPOTENCY_TTL_SECONDS);
    }

    // 14. Return the prompt to the app.
    return json(
      { prompt: chat.content, usage: usageBody(chat), credits_remaining: afterConsume },
      200,
    );
  } finally {
    // 15. Always free the slot — success, reject, or throw.
    await account.releaseSlot();
  }
}

// -----------------------------------------------------------------------------
// Identity resolution — each returns either a ResolvedAccount or an HTTP reject.
// -----------------------------------------------------------------------------
type Resolution =
  | { account: ResolvedAccount }
  | { error: string; status: number };

async function resolveSubscription(deps: GenerateDeps, subId: string): Promise<Resolution> {
  const sub = await deps.store.loadSubscription(subId);
  if (!sub) return { error: "not_found", status: 404 };
  // cancelled/expired → 403. past_due STILL generates on remaining credits (§9.1).
  if (sub.status !== "active" && sub.status !== "past_due") {
    return { error: "not_entitled", status: 403 };
  }
  return {
    account: {
      key: `generate:sub:${sub.id}`,
      logSubscriptionId: sub.id,
      creditsRemaining: () => deps.store.creditsRemaining(sub.id, sub.credits_limit),
      consume: () => deps.store.consumeCredit(sub.id),
      acquireSlot: () => deps.store.acquireSlot(sub.id, GENERATE_SLOT_STALE_SECONDS),
      releaseSlot: () => deps.store.releaseSlot(sub.id),
    },
  };
}

async function resolveTrial(deps: GenerateDeps, grantId: string): Promise<Resolution> {
  const grant = await deps.store.loadTrialGrant(grantId);
  if (!grant) return { error: "not_found", status: 404 };
  // An unverified grant must never authorize (defensive — the token is only
  // minted after verify, but the gate is here too).
  if (!grant.verified_at) return { error: "not_entitled", status: 403 };
  return {
    account: {
      key: `generate:trial:${grant.id}`,
      logSubscriptionId: null, // trial generations have no subscription FK
      creditsRemaining: () => deps.store.trialCreditsRemaining(grant.id),
      consume: () => deps.store.consumeTrialCredit(grant.id),
      acquireSlot: () => deps.store.acquireTrialSlot(grant.id, GENERATE_SLOT_STALE_SECONDS),
      releaseSlot: () => deps.store.releaseTrialSlot(grant.id),
    },
  };
}

function usageBody(chat: { inputTokens: number; outputTokens: number; model: string }) {
  return { input_tokens: chat.inputTokens, output_tokens: chat.outputTokens, model: chat.model };
}

/** Map a provider failure to a client response. Retryable → 503; else 502. The
 *  client (ManagedProxyClient.parse) keys on HTTP status, not this body string,
 *  so the strings are kept stable regardless of which provider failed. */
function providerErrorResponse(e: unknown): Response {
  if (e instanceof ProviderError) {
    if (e.retryable) return json({ error: "provider_unavailable", retryable: true }, 503);
    return json({ error: "generation_failed", retryable: false }, 502);
  }
  // Unexpected (non-provider) error — surface as a generic server error.
  console.error(JSON.stringify({ fn: "generate", error: String(e) }));
  return json({ error: "server_error" }, 500);
}
