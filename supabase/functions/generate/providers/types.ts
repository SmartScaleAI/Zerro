// =============================================================================
// Provider-neutral model interfaces for the `generate` proxy.
// =============================================================================
// The handler depends on these interfaces, never on a vendor. STT and chat are
// SEPARATE interfaces because they are independent calls in the handler — one
// provider can do transcription while another does the chat (today: OpenAI
// Whisper for STT, OpenAI or Gemini for chat). The interleaver emits the neutral
// `TimelineBlock` shape below; each chat adapter converts it to its own wire
// format, so the chronology/tagging logic stays shared and identical.
//
// These result types were already vendor-neutral in the old openai.ts; they
// move here unchanged except `ChatResult.provider` (added so cost.ts can key its
// price table on `${provider}:${model}`).
// =============================================================================

export interface SpeechSegment {
  start: number;
  end: number;
  text: string;
}

export interface TranscriptionResult {
  segments: SpeechSegment[];
  /** The STT provider's measured audio duration (seconds). */
  durationSeconds: number;
}

export interface ChatResult {
  /** Which provider produced this result ("openai" | "gemini") — cost key. */
  provider: string;
  content: string;
  inputTokens: number;
  outputTokens: number;
  /** The response's reported model version (logging only — NOT the cost key). */
  model: string;
}

export interface AudioInput {
  bytes: Uint8Array;
  mime: string;
  filename: string;
}

/**
 * A provider-neutral timeline block emitted by the interleaver. Each chat
 * adapter maps these to its own wire format (OpenAI `image_url` data-URLs,
 * Gemini `inlineData`, …). This is the ONLY shape that crosses the transport
 * boundary, so no vendor wire format leaks into the shared interleaving logic.
 */
export type TimelineBlock =
  | { type: "text"; text: string }
  | { type: "image"; mime: string; base64: string };

export interface SttClient {
  transcribe(audio: AudioInput): Promise<TranscriptionResult>;
}

export interface ChatClient {
  chat(systemPrompt: string, content: TimelineBlock[]): Promise<ChatResult>;
}

/**
 * A provider failure. `retryable` distinguishes a transient fault (429 / 5xx /
 * timeout / network — the client should try again, NO credit charged) from a
 * terminal one (a 4xx we won't recover from). The handler never charges a credit
 * on either. `provider` is for log clarity only; `message` carries an internal
 * code (`openai_*` / `gemini_*`) used by adapter tests, never sent on the wire.
 */
export class ProviderError extends Error {
  readonly retryable: boolean;
  readonly status: number | null;
  readonly provider: string;
  constructor(
    message: string,
    retryable: boolean,
    status: number | null = null,
    provider = "openai",
  ) {
    super(message);
    this.name = "ProviderError";
    this.retryable = retryable;
    this.status = status;
    this.provider = provider;
  }
}
