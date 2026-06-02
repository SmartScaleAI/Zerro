// =============================================================================
// OpenAI access for the `generate` proxy (Phase D2).
// =============================================================================
// The OpenAI key lives ONLY as the OPENAI_API_KEY secret, read from env HERE and
// never returned to the client or logged (§14.1). The transport is behind the
// `OpenAIClient` interface so the handler depends on the interface, not on fetch
// — tests inject a stub and never hit real OpenAI or spend money.
//
// Request shapes are IDENTICAL to the BYOK path so Managed output matches:
//   transcribe → multipart POST /v1/audio/transcriptions, verbose_json + segment
//     granularity (KEEP IN SYNC with OpenAITranscriptionService.swift)
//   chat       → POST /v1/chat/completions, system + interleaved user content
//     (KEEP IN SYNC with OpenAIPromptGenerationService.swift)
// =============================================================================

import type { SpeechSegment, UserContentBlock } from "./interleave.ts";
import { CHAT_MODEL, OPENAI_TIMEOUT_MS, STT_MODEL } from "./config.ts";

export interface TranscriptionResult {
  segments: SpeechSegment[];
  /** Whisper's measured audio duration (verbose_json `duration`), seconds. */
  durationSeconds: number;
}

export interface ChatResult {
  content: string;
  inputTokens: number;
  outputTokens: number;
  model: string;
}

export interface AudioInput {
  bytes: Uint8Array;
  mime: string;
  filename: string;
}

export interface OpenAIClient {
  transcribe(audio: AudioInput): Promise<TranscriptionResult>;
  chat(systemPrompt: string, userContent: UserContentBlock[]): Promise<ChatResult>;
}

/**
 * An OpenAI failure. `retryable` distinguishes a transient fault (429 / 5xx /
 * timeout — the client should try again, NO credit charged) from a terminal one
 * (a 4xx we won't recover from). The handler never charges a credit on either.
 */
export class OpenAIError extends Error {
  readonly retryable: boolean;
  readonly status: number | null;
  constructor(message: string, retryable: boolean, status: number | null = null) {
    super(message);
    this.name = "OpenAIError";
    this.retryable = retryable;
    this.status = status;
  }
}

const OPENAI_BASE = "https://api.openai.com/v1";

/** Real transport. Reads the key from env; one retry on a transient fault. */
export class HttpOpenAIClient implements OpenAIClient {
  constructor(
    private readonly apiKey: string,
    private readonly sttModel: string = STT_MODEL,
    private readonly chatModel: string = CHAT_MODEL,
    private readonly timeoutMs: number = OPENAI_TIMEOUT_MS,
    private readonly base: string = OPENAI_BASE,
  ) {}

  private async fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      return await fetch(url, { ...init, signal: ctrl.signal });
    } catch (e) {
      // Abort or network error → transient/retryable.
      throw new OpenAIError(`openai_transport_error: ${String(e)}`, true);
    } finally {
      clearTimeout(timer);
    }
  }

  private classify(status: number, where: string): OpenAIError {
    if (status === 401) return new OpenAIError(`openai_auth_${where}`, false, 401);
    if (status === 429 || status >= 500) return new OpenAIError(`openai_${status}_${where}`, true, status);
    return new OpenAIError(`openai_${status}_${where}`, false, status);
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

  async chat(systemPrompt: string, userContent: UserContentBlock[]): Promise<ChatResult> {
    const body = JSON.stringify({
      model: this.chatModel,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userContent },
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
    const content = json?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.length === 0) {
      // A 200 with no usable content is not retryable (we'd just get it again).
      throw new OpenAIError("openai_empty_content", false, 200);
    }
    return {
      content,
      inputTokens: Number(json?.usage?.prompt_tokens ?? 0),
      outputTokens: Number(json?.usage?.completion_tokens ?? 0),
      model: String(json?.model ?? this.chatModel),
    };
  }
}
