// =============================================================================
// trial-start — email-gated, server-funded trial credits (Phase F).
// =============================================================================
// An UNAUTHENTICATED public endpoint (deployed --no-verify-jwt): there's no
// Supabase JWT and no license key yet — the user is mid-trial and has nothing
// to present. The anti-abuse controls are: a per-email + per-IP rate limit, a
// hashed short-TTL attempt-limited code, a disposable-domain block, and — the
// hard cap — one server-funded grant per VERIFIED email (verify_trial_grant +
// the email_normalized UNIQUE), so reinstalling never farms fresh credits.
//
// Two actions on one function (dispatched on the `action` field):
//   request — { action:"request", email } → normalize, block disposables,
//             rate-limit, (refuse if this email already used its trial),
//             generate a 6-digit code, store its HASH with a short TTL, and
//             email it via Resend. Returns { status:"code_sent" }.
//   verify  — { action:"verify", email, code } → look up the pending code,
//             constant-time compare the hash, check TTL + attempts, then
//             create-once the grant (verify_trial_grant) and mint a short-lived
//             TRIAL session token. Returns { token, expires_at,
//             trial_credits_remaining }.
//   resume  — { action:"resume", email } → look up the grant by email_normalized
//             and, if it's already VERIFIED, mint a FRESH token against the
//             persisted balance with NO emailed code (the H1 fix: email is
//             verified exactly once, ever; token expiry is a silent background
//             refresh, never a re-verify). No grant → { status:"needs_verification" }
//             so the client routes to the genuine first-time email+code flow.
//             resume creates no grant and no credits, so the per-email abuse cap
//             is unchanged.
//
// The raw email never travels to `generate` — the trial token carries only the
// opaque trial_grants row id, exactly as the subscription token carries the
// subscription id.
//
// Deps are injected (store, email sender, jwt secret, clock) so the handler is
// fully unit-testable with an in-memory store + stub email sender, sending no
// real mail and writing no real rows.
// =============================================================================

import { json } from "../_shared/http.ts";
import { sha256Hex, timingSafeEqual } from "../_shared/crypto.ts";
import { signSessionToken } from "../_shared/jwt.ts";
import { EmailSendError, type EmailSender } from "./resend.ts";
import { generateCode, isDisposableEmail, normalizeEmail } from "./email.ts";
import type { TrialStore } from "./store.ts";
import {
  CODE_MAX_ATTEMPTS,
  CODE_TTL_SECONDS,
  TRIAL_CREDITS,
  TRIAL_RATE_LIMIT_PER_EMAIL,
  TRIAL_RATE_LIMIT_PER_IP,
  TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  TRIAL_TOKEN_TTL_SECONDS,
} from "./config.ts";

export interface TrialStartDeps {
  store: TrialStore;
  email: EmailSender;
  jwtSecret: string;
  /** Injectable clock (epoch seconds) for deterministic TTL + token tests. */
  nowSeconds?: number;
}

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

/** Combined per-email + per-IP rate gate. TRUE = allowed. */
async function withinRate(store: TrialStore, email: string, ip: string): Promise<boolean> {
  // Hash the email into the rate-limit key so the limiter table never holds a
  // raw address.
  const emailKeyHash = await sha256Hex(email);
  const okEmail = await store.rateLimitOk(
    `trial:email:${emailKeyHash}`,
    TRIAL_RATE_LIMIT_PER_EMAIL,
    TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!okEmail) return false;
  const okIp = await store.rateLimitOk(
    `trial:ip:${ip}`,
    TRIAL_RATE_LIMIT_PER_IP,
    TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  );
  return okIp;
}

export async function handleTrialStart(req: Request, deps: TrialStartDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  const action = String(body.action ?? "");
  // Tolerate the implicit form too: a body with `code` is a verify.
  const isVerify = action === "verify" || (action === "" && body.code !== undefined);
  const isResume = action === "resume";
  if (!isVerify && !isResume && action !== "request") {
    return json({ error: "invalid_action" }, 400);
  }

  const email = normalizeEmail(String(body.email ?? ""));
  if (!email) return json({ error: "invalid_email" }, 400);

  const ip = clientIp(req);
  if (!(await withinRate(deps.store, email, ip))) {
    return json({ error: "rate_limited" }, 429);
  }

  if (isResume) return await handleResume(deps, email);
  return isVerify
    ? await handleVerify(deps, email, body)
    : await handleRequest(deps, email);
}

// -----------------------------------------------------------------------------
// request — issue + email a code.
// -----------------------------------------------------------------------------
async function handleRequest(deps: TrialStartDeps, email: string): Promise<Response> {
  if (isDisposableEmail(email)) {
    return json({ error: "disposable_email" }, 422);
  }

  // One grant per email, ever. If this email already verified AND spent all its
  // credits, refuse up front — no point emailing a code it can't use.
  const grant = await deps.store.loadGrantByEmail(email);
  if (grant && grant.verified_at) {
    const remaining = Math.max(0, grant.trial_credits_limit - grant.trial_credits_used);
    if (remaining <= 0) {
      return json({ status: "already_used" }, 200);
    }
    // Verified but with credits left (e.g. the app lost its in-memory token on
    // reinstall): allow a re-request → re-verify to re-mint a token. This grants
    // NO new credits (verify_trial_grant never resets) — the code is still the
    // gate.
  }

  const nowSeconds = deps.nowSeconds ?? Math.floor(Date.now() / 1000);
  const code = generateCode();
  const codeHash = await sha256Hex(code);
  const expiresAt = new Date((nowSeconds + CODE_TTL_SECONDS) * 1000);
  await deps.store.upsertCode(email, codeHash, expiresAt);

  try {
    await deps.email.sendCode(email, code);
  } catch (e) {
    if (e instanceof EmailSendError) {
      // Couldn't deliver — surface so the app shows "couldn't send code, try
      // again". The stored code is harmless (it expires); a retry overwrites it.
      return json({ error: "send_failed" }, 502);
    }
    throw e;
  }

  return json({ status: "code_sent" }, 200);
}

// -----------------------------------------------------------------------------
// verify — check the code, create the grant once, mint a trial token.
// -----------------------------------------------------------------------------
async function handleVerify(
  deps: TrialStartDeps,
  email: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const code = String(body.code ?? "").trim();
  if (!/^\d{6}$/.test(code)) return json({ error: "invalid_code" }, 400);

  const pending = await deps.store.loadCode(email);
  if (!pending) return json({ error: "invalid_code" }, 400);

  const nowSeconds = deps.nowSeconds ?? Math.floor(Date.now() / 1000);
  const nowMs = nowSeconds * 1000;

  // Expired → burn it and tell the app to request a new one.
  if (new Date(pending.expires_at).getTime() <= nowMs) {
    await deps.store.deleteCode(email);
    return json({ error: "code_expired" }, 400);
  }

  // Attempt cap reached → burn it (forces a fresh request, defeating brute
  // force within the TTL).
  if (pending.attempts >= CODE_MAX_ATTEMPTS) {
    await deps.store.deleteCode(email);
    return json({ error: "too_many_attempts" }, 429);
  }

  // Constant-time compare of the HASHES (never the raw code).
  const codeHash = await sha256Hex(code);
  if (!timingSafeEqual(codeHash, pending.code_hash)) {
    await deps.store.incrementCodeAttempts(email);
    return json({ error: "invalid_code" }, 400);
  }

  // Correct code — consume it (single use) and establish the grant.
  await deps.store.deleteCode(email);
  const { grantId, creditsRemaining } = await deps.store.verifyGrant(email, TRIAL_CREDITS);

  // A re-verify of an already-exhausted grant: nothing to authorize.
  if (creditsRemaining <= 0) {
    return json({ status: "already_used" }, 200);
  }

  return await mintTokenResponse(deps, grantId, creditsRemaining, nowSeconds);
}

// -----------------------------------------------------------------------------
// resume — re-mint a token for an ALREADY-verified email, no code required (H1).
// -----------------------------------------------------------------------------
// "Verified" is a permanent server-side fact (the per-email grant), NOT the
// liveness of the ≤30-min token. A previously-verified email gets a fresh token
// silently, so token expiry never forces re-proving ownership. This only READS
// the grant — it creates no grant and no credits, so the per-email cap (the real
// abuse bound) is unchanged.
async function handleResume(deps: TrialStartDeps, email: string): Promise<Response> {
  const grant = await deps.store.loadGrantByEmail(email);

  // No grant, or one that never completed verification → genuine first-time
  // verification required. Do NOT auto-create a grant; signal the client to run
  // the normal email+code flow.
  if (!grant || !grant.verified_at) {
    return json({ status: "needs_verification" }, 200);
  }

  // Verified but the pool is spent → nothing to authorize (mirrors verify).
  const remaining = Math.max(0, grant.trial_credits_limit - grant.trial_credits_used);
  if (remaining <= 0) {
    return json({ status: "already_used" }, 200);
  }

  const nowSeconds = deps.nowSeconds ?? Math.floor(Date.now() / 1000);
  return await mintTokenResponse(deps, grant.id, remaining, nowSeconds);
}

// -----------------------------------------------------------------------------
// Shared token mint + response shaping (verify AND resume).
// -----------------------------------------------------------------------------
// The ONE place a trial token + its success body are produced, so the expires_at
// guard necessarily covers BOTH paths — no parallel mint that could drift.
async function mintTokenResponse(
  deps: TrialStartDeps,
  grantId: string,
  creditsRemaining: number,
  nowSeconds: number,
): Promise<Response> {
  // Mint a short-lived TRIAL session token. `sub` is the opaque grant id; no
  // tier (trial has none). The app sends THIS to /generate, never the email.
  const { token, exp } = await signSessionToken(
    { sub: grantId, kind: "trial" },
    deps.jwtSecret,
    TRIAL_TOKEN_TTL_SECONDS,
    nowSeconds,
  );

  // The expires_at guard — the highest-leverage line in the H1 fix. The client
  // treats a nil/unparseable/past expires_at as "expires in 60 seconds", which
  // would re-gate every user almost immediately. A token must NEVER be emitted
  // without a well-formed FUTURE expiry. This holds by construction (exp = now +
  // TTL, with TTL > 0), but we assert it so a misconfigured TRIAL_TOKEN_TTL
  // fails LOUDLY here instead of silently re-gating every client.
  if (!Number.isFinite(exp) || exp <= nowSeconds) {
    console.error(
      JSON.stringify({ fn: "trial-start", op: "mint", error: "non_future_exp", exp, nowSeconds }),
    );
    return json({ error: "server_error" }, 500);
  }

  return json(
    {
      token,
      expires_at: new Date(exp * 1000).toISOString(),
      trial_credits_remaining: creditsRemaining,
    },
    200,
  );
}
