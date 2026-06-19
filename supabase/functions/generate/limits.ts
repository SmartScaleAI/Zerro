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
import type { SpeechSegment } from "./providers/types.ts";
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
  MAX_TRANSCRIPT_SEGMENTS,
  MAX_TRANSCRIPT_TEXT_CHARS,
} from "./config.ts";

export interface ParsedRequest {
  /** Phase 4 — the validated generation model (always resolved: an absent wire
   *  field becomes DEFAULT_MODEL_ID). Selects provider + credit price ONLY —
   *  it never influences the (server-owned) system prompt; since the typed-
   *  artifact refactor NO client field does. */
  model: string;
  /** The recording audio, or `null` on the Dev Mode CALL 2 (`mode:"dev"` with a
   *  pre-supplied transcript): the audio already rode in the free call 1, so it
   *  is NOT re-uploaded and the handler uses `suppliedTranscript` instead of STT.
   *  Always present on every normal / non-dev path. */
  audio: { bytes: Uint8Array; mime: string; filename: string } | null;
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

  /** Phase 2 (Dev Mode) — `"dev"` selects the repo-scoped dev system prompt
   *  (Goal/Changes/Scope); undefined → the normal v2 prompt. This is a SELECTOR
   *  among server-owned prompts ONLY — the client never supplies prompt content
   *  (Appendix C #3). Any value other than `"dev"` resolves to normal. */
  mode: "dev" | undefined;

  /** Phase 2 (Dev Mode CALL 2) — the client-supplied transcript: the client
   *  already transcribed via the free call 1 (`dev_transcribe`) and resolved
   *  deixis anchors against THIS exact transcript, so the server SKIPS re-STT and
   *  generates against it (no double STT round-trip / charge, and the prompt
   *  lines up with the resolved anchors). `null` on every normal path (the server
   *  transcribes). Only honored for `mode:"dev"`. `durationSeconds` is the
   *  recording length (for the STT-cost meter + the true-seconds gate, since no
   *  audio is uploaded on call 2). */
  suppliedTranscript: { segments: SpeechSegment[]; durationSeconds: number } | null;
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

// =============================================================================
// Dev Mode "dev-transcribe" (Phase 2, call 1) — a FREE word-level transcription
// (§7). The request carries AUDIO ONLY (no frames, no model, no clicks): the
// client needs the word transcript to resolve anchors before the billable
// generation (call 2). Validated separately + minimally so a transcribe-only
// body isn't rejected for "missing_frames", and so the audio fuse (mime, size,
// duration) still applies. `validateBody` is deliberately left untouched.
// =============================================================================

export interface TranscribeRequest {
  audio: { bytes: Uint8Array; mime: string; filename: string };
  hasSpeech: boolean;
}

export type TranscribeValidationResult =
  | { ok: true; value: TranscribeRequest }
  | { ok: false; status: number; error: string };

export function validateTranscribeBody(body: unknown): TranscribeValidationResult {
  if (typeof body !== "object" || body === null) return { ok: false, status: 400, error: "invalid_body" };
  const b = body as Record<string, unknown>;

  // audio (same fuse as validateBody — mime allow-list, base64, size cap).
  const audio = b.audio as Record<string, unknown> | undefined;
  if (!audio || typeof audio !== "object") return { ok: false, status: 400, error: "missing_audio" };
  const audioMime = String(audio.mime ?? "");
  if (!ALLOWED_AUDIO_MIME.includes(audioMime)) return { ok: false, status: 415, error: "unsupported_audio_mime" };
  const audioData = audio.data;
  if (typeof audioData !== "string" || audioData.length === 0) return { ok: false, status: 400, error: "missing_audio_data" };

  let audioBytes: Uint8Array;
  try {
    audioBytes = decodeBase64(audioData);
  } catch {
    return { ok: false, status: 400, error: "invalid_audio_encoding" };
  }
  if (audioBytes.byteLength === 0) return { ok: false, status: 400, error: "empty_audio" };
  if (audioBytes.byteLength > MAX_AUDIO_BYTES) return { ok: false, status: 413, error: "audio_too_large" };

  if (audio.duration_seconds !== undefined && audio.duration_seconds !== null) {
    const d = Number(audio.duration_seconds);
    if (!Number.isFinite(d) || d < 0) return { ok: false, status: 400, error: "invalid_audio_duration" };
    if (d > MAX_AUDIO_SECONDS) return { ok: false, status: 413, error: "audio_too_long" };
  }

  const filename = typeof audio.filename === "string" && audio.filename ? audio.filename : "recording.m4a";
  const hasSpeech = b.has_speech !== false;

  return { ok: true, value: { audio: { bytes: audioBytes, mime: audioMime, filename }, hasSpeech } };
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

  // Phase 2 — Dev Mode prompt selector (server-owned prompts only). Only the
  // exact string "dev" selects the dev prompt; anything else → normal. Parsed
  // up here because it gates the audio-optionality + the supplied transcript.
  const mode: "dev" | undefined = b.mode === "dev" ? "dev" : undefined;

  // Phase 2 (Dev Mode CALL 2) — the client-supplied transcript. ONLY honored for
  // mode:"dev"; present → the server skips re-STT and the audio becomes optional
  // (it rode in the free call 1, not re-uploaded). A malformed transcript is a
  // hard reject (a real call-2 body always carries a well-formed one).
  let suppliedTranscript: { segments: SpeechSegment[]; durationSeconds: number } | null = null;
  if (mode === "dev" && b.transcript !== undefined && b.transcript !== null) {
    const parsed = parseSuppliedTranscript(b.transcript);
    if (!parsed.ok) return reject(parsed.status, parsed.error);
    suppliedTranscript = parsed.value;
  }

  // audio — OPTIONAL only on the Dev Mode call 2 (a pre-supplied transcript means
  // the audio already rode in the free call 1; it is NOT re-uploaded). Every
  // other path REQUIRES it (a normal body with no audio is still `missing_audio`).
  let audio: { bytes: Uint8Array; mime: string; filename: string } | null = null;
  let declaredAudioSeconds: number | null = null;
  const rawAudio = b.audio as Record<string, unknown> | undefined;
  if (rawAudio && typeof rawAudio === "object") {
    const audioMime = String(rawAudio.mime ?? "");
    if (!ALLOWED_AUDIO_MIME.includes(audioMime)) return reject(415, "unsupported_audio_mime");
    const audioData = rawAudio.data;
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
    if (rawAudio.duration_seconds !== undefined && rawAudio.duration_seconds !== null) {
      const d = Number(rawAudio.duration_seconds);
      if (!Number.isFinite(d) || d < 0) return reject(400, "invalid_audio_duration");
      if (d > MAX_AUDIO_SECONDS) return reject(413, "audio_too_long");
      declaredAudioSeconds = d;
    }

    const filename = typeof rawAudio.filename === "string" && rawAudio.filename ? rawAudio.filename : "recording.m4a";
    audio = { bytes: audioBytes, mime: audioMime, filename };
  } else if (!suppliedTranscript) {
    // No audio AND no dev transcript → a normal request missing its audio.
    return reject(400, "missing_audio");
  }

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
  // defaults to transcribing, the safe direction. (On the dev call 2 a supplied
  // transcript takes priority over this — see the handler's step 9.)
  const hasSpeech = b.has_speech !== false;

  return {
    ok: true,
    value: { model, audio, frames, clicks, declaredAudioSeconds, hasSpeech, mode, suppliedTranscript },
  };
}

/** Parse + defensively cap a client-supplied Dev Mode transcript (call 2). A
 *  non-object / non-array-segments body is a hard reject; individual malformed
 *  segments are DROPPED (a real transcript can't carry them), the segment count
 *  is capped, and each segment's text is length-capped — the same trust-and-cap
 *  posture the click + ocr_text fuses use. `duration_seconds` (the recording
 *  length, since no audio is uploaded) defaults to 0 when absent. */
type SuppliedTranscriptResult =
  | { ok: true; value: { segments: SpeechSegment[]; durationSeconds: number } }
  | { ok: false; status: number; error: string };

function parseSuppliedTranscript(raw: unknown): SuppliedTranscriptResult {
  if (typeof raw !== "object" || raw === null) return { ok: false, status: 400, error: "invalid_transcript" };
  const t = raw as Record<string, unknown>;

  const rawSegments = t.segments;
  if (!Array.isArray(rawSegments)) return { ok: false, status: 400, error: "invalid_transcript_segments" };
  const segments: SpeechSegment[] = [];
  for (const rawSeg of rawSegments) {
    if (segments.length >= MAX_TRANSCRIPT_SEGMENTS) break; // defensive cap; drop excess
    if (typeof rawSeg !== "object" || rawSeg === null) continue;
    const s = rawSeg as Record<string, unknown>;
    const start = Number(s.start);
    const end = Number(s.end);
    if (!Number.isFinite(start) || start < 0) continue;
    if (!Number.isFinite(end) || end < 0) continue;
    const text = typeof s.text === "string" ? s.text : "";
    if (text.length === 0) continue;
    segments.push({
      start,
      end,
      text: text.length > MAX_TRANSCRIPT_TEXT_CHARS ? text.slice(0, MAX_TRANSCRIPT_TEXT_CHARS) : text,
    });
  }

  let durationSeconds = 0;
  if (t.duration_seconds !== undefined && t.duration_seconds !== null) {
    const d = Number(t.duration_seconds);
    if (!Number.isFinite(d) || d < 0) return { ok: false, status: 400, error: "invalid_transcript_duration" };
    // Mirror the audio fuse's true-seconds cap (no audio rides on call 2, so this
    // is the only place the duration is bounded) — a forged over-length duration
    // can't slip through to inflate the logged STT cost on a later gate.
    if (d > MAX_AUDIO_SECONDS) return { ok: false, status: 413, error: "audio_too_long" };
    durationSeconds = d;
  }

  return { ok: true, value: { segments, durationSeconds } };
}
