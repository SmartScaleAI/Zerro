// =============================================================================
// feedback/slack.ts — pure Slack-payload helpers for the feedback relay.
// =============================================================================
// Extracted from index.ts so the injection hardening (C-04) is unit-testable
// without booting the Deno.serve handler: everything here is pure — no env,
// no network, no Supabase.

export type FeedbackKind = "issue" | "feedback";

export interface FeedbackInput {
  kind: FeedbackKind;
  message: string;
  appVersion: string | null;
  osVersion: string | null;
  /** Already gated by `validateEmail` — null when absent or implausible. */
  userEmail: string | null;
}

/// Slack's documented control-character escaping for user-generated content
/// (api.slack.com/reference/surfaces/formatting#escaping): replace `&` FIRST
/// (so the entities we emit are never themselves re-escaped), then `<` and
/// `>`. With `<` gone, none of mrkdwn's control sequences can form —
/// <!channel>/<!here>/<!everyone> pings, <url|text> link injection, and
/// <@user> mentions all render as inert text.
export function escapeSlack(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

/// Format-validates the self-reported email. Returns the address when it's
/// plausible, else null (rendered as "not signed in"). Deliberately loose —
/// one @, no whitespace, a dotted domain — this is a display-labeling gate,
/// not deliverability validation: the endpoint is unauthenticated, so the
/// value is untrusted either way and is labeled "(unverified)" in the Slack
/// message (buildSlackPayload).
export function validateEmail(value: string | null): string | null {
  if (value === null) return null;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) ? value : null;
}

/// Builds the Block Kit message: a header that names the kind, a section with
/// the user's message, and a context line carrying the diagnostic trailer + a
/// timestamp. EVERY user-controlled string — the message AND the context
/// metadata — passes through `escapeSlack` before it rides into an mrkdwn
/// block, so a <!channel> in the feedback text renders literally instead of
/// paging the channel.
export function buildSlackPayload(input: FeedbackInput) {
  const headerText = input.kind === "issue"
    ? "🐞 New issue report"
    : "💡 New feedback";

  // The email is unauthenticated self-report — label it so nobody in the
  // channel treats it as a verified identity.
  const account = input.userEmail !== null
    ? `reported by: ${escapeSlack(input.userEmail)} (unverified)`
    : "not signed in";
  const appVersion = escapeSlack(input.appVersion ?? "unknown");
  const osVersion = escapeSlack(input.osVersion ?? "unknown");
  const timestamp = new Date().toISOString();

  return {
    // `text` is the notification fallback shown in Slack push/preview.
    text: headerText,
    blocks: [
      {
        type: "header",
        text: { type: "plain_text", text: headerText, emoji: true },
      },
      {
        type: "section",
        // `mrkdwn` so multi-line messages render with line breaks; the message
        // is user content, so it is escaped — never interpolated raw.
        text: { type: "mrkdwn", text: escapeSlack(input.message) },
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text:
              `Zerro ${appVersion} · macOS ${osVersion} · ${account} · ${timestamp}`,
          },
        ],
      },
    ],
  };
}
