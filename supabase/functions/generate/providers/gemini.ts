// =============================================================================
// Gemini chat adapter for the `generate` proxy.
// =============================================================================
// GeminiChatClient maps the neutral TimelineBlock[] to a generateContent request
// and the response back to the neutral ChatResult. There is NO Gemini STT this
// phase — transcription stays on OpenAI Whisper (the interleaver needs
// segment-level timestamps Gemini's audio API doesn't expose the same way).
//
// Field casing verified against ai.google.dev/gemini-api/docs (2026-06-04):
//   - camelCase: systemInstruction, inlineData/mimeType, generationConfig,
//     thinkingConfig/thinkingLevel.
//   - mediaResolution nests PER-PART inside each image part (Gemini 3), not in
//     generationConfig.
//   - Auth via the x-goog-api-key HEADER, never the URL query string (it would
//     land in logs).
//   - With thinking on, response parts may include `thought`-flagged parts and
//     usageMetadata carries thoughtsTokenCount (billed as output) — we skip the
//     thought text but COUNT thought tokens so cost logging is honest.
// Re-verify field names at https://ai.google.dev/gemini-api/docs/gemini-3 and
// .../media-resolution if Google revs the API.
// =============================================================================

import { GEMINI_THINKING_LEVEL, PROVIDER_TIMEOUT_MS } from "../config.ts";
import {
  type ChatClient,
  type ChatResult,
  ProviderError,
  type TimelineBlock,
} from "./types.ts";

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta";

interface GeminiPart {
  text?: string;
  inlineData?: { mimeType: string; data: string };
  mediaResolution?: { level: string };
}

/** Map neutral timeline blocks to Gemini `parts`, per-part media resolution. */
export function toGeminiParts(blocks: TimelineBlock[]): GeminiPart[] {
  return blocks.map((b) =>
    b.type === "text"
      ? { text: b.text }
      : {
        inlineData: { mimeType: b.mime, data: b.base64 },
        mediaResolution: { level: "media_resolution_high" }, // analog of OpenAI detail:"high"
      }
  );
}

export class GeminiChatClient implements ChatClient {
  constructor(
    private readonly apiKey: string,
    private readonly chatModel: string,
    private readonly thinkingLevel: string = GEMINI_THINKING_LEVEL,
    private readonly timeoutMs: number = PROVIDER_TIMEOUT_MS,
    private readonly base: string = GEMINI_BASE,
  ) {}

  private async fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      return await fetch(url, { ...init, signal: ctrl.signal });
    } catch (e) {
      throw new ProviderError(`gemini_transport_error: ${String(e)}`, true, null, "gemini");
    } finally {
      clearTimeout(timer);
    }
  }

  private classify(status: number): ProviderError {
    if (status === 401 || status === 403) {
      return new ProviderError(`gemini_auth_${status}`, false, status, "gemini");
    }
    if (status === 429 || status >= 500) {
      return new ProviderError(`gemini_${status}`, true, status, "gemini");
    }
    return new ProviderError(`gemini_${status}`, false, status, "gemini");
  }

  async chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult> {
    const body = JSON.stringify({
      systemInstruction: { parts: [{ text: systemPrompt }] },
      contents: [{ role: "user", parts: toGeminiParts(content) }],
      generationConfig: {
        thinkingConfig: { thinkingLevel: this.thinkingLevel },
      },
    });
    const url = `${this.base}/models/${this.chatModel}:generateContent`;
    const send = () =>
      this.fetchWithTimeout(url, {
        method: "POST",
        headers: { "x-goog-api-key": this.apiKey, "Content-Type": "application/json" },
        body,
      });

    let res = await send();
    if (res.status === 429 || res.status >= 500) res = await send(); // single retry
    if (!res.ok) throw this.classify(res.status);

    const json = await res.json();

    // A prompt-level block (safety, recitation) means no candidate at all.
    const blockReason = json?.promptFeedback?.blockReason;
    if (blockReason) {
      throw new ProviderError(`gemini_empty_content: blocked ${blockReason}`, false, 200, "gemini");
    }

    const candidate = json?.candidates?.[0];
    const finish = candidate?.finishReason;

    // MAX_TOKENS = output-token truncation: the partial text can carry an
    // unterminated <<<ZERRO_ARTIFACT fence, so withhold it (handoff-artifact-
    // fence-leak). No longer folded into usableFinish.
    if (finish === "MAX_TOKENS") {
      throw new ProviderError("gemini_truncated: MAX_TOKENS", false, 200, "gemini", true);
    }
    // A non-STOP finish (SAFETY/RECITATION/PROHIBITED_CONTENT) yields no usable
    // text — same non-retryable "empty content" class as OpenAI.
    const usableFinish = finish === undefined || finish === "STOP";

    const parts = candidate?.content?.parts;
    const text = Array.isArray(parts)
      ? parts
        .filter((p: { thought?: boolean; text?: unknown }) =>
          p.thought !== true && typeof p.text === "string"
        )
        .map((p: { text: string }) => p.text)
        .join("")
      : "";

    if (!usableFinish || text.length === 0) {
      throw new ProviderError(
        `gemini_empty_content${finish ? `: ${finish}` : ""}`,
        false,
        200,
        "gemini",
      );
    }

    const usage = json?.usageMetadata ?? {};
    // thoughtsTokenCount is billed at the output rate — fold it into outputTokens
    // so cost logging matches the bill.
    const outputTokens = Number(usage.candidatesTokenCount ?? 0) +
      Number(usage.thoughtsTokenCount ?? 0);
    return {
      provider: "gemini",
      content: text,
      inputTokens: Number(usage.promptTokenCount ?? 0),
      outputTokens,
      model: String(json?.modelVersion ?? this.chatModel),
    };
  }
}
