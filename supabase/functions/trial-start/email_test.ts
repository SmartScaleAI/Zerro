import { assert, assertEquals } from "jsr:@std/assert@1";
import { generateCode, isDisposableEmail, normalizeEmail } from "./email.ts";

Deno.test("normalizeEmail lowercases + trims", () => {
  assertEquals(normalizeEmail("  Foo@Example.com "), "foo@example.com");
});

Deno.test("normalizeEmail collapses gmail dots + plus tags to one identity", () => {
  const canonical = "joesmith@gmail.com";
  assertEquals(normalizeEmail("joe.smith@gmail.com"), canonical);
  assertEquals(normalizeEmail("j.o.e.s.m.i.t.h+spam@gmail.com"), canonical);
  assertEquals(normalizeEmail("JoeSmith@googlemail.com"), canonical); // googlemail → gmail
});

Deno.test("normalizeEmail preserves dots for non-gmail but drops +tag", () => {
  assertEquals(normalizeEmail("a.b+promo@fastmail.com"), "a.b@fastmail.com");
});

Deno.test("normalizeEmail rejects malformed input", () => {
  assertEquals(normalizeEmail(""), null);
  assertEquals(normalizeEmail("nope"), null);
  assertEquals(normalizeEmail("@gmail.com"), null);
  assertEquals(normalizeEmail("user@"), null);
  assertEquals(normalizeEmail("user@localhost"), null); // no dot in domain
});

Deno.test("isDisposableEmail flags known throwaway domains, allows real ones", () => {
  assert(isDisposableEmail("x@mailinator.com"));
  assert(isDisposableEmail("x@guerrillamail.com"));
  assert(!isDisposableEmail("x@gmail.com"));
  assert(!isDisposableEmail("x@company.io"));
});

Deno.test("generateCode is always 6 numeric digits (leading zeros kept)", () => {
  for (let i = 0; i < 500; i++) {
    const code = generateCode();
    assert(/^\d{6}$/.test(code), `bad code: ${code}`);
  }
});
