// =============================================================================
// Anthropic chat adapter for the `generate` proxy (multi-model Phase 3).
// =============================================================================
// AnthropicChatClient maps the neutral TimelineBlock[] to a Messages API request
// and the response back to the neutral ChatResult. There is NO Anthropic STT —
// transcription stays on OpenAI Whisper regardless of the chat provider.
//
// Wire format verified against the Messages API (2026-06-10), mirroring the
// Phase 0 eval harness's chatAnthropic (apps/desktop/Scripts/eval-models.mjs):
//   - Headers: x-api-key (NOT Authorization), anthropic-version: 2023-06-01.
//   - `max_tokens` is REQUIRED (unlike OpenAI/Gemini here). 8192 is ample for
//     this workload (~966 output tokens typical).
//   - System prompt rides the TOP-LEVEL `system` field, never a message.
//   - Image blocks: {type:"image", source:{type:"base64", media_type, data}}.
//   - NO sampling params and NO `thinking` field: on Opus 4.7 temperature/
//     top_p/top_k 400, and an absent `thinking` field means thinking is off —
//     matches the eval-gated harness shape exactly (Phase 0.5 passed on it).
//   - usage.input_tokens / usage.output_tokens; thinking would be billed inside
//     output_tokens, and thinking is off, so output_tokens is the visible text.
//   - A safety refusal is stop_reason "refusal" (usually with no text) — the
//     same non-retryable "empty content" class as the other adapters.
// =============================================================================

import { PROVIDER_TIMEOUT_MS } from "../config.ts";
import {
  type ChatClient,
  type ChatResult,
  ProviderError,
  type TimelineBlock,
} from "./types.ts";

const ANTHROPIC_BASE = "https://api.anthropic.com/v1";
const ANTHROPIC_VERSION = "2023-06-01";
// Required by the Messages API. Generous headroom over the ~966-token typical so
// a long recording's longer response isn't cut off (the old 8192 truncated
// ~2-minute recordings — handoff-artifact-fence-leak). A response that still
// hits this is detected via stop_reason "max_tokens" and surfaced as a
// truncation, never returned half-formed. KEEP IN SYNC with the BYOK
// AnthropicPromptGenerationService.maxTokens.
const ANTHROPIC_MAX_TOKENS = 16384;

interface AnthropicContentBlock {
  type: string;
  text?: string;
  source?: { type: string; media_type: string; data: string };
}

/** Map neutral timeline blocks to Anthropic content blocks (text / base64 image). */
export function toAnthropicContent(blocks: TimelineBlock[]): AnthropicContentBlock[] {
  return blocks.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : { type: "image", source: { type: "base64", media_type: b.mime, data: b.base64 } }
  );
}

export class AnthropicChatClient implements ChatClient {
  constructor(
    private readonly apiKey: string,
    private readonly chatModel: string,
    private readonly timeoutMs: number = PROVIDER_TIMEOUT_MS,
    private readonly base: string = ANTHROPIC_BASE,
  ) {}

  private async fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      return await fetch(url, { ...init, signal: ctrl.signal });
    } catch (e) {
      throw new ProviderError(`anthropic_transport_error: ${String(e)}`, true, null, "anthropic");
    } finally {
      clearTimeout(timer);
    }
  }

  private classify(status: number): ProviderError {
    if (status === 401 || status === 403) {
      return new ProviderError(`anthropic_auth_${status}`, false, status, "anthropic");
    }
    if (status === 429 || status >= 500) {
      return new ProviderError(`anthropic_${status}`, true, status, "anthropic");
    }
    return new ProviderError(`anthropic_${status}`, false, status, "anthropic");
  }

  async chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult> {
    const body = JSON.stringify({
      model: this.chatModel,
      max_tokens: ANTHROPIC_MAX_TOKENS,
      system: systemPrompt,
      messages: [{ role: "user", content: toAnthropicContent(content) }],
    });
    const send = () =>
      this.fetchWithTimeout(`${this.base}/messages`, {
        method: "POST",
        headers: {
          "x-api-key": this.apiKey,
          "anthropic-version": ANTHROPIC_VERSION,
          "Content-Type": "application/json",
        },
        body,
      });

    let res = await send();
    if (res.status === 429 || res.status >= 500) res = await send(); // single retry
    if (!res.ok) throw this.classify(res.status);

    const json = await res.json();

    // A safety refusal yields stop_reason "refusal" and no usable text — the
    // same non-retryable "empty content" class as OpenAI/Gemini (the handler
    // maps non-retryable to 502; no credit is charged).
    const stopReason = json?.stop_reason;

    // Output-token truncation: the partial text can carry an unterminated
    // <<<ZERRO_ARTIFACT fence, so withhold it (handoff-artifact-fence-leak).
    // Checked before the empty-content guard — a truncated response has text.
    if (stopReason === "max_tokens") {
      throw new ProviderError("anthropic_truncated: max_tokens", false, 200, "anthropic", true);
    }

    const text = Array.isArray(json?.content)
      ? json.content
        .filter((b: { type?: string; text?: unknown }) =>
          b.type === "text" && typeof b.text === "string"
        )
        .map((b: { text: string }) => b.text)
        .join("")
      : "";

    if (stopReason === "refusal" || text.length === 0) {
      throw new ProviderError(
        `anthropic_empty_content${stopReason ? `: ${stopReason}` : ""}`,
        false,
        200,
        "anthropic",
      );
    }

    const usage = json?.usage ?? {};
    return {
      provider: "anthropic",
      content: text,
      inputTokens: Number(usage.input_tokens ?? 0),
      outputTokens: Number(usage.output_tokens ?? 0),
      model: String(json?.model ?? this.chatModel),
    };
  }
}
