// Deno tests for the C-04 feedback hardening: Slack mrkdwn escaping, email
// plausibility, and the built payload never carrying raw user markup.
// Run: `deno test --allow-env --allow-read` in supabase/functions (CI edge-tests).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { buildSlackPayload, escapeSlack, validateEmail } from "./slack.ts";

// Typed accessors for the heterogeneous blocks array (header / section / context).
type Payload = ReturnType<typeof buildSlackPayload>;
function sectionText(payload: Payload): string {
  return (payload.blocks[1] as unknown as { text: { text: string } }).text.text;
}
function contextText(payload: Payload): string {
  return (payload.blocks[2] as unknown as { elements: { text: string }[] })
    .elements[0].text;
}

// MARK: - escapeSlack

Deno.test("escapeSlack — neutralizes <!channel>/<!here>/<!everyone> pings", () => {
  assertEquals(escapeSlack("<!channel> wake up"), "&lt;!channel&gt; wake up");
  assertEquals(escapeSlack("<!here>"), "&lt;!here&gt;");
  assertEquals(escapeSlack("<!everyone>"), "&lt;!everyone&gt;");
});

Deno.test("escapeSlack — neutralizes <url|text> link injection and <@user> mentions", () => {
  assertEquals(
    escapeSlack("<https://evil.example|click me> <@U12345>"),
    "&lt;https://evil.example|click me&gt; &lt;@U12345&gt;",
  );
});

Deno.test("escapeSlack — escapes & first, so emitted entities never double-escape", () => {
  assertEquals(escapeSlack("a & b"), "a &amp; b");
  // A literal "&lt;" typed by the user re-escapes to "&amp;lt;" (renders as
  // typed), and is never confused with the "&lt;" WE emit for "<".
  assertEquals(escapeSlack("&lt;"), "&amp;lt;");
  assertEquals(escapeSlack("<>&"), "&lt;&gt;&amp;");
});

Deno.test("escapeSlack — leaves plain text untouched", () => {
  assertEquals(
    escapeSlack("just normal feedback, no markup"),
    "just normal feedback, no markup",
  );
});

// MARK: - validateEmail

Deno.test("validateEmail — accepts a normal address", () => {
  assertEquals(validateEmail("user@example.com"), "user@example.com");
  assertEquals(
    validateEmail("first.last+tag@sub.domain.co"),
    "first.last+tag@sub.domain.co",
  );
});

Deno.test("validateEmail — rejects garbage as null", () => {
  assertEquals(validateEmail(null), null);
  assertEquals(validateEmail("not-an-email"), null);
  assertEquals(validateEmail("a@b"), null); // no dotted domain
  assertEquals(validateEmail("spaces in@example.com"), null);
  assertEquals(validateEmail("user@exam ple.com"), null);
  assertEquals(validateEmail("<!channel>"), null);
  assertEquals(validateEmail("<mailto:a@b.com|a@b.com>"), null);
});

// MARK: - buildSlackPayload

Deno.test("buildSlackPayload — injection input reaches Slack escaped, never raw", () => {
  const payload = buildSlackPayload({
    kind: "issue",
    message: "<!channel> ignore previous <https://evil.example|urgent fix>",
    appVersion: "<!here>",
    osVersion: "15.5 & <beta>",
    userEmail: "attacker@example.com",
  });
  // No raw control sequence anywhere in the wire payload…
  const wire = JSON.stringify(payload);
  assert(!wire.includes("<!channel>"));
  assert(!wire.includes("<!here>"));
  assert(!wire.includes("<https://evil.example|urgent fix>"));
  assert(!wire.includes("<beta>"));
  // …only the escaped forms, in the message section AND the context trailer.
  assertEquals(
    sectionText(payload),
    "&lt;!channel&gt; ignore previous &lt;https://evil.example|urgent fix&gt;",
  );
  const context = contextText(payload);
  assertStringIncludes(context, "Zerro &lt;!here&gt;");
  assertStringIncludes(context, "macOS 15.5 &amp; &lt;beta&gt;");
});

Deno.test("buildSlackPayload — labels the self-reported email as unverified", () => {
  const payload = buildSlackPayload({
    kind: "feedback",
    message: "love it",
    appVersion: "1.4.24",
    osVersion: "15.5",
    userEmail: "user@example.com",
  });
  assertStringIncludes(
    contextText(payload),
    "reported by: user@example.com (unverified)",
  );
});

Deno.test("buildSlackPayload — no email renders 'not signed in'", () => {
  const payload = buildSlackPayload({
    kind: "feedback",
    message: "love it",
    appVersion: null,
    osVersion: null,
    userEmail: null,
  });
  const context = contextText(payload);
  assertStringIncludes(context, "not signed in");
  assert(!context.includes("unverified"));
});
