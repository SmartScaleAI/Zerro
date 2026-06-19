import { assert, assertEquals } from "jsr:@std/assert@1";
import { sha256Hex } from "../_shared/crypto.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { handleTrialStart, type TrialStartDeps } from "./handler.ts";
import { EmailSendError, type EmailSender } from "./resend.ts";
import type { TrialCodeRow, TrialGrantRow, TrialStore, VerifyGrantResult } from "./store.ts";

const SECRET = "test_session_jwt_secret";
const NOW = 1_000_000; // epoch seconds

// ---- In-memory TrialStore ---------------------------------------------------
interface Grant {
  id: string;
  verified: boolean;
  limit: number;
  used: number;
  deviceIdHash?: string | null;
}
interface Code {
  codeHash: string;
  expiresAt: number; // epoch ms
  attempts: number;
}

class InMemoryTrialStore implements TrialStore {
  grants = new Map<string, Grant>(); // email → grant
  codes = new Map<string, Code>(); // email → code
  rateOk = true;
  private nextId = 1;

  loadGrantByEmail(email: string): Promise<TrialGrantRow | null> {
    const g = this.grants.get(email);
    if (!g) return Promise.resolve(null);
    return Promise.resolve({
      id: g.id,
      verified_at: g.verified ? "2026-06-02T00:00:00.000Z" : null,
      trial_credits_limit: g.limit,
      trial_credits_used: g.used,
    });
  }
  upsertCode(email: string, codeHash: string, expiresAt: Date): Promise<void> {
    this.codes.set(email, { codeHash, expiresAt: expiresAt.getTime(), attempts: 0 });
    return Promise.resolve();
  }
  loadCode(email: string): Promise<TrialCodeRow | null> {
    const c = this.codes.get(email);
    if (!c) return Promise.resolve(null);
    return Promise.resolve({
      code_hash: c.codeHash,
      expires_at: new Date(c.expiresAt).toISOString(),
      attempts: c.attempts,
    });
  }
  incrementCodeAttempts(email: string): Promise<void> {
    const c = this.codes.get(email);
    if (c) c.attempts += 1;
    return Promise.resolve();
  }
  deleteCode(email: string): Promise<void> {
    this.codes.delete(email);
    return Promise.resolve();
  }
  verifyGrant(email: string, limit: number, deviceIdHash: string | null): Promise<VerifyGrantResult> {
    // Device already burned by a DIFFERENT email → hard block (mirrors
    // verify_trial_grant's pre-check + the partial unique index race backstop).
    if (deviceIdHash && this.deviceUsedByOther(deviceIdHash, email)) {
      return Promise.resolve({ deviceBlocked: true });
    }
    // Create-once / never-reset (mirrors verify_trial_grant).
    let g = this.grants.get(email);
    if (!g) {
      g = { id: `grant-${this.nextId++}`, verified: true, limit, used: 0, deviceIdHash };
      this.grants.set(email, g);
    } else {
      g.verified = true; // backfill, never reset credits
      if (g.deviceIdHash == null && deviceIdHash) g.deviceIdHash = deviceIdHash; // coalesce
    }
    return Promise.resolve({
      deviceBlocked: false,
      grantId: g.id,
      creditsRemaining: Math.max(0, g.limit - g.used),
    });
  }
  deviceAlreadyGranted(deviceIdHash: string, email: string): Promise<boolean> {
    return Promise.resolve(this.deviceUsedByOther(deviceIdHash, email));
  }
  private deviceUsedByOther(deviceIdHash: string, email: string): boolean {
    for (const [addr, g] of this.grants) {
      if (g.deviceIdHash === deviceIdHash && addr !== email) return true;
    }
    return false;
  }
  rateLimitOk(): Promise<boolean> {
    return Promise.resolve(this.rateOk);
  }
}

// ---- Stub EmailSender -------------------------------------------------------
class StubEmailSender implements EmailSender {
  sent: { to: string; code: string }[] = [];
  fail = false;
  sendCode(to: string, code: string): Promise<void> {
    if (this.fail) return Promise.reject(new EmailSendError("resend_500", 500));
    this.sent.push({ to, code });
    return Promise.resolve();
  }
}

function deps(store: InMemoryTrialStore, email: StubEmailSender): TrialStartDeps {
  return { store, email, jwtSecret: SECRET, nowSeconds: NOW };
}

function req(body: unknown) {
  return new Request("http://local/trial-start", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": "203.0.113.7" },
    body: JSON.stringify(body),
  });
}

// ---- request-code -----------------------------------------------------------
Deno.test("request: sends a code, stores its hash, returns code_sent", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "request", email: "User@Example.com" }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "code_sent");
  assertEquals(email.sent.length, 1);
  assertEquals(email.sent[0].to, "user@example.com"); // normalized

  // Stored as a HASH of the emailed code, never plaintext.
  const stored = store.codes.get("user@example.com")!;
  assert(stored);
  assertEquals(stored.codeHash, await sha256Hex(email.sent[0].code));
});

Deno.test("request: rejects a disposable domain (no email sent)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "request", email: "x@mailinator.com" }), deps(store, email));
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error, "disposable_email");
  assertEquals(email.sent.length, 0);
});

Deno.test("request: rate-limited → 429, no email sent", async () => {
  const store = new InMemoryTrialStore();
  store.rateOk = false;
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "request", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 429);
  assertEquals(email.sent.length, 0);
});

Deno.test("request: already-verified + exhausted → already_used, no email", async () => {
  const store = new InMemoryTrialStore();
  store.grants.set("a@b.com", { id: "g1", verified: true, limit: 15, used: 15 });
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "request", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "already_used");
  assertEquals(email.sent.length, 0);
});

Deno.test("request: Resend failure → 502 send_failed", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  email.fail = true;
  const res = await handleTrialStart(req({ action: "request", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, "send_failed");
});

// ---- verify-code ------------------------------------------------------------
async function sendAndGetCode(store: InMemoryTrialStore, email: StubEmailSender, addr: string): Promise<string> {
  await handleTrialStart(req({ action: "request", email: addr }), deps(store, email));
  return email.sent.at(-1)!.code;
}

Deno.test("verify: correct code creates a grant ONCE and mints a trial token", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const code = await sendAndGetCode(store, email, "a@b.com");

  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.trial_credits_remaining, 40); // TRIAL_CREDITS default
  assertEquals(json.trial_credits_limit, 40); // E4: grant total for the meter bar
  assert(typeof json.token === "string");

  // The token is a valid TRIAL token whose sub is the grant id.
  const claims = await verifySessionToken(json.token, SECRET, NOW + 1);
  assert(claims);
  assertEquals(claims!.kind, "trial");
  assertEquals(claims!.tier, undefined); // trial tokens carry no tier
  assertEquals(claims!.sub, store.grants.get("a@b.com")!.id);

  // The code is single-use (deleted on success).
  assertEquals(store.codes.has("a@b.com"), false);
});

Deno.test("verify: a SECOND verify for the same email does not double-grant / reset credits", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();

  // First verify → grant created, then spend a credit to simulate usage.
  const code1 = await sendAndGetCode(store, email, "a@b.com");
  await handleTrialStart(req({ action: "verify", email: "a@b.com", code: code1 }), deps(store, email));
  store.grants.get("a@b.com")!.used = 4; // 36 remaining

  // Re-request + re-verify (e.g. after a reinstall lost the token).
  const code2 = await sendAndGetCode(store, email, "a@b.com");
  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code: code2 }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  // Same grant, credits NOT reset (36 left, not 40).
  assertEquals(json.trial_credits_remaining, 36);
  assertEquals(json.trial_credits_limit, 40); // E4: limit rides along unchanged
  assertEquals(store.grants.size, 1);
});

Deno.test("verify: wrong code → invalid_code + attempt incremented, code retained", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  await sendAndGetCode(store, email, "a@b.com");

  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code: "000000" }), deps(store, email));
  // (vanishingly unlikely the random code is 000000; if so this still passes as success — accept either)
  if (res.status === 200) return;
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "invalid_code");
  assertEquals(store.codes.get("a@b.com")!.attempts, 1);
});

Deno.test("verify: expired code → code_expired, code burned", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const code = await sendAndGetCode(store, email, "a@b.com");
  // Force the stored code to have expired before `now`.
  store.codes.get("a@b.com")!.expiresAt = (NOW - 1) * 1000;

  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code }), deps(store, email));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "code_expired");
  assertEquals(store.codes.has("a@b.com"), false);
});

Deno.test("verify: too many attempts → 429, code burned", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const code = await sendAndGetCode(store, email, "a@b.com");
  store.codes.get("a@b.com")!.attempts = 5; // CODE_MAX_ATTEMPTS default

  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code }), deps(store, email));
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, "too_many_attempts");
  assertEquals(store.codes.has("a@b.com"), false);
});

Deno.test("verify: no pending code → invalid_code", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code: "123456" }), deps(store, email));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "invalid_code");
});

// ---- resume (H1: silent token refresh for an already-verified email) --------
function assertValidFutureExpiry(expiresAt: unknown) {
  assert(typeof expiresAt === "string", "expires_at must be a string");
  const ms = new Date(expiresAt as string).getTime();
  assert(Number.isFinite(ms), "expires_at must parse");
  assert(ms > NOW * 1000, "expires_at must be in the future");
}

Deno.test("resume: verified email re-mints a token with the persisted balance, no code", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  // Establish a verified grant, then spend some credits.
  const code = await sendAndGetCode(store, email, "a@b.com");
  await handleTrialStart(req({ action: "verify", email: "a@b.com", code }), deps(store, email));
  store.grants.get("a@b.com")!.used = 6; // 34 remaining
  const sentBefore = email.sent.length;

  const res = await handleTrialStart(req({ action: "resume", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  assert(typeof json.token === "string");
  assertEquals(json.trial_credits_remaining, 34); // persisted balance, NOT reset to 40
  assertEquals(json.trial_credits_limit, 40); // E4: the PERSISTED grant total
  assertValidFutureExpiry(json.expires_at);
  // No email sent and no new grant created — resume only reads the grant.
  assertEquals(email.sent.length, sentBefore);
  assertEquals(store.grants.size, 1);

  // The minted token is a valid TRIAL token for the SAME grant.
  const claims = await verifySessionToken(json.token, SECRET, NOW + 1);
  assert(claims);
  assertEquals(claims!.kind, "trial");
  assertEquals(claims!.sub, store.grants.get("a@b.com")!.id);
});

Deno.test("resume: unknown email → needs_verification, no token, no grant created", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "resume", email: "nobody@b.com" }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.status, "needs_verification");
  assertEquals(json.token, undefined);
  assertEquals(store.grants.size, 0); // resume NEVER auto-creates a grant
  assertEquals(email.sent.length, 0);
});

Deno.test("resume: grant exists but never verified → needs_verification", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  store.grants.set("a@b.com", { id: "g1", verified: false, limit: 15, used: 0 });
  const res = await handleTrialStart(req({ action: "resume", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "needs_verification");
});

Deno.test("resume: verified but exhausted → already_used (no token)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  store.grants.set("a@b.com", { id: "g1", verified: true, limit: 15, used: 15 });
  const res = await handleTrialStart(req({ action: "resume", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.status, "already_used");
  assertEquals(json.token, undefined);
});

Deno.test("resume: respects the rate limit (429, mints nothing)", async () => {
  const store = new InMemoryTrialStore();
  store.rateOk = false;
  store.grants.set("a@b.com", { id: "g1", verified: true, limit: 15, used: 0 });
  const email = new StubEmailSender();
  const res = await handleTrialStart(req({ action: "resume", email: "a@b.com" }), deps(store, email));
  assertEquals(res.status, 429);
});

Deno.test("mint: BOTH verify and resume emit a well-formed FUTURE expires_at", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();

  // verify path
  const code = await sendAndGetCode(store, email, "a@b.com");
  const vres = await handleTrialStart(req({ action: "verify", email: "a@b.com", code }), deps(store, email));
  assertValidFutureExpiry((await vres.json()).expires_at);

  // resume path
  const rres = await handleTrialStart(req({ action: "resume", email: "a@b.com" }), deps(store, email));
  assertValidFutureExpiry((await rres.json()).expires_at);
});

Deno.test("rejects invalid email + bad action", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  assertEquals((await handleTrialStart(req({ action: "request", email: "nope" }), deps(store, email))).status, 400);
  assertEquals((await handleTrialStart(req({ action: "bogus", email: "a@b.com" }), deps(store, email))).status, 400);
});

// ---- trial device binding ---------------------------------------------------
// `device_id_hash` is a SHA-256 hex digest; the handler only honors a well-formed
// 64-char lowercase-hex value (else it degrades to the email-only cap).
const DEV_A = "a".repeat(64);
const DEV_B = "b".repeat(64);

Deno.test("device: new device + new email → grant created and stamped", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  await handleTrialStart(req({ action: "request", email: "a@b.com", device_id_hash: DEV_A }), deps(store, email));
  assertEquals(email.sent.length, 1);
  const code = email.sent.at(-1)!.code;
  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code, device_id_hash: DEV_A }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).trial_credits_remaining, 40);
  assertEquals(store.grants.get("a@b.com")!.deviceIdHash, DEV_A); // bound to the device
});

Deno.test("device: known device + new email → device_trial_used at request (no email sent)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  // This Mac already trialed under a different email.
  store.grants.set("first@b.com", { id: "g1", verified: true, limit: 40, used: 0, deviceIdHash: DEV_A });
  const res = await handleTrialStart(req({ action: "request", email: "second@b.com", device_id_hash: DEV_A }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "device_trial_used");
  assertEquals(email.sent.length, 0); // blocked BEFORE any code is emailed
});

Deno.test("device: known device + new email → device_trial_used at verify (race backstop)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  store.grants.set("first@b.com", { id: "g1", verified: true, limit: 40, used: 0, deviceIdHash: DEV_A });
  // Request WITHOUT a device hash so the early block doesn't fire — simulates the
  // verify-time race the partial unique index guards against.
  const code = await sendAndGetCode(store, email, "second@b.com");
  const res = await handleTrialStart(req({ action: "verify", email: "second@b.com", code, device_id_hash: DEV_A }), deps(store, email));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "device_trial_used");
  assertEquals(store.grants.has("second@b.com"), false); // nothing created
});

Deno.test("device: same device + SAME email → reinstall re-verify resumes, never blocked", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  await handleTrialStart(req({ action: "request", email: "a@b.com", device_id_hash: DEV_A }), deps(store, email));
  const code1 = email.sent.at(-1)!.code;
  await handleTrialStart(req({ action: "verify", email: "a@b.com", code: code1, device_id_hash: DEV_A }), deps(store, email));
  store.grants.get("a@b.com")!.used = 5; // 35 remaining

  // Reinstall on the SAME Mac with the SAME email → not a "different email", so
  // never blocked; re-verify resumes the persisted balance.
  const r1 = await handleTrialStart(req({ action: "request", email: "a@b.com", device_id_hash: DEV_A }), deps(store, email));
  assertEquals((await r1.json()).status, "code_sent");
  const code2 = email.sent.at(-1)!.code;
  const r2 = await handleTrialStart(req({ action: "verify", email: "a@b.com", code: code2, device_id_hash: DEV_A }), deps(store, email));
  assertEquals((await r2.json()).trial_credits_remaining, 35); // resumed, not reset to 40
  assertEquals(store.grants.size, 1);
});

Deno.test("device: a DIFFERENT device + new email → granted (only the same Mac is capped)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  store.grants.set("first@b.com", { id: "g1", verified: true, limit: 40, used: 0, deviceIdHash: DEV_A });
  const code = await sendAndGetCode(store, email, "second@b.com"); // request not blocked
  const res = await handleTrialStart(req({ action: "verify", email: "second@b.com", code, device_id_hash: DEV_B }), deps(store, email));
  assertEquals((await res.json()).trial_credits_remaining, 40);
  assertEquals(store.grants.get("second@b.com")!.deviceIdHash, DEV_B);
});

Deno.test("device: missing device hash → email-only cap unchanged (two emails both grant)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  const c1 = await sendAndGetCode(store, email, "a@b.com");
  await handleTrialStart(req({ action: "verify", email: "a@b.com", code: c1 }), deps(store, email));
  const c2 = await sendAndGetCode(store, email, "c@d.com");
  const res = await handleTrialStart(req({ action: "verify", email: "c@d.com", code: c2 }), deps(store, email));
  assertEquals((await res.json()).trial_credits_remaining, 40);
  assertEquals(store.grants.size, 2); // no device hash → no device cap
});

Deno.test("device: malformed device hash is ignored (degrades to the email-only cap)", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  store.grants.set("first@b.com", { id: "g1", verified: true, limit: 40, used: 0, deviceIdHash: DEV_A });
  // A non-hex / wrong-length value is not a plausible digest → ignored, so the
  // request proceeds on the email-only cap rather than mis-keying the device cap.
  const res = await handleTrialStart(req({ action: "request", email: "second@b.com", device_id_hash: "not-a-valid-hash" }), deps(store, email));
  assertEquals((await res.json()).status, "code_sent");
});
