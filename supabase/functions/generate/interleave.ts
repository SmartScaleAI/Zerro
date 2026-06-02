// =============================================================================
// Server-side port of the frame+transcript interleaving (Phase D2).
// =============================================================================
// The Managed path must build the SAME chronologically-interleaved multimodal
// payload the BYOK path does, or Managed output drifts from BYOK.
//   KEEP IN SYNC with Zerro/Services/InterleavedTimeline.swift (Interleaver.merge,
//     TimelineItem.timestampTag / mmss, the frame-before-speech tie-break)
//   KEEP IN SYNC with Zerro/Services/OpenAI/OpenAIPromptGenerationService.swift
//     (the per-item text + image_url content-block shape, detail:"high", the
//     leading-newline prefix on every tag).
//
// The naive "all frames, then all transcript" ordering is destructive — it
// severs the temporal link the model uses to resolve deictic references
// ("this"/"that"/"here") against the visual context. Preserve the chronology.
// =============================================================================

export interface FrameInput {
  /** Seconds from recording start (client-supplied, validated upstream). */
  timestamp: number;
  /** A `data:image/jpeg;base64,…` URL reconstructed from the uploaded frame. */
  dataUrl: string;
}

export interface SpeechSegment {
  start: number;
  end: number;
  text: string;
}

/** OpenAI chat user-content block — text or an image_url (detail-tagged). */
export type UserContentBlock =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail: string } };

type Item =
  | { kind: "frame"; start: number; dataUrl: string }
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
 * Merge frames + transcript segments into the interleaved OpenAI user-content
 * array. One text block per item; frames additionally emit an image_url block.
 * Every tag is newline-prefixed so each lands on its own rendered line —
 * matching the BYOK request byte-for-byte.
 */
export function buildInterleavedContent(
  frames: FrameInput[],
  segments: SpeechSegment[],
): UserContentBlock[] {
  const items: Item[] = [];
  for (const f of frames) items.push({ kind: "frame", start: f.timestamp, dataUrl: f.dataUrl });
  for (const s of segments) {
    items.push({ kind: "speech", start: s.start, end: s.end, text: s.text });
  }

  // Sort by start time; ties broken frame-before-speech (file header).
  items.sort((a, b) => (a.start !== b.start ? a.start - b.start : tieRank(a) - tieRank(b)));

  const content: UserContentBlock[] = [];
  for (const item of items) {
    if (item.kind === "frame") {
      content.push({ type: "text", text: `\n[${mmss(item.start)}] ` });
      content.push({ type: "image_url", image_url: { url: item.dataUrl, detail: "high" } });
    } else {
      const tag = `[${mmss(item.start)}–${mmss(item.end)}]`;
      content.push({ type: "text", text: `\n${tag} "${item.text}"` });
    }
  }
  return content;
}
