// =============================================================================
// Request parsing + the server-side input fuse (Phase D2).
// =============================================================================
// Enforced BEFORE any OpenAI call or credit work (money-safety ordering). The
// limits in config.ts are set generously ABOVE what the app can produce, so a
// real recording never trips them — they exist only to reject a bypassed /
// forged oversized payload cleanly (413/400), with NO OpenAI call and NO credit
// charged. v1 does not flag/abuse-track (possible Phase G add); it just rejects.
//
// Wire shape the app sends (audio + frames ONLY — never a transcript or
// prompt; the server transcribes and owns the prompt):
//   {
//     "has_speech": true,                                          // optional (Phase 6); false → skip STT
//     "audio": { "mime": "audio/m4a", "filename": "rec.m4a",
//                "data": "<base64>", "duration_seconds": 42.0 },   // duration optional
//     "frames": [ { "timestamp": 0.0, "mime": "image/jpeg", "data": "<base64>" }, … ]
//   }
// Typed-artifact refactor (Phase 3): the former "mode" field is GONE from the
// contract. A body that still carries one (the pre-Phase-4 dev client does) is
// tolerated like any unknown field — silently ignored, never a 400 — so the
// in-flight client doesn't brick during the server-first deploy window.
// =============================================================================

import type { ClickInput, FrameInput } from "./interleave.ts";
import { ALLOWED_MODELS, DEFAULT_MODEL_ID } from "./models.ts";
import {
  ALLOWED_AUDIO_MIME,
  ALLOWED_FRAME_MIME,
  MAX_AUDIO_BYTES,
  MAX_AUDIO_SECONDS,
  MAX_CLICK_LABEL_CHARS,
  MAX_CLICKS,
  MAX_FRAMES,
  MAX_OCR_TEXT_CHARS,
} from "./config.ts";

export interface ParsedRequest {
  /** Phase 4 — the validated generation model (always resolved: an absent wire
   *  field becomes DEFAULT_MODEL_ID). Selects provider + credit price ONLY —
   *  it never influences the (server-owned) system prompt; since the typed-
   *  artifact refactor NO client field does. */
  model: string;
  audio: { bytes: Uint8Array; mime: string; filename: string };
  frames: FrameInput[];
  /** Phase 4 — resolved clicks (already redacted client-side; count + label
   *  length capped here). Empty array when none were sent. */
  clicks: ClickInput[];
  /** Client-declared seconds, if any — a cheap pre-call sanity gate only. */
  declaredAudioSeconds: number | null;
  /** Phase 6 — client's no-speech hint. `false` ONLY when the client detected
   *  no speech-level energy; the server then skips the Whisper call. Defaults
   *  to `true` (transcribe) for any other / absent value, so an older app or a
   *  forged body never silently suppresses transcription. A cost hint only —
   *  it never influences the (server-owned) system prompt. */
  hasSpeech: boolean;
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

  // (The v1 "mode" field is no longer read — see the header note. Its absence,
  // presence, or any value is equally ignored.)

  // model (Phase 4) — OPTIONAL. Absent → the registry's recommended default
  // (backward compatible: a pre-multi-model app sends no model). Present but
  // not an ENABLED registry entry → 400 before any provider call or credit
  // work (ALLOWED_MODELS is also the kill switch). No tier gating — every
  // identity sees all models (Appendix C #6).
  let model: string = DEFAULT_MODEL_ID;
  if (b.model !== undefined && b.model !== null) {
    if (typeof b.model !== "string" || !ALLOWED_MODELS.has(b.model)) {
      return reject(400, "invalid_model");
    }
    model = b.model;
  }

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
    // Phase 3: optional redacted OCR text. Already masked client-side — we DON'T
    // re-scan (the server trusts the client's redaction). Defensively length-cap
    // it so a forged body can't bloat the prompt the server's key pays for; an
    // empty/absent value becomes undefined so no `on-screen text:` block emits.
    let ocrText: string | undefined;
    const rawOcr = f.ocr_text;
    if (typeof rawOcr === "string" && rawOcr.length > 0) {
      ocrText = rawOcr.length > MAX_OCR_TEXT_CHARS ? rawOcr.slice(0, MAX_OCR_TEXT_CHARS) : rawOcr;
    }
    // Pass the raw base64 + MIME through (no decode round-trip). The chat adapter
    // wraps it for its wire format (OpenAI data-URL, Gemini inlineData, …).
    frames.push({ timestamp: ts, mime: frameMime, base64: data, ocrText });
  }

  // clicks (Phase 4) — OPTIONAL (older apps omit it → none). Not a hard reject:
  // a malformed/oversized clicks array can't come from a real recording, so we
  // defensively DROP bad/excess entries rather than failing the whole request.
  // The count is capped (excess sliced off) and each label length-capped; labels
  // are already redacted client-side, so we trust + cap only.
  const clicks: ClickInput[] = [];
  const rawClicks = b.clicks;
  if (Array.isArray(rawClicks)) {
    for (const raw of rawClicks) {
      if (clicks.length >= MAX_CLICKS) break;
      if (typeof raw !== "object" || raw === null) continue;
      const c = raw as Record<string, unknown>;
      const ts = Number(c.timestamp);
      if (!Number.isFinite(ts) || ts < 0) continue;
      const rawLabel = c.label;
      if (typeof rawLabel !== "string" || rawLabel.length === 0) continue;
      const label = rawLabel.length > MAX_CLICK_LABEL_CHARS
        ? rawLabel.slice(0, MAX_CLICK_LABEL_CHARS)
        : rawLabel;
      clicks.push({ timestamp: ts, label });
    }
  }

  // Phase 6 — no-speech hint. Skip Whisper ONLY on an explicit `false`; every
  // other value (true / absent / non-boolean from an older or forged body)
  // defaults to transcribing, the safe direction.
  const hasSpeech = b.has_speech !== false;

  return {
    ok: true,
    value: { model, audio: { bytes: audioBytes, mime: audioMime, filename }, frames, clicks, declaredAudioSeconds, hasSpeech },
  };
}
