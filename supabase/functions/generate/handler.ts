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
import { extractAnchors } from "./anchors.ts";
import { composedSystemPrompt } from "./prompt.ts";
import { buildInterleavedContent } from "./interleave.ts";
import { creditCostForModel, creditCostForUsd, estimatedCostUsd, sttCostUsd } from "./cost.ts";
import { modelById } from "./models.ts";
import { validateBody, validateTranscribeBody } from "./limits.ts";
import { type ChatClient, ProviderError, type SpeechSegment, type SttClient } from "./providers/types.ts";
import type { BillingStore } from "./store.ts";
import {
  DEV_TRANSCRIBE_FALLBACK_CREDITS,
  GENERATE_RATE_LIMIT_PER_SUB,
  GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  GENERATE_SLOT_STALE_SECONDS,
  IDEMPOTENCY_TTL_SECONDS,
  MAX_AUDIO_SECONDS,
  MAX_PAYLOAD_BYTES,
  STT_MODEL,
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

  // 4.5 Dev Mode call 1 (Phase 2 §7) — a FREE word-level transcription. The
  //     client needs the word transcript to resolve deixis anchors BEFORE the
  //     billable generation (call 2). This path deliberately does NONE of the
  //     billing machinery: no credit, no chat model, no concurrency SLOT, no
  //     idempotency entry. It is still auth-gated (above) and rate-limited
  //     (inside) because STT costs us real money. For a SUBSCRIPTION token it
  //     takes NO slot and is FREE (unchanged: the pair consumes two rate-limit
  //     tokens and exactly one credit on call 2). For a TRIAL token it is METERED
  //     against the per-grant pool (X-01 / B-03) — see handleDevTranscribe.
  if (isDevTranscribeRequest(body)) {
    return await handleDevTranscribe(body, account, deps, claims.kind === "trial", idemKey);
  }

  // 5. Server-side input fuse — BEFORE any OpenAI call or credit work. A legit
  //    recording can never trip this; only a forged/oversized payload does.
  const parsed = validateBody(body);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.status);
  const { model, audio, frames, clicks, declaredAudioSeconds, hasSpeech, mode, suppliedTranscript } = parsed.value;

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
            // Dev Mode: re-derive the structured anchors from the cached prompt
            // (no new cache column) so a replay returns the same `anchors[]`.
            ...devAnchorsBody(mode, cached.prompt),
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

    // 8. THE credit gate (read-only; do NOT decrement yet). This is the ≤ 0
    //    block: an account that can't afford even the 1-credit floor of a
    //    successful generation is refused here, before any STT cost. An account
    //    with >= 1 spendable credit is allowed exactly ONE generation of ANY
    //    cost — it is charged in full post-chat (step 12), which may drive the
    //    balance NEGATIVE; this gate then blocks EVERY further generation until
    //    the monthly period renews or a top-up is bought. There is no longer a
    //    pre-generation estimate gate — the one final generation is uncapped.
    //    402 carries `estimate: null` (the field is kept for response-shape
    //    stability; the app keys on the status, not this value).
    const remaining = await account.creditsRemaining();
    if (remaining < 1) {
      return json(
        { error: "out_of_credits", credits_remaining: remaining, estimate: null },
        402,
      );
    }

    // 9. Transcribe with the server-held key. A failure here charges NOTHING.
    //    Phase 2 Dev Mode CALL 2: when the client supplied a transcript (it
    //    already transcribed via the free call 1 and resolved deixis anchors
    //    against it), SKIP re-STT entirely and generate against that exact
    //    transcript — no double STT round-trip / charge, and the prompt lines up
    //    with the resolved anchors. (No audio was uploaded on call 2; the
    //    duration rode in the transcript for the STT-cost meter + seconds gate.)
    //    Phase 6 no-speech gate: when the client signalled `has_speech:false`,
    //    SKIP the Whisper call entirely — no STT round-trip, no STT cost — and
    //    compose from frames + OCR + clicks on empty segments. This is the ONLY
    //    behavioural change of the gate on the server; the credit gate, the
    //    concurrency slot, and idempotency below are untouched. The true-seconds
    //    gate (step 10) still runs against the (client-declared / supplied) duration.
    let durationSeconds: number;
    let segments: SpeechSegment[];
    if (suppliedTranscript) {
      segments = suppliedTranscript.segments;
      durationSeconds = suppliedTranscript.durationSeconds;
    } else if (!hasSpeech) {
      segments = [];
      durationSeconds = declaredAudioSeconds ?? 0;
    } else {
      // Audio is guaranteed present here: validateBody only allows a null audio
      // when a supplied transcript exists, and that case is handled above.
      if (!audio) return json({ error: "missing_audio" }, 400);
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
          creditsUsed: null, // nothing charged
          durationSeconds: declaredAudioSeconds ?? null, // measured not yet known here
          frameCount: frames.length,
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
        creditsUsed: null, // nothing charged
        durationSeconds: measured,
        frameCount: frames.length,
      });
      return json({ error: "audio_too_long" }, 413);
    }

    // (No pre-generation estimate gate: the step-8 credit gate already proved
    //  the account has >= 1 spendable credit, which buys exactly one uncapped
    //  generation. The metered charge is applied in full at step 12 and may take
    //  the balance negative; the next request is then blocked at step 8.)

    // 11. Compose the system prompt SERVER-SIDE (the server owns the whole
    //     text; the client supplies only the `mode` SELECTOR, never content),
    //     interleave, and call chat. Phase 2: `mode:"dev"` selects the
    //     repo-scoped dev prompt so a Dev Mode recording generates the
    //     Goal/Changes/Scope agent spec, not the clipboard prompt.
    const systemPrompt = composedSystemPrompt(mode);
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
        creditsUsed: null, // nothing charged
        durationSeconds: measured,
        frameCount: frames.length,
      });
      return providerErrorResponse(e);
    }

    // 12. Fully successful + usable result → consume the METERED credit charge.
    // Cost keys on the VALIDATED selected model, not chat.model — a provider
    // may report a dated modelVersion the price table doesn't carry. estCost is
    // the real measured cost; `creditCostForModel` meters it to
    // `ceil(estCost / USD_PER_CREDIT)` (floor 1), falling back to the model's
    // fallbackCredits only when estCost is unavailable. Whether the generation
    // runs was decided long ago; this only sets the AMOUNT.
    const estCost = estimatedCostUsd(measured, modelEntry.provider, model, chat.inputTokens, chat.outputTokens);
    const credits = creditCostForModel(model, estCost);
    const afterConsume = await account.consume(credits);

    if (afterConsume === null) {
      // DEFENSIVE ONLY. With the allow-negative consume RPCs a spendable account
      // is ALWAYS charged (a costlier-than-balance generation simply drives the
      // balance negative — see `consume` above). A null here therefore means the
      // account is genuinely NON-spendable: no spendable usage_period for an
      // active/past_due subscription, or a missing/unverified trial grant — both
      // already excluded by resolve-time auth (step 4) and the step-8 gate. We
      // only reach this on a since-cancelled mid-flight race. We have ALREADY
      // paid the provider, but the money-safety rule is absolute: NEVER return a
      // prompt without charging. Log a failure row and refuse with 402 — no free
      // result, nothing cached.
      console.error(JSON.stringify({ fn: "generate", key: account.key, error: "consume_non_spendable", model }));
      await deps.store.logGeneration({
        subscriptionId: account.logSubscriptionId,
        tokensIn: chat.inputTokens,
        tokensOut: chat.outputTokens,
        estCostUsd: estCost, // the provider WAS paid — record it honestly
        success: false,
        model,
        provider: modelEntry.provider,
        creditsUsed: null, // nothing charged
        durationSeconds: measured,
        frameCount: frames.length,
      });
      return json(
        { error: "out_of_credits", credits_remaining: 0, estimate: null },
        402,
      );
    }

    // 13. Log token counts + cost + model/provider + Phase 3 calibration
    //     metadata + success ONLY (no content, §14.5 — all of it is non-content
    //     attribution: credits charged, recording seconds, keyframe count).
    await deps.store.logGeneration({
      subscriptionId: account.logSubscriptionId,
      tokensIn: chat.inputTokens,
      tokensOut: chat.outputTokens,
      estCostUsd: estCost,
      success: true,
      model,
      provider: modelEntry.provider,
      creditsUsed: credits, // the metered charge actually consumed
      durationSeconds: measured,
      frameCount: frames.length,
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

    // 14. Return the prompt to the app. `credits_charged` is the exact METERED
    //     spend (D2) — the real `ceil(est_cost_usd / USD_PER_CREDIT)`, not any
    //     fixed/fallback price, so the app must read it rather than derive it.
    return json(
      {
        prompt: chat.content,
        usage: usageBody(chat),
        credits_remaining: afterConsume,
        credits_charged: credits,
        ...devAnchorsBody(mode, chat.content),
      },
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

  // CROSS-LEDGER (combined) spend: a converted user (linked trial grant) with a
  // verified trial remainder spends the trial credits FIRST, then bills only the
  // difference to plan + top-ups — atomically, via consume_combined_credit. This
  // un-strands trial credits that the subscription path would otherwise never
  // touch. When there's no link (or the grant is exhausted/unverified) we keep
  // the byte-for-byte original subscription-only path.
  let combinedGrantId: string | null = null;
  if (sub.trial_grant_id) {
    const grant = await deps.store.loadTrialGrant(sub.trial_grant_id);
    const trialRemaining = grant && grant.verified_at
      ? Math.max(0, grant.trial_credits_limit - grant.trial_credits_used)
      : 0;
    if (grant && grant.verified_at && trialRemaining > 0) combinedGrantId = grant.id;
  }

  // The slot, rate-limit key, and logging identity are ALWAYS the subscription's
  // — the converted user only ever drives /generate with the subscription token,
  // so cap-1 holds, and a stale trial slot must never block a paying subscriber.
  // The combined RPC's grant-row lock is the hard double-spend guard for the
  // trial portion regardless (consume_* are the guards; the slot is the
  // check-then-consume optimization — same posture as the single-ledger paths).
  return {
    account: {
      key: `generate:sub:${sub.id}`,
      logSubscriptionId: sub.id,
      creditsRemaining: combinedGrantId
        ? async () =>
          (await deps.store.creditsRemaining(sub.id, sub.credits_limit)) +
          (await deps.store.trialCreditsRemaining(combinedGrantId!))
        : () => deps.store.creditsRemaining(sub.id, sub.credits_limit),
      consume: combinedGrantId
        ? async (credits) => {
          const r = await deps.store.consumeCombinedCredit(combinedGrantId!, sub.id, credits);
          return r === null ? null : r.remaining;
        }
        : (credits) => deps.store.consumeCredit(sub.id, credits),
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

/** Phase 2 (Dev Mode CALL 2) — the structured per-reference `anchors[]` the
 *  client's M6 confirm gate consumes, parsed out of the model's `zerro_anchors`
 *  block (the M7 contract). Returned ONLY for `mode:"dev"`; spread into every dev
 *  response (fresh, idempotent replay, and the uncharged-race path) so a replay
 *  carries the same field. `{}` on the normal path → byte-identical normal body.
 *  Derived from the returned prompt content, so the idempotency cache needs no
 *  new column. */
function devAnchorsBody(mode: "dev" | undefined, content: string): Record<string, unknown> {
  return mode === "dev" ? { anchors: extractAnchors(content) } : {};
}

// =============================================================================
// Dev Mode call 1 — free word-level transcription (Phase 2 §7)
// =============================================================================

/** True when the body is a Dev Mode "dev-transcribe" request (the only place a
 *  `mode` field is read again — the normal generation path ignores it). */
function isDevTranscribeRequest(body: unknown): boolean {
  return typeof body === "object" && body !== null &&
    (body as Record<string, unknown>).mode === "dev_transcribe";
}

/** Handle Dev Mode call 1: transcribe audio with WORD-level timing and return it.
 *  Always rate-limited (STT costs money). Cost policy splits on identity:
 *   • SUBSCRIPTION → FREE, slot-free, no credit/idempotency (unchanged).
 *   • TRIAL        → METERED against the per-grant pool (X-01 / B-03): floor gate
 *     (≥1 credit), the SAME trial slot generate holds (cap-1 makes check-then-
 *     consume safe), consume the absorbed STT cost on success, and an idempotent
 *     retry replays the cached transcript without a second charge.
 *  `has_speech:false` → an empty transcript with NO provider call, so it's free
 *  for both kinds (nothing to meter) and never breaks the 2-call flow. */
async function handleDevTranscribe(
  body: unknown,
  account: ResolvedAccount,
  deps: GenerateDeps,
  isTrial: boolean,
  idemKey: string | null,
): Promise<Response> {
  const v = validateTranscribeBody(body);
  if (!v.ok) return json({ error: v.error }, v.status);

  // Rate-limit (same coarse per-identity limiter as generation) so this can't be
  // abused as a free unlimited transcription service.
  const withinRate = await deps.store.rateLimitOk(
    account.key,
    GENERATE_RATE_LIMIT_PER_SUB,
    GENERATE_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!withinRate) return json({ error: "rate_limited" }, 429);

  // No speech → no provider call → nothing to meter. Return an empty transcript;
  // the client falls back to click/dwell anchoring (build requirement #3). Free
  // for both identities and short-circuited before any slot/credit work.
  if (!v.value.hasSpeech) {
    return json({ transcript: { segments: [], words: [], durationSeconds: 0 } }, 200);
  }

  // --- Subscription (free) path: unchanged — no slot, no credit, no idempotency.
  if (!isTrial) {
    try {
      const tr = await deps.stt.transcribe(v.value.audio, { words: true });
      return json(
        { transcript: { segments: tr.segments, words: tr.words ?? [], durationSeconds: tr.durationSeconds } },
        200,
      );
    } catch (e) {
      // A transcription failure charges nothing and is NOT logged — call 1 is not
      // a billable generation.
      return providerErrorResponse(e);
    }
  }

  // --- Trial (metered) path. Mirrors generate's slot → replay → floor → spend.
  // The idempotency identity key is namespaced apart from the paired /generate
  // (`account.key`) so a recording's single Idempotency-Key can't cross-replay a
  // cached transcript as a generation prompt (or vice-versa).
  const idemIdentity = `${account.key}:transcribe`;

  const gotSlot = await account.acquireSlot();
  if (!gotSlot) return json({ error: "generation_in_progress" }, 429);
  try {
    // Idempotent replay: a retry carrying the same key returns the cached
    // transcript (stored as JSON in the cache's `prompt` field) and charges 0.
    if (idemKey) {
      const cached = await deps.store.getIdempotent(idemIdentity, idemKey, IDEMPOTENCY_TTL_SECONDS);
      if (cached) {
        try {
          return json({ transcript: JSON.parse(cached.prompt) }, 200);
        } catch {
          // A malformed/legacy cache row → fall through and re-transcribe.
        }
      }
    }

    // Floor gate. FAIL CLOSED: refuse on a credit-lookup error rather than serve
    // a free Whisper call.
    let remaining: number;
    try {
      remaining = await account.creditsRemaining();
    } catch (e) {
      console.error(JSON.stringify({ fn: "generate", key: account.key, op: "devTranscribeFloor", error: String(e) }));
      return json({ error: "credit_check_failed", retryable: true }, 503);
    }
    if (remaining < 1) {
      return json({ error: "out_of_credits", credits_remaining: remaining, estimate: null }, 402);
    }

    // Transcribe (paid). A failure charges nothing.
    let tr;
    try {
      tr = await deps.stt.transcribe(v.value.audio, { words: true });
    } catch (e) {
      return providerErrorResponse(e);
    }

    // Meter the absorbed STT cost and consume from the grant — `ceil(stt / $0.01)`,
    // floor 1, the same metering generate uses (cost.ts).
    const credits = creditCostForUsd(sttCostUsd(tr.durationSeconds), DEV_TRANSCRIBE_FALLBACK_CREDITS);
    const after = await account.consume(credits);
    if (after === null) {
      // DEFENSIVE: consume returns null only for a missing/unverified grant —
      // already excluded by resolve-time auth. Provider paid; refuse a free result.
      console.error(JSON.stringify({ fn: "generate", key: account.key, error: "devTranscribe_consume_non_spendable" }));
      return json({ error: "out_of_credits", credits_remaining: 0, estimate: null }, 402);
    }

    const transcript = { segments: tr.segments, words: tr.words ?? [], durationSeconds: tr.durationSeconds };
    // Cache the charged transcript for an idempotent retry — best-effort.
    if (idemKey) {
      await deps.store.putIdempotent(idemIdentity, idemKey, {
        prompt: JSON.stringify(transcript),
        usage: { input_tokens: 0, output_tokens: 0, model: STT_MODEL },
        creditsRemaining: after,
        creditsCharged: credits,
      }, IDEMPOTENCY_TTL_SECONDS);
    }
    return json({ transcript }, 200);
  } finally {
    await account.releaseSlot();
  }
}

/** Map a provider failure to a client response. Retryable → 503; else 502. The
 *  client (ManagedProxyClient.parse) keys on HTTP status, not this body string,
 *  so the strings are kept stable regardless of which provider failed. */
function providerErrorResponse(e: unknown): Response {
  if (e instanceof ProviderError) {
    // Output-token truncation → 422 so the app shows a distinct "response too
    // long" state. Withholding the (partial) prompt is the point: a half-formed
    // result can carry an unterminated artifact fence (handoff-artifact-fence-leak).
    if (e.truncated) return json({ error: "response_truncated", retryable: false }, 422);
    if (e.retryable) return json({ error: "provider_unavailable", retryable: true }, 503);
    return json({ error: "generation_failed", retryable: false }, 502);
  }
  // Unexpected (non-provider) error — surface as a generic server error.
  console.error(JSON.stringify({ fn: "generate", error: String(e) }));
  return json({ error: "server_error" }, 500);
}
