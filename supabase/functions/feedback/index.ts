// =============================================================================
// feedback — relays an in-app feedback / issue report to a Slack channel.
// =============================================================================
// Deployed with verify_jwt = false at the Supabase GATEWAY (see config.toml):
// the Zerro app posts here unauthenticated (the in-app dialog works signed-out),
// exactly like `trial-start`. There is no credential to verify, so the C-04
// hardening posture is: the payload is short, validated, and length-capped in
// code; every user string is mrkdwn-escaped before it reaches Slack (slack.ts);
// and a per-IP rate limit bounds relay spam. The webhook URL is a secret
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
//   → 429 { error: "rate_limited" } past the per-IP cap (or limiter failure)
//   → 502 { error: "slack_delivery_failed" } when Slack returns non-2xx.

import { requireEnv } from "../_shared/env.ts";
import { handlePreflight, json } from "../_shared/http.ts";
import { serviceClient } from "../_shared/db.ts";
import {
  FEEDBACK_RATE_LIMIT_PER_IP,
  FEEDBACK_RATE_LIMIT_WINDOW_SECONDS,
} from "./config.ts";
import { buildSlackPayload, validateEmail } from "./slack.ts";

/// Hard caps mirrored on the client (FeedbackService) so a well-behaved app
/// never trips them; enforced here too because the endpoint is unauthenticated.
const MESSAGE_MAX = 4000;
/// Defensive caps on the diagnostic strings — they ride straight into a Slack
/// context block, so bound them rather than trusting client length.
const META_MAX = 200;

function clampMeta(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "") return null;
  return trimmed.slice(0, META_MAX);
}

/** First hop of x-forwarded-for (the gateway-appended client IP), mirroring
 * trial-start. */
function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

/** Per-IP fixed-window gate (check_rate_limit, the same limiter trial-start
 * uses). TRUE = allowed. Fails CLOSED: this is an unauthenticated relay into
 * Slack, so a broken limiter must reject rather than degrade into an unbounded
 * spam channel — the opposite call from trial-start, where fail-open protects
 * a legitimate signup that has other hard caps behind it. */
async function withinRate(ip: string): Promise<boolean> {
  const { data, error } = await serviceClient().rpc("check_rate_limit", {
    p_key: `feedback:${ip}`,
    p_max: FEEDBACK_RATE_LIMIT_PER_IP,
    p_window_seconds: FEEDBACK_RATE_LIMIT_WINDOW_SECONDS,
  });
  if (error) {
    console.error(
      JSON.stringify({ fn: "feedback", op: "rateLimit", error: error.message }),
    );
    return false;
  }
  return data === true;
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
  // Self-reported and unauthenticated: keep only plausible addresses; the
  // Slack context line labels whatever survives as "(unverified)".
  const userEmail = validateEmail(clampMeta(raw.user_email));

  // Per-IP rate gate BEFORE the Slack POST — the only quantitative abuse
  // bound on this endpoint.
  if (!(await withinRate(clientIp(req)))) {
    return json({ error: "rate_limited" }, 429);
  }

  const webhook = requireEnv("SLACK_WEBHOOK_URL");

  const payload = buildSlackPayload({
    kind,
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
