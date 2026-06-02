// Deno tests for the crypto primitives. Run: `deno test` in supabase/functions.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  base64UrlDecode,
  base64UrlEncode,
  sha256Hex,
  timingSafeEqual,
  toHex,
} from "./crypto.ts";

Deno.test("sha256Hex — known vector for empty string", async () => {
  // SHA-256("") = e3b0c442...
  assertEquals(
    await sha256Hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
});

Deno.test("sha256Hex — known vector for 'abc'", async () => {
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

Deno.test("base64url round-trips arbitrary bytes", () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255, 62, 63]);
  const decoded = base64UrlDecode(base64UrlEncode(bytes));
  assertEquals([...decoded], [...bytes]);
});

Deno.test("base64url is URL-safe (no +,/,=)", () => {
  const s = base64UrlEncode(new Uint8Array([251, 255, 191, 254]));
  assert(!/[+/=]/.test(s));
});

Deno.test("toHex pads single digits", () => {
  assertEquals(toHex(new Uint8Array([0, 15, 16, 255])), "000f10ff");
});

Deno.test("timingSafeEqual: equal strings true, any difference false", () => {
  assert(timingSafeEqual("deadbeef", "deadbeef"));
  assert(!timingSafeEqual("deadbeef", "deadbeee"));
  assert(!timingSafeEqual("deadbeef", "deadbee")); // length mismatch
  assert(!timingSafeEqual("", "x"));
  assert(timingSafeEqual("", ""));
});
