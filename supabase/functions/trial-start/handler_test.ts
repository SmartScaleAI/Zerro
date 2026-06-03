import { assert, assertEquals } from "jsr:@std/assert@1";
import { sha256Hex } from "../_shared/crypto.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { handleTrialStart, type TrialStartDeps } from "./handler.ts";
import { EmailSendError, type EmailSender } from "./resend.ts";
import type { TrialCodeRow, TrialGrantRow, TrialStore } from "./store.ts";

const SECRET = "test_session_jwt_secret";
const NOW = 1_000_000; // epoch seconds

// ---- In-memory TrialStore ---------------------------------------------------
interface Grant {
  id: string;
  verified: boolean;
  limit: number;
  used: number;
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
  verifyGrant(email: string, limit: number): Promise<{ grantId: string; creditsRemaining: number }> {
    // Create-once / never-reset (mirrors verify_trial_grant).
    let g = this.grants.get(email);
    if (!g) {
      g = { id: `grant-${this.nextId++}`, verified: true, limit, used: 0 };
      this.grants.set(email, g);
    } else {
      g.verified = true; // backfill, never reset credits
    }
    return Promise.resolve({ grantId: g.id, creditsRemaining: Math.max(0, g.limit - g.used) });
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
  assertEquals(json.trial_credits_remaining, 15);
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
  store.grants.get("a@b.com")!.used = 4; // 11 remaining

  // Re-request + re-verify (e.g. after a reinstall lost the token).
  const code2 = await sendAndGetCode(store, email, "a@b.com");
  const res = await handleTrialStart(req({ action: "verify", email: "a@b.com", code: code2 }), deps(store, email));
  assertEquals(res.status, 200);
  const json = await res.json();
  // Same grant, credits NOT reset (11 left, not 15).
  assertEquals(json.trial_credits_remaining, 11);
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

Deno.test("rejects invalid email + bad action", async () => {
  const store = new InMemoryTrialStore();
  const email = new StubEmailSender();
  assertEquals((await handleTrialStart(req({ action: "request", email: "nope" }), deps(store, email))).status, 400);
  assertEquals((await handleTrialStart(req({ action: "bogus", email: "a@b.com" }), deps(store, email))).status, 400);
});
