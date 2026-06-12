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
import { creditCostForModel, estimatedCostUsd, sttCostUsd } from "./cost.ts";
import { modelById } from "./models.ts";
import { validateBody } from "./limits.ts";
import { type ChatClient, ProviderError, type SpeechSegment, type SttClient } from "./providers/types.ts";
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
  /** Chat / vision client factory (F2): the model is chosen PER REQUEST, so the
   *  handler builds the adapter once it knows the validated provider+model.
   *  Closes over the resolved provider keys in index.ts; tests inject a fake
   *  factory. May THROW for a provider whose key is unset — the handler maps
   *  that to a clean 503, never an opaque 500. */
  makeChat: (provider: string, model: string) => ChatClient;
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
  /** COMBINED spendable balance (plan + non-expired top-up for a subscription;
   *  the single grant bucket for a trial). */
  creditsRemaining(): Promise<number>;
  /** Atomically spend `credits` (all-or-nothing). Combined remaining after,
   *  or null with NOTHING spent if the balance can't cover it. */
  consume(credits: number): Promise<number | null>;
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
  const { model, audio, frames, clicks, declaredAudioSeconds, hasSpeech } = parsed.value;

  // 5.5 Resolve the validated model → provider + fixed credit price (Phase 4).
  //     validateBody already gated on ALLOWED_MODELS, so a miss here is a
  //     registry/validation drift bug — reject defensively rather than throw.
  //     The model selects the ADAPTER and the PRICE only; the system prompt is
  //     server-owned and fixed — no client field influences it (Appendix C #3;
  //     since the typed-artifact refactor there is no mode either).
  const modelEntry = modelById(model);
  if (!modelEntry) return json({ error: "invalid_model" }, 400);

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
          {
            prompt: cached.prompt,
            usage: cached.usage,
            credits_remaining: cached.creditsRemaining,
            // D2: the ORIGINAL charge, replayed — the retry itself charged 0,
            // but the app's toast must reflect what this recording cost.
            credits_charged: cached.creditsCharged,
          },
          200,
        );
      }
    }

    // 7.6 Build the chat client for the selected model — AFTER the idempotent
    //     replay (a replay needs no provider client, so a since-unset key can
    //     never block returning an already-charged result) and BEFORE the
    //     credit check + STT (a misconfigured provider key fails here with
    //     ZERO side effects: nothing paid, nothing charged, nothing logged as
    //     a generation). A throw means a key for this model's provider is
    //     unset in the deployment (Phase 3 reads them optionally) — an ops
    //     problem, surfaced as a clean 503 rather than an opaque 500.
    let chatClient: ChatClient;
    try {
      chatClient = deps.makeChat(modelEntry.provider, model);
    } catch (e) {
      console.error(JSON.stringify({
        fn: "generate",
        error: "make_chat_failed",
        model,
        provider: modelEntry.provider,
        detail: String(e),
      }));
      return json({ error: "provider_unavailable", retryable: false }, 503);
    }

    // 8. Credit availability for THIS model's price (read-only; do NOT
    //    decrement yet). The combined balance must cover the model's fixed
    //    price; otherwise 402 with the numbers the app's top-up prompt needs
    //    (F3 — the NULL-stranding → top-up mapping).
    const remaining = await account.creditsRemaining();
    if (remaining < modelEntry.creditPrice) {
      return json(
        { error: "out_of_credits", credits_remaining: remaining, model_price: modelEntry.creditPrice },
        402,
      );
    }

    // 9. Transcribe with the server-held key. A failure here charges NOTHING.
    //    Phase 6 no-speech gate: when the client signalled `has_speech:false`,
    //    SKIP the Whisper call entirely — no STT round-trip, no STT cost — and
    //    compose from frames + OCR + clicks on empty segments. This is the ONLY
    //    behavioural change of the gate on the server; the credit gate, the
    //    concurrency slot, and idempotency below are untouched. The true-seconds
    //    gate (step 10) still runs against the client-declared duration.
    let durationSeconds: number;
    let segments: SpeechSegment[];
    if (!hasSpeech) {
      segments = [];
      durationSeconds = declaredAudioSeconds ?? 0;
    } else {
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
          model,
          provider: modelEntry.provider,
        });
        return providerErrorResponse(e);
      }
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
        model,
        provider: modelEntry.provider,
      });
      return json({ error: "audio_too_long" }, 413);
    }

    // 11. Compose the system prompt SERVER-SIDE (the server owns the whole
    //     text; the client supplies nothing that influences it), interleave,
    //     and call chat.
    const systemPrompt = composedSystemPrompt();
    const userContent = buildInterleavedContent(frames, segments, clicks);

    let chat;
    try {
      chat = await chatClient.chat(systemPrompt, userContent);
    } catch (e) {
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: null,
        tokensOut: null,
        estCostUsd: sttCostUsd(measured), // STT was paid; chat failed
        success: false,
        model,
        provider: modelEntry.provider,
      });
      return providerErrorResponse(e);
    }

    // 12. Fully successful + usable result → consume the model's credit price.
    // Cost keys on the VALIDATED selected model, not chat.model — a provider
    // may report a dated modelVersion the price table doesn't carry. estCost
    // is computed FIRST so the circuit-breaker (anti-abuse metered charge,
    // §1.2) can compare it against the fixed price; the breaker only ever
    // changes the AMOUNT — whether the generation runs was decided long ago.
    const estCost = estimatedCostUsd(measured, modelEntry.provider, model, chat.inputTokens, chat.outputTokens);
    const credits = creditCostForModel(model, estCost);
    const afterConsume = await account.consume(credits);

    if (afterConsume === null) {
      // Race edge (near-impossible under the cap=1 slot): the credit became
      // unspendable between step 8 and here. We've ALREADY paid OpenAI, so per
      // the locked default we return the result ONCE and log it; we just
      // couldn't charge. (Reserve-then-commit, Phase G, would avoid the pay.)
      console.warn(JSON.stringify({ fn: "generate", key: account.key, warn: "uncharged_result_returned", model }));
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: chat.inputTokens,
        tokensOut: chat.outputTokens,
        estCostUsd: estCost,
        success: true,
        model,
        provider: modelEntry.provider,
      });
      // Cache this (uncharged) result too: a retry should replay it, not re-run.
      if (idemKey) {
        await deps.store.putIdempotent(account.key, idemKey, {
          prompt: chat.content,
          usage: usageBody(chat),
          creditsRemaining: 0,
          creditsCharged: 0, // circuit-breaker race: nothing was charged (D2)
        }, IDEMPOTENCY_TTL_SECONDS);
      }
      return json(
        { prompt: chat.content, usage: usageBody(chat), credits_remaining: 0, credits_charged: 0 },
        200,
      );
    }

    // 13. Log token counts + cost + model/provider + success ONLY (no content,
    //     §14.5 — model/provider are non-content attribution metadata).
    await deps.store.logGeneration({
      subscriptionId: account.logSubscriptionId,
      tokensIn: chat.inputTokens,
      tokensOut: chat.outputTokens,
      estCostUsd: estCost,
      success: true,
      model,
      provider: modelEntry.provider,
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
        creditsCharged: credits,
      }, IDEMPOTENCY_TTL_SECONDS);
    }

    // 14. Return the prompt to the app. `credits_charged` is the exact spend
    //     (D2) — usually the model's fixed price, but the §1.2 circuit-breaker
    //     can meter it higher, so the app must not derive it from the price.
    return json(
      { prompt: chat.content, usage: usageBody(chat), credits_remaining: afterConsume, credits_charged: credits },
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
      consume: (credits) => deps.store.consumeCredit(sub.id, credits),
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
      consume: (credits) => deps.store.consumeTrialCredit(grant.id, credits),
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
