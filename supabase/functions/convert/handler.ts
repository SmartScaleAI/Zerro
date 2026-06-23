// =============================================================================
// convert — the free "Write agent prompt" conversion fallback (Phase 6 of the
// typed-artifact refactor).
// =============================================================================
// When a generated response carried NO artifact (the model judged it a
// question/diagnosis), the app can still produce an agent prompt: it sends the
// response's chat text + the recording's Attached Context block here, and gets
// back a §2 `agent_prompt` artifact block (raw fenced text — the CLIENT
// parses, locked decision).
//
// TWO IDENTITIES, TWO COST POLICIES (X-01):
//   • kind="subscription" → FREE, stateless: session-token auth + per-identity
//     rate limit ONLY. A managed subscriber is already paying; convert is a
//     cheap fallback for them, with the full model picker. (Behavior unchanged.)
//   • kind="trial"        → METERED against the SAME per-grant credit pool that
//     /generate spends (consume_trial_credit). Farmable trial credentials riding
//     this previously-unmetered endpoint were the cost-abuse vector (X-01); the
//     fix bounds a trial identity's free-endpoint spend to its 30-credit grant.
//     The trial path mirrors generate's money-safety ordering exactly:
//       slot (cap-1) → idempotent replay → floor gate (≥1 credit) → chat →
//       consume the metered charge on success only → cache for retry.
//     A trial is also PINNED to the cheapest model (limits.modelForConvert): a
//     structured rewrite gains nothing from the priciest models.
// FAIL CLOSED: any credit-lookup error on the trial path REFUSES rather than
// serving a free provider call.
//
// PRIVACY: source text and context are processed in memory and never persisted,
// EXCEPT the documented §14.5 idempotency carve-out (the trial retry cache, the
// same time-bounded mechanism /generate uses). The console log carries token
// counts only, never content.
//
// This phase imports the model registry, provider adapters, cost meter, and
// billing store from generate/** READ-ONLY (one registry, one ledger — no
// duplicate, no parallel trial ledger).
// =============================================================================

import { json } from "../_shared/http.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { conversionSystemPrompt } from "./prompt.ts";
import { modelForConvert, validateConvertBody } from "./limits.ts";
import { type ModelEntry, modelById } from "../generate/models.ts";
import { chatCostUsd, creditCostForModel } from "../generate/cost.ts";
import { type ChatClient, type ChatResult, ProviderError } from "../generate/providers/types.ts";
import type { IdempotentResult, TrialGrantRow } from "../generate/store.ts";
import {
  CONVERT_IDEMPOTENCY_TTL_SECONDS,
  CONVERT_MAX_PAYLOAD_BYTES,
  CONVERT_RATE_LIMIT_PER_IDENTITY,
  CONVERT_RATE_LIMIT_WINDOW_SECONDS,
  CONVERT_SLOT_STALE_SECONDS,
} from "./config.ts";

/** The store operations convert needs. SupabaseBillingStore satisfies this
 *  structurally; tests inject a stub. The trial-metering operations are the SAME
 *  per-grant RPCs /generate uses (no parallel ledger) — used only on the trial
 *  path; a subscription request touches just `rateLimitOk`. */
export interface ConvertStore {
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
  // ---- Trial metering (X-01) — the exact per-grant primitives generate spends.
  loadTrialGrant(grantId: string): Promise<TrialGrantRow | null>;
  trialCreditsRemaining(grantId: string): Promise<number>;
  consumeTrialCredit(grantId: string, credits: number): Promise<number | null>;
  acquireTrialSlot(grantId: string, staleSeconds: number): Promise<boolean>;
  releaseTrialSlot(grantId: string): Promise<void>;
  getIdempotent(identityKey: string, idemKey: string, ttlSeconds: number): Promise<IdempotentResult | null>;
  putIdempotent(identityKey: string, idemKey: string, value: IdempotentResult, ttlSeconds: number): Promise<void>;
}

export interface ConvertDeps {
  store: ConvertStore;
  /** Chat client factory — same contract as generate's: may THROW for a
   *  provider whose key is unset, mapped to a clean 503 here. */
  makeChat: (provider: string, model: string) => ChatClient;
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

/** The client-minted idempotency key (one per recording, reused across retries),
 *  or null. Same discipline as generate — used on the metered trial path so a
 *  charged-but-dropped response is replayed on retry WITHOUT a second charge. */
function idempotencyKey(req: Request): string | null {
  const v = req.headers.get("Idempotency-Key");
  const trimmed = v?.trim();
  return trimmed ? trimmed : null;
}

export async function handleConvert(req: Request, deps: ConvertDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 1. Cheapest gate first: cap the raw body before parsing.
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > CONVERT_MAX_PAYLOAD_BYTES) return json({ error: "payload_too_large" }, 413);

  // 2. Verify OUR session JWT — identical gate to generate's.
  const token = bearer(req);
  if (!token) return json({ error: "missing_token" }, 401);
  const claims = await verifySessionToken(token, deps.jwtSecret, deps.nowSeconds);
  if (!claims) return json({ error: "invalid_token" }, 401);
  if (claims.kind !== "subscription" && claims.kind !== "trial") {
    return json({ error: "unsupported_token_kind" }, 401);
  }

  // 3. Parse the (size-capped) body.
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  // 4. Input fuse — caps + model gate, before any provider work.
  const parsed = validateConvertBody(body);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.status);
  const { sourceText, context } = parsed.value;

  // 4.5 Resolve the EFFECTIVE model → provider. A trial token is pinned to the
  //     cheapest enabled model (X-01 / B-01) regardless of the client's selection;
  //     a subscription token keeps its choice. validateConvertBody already gated
  //     the requested model on ALLOWED_MODELS; a miss on the resolved model is
  //     registry drift — reject defensively (same posture as generate step 5.5).
  const model = modelForConvert(claims.kind, parsed.value.model);
  const modelEntry = modelById(model);
  if (!modelEntry) return json({ error: "invalid_model" }, 400);

  // 5. Per-identity rate limit — keyed per identity under a `convert:` prefix so
  //    it can't collide with (or eat into) generate's window.
  const key = claims.kind === "trial" ? `convert:trial:${claims.sub}` : `convert:sub:${claims.sub}`;
  const withinRate = await deps.store.rateLimitOk(
    key,
    CONVERT_RATE_LIMIT_PER_IDENTITY,
    CONVERT_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!withinRate) return json({ error: "rate_limited" }, 429);

  // 6. The conversion input: source text, then the Attached Context block when
  //    present (the same separator the prompt's input description assumes).
  const userText = context ? `${sourceText}\n\n${context}` : sourceText;

  // 7. Cost policy split. A subscription stays on the original FREE, stateless
  //    path; a trial runs the metered path against its per-grant pool.
  if (claims.kind === "trial") {
    return await meteredTrialConvert(deps, claims.sub, key, model, modelEntry, userText, idempotencyKey(req));
  }

  // --- Subscription (free) path: unchanged from the original handler. ---------
  const r = await runConversionChat(deps, modelEntry.provider, model, userText);
  if (!r.ok) return r.res;
  console.log(JSON.stringify({
    fn: "convert",
    key,
    model,
    provider: modelEntry.provider,
    tokens_in: r.chat.inputTokens,
    tokens_out: r.chat.outputTokens,
  }));
  return json({ prompt: r.chat.content }, 200);
}

// -----------------------------------------------------------------------------
// Trial metered path (X-01). Mirrors generate's money-safety ordering so a
// farmed trial credential can't ride convert for unbounded provider spend: its
// total free-endpoint spend is bounded to the grant's per-grant credit pool.
// -----------------------------------------------------------------------------
async function meteredTrialConvert(
  deps: ConvertDeps,
  grantId: string,
  key: string,
  model: string,
  modelEntry: ModelEntry,
  userText: string,
  idemKey: string | null,
): Promise<Response> {
  // Resolve + authorize the grant. FAIL CLOSED: a load error refuses rather than
  // serving a free provider call. The trial token is only minted for a verified
  // grant, but (like generate's resolveTrial) the gate is re-checked here.
  let grant: TrialGrantRow | null;
  try {
    grant = await deps.store.loadTrialGrant(grantId);
  } catch (e) {
    console.error(JSON.stringify({ fn: "convert", key, error: "grant_lookup_failed", detail: String(e) }));
    return json({ error: "credit_check_failed", retryable: true }, 503);
  }
  if (!grant) return json({ error: "not_found" }, 404);
  if (!grant.verified_at) return json({ error: "not_entitled" }, 403);

  // Concurrency cap = 1 (the SAME trial slot generate holds). This is what makes
  // check-then-consume safe: a single grant can't have two metered calls passing
  // the floor gate before either consumes. convert runs only AFTER a generation
  // returns, so it never genuinely contends with that grant's /generate.
  const gotSlot = await deps.store.acquireTrialSlot(grantId, CONVERT_SLOT_STALE_SECONDS);
  if (!gotSlot) return json({ error: "conversion_in_progress" }, 429);

  try {
    // Idempotent replay (M1 discipline): a retry carrying the same key replays
    // the cached prompt with NO second charge. Checked inside the slot and BEFORE
    // the floor gate (a retry of a charged conversion must not be rejected as
    // out_of_credits once that charge zeroed the balance). getIdempotent fails
    // OPEN (null) on infra error — a broken cache must never block, only re-run.
    if (idemKey) {
      const cached = await deps.store.getIdempotent(key, idemKey, CONVERT_IDEMPOTENCY_TTL_SECONDS);
      if (cached) return json({ prompt: cached.prompt }, 200);
    }

    // Floor gate — refuse a grant that can't afford even the 1-credit floor of a
    // successful conversion. FAIL CLOSED on a lookup error.
    let remaining: number;
    try {
      remaining = await deps.store.trialCreditsRemaining(grantId);
    } catch (e) {
      console.error(JSON.stringify({ fn: "convert", key, error: "credit_lookup_failed", detail: String(e) }));
      return json({ error: "credit_check_failed", retryable: true }, 503);
    }
    if (remaining < 1) {
      return json({ error: "out_of_credits", credits_remaining: remaining }, 402);
    }

    // The conversion call. A provider failure (incl. an output-cap truncation)
    // charges NOTHING — we consume only on a fully usable result (mirrors generate).
    const r = await runConversionChat(deps, modelEntry.provider, model, userText);
    if (!r.ok) return r.res;

    // Meter the REAL chat cost (no STT on this endpoint) and consume from the
    // grant — `ceil(cost / $0.01)`, floor 1, same as generate.
    const estCost = chatCostUsd(modelEntry.provider, model, r.chat.inputTokens, r.chat.outputTokens);
    const credits = creditCostForModel(model, estCost);
    let after: number | null;
    try {
      after = await deps.store.consumeTrialCredit(grantId, credits);
    } catch (e) {
      // The provider WAS paid, but the money-safety rule is absolute: never return
      // a prompt we couldn't charge for. Refuse (no free result, nothing cached).
      console.error(JSON.stringify({ fn: "convert", key, error: "consume_failed", detail: String(e) }));
      return json({ error: "server_error" }, 500);
    }
    if (after === null) {
      // DEFENSIVE: consume_trial_credit returns null only for a missing/unverified
      // grant — already excluded above, so this is a since-deleted mid-flight race.
      // Provider paid; refuse rather than hand over a free result.
      console.error(JSON.stringify({ fn: "convert", key, error: "consume_non_spendable", model }));
      return json({ error: "out_of_credits", credits_remaining: 0 }, 402);
    }

    // Cache the charged result for an idempotent retry — best-effort, like generate.
    if (idemKey) {
      await deps.store.putIdempotent(key, idemKey, {
        prompt: r.chat.content,
        usage: { input_tokens: r.chat.inputTokens, output_tokens: r.chat.outputTokens, model: r.chat.model },
        creditsRemaining: after,
        creditsCharged: credits,
      }, CONVERT_IDEMPOTENCY_TTL_SECONDS);
    }

    console.log(JSON.stringify({
      fn: "convert",
      key,
      kind: "trial",
      model,
      provider: modelEntry.provider,
      tokens_in: r.chat.inputTokens,
      tokens_out: r.chat.outputTokens,
      credits_charged: credits,
      credits_remaining: after,
    }));

    // Response shape is identical to the subscription path ({ prompt }); the
    // metering is server-side only (the next /generate reflects the balance).
    return json({ prompt: r.chat.content }, 200);
  } finally {
    // Always free the slot — success, reject, or throw.
    await deps.store.releaseTrialSlot(grantId);
  }
}

/** Build the chat client and run the server-owned conversion call. Returns the
 *  ChatResult, or a ready-to-send error Response (a 503 for an unset provider key,
 *  the generate-style provider-error mapping otherwise). Shared by both paths so
 *  the prompt + error mapping stay identical across subscription and trial. */
async function runConversionChat(
  deps: ConvertDeps,
  provider: string,
  model: string,
  userText: string,
): Promise<{ ok: true; chat: ChatResult } | { ok: false; res: Response }> {
  let chatClient: ChatClient;
  try {
    chatClient = deps.makeChat(provider, model);
  } catch (e) {
    console.error(JSON.stringify({ fn: "convert", error: "make_chat_failed", model, provider, detail: String(e) }));
    return { ok: false, res: json({ error: "provider_unavailable", retryable: false }, 503) };
  }
  try {
    const chat = await chatClient.chat(conversionSystemPrompt(), [{ type: "text", text: userText }]);
    return { ok: true, chat };
  } catch (e) {
    return { ok: false, res: providerErrorResponse(e) };
  }
}

/** Provider failure → client response, exactly generate's mapping: output-cap
 *  truncation → 422, transient → 503 retryable, terminal → 502, unexpected → 500. */
function providerErrorResponse(e: unknown): Response {
  if (e instanceof ProviderError) {
    // Output-cap truncation → 422: withhold the (partial) prompt — it can carry an
    // unterminated <<<ZERRO_ARTIFACT fence (handoff-artifact-fence-leak). Reachable
    // now that convert pins a server-side output cap (B-04); mirrors generate's map.
    if (e.truncated) return json({ error: "response_truncated", retryable: false }, 422);
    if (e.retryable) return json({ error: "provider_unavailable", retryable: true }, 503);
    return json({ error: "generation_failed", retryable: false }, 502);
  }
  console.error(JSON.stringify({ fn: "convert", error: String(e) }));
  return json({ error: "server_error" }, 500);
}
