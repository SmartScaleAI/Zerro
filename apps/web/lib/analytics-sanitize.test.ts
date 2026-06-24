import assert from "node:assert/strict";
import { test } from "node:test";
import {
  redactSensitiveText,
  redactSensitiveUrl,
  sanitizePostHogEvent,
  SENSITIVE_QUERY_PARAMS,
} from "./analytics-sanitize.ts";

// Run with: npm test  (Node's built-in runner strips the TS types natively)

test("strips license_key from an absolute URL", () => {
  const out = redactSensitiveUrl(
    "https://getzerro.app/checkout-complete?license_key=ABC-123",
  );
  assert.equal(out, "https://getzerro.app/checkout-complete");
});

test("strips order_id too", () => {
  const out = redactSensitiveUrl(
    "https://getzerro.app/checkout-complete?order_id=99",
  );
  assert.equal(out, "https://getzerro.app/checkout-complete");
});

test("strips the sensitive params but keeps benign ones", () => {
  const out = redactSensitiveUrl(
    "https://getzerro.app/checkout-complete?product=pro&license_key=SECRET&order_id=42",
  );
  assert.equal(out, "https://getzerro.app/checkout-complete?product=pro");
});

test("param-name match is case-insensitive", () => {
  const out = redactSensitiveUrl(
    "https://getzerro.app/c?License_Key=SECRET&Order_ID=7",
  );
  assert.equal(out, "https://getzerro.app/c");
});

test("preserves a relative URL's shape (no origin injected)", () => {
  const out = redactSensitiveUrl("/checkout-complete?license_key=SECRET&a=1");
  assert.equal(out, "/checkout-complete?a=1");
});

test("preserves the hash fragment", () => {
  const out = redactSensitiveUrl(
    "https://getzerro.app/c?license_key=SECRET#section",
  );
  assert.equal(out, "https://getzerro.app/c#section");
});

test("leaves a clean URL byte-for-byte unchanged (no trailing '?')", () => {
  const clean = "https://getzerro.app/pricing?ref=footer";
  assert.equal(redactSensitiveUrl(clean), clean);
});

test("leaves a plain pathname unchanged", () => {
  assert.equal(redactSensitiveUrl("/checkout-complete"), "/checkout-complete");
});

test("a benign substring match does not corrupt the URL", () => {
  // "token-economics" contains the substring "token" but has no `token=` param.
  const url = "https://getzerro.app/blog/token-economics?utm=x";
  assert.equal(redactSensitiveUrl(url), url);
});

test("non-URL and empty strings pass through", () => {
  assert.equal(redactSensitiveUrl(""), "");
  assert.equal(redactSensitiveUrl("not a url"), "not a url");
});

test("every listed param is actually removed", () => {
  for (const param of SENSITIVE_QUERY_PARAMS) {
    const out = redactSensitiveUrl(`https://x.test/p?${param}=SECRET&keep=1`);
    assert.equal(
      out,
      "https://x.test/p?keep=1",
      `expected ${param} to be stripped`,
    );
  }
});

test("sanitizePostHogEvent scrubs $current_url on a pageview", () => {
  const event = {
    uuid: "1",
    event: "$pageview",
    properties: {
      $current_url:
        "https://getzerro.app/checkout-complete?license_key=ABC&order_id=9",
      $pathname: "/checkout-complete",
      $browser: "Chrome",
    },
  };
  const out = sanitizePostHogEvent(event as never) as typeof event;
  assert.equal(
    out.properties.$current_url,
    "https://getzerro.app/checkout-complete",
  );
  // Non-URL props are untouched.
  assert.equal(out.properties.$browser, "Chrome");
});

test("sanitizePostHogEvent scrubs $referrer and $set", () => {
  const event = {
    uuid: "2",
    event: "$autocapture",
    properties: {
      $referrer: "https://getzerro.app/checkout-complete?license_key=ABC",
    },
    $set: {
      $initial_current_url: "https://getzerro.app/checkout-complete?order_id=1",
    },
  };
  const out = sanitizePostHogEvent(event as never) as typeof event;
  assert.equal(
    out.properties.$referrer,
    "https://getzerro.app/checkout-complete",
  );
  assert.equal(
    out.$set.$initial_current_url,
    "https://getzerro.app/checkout-complete",
  );
});

test("sanitizePostHogEvent leaves a normal pageview untouched", () => {
  const event = {
    uuid: "3",
    event: "$pageview",
    properties: { $current_url: "https://getzerro.app/pricing?ref=footer" },
  };
  const out = sanitizePostHogEvent(event as never) as typeof event;
  assert.equal(
    out.properties.$current_url,
    "https://getzerro.app/pricing?ref=footer",
  );
});

test("sanitizePostHogEvent passes a null event through (PostHog drop signal)", () => {
  assert.equal(sanitizePostHogEvent(null), null);
});

// --- autocapture element data (the $click leak the adversarial review found) ---

test("redactSensitiveText redacts secret values inside a serialized chain", () => {
  const chain =
    'a:attr__href="zerro://checkout-complete?license_key=ABC&order_id=42";nth-child="1"';
  const out = redactSensitiveText(chain);
  assert.ok(!out.includes("ABC"), "license_key value must be gone");
  assert.ok(!out.includes("=42"), "order_id value must be gone");
  // Structure (and the closing quote) is preserved.
  assert.ok(out.includes('nth-child="1"'));
  assert.ok(out.includes("license_key=[redacted]"));
});

test("redactSensitiveText leaves a chain with no secrets untouched", () => {
  const chain = 'a:attr__href="https://getzerro.app/pricing";nth-child="2"';
  assert.equal(redactSensitiveText(chain), chain);
});

test("sanitizePostHogEvent scrubs $elements_chain on a $click", () => {
  const event = {
    uuid: "10",
    event: "$autocapture",
    properties: {
      $event_type: "click",
      $elements_chain:
        'a.btn:attr__href="zerro://checkout-complete?license_key=SECRET-LEAK&order_id=9":text="Open Zerro"',
    },
  };
  const out = sanitizePostHogEvent(event as never) as typeof event;
  assert.ok(
    !out.properties.$elements_chain.includes("SECRET-LEAK"),
    "license_key must not survive in $elements_chain",
  );
});

test("sanitizePostHogEvent scrubs href/attr__href in the $elements array", () => {
  const event = {
    uuid: "11",
    event: "$autocapture",
    properties: {
      $elements: [
        {
          tag_name: "a",
          $el_text: "Open Zerro",
          href: "zerro://checkout-complete?license_key=SECRET-LEAK&order_id=9",
          attr__href:
            "zerro://checkout-complete?license_key=SECRET-LEAK&order_id=9",
        },
      ],
    },
  };
  const out = sanitizePostHogEvent(event as never) as typeof event;
  const el = out.properties.$elements[0];
  assert.ok(!el.href.includes("SECRET-LEAK"), "href value must be redacted");
  assert.ok(
    !el.attr__href.includes("SECRET-LEAK"),
    "attr__href value must be redacted",
  );
  // Non-sensitive fields are preserved.
  assert.equal(el.$el_text, "Open Zerro");
  assert.equal(el.tag_name, "a");
});
