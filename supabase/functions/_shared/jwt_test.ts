import { assert, assertEquals } from "jsr:@std/assert@1";
import { signSessionToken, verifySessionToken } from "./jwt.ts";

const SECRET = "test_session_jwt_secret";

Deno.test("round-trips claims and exp", async () => {
  const now = 1_000_000;
  const { token, exp } = await signSessionToken(
    { sub: "sub-123", tier: "pro" },
    SECRET,
    1800,
    now,
  );
  assertEquals(exp, now + 1800);

  const claims = await verifySessionToken(token, SECRET, now + 1);
  assert(claims);
  assertEquals(claims!.sub, "sub-123");
  assertEquals(claims!.tier, "pro");
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
  const { token } = await signSessionToken({ sub: "s", tier: "starter" }, SECRET, 60, now);
  assertEquals(await verifySessionToken(token, SECRET, now + 61), null);
});

Deno.test("rejects a wrong secret", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "starter" }, SECRET, 60, now);
  assertEquals(await verifySessionToken(token, "wrong_secret", now + 1), null);
});

Deno.test("rejects a tampered payload", async () => {
  const now = 1_000_000;
  const { token } = await signSessionToken({ sub: "s", tier: "starter" }, SECRET, 60, now);
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
