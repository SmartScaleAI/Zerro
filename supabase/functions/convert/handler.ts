// =============================================================================
// convert — the free "Write agent prompt" conversion fallback (Phase 6 of the
// typed-artifact refactor).
// =============================================================================
// When a generated response carried NO artifact (the model judged it a
// question/diagnosis), the app can still produce an agent prompt: it sends the
// response's chat text + the recording's Attached Context block here, and gets
// back a §2 `agent_prompt` artifact block (raw fenced text — the CLIENT
// parses, locked decision).
//
// DELIBERATELY SIMPLE — this endpoint is free, cheap, and stateless:
//   • session-token auth (subscription AND trial kinds), method/size gates
//     first — same order as generate;
//   • per-identity rate limit (reuses check_rate_limit) — the ONLY
//     quantitative gate, since there is NO credit check, NO credit
//     consumption, NO concurrency slot, and NO idempotency cache;
//   • the chat call with the server-owned conversion prompt; provider errors
//     map exactly like generate's (503 retryable / 502 not);
//   • console logging only — no generation_log writes (that table is billing
//     attribution; conversions charge 0).
// Unlike generate, identity resolution stops at the verified token: no DB
// status lookup. The token is only minted for an entitled identity and is
// short-lived; for a free, rate-limited endpoint that bound is enough, and it
// keeps this handler stateless (one RPC, no table reads).
//
// PRIVACY: source text and context are processed in memory and never
// persisted; the console log carries token counts only, never content.
//
// This phase does NOT touch generate/** — the model registry and provider
// adapters are imported from there READ-ONLY (one registry, no duplicate).
// =============================================================================

import { json } from "../_shared/http.ts";
import { verifySessionToken } from "../_shared/jwt.ts";
import { conversionSystemPrompt } from "./prompt.ts";
import { validateConvertBody } from "./limits.ts";
import { modelById } from "../generate/models.ts";
import { type ChatClient, ProviderError } from "../generate/providers/types.ts";
import {
  CONVERT_MAX_PAYLOAD_BYTES,
  CONVERT_RATE_LIMIT_PER_IDENTITY,
  CONVERT_RATE_LIMIT_WINDOW_SECONDS,
} from "./config.ts";

/** The one store operation convert needs. SupabaseBillingStore satisfies this
 *  structurally; tests inject a stub. */
export interface ConvertStore {
  rateLimitOk(key: string, max: number, windowSeconds: number): Promise<boolean>;
}

export interface ConvertDeps {
  store: ConvertStore;
  /** Chat client factory — same contract as generate's: may THROW for a
   *  provider whose key is unset, mapped to a clean 503 here. */
  makeChat: (provider: string, model: string) => ChatClient;
  jwtSecret: string;
  /** Injectable clock for verifying the session token in tests. */
  nowSeconds?: number;
}

function bearer(req: Request): string | null {
  const h = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!h) return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

export async function handleConvert(req: Request, deps: ConvertDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 1. Cheapest gate first: cap the raw body before parsing.
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > CONVERT_MAX_PAYLOAD_BYTES) return json({ error: "payload_too_large" }, 413);

  // 2. Verify OUR session JWT — identical gate to generate's.
  const token = bearer(req);
  if (!token) return json({ error: "missing_token" }, 401);
  const claims = await verifySessionToken(token, deps.jwtSecret, deps.nowSeconds);
  if (!claims) return json({ error: "invalid_token" }, 401);
  if (claims.kind !== "subscription" && claims.kind !== "trial") {
    return json({ error: "unsupported_token_kind" }, 401);
  }

  // 3. Parse the (size-capped) body.
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  // 4. Input fuse — caps + model gate, before any provider work.
  const parsed = validateConvertBody(body);
  if (!parsed.ok) return json({ error: parsed.error }, parsed.status);
  const { sourceText, context, model } = parsed.value;

  // 4.5 Resolve the validated model → provider. validateConvertBody already
  //     gated on ALLOWED_MODELS, so a miss is registry drift — reject
  //     defensively rather than throw (same posture as generate step 5.5).
  const modelEntry = modelById(model);
  if (!modelEntry) return json({ error: "invalid_model" }, 400);

  // 5. Per-identity rate limit — the endpoint's only quantitative gate.
  //    Keyed per identity under a `convert:` prefix so it can't collide with
  //    (or eat into) generate's window.
  const key = claims.kind === "trial" ? `convert:trial:${claims.sub}` : `convert:sub:${claims.sub}`;
  const withinRate = await deps.store.rateLimitOk(
    key,
    CONVERT_RATE_LIMIT_PER_IDENTITY,
    CONVERT_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!withinRate) return json({ error: "rate_limited" }, 429);

  // 6. Build the chat client. A throw means the provider's key is unset in
  //    the deployment — an ops problem, surfaced as a clean 503 (same mapping
  //    as generate step 7.6). Nothing has been spent.
  let chatClient: ChatClient;
  try {
    chatClient = deps.makeChat(modelEntry.provider, model);
  } catch (e) {
    console.error(JSON.stringify({
      fn: "convert",
      error: "make_chat_failed",
      model,
      provider: modelEntry.provider,
      detail: String(e),
    }));
    return json({ error: "provider_unavailable", retryable: false }, 503);
  }

  // 7. The conversion call: server-owned prompt, the client's text as the one
  //    user block (source text, then the Attached Context block when present —
  //    the same separator the prompt's input description assumes).
  const userText = context ? `${sourceText}\n\n${context}` : sourceText;
  let chat;
  try {
    chat = await chatClient.chat(conversionSystemPrompt(), [{ type: "text", text: userText }]);
  } catch (e) {
    return providerErrorResponse(e);
  }

  // 8. Console-only success log — token counts and attribution, never content
  //    (no generation_log row: that table is billing attribution and this
  //    endpoint charges 0 by design).
  console.log(JSON.stringify({
    fn: "convert",
    key,
    model,
    provider: modelEntry.provider,
    tokens_in: chat.inputTokens,
    tokens_out: chat.outputTokens,
  }));

  // 9. Pass-through: the raw fenced text. The client parses (locked decision).
  return json({ prompt: chat.content }, 200);
}

/** Provider failure → client response, exactly generate's mapping: transient →
 *  503 retryable, terminal → 502, anything unexpected → 500. */
function providerErrorResponse(e: unknown): Response {
  if (e instanceof ProviderError) {
    if (e.retryable) return json({ error: "provider_unavailable", retryable: true }, 503);
    return json({ error: "generation_failed", retryable: false }, 502);
  }
  console.error(JSON.stringify({ fn: "convert", error: String(e) }));
  return json({ error: "server_error" }, 500);
}
