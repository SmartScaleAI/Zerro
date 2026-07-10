import { assert, assertEquals } from "jsr:@std/assert@1";
import { signSessionToken, verifySessionToken } from "./jwt.ts";

const SECRET = "test_session_jwt_secret";

Deno.test("round-trips claims and exp", async () => {
  const now = 1_000_000;
  const { token, exp } = await signSessionToken(
    { sub: "sub-123", tier: "managed" },
    SECRET,
    1800,
    now,
  );
  assertEquals(exp, now + 1800);

  const claims = await verifySessionToken(token, SECRET, now + 1);
  assert(claims);
  assertEquals(claims!.sub, "sub-123");
  assertEquals(claims!.tier, "managed");
  assertEquals(claims!.kind, "subscription");
  assertEquals(claims!.exp, now + 1800);
});

Deno.test("mints a trial token with no tier (Phase F)", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken(
    { sub: "grant-abc", kind: "trial" },
    SECRET,
    1800,
    now,
  );
  const claims = await verifySessionToken(token, SECRET, now + 1);
  assert(claims);
  assertEquals(claims!.sub, "grant-abc");
  assertEquals(claims!.kind, "trial");
  assertEquals(claims!.tier, undefined); // trial carries no tier
});

Deno.test("rejects an expired token", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "managed" }, SECRET, 60, now);
  assertEquals(await verifySessionToken(token, SECRET, now + 61), null);
});

Deno.test("rejects a wrong secret", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "managed" }, SECRET, 60, now);
  assertEquals(await verifySessionToken(token, "wrong_secret", now + 1), null);
});

Deno.test("rejects a tampered payload", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "managed" }, SECRET, 60, now);
  const [h, _p, s] = token.split(".");
  // swap in a forged payload claiming pro tier + far-future exp
  const forged = btoa(JSON.stringify({ sub: "s", tier: "pro", kind: "subscription", iat: now, exp: now + 99999 }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  assertEquals(await verifySessionToken(`${h}.${forged}.${s}`, SECRET, now + 1), null);
});

Deno.test("rejects a malformed token", async () => {
  assertEquals(await verifySessionToken("not.a.jwt", SECRET), null);
  assertEquals(await verifySessionToken("only-one-part", SECRET), null);
});

// A-17 — algorithm-confusion pins. verifySessionToken never reads the header's
// `alg`: it unconditionally recomputes HMAC-SHA256 over header.payload and
// compares. These tests make that defense EXPLICIT, so a future refactor that
// starts trusting the attacker-controlled header (the classic alg:none /
// RS256→HS256 downgrade vector) fails loudly instead of shipping.

const b64url = (s: string) =>
  btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

Deno.test("rejects an alg:none token (empty signature never verifies)", async () => {
  const now = 1_000_000;
  const header = b64url(JSON.stringify({ alg: "none", typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    sub: "s",
    tier: "managed",
    kind: "subscription",
    iat: now,
    exp: now + 99999,
  }));
  // Both the spec-shaped alg:none form (empty third segment) and a junk
  // signature must fail the HMAC compare.
  assertEquals(await verifySessionToken(`${header}.${payload}.`, SECRET, now + 1), null);
  assertEquals(await verifySessionToken(`${header}.${payload}.${b64url("x")}`, SECRET, now + 1), null);
});

Deno.test("rejects a header alg swap on an otherwise-valid token", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "managed" }, SECRET, 60, now);
  const [, p, s] = token.split(".");
  // Keep the genuine payload + signature, swap only the header's alg — the
  // signature was minted over the ORIGINAL header, so verification must fail
  // (i.e. the header is covered by the MAC, not trusted).
  for (const alg of ["RS256", "none", "HS512"]) {
    const forged = b64url(JSON.stringify({ alg, typ: "JWT" }));
    assertEquals(await verifySessionToken(`${forged}.${p}.${s}`, SECRET, now + 1), null);
  }
});
