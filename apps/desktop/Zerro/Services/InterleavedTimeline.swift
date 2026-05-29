//
//  InterleavedTimeline.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Step 2 of the Phase 9 pipeline. Merges the Phase 8 frames + the
//  Whisper transcript into a single chronologically-ordered timeline
//  that the prompt-generation step (Step 3) hands to the multimodal
//  model.
//
//  The interleaving format is product IP — locked by the Phase 9
//  kickoff and matched literally here:
//
//      [0:00] {frame_0}
//      [0:00–0:08] "okay so this is the settings page i'm working on"
//      [0:08] {frame_1}
//      [0:08–0:14] "and i want to make this save button bigger"
//      [0:14] {frame_2}
//      ...
//
//  The naive "all frames, then all transcript" pattern is destructive
//  — it severs the temporal link the model relies on to resolve
//  deictic references ("this", "that", "here") against the visual
//  context. Don't write that version even though it's easier.
//
//  Tie-breaking
//  ------------
//  When a frame and a speech segment share the same start second, the
//  frame renders FIRST (matches the kickoff example: `[0:00] {frame_0}`
//  precedes `[0:00–0:08] "okay so..."`). The model reads top-down, so
//  putting the frame before the segment that starts at the same time
//  means the frame is already in the model's context when it reads
//  what was said during that beat.
//
//  Timestamp format
//  ----------------
//  M:SS (single-digit minutes for our 3-minute recording cap). Seconds
//  truncated, not rounded — Whisper returns sub-second precision
//  (e.g. 11.32s) but the model only needs the whole-second tag.
//

import CoreMedia
import Foundation

// MARK: - InterleavedTimeline

struct InterleavedTimeline: Sendable {
    let items: [TimelineItem]
}

// MARK: - TimelineItem

enum TimelineItem: Sendable {
    case frame(timestamp: TimeInterval, imageURL: URL)
    case speech(start: TimeInterval, end: TimeInterval, text: String)

    /// The sort key for chronological merge. Speech uses its start
    /// time, not its midpoint — keeps the alignment with the moment
    /// the user STARTED talking about something, which is when the
    /// nearby frame is most likely relevant.
    var startTime: TimeInterval {
        switch self {
        case .frame(let t, _):       return t
        case .speech(let s, _, _):   return s
        }
    }

    /// The bracketed timestamp tag rendered in the API payload + the
    /// debug view. Frames are instants, speech is a range with em-dash.
    var timestampTag: String {
        switch self {
        case .frame(let t, _):
            return "[\(Self.mmss(t))]"
        case .speech(let s, let e, _):
            return "[\(Self.mmss(s))\u{2013}\(Self.mmss(e))]"
        }
    }

    private static func mmss(_ seconds: TimeInterval) -> String {
        // Negative timestamps shouldn't happen, but guard so the
        // truncation arithmetic doesn't render "-1:59" if a future
        // bug feeds us bad input.
        let safe = max(0, seconds)
        let total = Int(safe)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

// MARK: - Interleaver

enum Interleaver {

    /// Merges `frames` (from a ProcessedRecording) with `transcript`
    /// segments into a single chronologically-ordered timeline.
    /// Trimming/dedup: none — every frame and every segment passes
    /// through. Empty transcript → only frames (the system prompt
    /// handles that case explicitly in the model).
    static func merge(
        frames: [ExtractedFrame],
        transcript: Transcript
    ) -> InterleavedTimeline {
        var items: [TimelineItem] = []
        items.reserveCapacity(frames.count + transcript.segments.count)

        for frame in frames {
            items.append(.frame(
                timestamp: CMTimeGetSeconds(frame.timestamp),
                imageURL: frame.url
            ))
        }
        for seg in transcript.segments {
            items.append(.speech(start: seg.start, end: seg.end, text: seg.text))
        }

        // Sort by start time. Tie-breaking: frame before speech (see
        // file header).
        items.sort { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return Self.tieRank(lhs) < Self.tieRank(rhs)
        }

        return InterleavedTimeline(items: items)
    }

    private static func tieRank(_ item: TimelineItem) -> Int {
        switch item {
        case .frame:  return 0
        case .speech: return 1
        }
    }
}

// MARK: - Debug rendering

extension InterleavedTimeline {

    /// Plain-text view of the timeline with `{frame_N}` placeholders in
    /// place of the actual image blocks. Used by the Phase 9 Step 2
    /// dev trigger so the chronology + format can be eyeballed before
    /// the multimodal payload is built. Frame indices are sequential
    /// in TIMELINE order, not in ExtractedFrame.index order — keeps
    /// `frame_0` as "the first frame the model sees" regardless of
    /// whether a speech segment edged it forward.
    var debugDescription: String {
        var lines: [String] = []
        var frameIndex = 0
        for item in items {
            switch item {
            case .frame:
                lines.append("\(item.timestampTag) {frame_\(frameIndex)}")
                frameIndex += 1
            case .speech(_, _, let text):
                lines.append("\(item.timestampTag) \"\(text)\"")
            }
        }
        return lines.joined(separator: "\n")
    }
}
