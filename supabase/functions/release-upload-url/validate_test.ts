// Tests for release-upload-url's security-critical pure helpers: the path
// allow-list (what bounds a leaked secret to "upload a Zerro DMG") and the
// constant-time secret compare. Imported from validate.ts, NOT index.ts, so
// the test never boots Deno.serve.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { isAllowedDmgPath, timingSafeEqual } from "./validate.ts";

// -- Path allow-list ----------------------------------------------------------

Deno.test("isAllowedDmgPath: accepts the mutable latest object", () => {
  assert(isAllowedDmgPath("Zerro.dmg"));
});

Deno.test("isAllowedDmgPath: accepts a versioned release object", () => {
  assert(isAllowedDmgPath("Zerro-226.dmg"));
  assert(isAllowedDmgPath("Zerro-1.dmg"));
});

Deno.test("isAllowedDmgPath: rejects any other object", () => {
  assertEquals(isAllowedDmgPath("evil.dmg"), false);
  assertEquals(isAllowedDmgPath("appcast.xml"), false);
});

Deno.test("isAllowedDmgPath: rejects nested paths and traversal", () => {
  assertEquals(isAllowedDmgPath("Zerro.dmg/x"), false);
  assertEquals(isAllowedDmgPath("../secrets"), false);
  assertEquals(isAllowedDmgPath("../Zerro.dmg"), false);
  assertEquals(isAllowedDmgPath("downloads/Zerro.dmg"), false);
});

Deno.test("isAllowedDmgPath: rejects malformed version suffixes", () => {
  assertEquals(isAllowedDmgPath("Zerro-.dmg"), false);
  assertEquals(isAllowedDmgPath("Zerro-1.2.dmg"), false);
  assertEquals(isAllowedDmgPath("Zerro-abc.dmg"), false);
});

Deno.test("isAllowedDmgPath: rejects empty / non-string / affix tricks", () => {
  assertEquals(isAllowedDmgPath(""), false);
  assertEquals(isAllowedDmgPath(undefined), false);
  assertEquals(isAllowedDmgPath(null), false);
  assertEquals(isAllowedDmgPath(42), false);
  assertEquals(isAllowedDmgPath("Zerro.dmgx"), false);
  assertEquals(isAllowedDmgPath("xZerro.dmg"), false);
  assertEquals(isAllowedDmgPath("Zerro.dmg\n"), false);
});

// -- Constant-time compare ----------------------------------------------------

Deno.test("timingSafeEqual: equal strings match", () => {
  assert(timingSafeEqual("secret-123", "secret-123"));
  assert(timingSafeEqual("", ""));
});

Deno.test("timingSafeEqual: any mismatch fails", () => {
  assertEquals(timingSafeEqual("secret-123", "secret-124"), false);
  assertEquals(timingSafeEqual("Secret-123", "secret-123"), false);
});

Deno.test("timingSafeEqual: length difference fails", () => {
  assertEquals(timingSafeEqual("secret", "secret-123"), false);
  assertEquals(timingSafeEqual("secret-123", "secret"), false);
  assertEquals(timingSafeEqual("", "x"), false);
});
