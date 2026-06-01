//
//  ModeSwitchDetector.swift
//  Zerro
//
//  Created by Colin Breeding on 5/31/26.
//
//  Phase 17 shipped the seam (the no-op stub below the fold) + the whole
//  confirmation-pill flow in AppState. Phase 18 fills in the predicate:
//  fully LOCAL string matching that fires the pill only when the
//  narration verbally asks for the OPPOSITE output mode from the one the
//  user selected on the overlay (picked Instruct, then said "actually,
//  just explain this instead").
//
//  Wholly local, zero added latency: it runs on the Whisper transcript we
//  already have, in the dead time between transcription and generation.
//  No API, no network, no model.
//
//  Shape of the rule (strict, fail-closed):
//    1. Scan ONLY for the opposite mode's targets — never reinforce the
//       mode you're already in.
//    2. A match REQUIRES both a switch CUE and a mode TARGET within
//       `proximityWordWindow` words of each other. A bare format-noun
//       ("the instructions on this page…") never matches on its own.
//    3. Edge-weight by time: a match in the first/last `edgeWindowSeconds`
//       of the recording is `.high` (surfaces the pill); a mid-recording
//       match is `.low` (logged, never interrupts). End-of-take "actually,
//       explain this instead" is the canonical high case; an aside in the
//       middle of narration is the canonical low case.
//    4. When in doubt, `.noMatch`.
//
//  The word lists are tuning data in ModeSwitchPatterns.json; everything
//  here is the logic that consumes them.
//
//  DEFERRED (out of scope, by design):
//    • LLM/API/classifier-based detection — this stays pure string logic.
//    • Multi-language transcripts — patterns + tokenization assume English.
//    • Persisting a switched mode back onto the toggle — overrides remain
//      per-recording (AppState.resolveModeSwitch), never sticky.
//

import Foundation

/// The outcome of a mode-switch intent check.
///
/// `nonisolated` so it can be built and returned from the off-main-actor
/// `detect` (the project default-isolates to MainActor). A plain value
/// type — safe to construct and read from any context.
nonisolated struct ModeSwitchDetection: Equatable {

    /// Where in the recording the match landed. Edges read as deliberate
    /// course-corrections; the middle reads as narration.
    enum Region: String, Equatable {
        case early, middle, late
    }

    /// `.high` surfaces the confirmation pill; `.low` is recorded for
    /// telemetry but never interrupts generation.
    enum Confidence: String, Equatable {
        case high, low
    }

    /// True when the narration appears to ask for a different output mode
    /// than the one selected on the overlay. Note this can be true with
    /// `.low` confidence — a detected-but-not-surfaced mid-recording aside.
    let didMatch: Bool

    /// The mode the user appears to be asking for — the opposite of the
    /// selected mode. `nil` whenever `didMatch` is false.
    let suggestedMode: OutputMode?

    /// The canonical switch cue that matched (from the pattern list, NOT
    /// the user's raw words). `nil` on `.noMatch`. Carried for telemetry.
    let matchedCue: String?

    /// The canonical mode target that matched (from the pattern list).
    /// `nil` on `.noMatch`. Carried for telemetry.
    let matchedTarget: String?

    /// Where the match landed; `nil` on `.noMatch`.
    let region: Region?

    /// Surfacing gate. `.noMatch` carries `.low` (meaningless there, but
    /// keeps the field non-optional so the AppState gate reads cleanly).
    let confidence: Confidence

    /// The canonical "nothing detected" result. Keep / dismiss / inaction
    /// all resolve to it too.
    static let noMatch = ModeSwitchDetection(
        didMatch: false,
        suggestedMode: nil,
        matchedCue: nil,
        matchedTarget: nil,
        region: nil,
        confidence: .low
    )
}

// `nonisolated` propagates to every member below — the detector is pure
// string logic that runs off the main actor (between transcription and
// generation), and the project default-isolates to MainActor.
nonisolated enum ModeSwitchDetector {

    // MARK: - Tunable knobs
    //
    // Two intentionally-tunable constants (flagged in the Phase 18
    // summary). These are detection POLICY, not pattern data, so they
    // live in code next to the logic they govern rather than in the JSON.

    /// Max number of words allowed BETWEEN a cue and a target for them to
    /// count as one request. Spec range 4–6; 5 is the middle. Smaller →
    /// stricter (fewer false fires); larger → looser.
    static let proximityWordWindow = 5

    /// How much of the recording's head and tail counts as an "edge" for
    /// confidence weighting. Spec range ~15–20s; 18s chosen. A match whose
    /// span starts within this of the start, or ends within this of the
    /// end, is `.high`; otherwise `.low`.
    static let edgeWindowSeconds: TimeInterval = 18

    // MARK: - Entry point

    /// Inspects the narration for an explicit request to switch output
    /// modes mid-recording, returning the opposite mode to suggest on a
    /// match.
    ///
    /// - Parameters:
    ///   - transcript: the full Whisper transcript, WITH segment-level
    ///     timestamps — required for the time-based edge weighting.
    ///   - selectedMode: the mode chosen on the overlay for this recording.
    /// - Returns: `.noMatch`, a `.low` mid-recording match (logged, not
    ///   surfaced), or a `.high` edge match (surfaces the pill).
    static func detect(
        transcript: Transcript,
        selectedMode: OutputMode
    ) -> ModeSwitchDetection {
        detect(transcript: transcript, selectedMode: selectedMode, patterns: .bundled)
    }

    /// Pattern-injecting overload. The public entry point binds
    /// `.bundled`; unit tests pass a fixed set so they don't depend on the
    /// shipped JSON (which is tuning data and will drift).
    static func detect(
        transcript: Transcript,
        selectedMode: OutputMode,
        patterns: ModeSwitchPatterns
    ) -> ModeSwitchDetection {
        // (4) Opposite-mode-only: only ever suggest switching TO the other
        // mode. Scan exclusively for that mode's targets.
        let suggested = selectedMode.opposite
        let targets = patterns.targets(for: suggested)

        // Fail-closed: no cues or no targets → nothing to match against.
        guard !patterns.switchCues.isEmpty, !targets.isEmpty else { return .noMatch }

        // (3) Normalize per segment so each surviving token keeps its
        // segment's timestamps for edge weighting.
        let tokens = normalizedTokens(from: transcript.segments, patterns: patterns)
        guard !tokens.isEmpty else { return .noMatch }

        // Recording end for the "last N seconds" test. Prefer the real
        // segment end; fall back to the last token's segment end.
        let recordingEnd = transcript.segments.map(\.end).max()
            ?? tokens.last?.segmentEnd ?? 0

        // (5) Every cue and target occurrence, by token position.
        let cueHits = phraseHits(in: tokens, phrases: patterns.switchCues)
        let targetHits = phraseHits(in: tokens, phrases: targets)
        guard !cueHits.isEmpty, !targetHits.isEmpty else { return .noMatch }

        // Best match across all cue×target pairs within the proximity
        // window. `.high` (edge) beats `.low` (middle); first found wins
        // ties, which is deterministic for a fixed transcript.
        var best: ModeSwitchDetection?
        for cue in cueHits {
            for target in targetHits {
                guard let gap = wordGap(cue, target), gap <= proximityWordWindow else { continue }
                let region = region(cue: cue, target: target, recordingEnd: recordingEnd)
                let candidate = ModeSwitchDetection(
                    didMatch: true,
                    suggestedMode: suggested,
                    matchedCue: cue.phrase,
                    matchedTarget: target.phrase,
                    region: region,
                    confidence: region == .middle ? .low : .high
                )
                best = stronger(best, candidate)
            }
        }
        return best ?? .noMatch
    }

    // MARK: - Normalization

    /// One normalized token, carrying the timestamps of the segment it
    /// came from so a match can be edge-weighted by time.
    private struct Token {
        let text: String
        let segmentStart: TimeInterval
        let segmentEnd: TimeInterval
    }

    /// Lowercase, normalize app-name variants, strip filler, collapse to
    /// alphanumeric words — applied PER SEGMENT so word offsets and
    /// timestamps stay meaningful. Filler is dropped here (not just
    /// matched-around) so it doesn't pad the cue↔target word distance.
    private static func normalizedTokens(
        from segments: [TranscriptSegment],
        patterns: ModeSwitchPatterns
    ) -> [Token] {
        let fillerWords = Set(patterns.fillerTokens.filter { !$0.contains(" ") })
        // Multi-word filler ("you know") and longer app variants first so
        // a longer phrase wins over a shorter one it contains.
        let fillerPhrases = patterns.fillerTokens
            .filter { $0.contains(" ") }
            .sorted { $0.count > $1.count }

        var tokens: [Token] = []
        for seg in segments {
            var text = seg.text.lowercased()
            text = normalizeAppNames(in: text, variants: patterns.appNameVariants)
            for phrase in fillerPhrases {
                text = text.replacingOccurrences(of: phrase, with: " ")
            }
            for word in tokenize(text) where !fillerWords.contains(word) {
                tokens.append(Token(text: word, segmentStart: seg.start, segmentEnd: seg.end))
            }
        }
        return tokens
    }

    /// Replace each spoken/spelled app-name variant with its canonical
    /// form so a target like "for cursor" matches "for Cursor AI". Padded
    /// with spaces and matched longest-first to avoid partial-word hits
    /// and to prefer "cursor ai" over "cursor".
    private static func normalizeAppNames(
        in text: String,
        variants: [String: [String]]
    ) -> String {
        var padded = " \(text) "
        // Flatten to (variant, canonical), longest variant first.
        let pairs = variants
            .flatMap { canonical, list in list.map { (variant: $0, canonical: canonical) } }
            .sorted { $0.variant.count > $1.variant.count }
        for pair in pairs {
            padded = padded.replacingOccurrences(of: " \(pair.variant) ", with: " \(pair.canonical) ")
        }
        return padded
    }

    /// Split on anything that isn't a letter or digit. Collapses runs of
    /// whitespace/punctuation implicitly (empty splits are dropped).
    private static func tokenize(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: - Phrase matching

    /// One occurrence of a (possibly multi-word) pattern phrase in the
    /// token stream.
    private struct PhraseHit {
        /// Token index of the first word of the phrase.
        let startIndex: Int
        /// Token index of the last word (inclusive).
        let endIndex: Int
        /// The canonical pattern phrase that matched (for telemetry).
        let phrase: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// All occurrences of any of `phrases` in `tokens`, by position.
    /// Phrases are tokenized the same way the transcript was so a
    /// multi-word phrase ("explain this") matches a span of tokens.
    private static func phraseHits(in tokens: [Token], phrases: [String]) -> [PhraseHit] {
        var hits: [PhraseHit] = []
        for phrase in phrases {
            let words = tokenize(phrase.lowercased())
            guard !words.isEmpty, words.count <= tokens.count else { continue }
            for start in 0...(tokens.count - words.count) {
                var matched = true
                for offset in 0..<words.count where tokens[start + offset].text != words[offset] {
                    matched = false
                    break
                }
                guard matched else { continue }
                let end = start + words.count - 1
                hits.append(PhraseHit(
                    startIndex: start,
                    endIndex: end,
                    phrase: phrase,
                    startTime: tokens[start].segmentStart,
                    endTime: tokens[end].segmentEnd
                ))
            }
        }
        return hits
    }

    /// Number of words BETWEEN two non-overlapping phrase hits (0 when
    /// adjacent). `nil` is never returned today — overlaps resolve to 0 —
    /// but the optional keeps room for a future "ignore overlapping"
    /// rule without a signature change at the call site.
    private static func wordGap(_ a: PhraseHit, _ b: PhraseHit) -> Int? {
        if a.endIndex < b.startIndex { return b.startIndex - a.endIndex - 1 }
        if b.endIndex < a.startIndex { return a.startIndex - b.endIndex - 1 }
        return 0 // overlapping — disjoint cue/target lists make this unreachable
    }

    // MARK: - Edge weighting

    /// Classify a match by where its span sits in the recording. The span
    /// runs from the earliest start to the latest end of the cue/target
    /// pair; head/tail within `edgeWindowSeconds` → edge, else middle.
    private static func region(
        cue: PhraseHit,
        target: PhraseHit,
        recordingEnd: TimeInterval
    ) -> ModeSwitchDetection.Region {
        let spanStart = min(cue.startTime, target.startTime)
        let spanEnd = max(cue.endTime, target.endTime)
        if spanStart <= edgeWindowSeconds { return .early }
        if recordingEnd > 0, spanEnd >= recordingEnd - edgeWindowSeconds { return .late }
        return .middle
    }

    /// Pick the stronger of two candidate matches: `.high` beats `.low`;
    /// at equal confidence the incumbent (first found) wins, keeping the
    /// result stable for a given transcript.
    private static func stronger(
        _ incumbent: ModeSwitchDetection?,
        _ candidate: ModeSwitchDetection
    ) -> ModeSwitchDetection {
        guard let incumbent else { return candidate }
        if incumbent.confidence != candidate.confidence {
            return incumbent.confidence == .high ? incumbent : candidate
        }
        return incumbent
    }
}
