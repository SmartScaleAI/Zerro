// =============================================================================
// Request parsing + the server-side input fuse (Phase D2).
// =============================================================================
// Enforced BEFORE any OpenAI call or credit work (money-safety ordering). The
// limits in config.ts are set generously ABOVE what the app can produce, so a
// real recording never trips them — they exist only to reject a bypassed /
// forged oversized payload cleanly (413/400), with NO OpenAI call and NO credit
// charged. v1 does not flag/abuse-track (possible Phase G add); it just rejects.
//
// Wire shape the app sends (audio + frames + mode ONLY — never a transcript or
// prompt; the server transcribes and owns the prompt):
//   {
//     "mode": "instruct" | "explain",
//     "audio": { "mime": "audio/m4a", "filename": "rec.m4a",
//                "data": "<base64>", "duration_seconds": 42.0 },   // duration optional
//     "frames": [ { "timestamp": 0.0, "mime": "image/jpeg", "data": "<base64>" }, … ]
//   }
// =============================================================================

import type { FrameInput } from "./interleave.ts";
import type { OutputMode } from "./prompt.ts";
import {
  ALLOWED_AUDIO_MIME,
  ALLOWED_FRAME_MIME,
  MAX_AUDIO_BYTES,
  MAX_AUDIO_SECONDS,
  MAX_FRAMES,
} from "./config.ts";

export interface ParsedRequest {
  mode: OutputMode;
  audio: { bytes: Uint8Array; mime: string; filename: string };
  frames: FrameInput[];
  /** Client-declared seconds, if any — a cheap pre-call sanity gate only. */
  declaredAudioSeconds: number | null;
}

export type ValidationResult =
  | { ok: true; value: ParsedRequest }
  | { ok: false; status: number; error: string };

function reject(status: number, error: string): ValidationResult {
  return { ok: false, status, error };
}

/** Standard (non-url-safe) base64 → bytes. Throws on malformed input. */
function decodeBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Validate an already-parsed JSON body against the input fuse. The caller has
 * already enforced MAX_PAYLOAD_BYTES on the raw bytes (cheapest gate, pre-parse)
 * and JSON-parsed it. Returns a typed ParsedRequest or a {status,error} reject.
 */
export function validateBody(body: unknown): ValidationResult {
  if (typeof body !== "object" || body === null) return reject(400, "invalid_body");
  const b = body as Record<string, unknown>;

  // mode — the ONLY field that influences the (server-owned) system prompt.
  const mode = b.mode;
  if (mode !== "instruct" && mode !== "explain") return reject(400, "invalid_mode");

  // audio.
  const audio = b.audio as Record<string, unknown> | undefined;
  if (!audio || typeof audio !== "object") return reject(400, "missing_audio");
  const audioMime = String(audio.mime ?? "");
  if (!ALLOWED_AUDIO_MIME.includes(audioMime)) return reject(415, "unsupported_audio_mime");
  const audioData = audio.data;
  if (typeof audioData !== "string" || audioData.length === 0) return reject(400, "missing_audio_data");

  let audioBytes: Uint8Array;
  try {
    audioBytes = decodeBase64(audioData);
  } catch {
    return reject(400, "invalid_audio_encoding");
  }
  if (audioBytes.byteLength === 0) return reject(400, "empty_audio");
  if (audioBytes.byteLength > MAX_AUDIO_BYTES) return reject(413, "audio_too_large");

  // Optional declared duration: a cheap honest-client pre-gate. A forged tiny-
  // bitrate long file slips past here but is bounded by MAX_AUDIO_BYTES, and the
  // TRUE seconds gate is re-applied post-transcription before the chat call.
  let declaredAudioSeconds: number | null = null;
  if (audio.duration_seconds !== undefined && audio.duration_seconds !== null) {
    const d = Number(audio.duration_seconds);
    if (!Number.isFinite(d) || d < 0) return reject(400, "invalid_audio_duration");
    if (d > MAX_AUDIO_SECONDS) return reject(413, "audio_too_long");
    declaredAudioSeconds = d;
  }

  const filename = typeof audio.filename === "string" && audio.filename ? audio.filename : "recording.m4a";

  // frames.
  const rawFrames = b.frames;
  if (!Array.isArray(rawFrames)) return reject(400, "missing_frames");
  if (rawFrames.length === 0) return reject(400, "no_frames");
  if (rawFrames.length > MAX_FRAMES) return reject(413, "too_many_frames");

  const frames: FrameInput[] = [];
  for (const raw of rawFrames) {
    if (typeof raw !== "object" || raw === null) return reject(400, "invalid_frame");
    const f = raw as Record<string, unknown>;
    const frameMime = String(f.mime ?? "");
    if (!ALLOWED_FRAME_MIME.includes(frameMime)) return reject(415, "unsupported_frame_mime");
    const ts = Number(f.timestamp);
    if (!Number.isFinite(ts) || ts < 0) return reject(400, "invalid_frame_timestamp");
    const data = f.data;
    if (typeof data !== "string" || data.length === 0) return reject(400, "missing_frame_data");
    // Pass the raw base64 + MIME through (no decode round-trip). The chat adapter
    // wraps it for its wire format (OpenAI data-URL, Gemini inlineData, …).
    frames.push({ timestamp: ts, mime: frameMime, base64: data });
  }

  return {
    ok: true,
    value: { mode, audio: { bytes: audioBytes, mime: audioMime, filename }, frames, declaredAudioSeconds },
  };
}
