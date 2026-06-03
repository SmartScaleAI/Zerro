import { assertEquals } from "jsr:@std/assert@1";
import { normalizeLsStatus } from "./lemonsqueezy.ts";

// The normalization decides which LIVE LemonSqueezy statuses revoke a session
// (§14.6). It must mirror the webhook's own mapping so a live re-check and a
// delivered webhook reconcile the mirror to the SAME value. Lock it down here.
Deno.test("normalizeLsStatus: entitled statuses → active", () => {
  assertEquals(normalizeLsStatus("active"), "active");
  assertEquals(normalizeLsStatus("on_trial"), "active");
  assertEquals(normalizeLsStatus("paused"), "active");
  assertEquals(normalizeLsStatus("ACTIVE"), "active"); // case-insensitive
});

Deno.test("normalizeLsStatus: past_due → past_due (still entitled, §9.1)", () => {
  assertEquals(normalizeLsStatus("past_due"), "past_due");
});

Deno.test("normalizeLsStatus: terminal statuses revoke", () => {
  assertEquals(normalizeLsStatus("cancelled"), "cancelled");
  assertEquals(normalizeLsStatus("expired"), "expired");
  assertEquals(normalizeLsStatus("unpaid"), "expired"); // exhausted grace → terminal
});

Deno.test("normalizeLsStatus: unknown/empty → null (inconclusive → fail-open)", () => {
  assertEquals(normalizeLsStatus("something_new"), null);
  assertEquals(normalizeLsStatus(""), null);
  assertEquals(normalizeLsStatus(null), null);
  assertEquals(normalizeLsStatus(undefined), null);
});
