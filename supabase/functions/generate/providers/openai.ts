// =============================================================================
// OpenAI adapters for the `generate` proxy (Phase D2).
// =============================================================================
// The OpenAI key lives ONLY as the OPENAI_API_KEY secret, read from env in
// index.ts and never returned to the client or logged (§14.1). The transport is
// behind the SttClient / ChatClient interfaces so the handler depends on the
// interface, not on fetch — tests inject a stub and never hit real OpenAI or
// spend money.
//
// Request shapes are IDENTICAL to the BYOK path so Managed output matches:
//   transcribe → multipart POST /v1/audio/transcriptions, verbose_json + segment
//     granularity (KEEP IN SYNC with OpenAITranscriptionService.swift)
//   chat       → POST /v1/chat/completions, system + interleaved user content
//     (KEEP IN SYNC with OpenAIPromptGenerationService.swift)
// The TimelineBlock → OpenAI content-block mapping (`image_url` data-URLs with
// detail:"high") lives here — it is the OpenAI-specific wire format and must not
// leak into the shared interleaver.
// =============================================================================

import { CHAT_MODEL, PROVIDER_TIMEOUT_MS, STT_MODEL } from "../config.ts";
import {
  type AudioInput,
  type ChatClient,
  type ChatResult,
  ProviderError,
  type SpeechSegment,
  type SttClient,
  type TimelineBlock,
  type TranscriptionResult,
} from "./types.ts";

const OPENAI_BASE = "https://api.openai.com/v1";

/** An OpenAI content block on the chat wire (text or a detail-tagged image_url). */
type OpenAIContentBlock =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail: string } };

/** Map neutral timeline blocks to OpenAI chat content blocks (detail:"high"). */
export function toOpenAIContent(blocks: TimelineBlock[]): OpenAIContentBlock[] {
  return blocks.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : {
        type: "image_url",
        image_url: { url: `data:${b.mime};base64,${b.base64}`, detail: "high" },
      }
  );
}

/** Shared transport helpers for the OpenAI clients (timeout + classification). */
abstract class OpenAITransport {
  constructor(
    protected readonly apiKey: string,
    protected readonly timeoutMs: number = PROVIDER_TIMEOUT_MS,
    protected readonly base: string = OPENAI_BASE,
  ) {}

  protected async fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      return await fetch(url, { ...init, signal: ctrl.signal });
    } catch (e) {
      // Abort or network error → transient/retryable.
      throw new ProviderError(`openai_transport_error: ${String(e)}`, true, null, "openai");
    } finally {
      clearTimeout(timer);
    }
  }

  protected classify(status: number, where: string): ProviderError {
    if (status === 401) return new ProviderError(`openai_auth_${where}`, false, 401, "openai");
    if (status === 429 || status >= 500) {
      return new ProviderError(`openai_${status}_${where}`, true, status, "openai");
    }
    return new ProviderError(`openai_${status}_${where}`, false, status, "openai");
  }
}

/** Real Whisper STT transport. One retry on a transient fault. */
export class OpenAISttClient extends OpenAITransport implements SttClient {
  constructor(
    apiKey: string,
    private readonly sttModel: string = STT_MODEL,
    timeoutMs: number = PROVIDER_TIMEOUT_MS,
    base: string = OPENAI_BASE,
  ) {
    super(apiKey, timeoutMs, base);
  }

  async transcribe(audio: AudioInput): Promise<TranscriptionResult> {
    const send = async (): Promise<Response> => {
      const form = new FormData();
      // copy into a fresh ArrayBuffer-backed view so the Blob owns clean bytes.
      const view = new Uint8Array(audio.bytes);
      form.append("file", new Blob([view], { type: audio.mime }), audio.filename);
      form.append("model", this.sttModel);
      form.append("response_format", "verbose_json");
      // The trailing [] is required for this repeated field.
      form.append("timestamp_granularities[]", "segment");
      return await this.fetchWithTimeout(`${this.base}/audio/transcriptions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${this.apiKey}` },
        body: form,
      });
    };

    let res = await send();
    if (res.status === 429 || res.status >= 500) res = await send(); // single retry
    if (!res.ok) throw this.classify(res.status, "transcribe");

    const json = await res.json();
    const segments: SpeechSegment[] = Array.isArray(json.segments)
      ? json.segments.map((s: { start: number; end: number; text: string }) => ({
        start: Number(s.start),
        end: Number(s.end),
        // Whisper prefixes a leading space; trim so it doesn't leak into the tag.
        text: String(s.text ?? "").trim(),
      }))
      : [];
    return { segments, durationSeconds: Number(json.duration ?? 0) };
  }
}

/** Real chat-completions transport. One retry on a transient fault. */
export class OpenAIChatClient extends OpenAITransport implements ChatClient {
  constructor(
    apiKey: string,
    private readonly chatModel: string = CHAT_MODEL,
    timeoutMs: number = PROVIDER_TIMEOUT_MS,
    base: string = OPENAI_BASE,
  ) {
    super(apiKey, timeoutMs, base);
  }

  async chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult> {
    const body = JSON.stringify({
      model: this.chatModel,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: toOpenAIContent(content) },
      ],
    });
    const send = () =>
      this.fetchWithTimeout(`${this.base}/chat/completions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${this.apiKey}`, "Content-Type": "application/json" },
        body,
      });

    let res = await send();
    if (res.status === 429 || res.status >= 500) res = await send(); // single retry
    if (!res.ok) throw this.classify(res.status, "chat");

    const json = await res.json();
    const text = json?.choices?.[0]?.message?.content;
    if (typeof text !== "string" || text.length === 0) {
      // A 200 with no usable content is not retryable (we'd just get it again).
      throw new ProviderError("openai_empty_content", false, 200, "openai");
    }
    return {
      provider: "openai",
      content: text,
      inputTokens: Number(json?.usage?.prompt_tokens ?? 0),
      outputTokens: Number(json?.usage?.completion_tokens ?? 0),
      model: String(json?.model ?? this.chatModel),
    };
  }
}
