// =============================================================================
// trial-start — email-gated, server-funded trial credits (Phase F).
// =============================================================================
// An UNAUTHENTICATED public endpoint (deployed --no-verify-jwt): there's no
// Supabase JWT and no license key yet — the user is mid-trial and has nothing
// to present. The anti-abuse controls are: a per-email + per-IP rate limit, a
// hashed short-TTL attempt-limited code, a disposable-domain block, and — the
// hard cap — one server-funded grant per VERIFIED email (verify_trial_grant +
// the email_normalized UNIQUE), so reinstalling never farms fresh credits. A
// SECOND hard cap closes the "different emails, same Mac" hole: each grant is
// bound to a hashed hardware id (`device_id_hash`), so a device that already
// trialed is blocked regardless of which email it presents (the partial unique
// index on device_id_hash is the race backstop). The device hash is optional +
// tolerated-missing (old builds / unreadable UUID degrade to the email cap) and
// kill-switchable via TRIAL_DEVICE_BINDING_ENABLED.
//
// Two actions on one function (dispatched on the `action` field):
//   request — { action:"request", email } → normalize, block disposables,
//             rate-limit, generate a 6-digit code, store its HASH with a short
//             TTL, and email it via Resend. Returns { status:"code_sent" } —
//             UNIFORMLY (C-05): an already-exhausted email gets the SAME body
//             with no send, so `request` never works as an email-enumeration
//             oracle; the true already_used only surfaces at verify/resume,
//             after the caller proves control of the mailbox.
//   verify  — { action:"verify", email, code } → look up the pending code,
//             constant-time compare the hash, check TTL + attempts, then
//             create-once the grant (verify_trial_grant) and mint a short-lived
//             TRIAL session token. Returns { token, expires_at,
//             trial_credits_remaining, trial_credits_limit }.
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
  TRIAL_DEVICE_BINDING_ENABLED,
  TRIAL_RATE_LIMIT_PER_EMAIL,
  TRIAL_RATE_LIMIT_PER_IP,
  TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  TRIAL_SEND_LIMIT_PER_EMAIL,
  TRIAL_SEND_WINDOW_SECONDS,
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

/** Combined per-email + per-IP rate gate. TRUE = allowed. C-07: the two keys
 * carry DIFFERENT limiter-error postures (the old blanket fail-open silently
 * disabled every abuse bound whenever check_rate_limit broke). */
async function withinRate(store: TrialStore, email: string, ip: string): Promise<boolean> {
  // Hash the email into the rate-limit key so the limiter table never holds a
  // raw address. Per-email fails OPEN on limiter error: this key also meters
  // legitimate verify retries, so a limiter outage must not lock a real user
  // out of a code already sitting in their inbox — the per-IP and send caps
  // (both fail-closed) still bound abuse during the outage.
  const emailKeyHash = await sha256Hex(email);
  const okEmail = await store.rateLimitOk(
    `trial:email:${emailKeyHash}`,
    TRIAL_RATE_LIMIT_PER_EMAIL,
    TRIAL_RATE_LIMIT_WINDOW_SECONDS,
    "allow",
    "email",
  );
  if (!okEmail) return false;
  // Per-IP fails CLOSED: it is the broad anti-abuse bound on an
  // unauthenticated endpoint, so a broken limiter must not silently erase it.
  const okIp = await store.rateLimitOk(
    `trial:ip:${ip}`,
    TRIAL_RATE_LIMIT_PER_IP,
    TRIAL_RATE_LIMIT_WINDOW_SECONDS,
    "deny",
    "ip",
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

  // The hashed hardware id (trial device binding). Optional + tolerated-missing
  // so old app builds (no `device_id_hash`) and rare unreadable-UUID clients
  // degrade to the email-only cap. The kill switch ignores it entirely when off.
  const deviceIdHash = readDeviceIdHash(body);

  // resume grants nothing new and is email-keyed, so the device hash is
  // telemetry-only there — handled inside handleResume (no behavioral change).
  if (isResume) return await handleResume(deps, email);
  return isVerify
    ? await handleVerify(deps, email, body, deviceIdHash)
    : await handleRequest(deps, email, deviceIdHash);
}

/** Read + sanitize the optional `device_id_hash` from the body. Returns null
 * when binding is disabled, the field is missing, or it isn't a plausible
 * SHA-256 hex digest — so a malformed value never poisons the device cap. */
function readDeviceIdHash(body: Record<string, unknown>): string | null {
  if (!TRIAL_DEVICE_BINDING_ENABLED) return null;
  const raw = body.device_id_hash;
  if (typeof raw !== "string") return null;
  const hex = raw.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(hex) ? hex : null;
}

/** Structured device-block telemetry: the hashed device id only — never an email
 * or a raw UUID (tier-only analytics rule). Greppable in the function logs; a
 * PostHog event can be layered on via the shared `capturePostHog` helper. */
function logDeviceBlock(phase: "request" | "verify", deviceIdHash: string): void {
  console.log(JSON.stringify({
    fn: "trial-start",
    event: "trial_device_block",
    phase,
    device_id_hash: deviceIdHash,
  }));
}

// -----------------------------------------------------------------------------
// request — issue + email a code.
// -----------------------------------------------------------------------------
async function handleRequest(
  deps: TrialStartDeps,
  email: string,
  deviceIdHash: string | null,
): Promise<Response> {
  if (isDisposableEmail(email)) {
    return json({ error: "disposable_email" }, 422);
  }

  // Trial device binding: if THIS Mac already trialed under a DIFFERENT email,
  // hard-block here — BEFORE generating/emailing a code (saves the mail + gives
  // instant UX). A grant under the SAME email is a legitimate reinstall and
  // falls through to the normal re-verify path below.
  if (deviceIdHash && (await deps.store.deviceAlreadyGranted(deviceIdHash, email))) {
    logDeviceBlock("request", deviceIdHash);
    return json({ status: "device_trial_used" }, 200);
  }

  // One grant per email, ever. If this email already verified AND spent all its
  // credits, a new code can't unlock anything — but DON'T say so here. C-05:
  // `request` answers an unauthenticated prober, so every email state
  // (brand-new, verified-with-credits, exhausted) gets the SAME
  // { status: "code_sent" }; for the exhausted email we just skip the send.
  // The true already_used still surfaces — at verify/resume, AFTER the caller
  // proves control of the mailbox. (The early returns above are NOT email
  // oracles: device_trial_used reflects the caller's own device and
  // disposable_email the domain's class, not this address's trial state.)
  const grant = await deps.store.loadGrantByEmail(email);
  if (grant && grant.verified_at) {
    const remaining = Math.max(0, grant.trial_credits_limit - grant.trial_credits_used);
    if (remaining <= 0) {
      return json({ status: "code_sent" }, 200);
    }
    // Verified but with credits left (e.g. the app lost its in-memory token on
    // reinstall): allow a re-request → re-verify to re-mint a token. This grants
    // NO new credits (verify_trial_grant never resets) — the code is still the
    // gate.
  }

  // C-05 email-bomb sub-limit: a second, TIGHTER per-email counter consumed
  // only when a code email is actually about to go out (every ineligible path
  // has already returned) — the request limiter in withinRate is shared with
  // verify/resume and sized for that, so it alone lets a code-request loop
  // bomb one inbox. Hashed-email key: the limiter table never holds a raw
  // address (mirrors withinRate). Past the cap we SKIP the send but still
  // answer the uniform code_sent — surfacing the throttle would re-open the
  // very oracle the uniform response closes. Checked BEFORE the code upsert
  // so an over-limit request can't clobber the still-valid code from the last
  // real send. C-07: fails CLOSED on limiter error — this gate only stops
  // outbound mail, so a broken limiter must not re-open the email-bomb; the
  // deny path below still answers the uniform code_sent, so nothing leaks.
  const sendKeyHash = await sha256Hex(email);
  const sendOk = await deps.store.rateLimitOk(
    `trial:send:${sendKeyHash}`,
    TRIAL_SEND_LIMIT_PER_EMAIL,
    TRIAL_SEND_WINDOW_SECONDS,
    "deny",
    "send",
  );
  if (!sendOk) {
    return json({ status: "code_sent" }, 200);
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
  deviceIdHash: string | null,
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

  // Correct code — consume it (single use) and establish the grant, atomically
  // enforcing the one-grant-per-device cap (the partial unique index is the race
  // backstop behind verify_trial_grant).
  await deps.store.deleteCode(email);
  const result = await deps.store.verifyGrant(email, TRIAL_CREDITS, deviceIdHash);

  // This Mac already trialed under a different email → hard block (mirrors the
  // `request` early-block for the race where two emails verify near-simultaneously
  // or the app skipped straight to verify).
  if (result.deviceBlocked) {
    if (deviceIdHash) logDeviceBlock("verify", deviceIdHash);
    return json({ status: "device_trial_used" }, 200);
  }
  const { grantId, creditsRemaining } = result;

  // A re-verify of an already-exhausted grant: nothing to authorize.
  if (creditsRemaining <= 0) {
    return json({ status: "already_used" }, 200);
  }

  // E4: the response carries the grant TOTAL so the app's trial meter has a
  // denominator. Read it back rather than assuming TRIAL_CREDITS — an existing
  // grant keeps the limit it was created with even if the env value changed.
  const grant = await deps.store.loadGrantByEmail(email);
  const creditsLimit = grant?.trial_credits_limit ?? TRIAL_CREDITS;

  return await mintTokenResponse(deps, grantId, creditsRemaining, creditsLimit, nowSeconds);
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
  return await mintTokenResponse(deps, grant.id, remaining, grant.trial_credits_limit, nowSeconds);
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
  creditsLimit: number,
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
      // E4: the grant total, so the trial usage meter can draw a proportional
      // bar instead of a bare count (the app must not hardcode 30).
      trial_credits_limit: creditsLimit,
      // The opaque grant id (same value as the token's `sub`). The app caches it
      // and passes it through checkout custom_data on conversion, so the
      // lemonsqueezy-webhook can link this grant to the new subscription EXACTLY
      // (the email-normalization fallback then covers older/absent clients). Not
      // a secret — it already travels inside the token's `sub` claim.
      trial_grant_id: grantId,
    },
    200,
  );
}
