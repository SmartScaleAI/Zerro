//
//  DeixisResolver.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestones 4) — the deixis alignment engine (§7). A deictic
//  reference is a moment where the user SAID a pointing word ("this", "the
//  header") while the cursor was RESTING on something. This fuses the word-level
//  transcript (M2) with the continuous cursor track (M1) to find, per reference,
//  the on-screen point being pointed at — which M5 then turns into a labeled
//  element via the native frame (M3) + OCR + the model.
//
//  Algorithm (§7):
//    1. Scan the timestamped transcript for REFERRING EXPRESSIONS — deictics
//       (this/that/these/here/it) and definite UI noun phrases ("the button").
//    2. For each, open a window biased EARLIER than the phrase (pointing precedes
//       speech): [phrase_start − 800ms, phrase_end + 200ms].
//    3. Target point priority: click > hover-dwell > last-known. Dwell = the
//       stillest cursor cluster in the window; its tightness is a confidence
//       input (the CLIENT half of the M6 min(client,model) confidence).
//
//  Points are already in normalized frame space ([0,1], top-left) — the global→
//  frame transform happened at capture (`RecordingSession.normalizedClick`), so
//  the resolver does no coordinate math; M5 scales [0,1] → native pixels.
//
//  Pure + deterministic (no clock/IO) so it's fully unit-testable. Dev-Mode-only.
//

import Foundation

// MARK: - Output types

struct DeixisPoint: Equatable, Sendable {
    /// Normalized [0,1], top-left, frame space.
    let x: Double
    let y: Double
}

struct CandidateAnchor: Equatable, Sendable {
    /// How the target point was resolved (priority order, §7).
    enum Source: String, Equatable, Sendable {
        case click       // a click landed in the window — highest confidence
        case dwell       // the cursor rested (stillest cluster)
        case lastKnown   // no in-window samples — last position before the window
        case none        // no pointer position at all (empty space)
    }

    /// The referring expression verbatim ("this", "the header").
    let phrase: String
    let phraseStart: TimeInterval
    let phraseEnd: TimeInterval
    /// The resolved moment M5 extracts the native frame at.
    let targetSeconds: TimeInterval
    /// Normalized target point, or nil when none could be resolved.
    let point: DeixisPoint?
    let source: Source
    /// [0,1] cursor-stillness signal: 1 = a clear click or tight dwell; ~0 =
    /// transit / last-known / empty. Feeds the M6 confidence gate.
    let dwellConfidence: Double
}

// MARK: - Resolver

enum DeixisResolver {

    /// Tuning (§7 + §11). The 800ms lead absorbs the "pointing precedes speech"
    /// lag AND Whisper's approximate word timing; the dwell radius is ~3% of the
    /// frame (a hover stays within a small region).
    struct Config: Sendable {
        var windowLead: TimeInterval = 0.8
        var windowTrail: TimeInterval = 0.2
        var dwellRadius: Double = 0.03
        /// A click within this many seconds of a window counts as "in" it.
        var clickSlop: TimeInterval = 0.0
        static let `default` = Config()
    }

    /// Resolve every referring expression in `words` to a candidate anchor.
    /// `clickTimes` are click moments (`ResolvedClick.seconds`); the click point
    /// is read from the cursor track at that moment (a click means the cursor was
    /// in-region, so the ~30Hz track has it).
    static func resolve(
        words: [WordTiming],
        cursorTrack: [CursorSample],
        clickTimes: [TimeInterval] = [],
        config: Config = .default
    ) -> [CandidateAnchor] {
        let refs = referringExpressions(in: words)
        let track = cursorTrack.sorted { $0.seconds < $1.seconds }
        let clicks = clickTimes.sorted()
        return refs.map { resolveOne($0, track: track, clickTimes: clicks, config: config) }
    }

    // MARK: Referring-expression scan

    /// Bare deictics — a pointing word on its own.
    static let deictics: Set<String> = ["this", "that", "these", "those", "here", "it"]

    /// Determiners that can head a definite noun phrase ("the button", "this
    /// header").
    private static let determiners: Set<String> = ["the", "this", "that", "these", "those"]

    /// UI nouns that make "<determiner> <noun>" a concrete on-screen reference.
    /// Deliberately a closed lexicon (deterministic + testable) rather than a POS
    /// tagger — these cover the vocabulary users actually point with.
    static let uiNouns: Set<String> = [
        "button", "link", "header", "heading", "title", "subtitle", "nav", "navbar",
        "navigation", "menu", "footer", "sidebar", "panel", "card", "banner", "hero",
        "section", "logo", "icon", "image", "img", "text", "label", "input", "field",
        "form", "box", "dropdown", "tab", "tabs", "list", "item", "row", "column",
        "modal", "dialog", "popup", "tooltip", "badge", "avatar", "thumbnail", "cta",
        "container", "wrapper", "grid", "table", "cell", "toggle", "switch", "slider",
        "checkbox", "radio", "tag", "chip", "pill", "spinner", "loader", "div", "page",
    ]

    /// Normalize a transcript token for matching: lowercase, strip surrounding
    /// punctuation ("this," → "this").
    private static func normalize(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Find referring expressions. A bare deictic is one; a determiner followed
    /// within two tokens by a UI noun is one spanning determiner→noun.
    static func referringExpressions(in words: [WordTiming]) -> [ReferringExpression] {
        var out: [ReferringExpression] = []
        var i = 0
        while i < words.count {
            let tok = normalize(words[i].word)
            if determiners.contains(tok) {
                // Look ahead up to 2 tokens for a UI noun ("the big button"), but
                // STOP at another determiner — that begins a new noun phrase, so
                // "this the header" is "this" + "the header", not one span.
                var j = i + 1
                var nounIndex: Int?
                while j < words.count, j <= i + 2 {
                    let nj = normalize(words[j].word)
                    if determiners.contains(nj) { break }
                    if uiNouns.contains(nj) { nounIndex = j; break }
                    j += 1
                }
                if let n = nounIndex {
                    let phrase = words[i...n].map { $0.word }.joined(separator: " ")
                    out.append(ReferringExpression(phrase: phrase, start: words[i].start, end: words[n].end))
                    i = n + 1
                    continue
                }
                // A bare deictic determiner ("this"/"that"/…) still refers.
                if deictics.contains(tok) {
                    out.append(ReferringExpression(phrase: words[i].word, start: words[i].start, end: words[i].end))
                }
                i += 1
                continue
            }
            if deictics.contains(tok) { // "here", "it"
                out.append(ReferringExpression(phrase: words[i].word, start: words[i].start, end: words[i].end))
            }
            i += 1
        }
        return out
    }

    // MARK: Per-reference resolution

    private static func resolveOne(
        _ ref: ReferringExpression,
        track: [CursorSample],
        clickTimes: [TimeInterval],
        config: Config
    ) -> CandidateAnchor {
        let lo = ref.start - config.windowLead
        let hi = ref.end + config.windowTrail

        // 1. Click in the window → highest confidence. Point from the cursor
        //    track at the click moment.
        if let clickT = clickTimes.first(where: { $0 >= lo - config.clickSlop && $0 <= hi + config.clickSlop }),
           let s = nearestSample(in: track, to: clickT) {
            return CandidateAnchor(
                phrase: ref.phrase, phraseStart: ref.start, phraseEnd: ref.end,
                targetSeconds: clickT, point: DeixisPoint(x: s.x, y: s.y),
                source: .click, dwellConfidence: 1.0
            )
        }

        // 2. Hover-dwell — the stillest cluster among in-window samples.
        let inWindow = track.filter { $0.seconds >= lo && $0.seconds <= hi }
        if let dwell = dwell(in: inWindow, radius: config.dwellRadius) {
            return CandidateAnchor(
                phrase: ref.phrase, phraseStart: ref.start, phraseEnd: ref.end,
                targetSeconds: dwell.seconds, point: DeixisPoint(x: dwell.x, y: dwell.y),
                source: .dwell, dwellConfidence: dwell.confidence
            )
        }

        // 3. Last-known position before the window (cursor left / no dwell).
        if let last = track.last(where: { $0.seconds <= lo }) {
            return CandidateAnchor(
                phrase: ref.phrase, phraseStart: ref.start, phraseEnd: ref.end,
                targetSeconds: last.seconds, point: DeixisPoint(x: last.x, y: last.y),
                source: .lastKnown, dwellConfidence: 0.15
            )
        }

        // 4. Nothing — empty space (said "this" with the cursor never in-region).
        return CandidateAnchor(
            phrase: ref.phrase, phraseStart: ref.start, phraseEnd: ref.end,
            targetSeconds: ref.start, point: nil, source: .none, dwellConfidence: 0.0
        )
    }

    private static func nearestSample(in track: [CursorSample], to t: TimeInterval) -> CursorSample? {
        track.min { abs($0.seconds - t) < abs($1.seconds - t) }
    }

    /// The stillest cluster: the densest cluster of samples within `radius`. The
    /// point is the cluster centroid; confidence blends cluster COVERAGE (what
    /// fraction of the window clusters there) with TIGHTNESS (how packed it is) —
    /// so a transit sweep (samples spread out, no dense cluster) scores low while
    /// a genuine rest scores high. nil when there are no samples.
    private struct Dwell { let x: Double; let y: Double; let seconds: TimeInterval; let confidence: Double }

    private static func dwell(in samples: [CursorSample], radius: Double) -> Dwell? {
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 {
            let s = samples[0]
            return Dwell(x: s.x, y: s.y, seconds: s.seconds, confidence: 0.5)
        }
        // Density peak: the sample with the most neighbors within `radius`.
        var bestIndex = 0
        var bestCount = -1
        for i in samples.indices {
            var count = 0
            for j in samples.indices where dist(samples[i], samples[j]) <= radius { count += 1 }
            if count > bestCount { bestCount = count; bestIndex = i }
        }
        let center = samples[bestIndex]
        let cluster = samples.filter { dist($0, center) <= radius }
        let cx = cluster.map(\.x).reduce(0, +) / Double(cluster.count)
        let cy = cluster.map(\.y).reduce(0, +) / Double(cluster.count)
        // Centroid time = the median time of the cluster (the heart of the rest).
        let times = cluster.map(\.seconds).sorted()
        let centerSeconds = times[times.count / 2]

        let coverage = Double(cluster.count) / Double(samples.count) // 0..1
        let avgSpread = cluster.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / Double(cluster.count)
        let tightness = max(0, 1 - avgSpread / radius) // 1 = packed, 0 = at the radius edge
        // Weight coverage a bit higher: a long rest is the strongest dwell signal.
        let confidence = min(1, 0.6 * coverage + 0.4 * tightness)
        return Dwell(x: cx, y: cy, seconds: centerSeconds, confidence: confidence)
    }

    private static func dist(_ a: CursorSample, _ b: CursorSample) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - ReferringExpression

struct ReferringExpression: Equatable, Sendable {
    /// Verbatim phrase ("this", "the header").
    let phrase: String
    let start: TimeInterval
    let end: TimeInterval
}
