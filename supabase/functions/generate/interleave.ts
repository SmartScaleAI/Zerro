// =============================================================================
// Server-side port of the frame+transcript interleaving (Phase D2).
// =============================================================================
// The Managed path must build the SAME chronologically-interleaved multimodal
// payload the BYOK path does, or Managed output drifts from BYOK.
//   KEEP IN SYNC with Zerro/Services/InterleavedTimeline.swift (Interleaver.merge,
//     TimelineItem.timestampTag / mmss, the frame-before-speech tie-break)
//
// The interleaving ALGORITHM and tag text are byte-identical across BYOK/Managed
// and across chat providers. What differs per provider is only the final WIRE
// format: this file emits provider-neutral `TimelineBlock`s, and each chat
// adapter (providers/openai.ts, providers/gemini.ts) converts them to its own
// content shape (OpenAI `image_url` data-URLs with detail:"high", Gemini
// `inlineData`, …). BYOK is intentionally OpenAI-only; do not "fix" that
// divergence — it is correct, not drift.
//
// The naive "all frames, then all transcript" ordering is destructive — it
// severs the temporal link the model uses to resolve deictic references
// ("this"/"that"/"here") against the visual context. Preserve the chronology.
// =============================================================================

import type { SpeechSegment, TimelineBlock } from "./providers/types.ts";

export type { SpeechSegment, TimelineBlock };

export interface FrameInput {
  /** Seconds from recording start (client-supplied, validated upstream). */
  timestamp: number;
  /** Frame image MIME (image/jpeg) and its raw base64 — NOT a data URL. The
   *  data-URL / inline-data wrapping is the chat adapter's job. */
  mime: string;
  base64: string;
}

type Item =
  | { kind: "frame"; start: number; mime: string; base64: string }
  | { kind: "speech"; start: number; end: number; text: string };

/** M:SS, seconds TRUNCATED not rounded, clamped at 0. Mirrors Swift `mmss`. */
function mmss(seconds: number): string {
  const safe = Math.max(0, seconds);
  const total = Math.floor(safe);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

/** Frames render BEFORE speech that starts at the same second (Swift tieRank). */
function tieRank(item: Item): number {
  return item.kind === "frame" ? 0 : 1;
}

/**
 * Merge frames + transcript segments into the interleaved neutral timeline.
 * One text block per item; frames additionally emit an image block. Every tag is
 * newline-prefixed so each lands on its own rendered line — matching the BYOK
 * request byte-for-byte once an adapter renders the blocks.
 */
export function buildInterleavedContent(
  frames: FrameInput[],
  segments: SpeechSegment[],
): TimelineBlock[] {
  const items: Item[] = [];
  for (const f of frames) {
    items.push({ kind: "frame", start: f.timestamp, mime: f.mime, base64: f.base64 });
  }
  for (const s of segments) {
    items.push({ kind: "speech", start: s.start, end: s.end, text: s.text });
  }

  // Sort by start time; ties broken frame-before-speech (file header).
  items.sort((a, b) => (a.start !== b.start ? a.start - b.start : tieRank(a) - tieRank(b)));

  const content: TimelineBlock[] = [];
  for (const item of items) {
    if (item.kind === "frame") {
      content.push({ type: "text", text: `\n[${mmss(item.start)}] ` });
      content.push({ type: "image", mime: item.mime, base64: item.base64 });
    } else {
      const tag = `[${mmss(item.start)}–${mmss(item.end)}]`;
      content.push({ type: "text", text: `\n${tag} "${item.text}"` });
    }
  }
  return content;
}
