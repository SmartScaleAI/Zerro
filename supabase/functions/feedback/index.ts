// =============================================================================
// feedback — relays an in-app feedback / issue report to a Slack channel.
// =============================================================================
// Deployed with verify_jwt = false at the Supabase GATEWAY (see config.toml):
// the Zerro app posts here unauthenticated (the in-app dialog works signed-out),
// exactly like `trial-start`. There is no credential to verify — the payload is
// short, validated, and length-capped in code, and the only side effect is a
// POST to a server-held Slack webhook. The webhook URL is a secret
// (SLACK_WEBHOOK_URL) and is NEVER echoed back to the client or logged.
//
// Wire shape (matches FeedbackService.swift):
//   POST /feedback
//   { "kind": "issue" | "feedback",
//     "message": <string, 1–4000 chars, trimmed>,
//     "app_version": <string|null>,
//     "os_version":  <string|null>,
//     "user_email":  <string|null> }
//   → 200 { ok: true } on success
//   → 400 { error: "invalid_body" | "invalid_kind" | "invalid_message" }
//   → 405 { error: "method_not_allowed" }
//   → 502 { error: "slack_delivery_failed" } when Slack returns non-2xx.

import { requireEnv } from "../_shared/env.ts";
import { handlePreflight, json } from "../_shared/http.ts";

/// Hard caps mirrored on the client (FeedbackService) so a well-behaved app
/// never trips them; enforced here too because the endpoint is unauthenticated.
const MESSAGE_MAX = 4000;
/// Defensive caps on the diagnostic strings — they ride straight into a Slack
/// context block, so bound them rather than trusting client length.
const META_MAX = 200;

type FeedbackKind = "issue" | "feedback";

function clampMeta(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "") return null;
  return trimmed.slice(0, META_MAX);
}

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // Parse + validate. A non-JSON body, a bad `kind`, or an empty / oversized
  // `message` all reject with a 400 BEFORE we touch Slack.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  if (typeof body !== "object" || body === null) {
    return json({ error: "invalid_body" }, 400);
  }

  const raw = body as Record<string, unknown>;

  const kind = raw.kind;
  if (kind !== "issue" && kind !== "feedback") {
    return json({ error: "invalid_kind" }, 400);
  }

  const message = typeof raw.message === "string" ? raw.message.trim() : "";
  if (message.length < 1 || message.length > MESSAGE_MAX) {
    return json({ error: "invalid_message" }, 400);
  }

  const appVersion = clampMeta(raw.app_version);
  const osVersion = clampMeta(raw.os_version);
  const userEmail = clampMeta(raw.user_email);

  const webhook = requireEnv("SLACK_WEBHOOK_URL");

  const payload = buildSlackPayload({
    kind: kind as FeedbackKind,
    message,
    appVersion,
    osVersion,
    userEmail,
  });

  let slackStatus: number;
  try {
    const res = await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    slackStatus = res.status;
    // Drain the body so the connection can be reused / closed cleanly.
    await res.text().catch(() => undefined);
  } catch (error) {
    // Never log the webhook URL or the request body — just the failure class.
    console.error(
      JSON.stringify({
        fn: "feedback",
        error: "slack_transport_failed",
        detail: error instanceof Error ? error.message : "unknown",
      }),
    );
    return json({ error: "slack_delivery_failed" }, 502);
  }

  if (slackStatus < 200 || slackStatus >= 300) {
    console.error(
      JSON.stringify({ fn: "feedback", error: "slack_non_2xx", status: slackStatus }),
    );
    return json({ error: "slack_delivery_failed" }, 502);
  }

  console.log(JSON.stringify({ fn: "feedback", ok: true, kind }));
  return json({ ok: true }, 200);
});

// MARK: - Slack Block Kit

interface FeedbackInput {
  kind: FeedbackKind;
  message: string;
  appVersion: string | null;
  osVersion: string | null;
  userEmail: string | null;
}

/// Builds the Block Kit message: a header that names the kind, a section with
/// the user's verbatim message, and a context line carrying the diagnostic
/// trailer + a timestamp.
function buildSlackPayload(input: FeedbackInput) {
  const headerText = input.kind === "issue"
    ? "🐞 New issue report"
    : "💡 New feedback";

  const account = input.userEmail ?? "not signed in";
  const appVersion = input.appVersion ?? "unknown";
  const osVersion = input.osVersion ?? "unknown";
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
        // is user content, so it is NOT formatted as code or interpolated into
        // any other markup.
        text: { type: "mrkdwn", text: input.message },
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
