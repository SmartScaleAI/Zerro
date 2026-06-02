import { assert, assertEquals } from "jsr:@std/assert@1";
import { verifyLemonSqueezySignature } from "./ls-signature.ts";
import { hmacSha256, toHex } from "./crypto.ts";

const SECRET = "test_webhook_signing_secret";
const BODY = JSON.stringify({ meta: { event_name: "subscription_created" }, data: { id: "42" } });

async function validSig(body: string, secret = SECRET): Promise<string> {
  return toHex(await hmacSha256(secret, body));
}

Deno.test("accepts a correct signature computed over the raw body", async () => {
  const sig = await validSig(BODY);
  assert(await verifyLemonSqueezySignature(BODY, sig, SECRET));
});

Deno.test("accepts uppercase hex (we lowercase before compare)", async () => {
  const sig = (await validSig(BODY)).toUpperCase();
  assert(await verifyLemonSqueezySignature(BODY, sig, SECRET));
});

Deno.test("rejects a tampered body", async () => {
  const sig = await validSig(BODY);
  assertEquals(await verifyLemonSqueezySignature(BODY + " ", sig, SECRET), false);
});

Deno.test("rejects a wrong secret", async () => {
  const sig = await validSig(BODY, "other_secret");
  assertEquals(await verifyLemonSqueezySignature(BODY, sig, SECRET), false);
});

Deno.test("rejects a missing signature", async () => {
  assertEquals(await verifyLemonSqueezySignature(BODY, null, SECRET), false);
  assertEquals(await verifyLemonSqueezySignature(BODY, "", SECRET), false);
});
