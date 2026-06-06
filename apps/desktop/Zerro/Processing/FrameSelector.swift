//
//  FrameSelector.swift
//  Zerro
//
//  Created by Colin Breeding on 6/6/26.
//
//  Phase 2 — the testable core of content-driven keyframing.
//
//  ProcessingPipeline.extractFrames used to sample on a fixed clock (one
//  frame every `sampleIntervalSeconds`), which over-samples static reading/
//  thinking stretches and catches scrolling mid-motion (blurry, redundant).
//  Phase 2 replaces that with two passes: a cheap analysis pass decodes tiny
//  thumbnails and measures, per candidate, how much changed since the last
//  one (`motion`) and a perceptual fingerprint (`hash`); THIS file is the
//  pure function that turns those measurements into the set of times worth
//  encoding at full resolution.
//
//  It deliberately imports no AVFoundation and touches no main-actor state —
//  it's plain arithmetic over `[Candidate]`, so it can be unit-tested with
//  synthetic sequences (FrameSelectorTests) with no recording and no network.
//  Every threshold lives in ProcessingConfig with its rationale; this file
//  only applies them.
//

import Foundation

// MARK: - Candidate

/// One cheap analysis sample taken by the pipeline's Pass 1 (a tiny
/// downsampled decode every `analysisIntervalSeconds`). `Sendable` (all
/// fields already are) so the off-main pixel work that produces the inputs,
/// and this nonisolated selector that consumes them, both sidestep the
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` inference.
struct Candidate: Sendable, Equatable {
    /// Position in the analysis stream (0-based, ascending in time). This is
    /// what `FrameSelector.select` returns, and what the pipeline maps back
    /// to a `timestampSeconds` for the full-res Pass 2.
    let index: Int
    /// `actualTime` of the decoded thumbnail, in seconds.
    let timestampSeconds: Double
    /// Normalized mean-absolute-difference of grayscale pixels versus the
    /// PREVIOUS candidate, in 0…1 (0 = identical, 1 = maximally different).
    /// The first candidate has no predecessor, so its motion is 0.
    let motion: Double
    /// 64-bit dHash (9×8 horizontal-gradient bits) of the thumbnail — a
    /// perceptual fingerprint compared via Hamming distance to drop
    /// near-duplicate end-states.
    let hash: UInt64
}

// MARK: - SelectionParams

/// The knobs `select` reads, snapshotted from `ProcessingConfig` (plus the
/// duration-derived floor/ceiling) at the call site. Kept as a value type so
/// the selector stays pure and the tests can drive it with explicit values
/// rather than reaching into the config singleton.
struct SelectionParams: Sendable {
    /// Skip candidates before this time — the session pre-roll (cursor
    /// mid-click, half-rendered surface) isn't worth a keyframe.
    let startOffsetSeconds: Double
    /// Accumulated inter-frame `motion` since the last kept frame that must
    /// build up before a new keyframe is allowed.
    let changeThreshold: Double
    /// A candidate must be at or below this `motion` to count as "settled"
    /// (not mid-scroll/animation) — this is what makes scroll-settle fall
    /// out for free.
    let stabilityThreshold: Double
    /// Drop a keyframe whose dHash is within this Hamming distance of the
    /// last kept frame's (a near-duplicate).
    let dedupHamming: Int
    /// Hard ceiling on kept keyframes.
    let maxKeyframes: Int
    /// Floor: top up with evenly-spaced fallbacks if fewer than this were
    /// kept, so a fully static narrated screen still yields a few frames.
    let minKeyframes: Int
}

// MARK: - FrameSelector

/// Pure selector. `nonisolated` static API only — no AVFoundation, no
/// main-actor state, so it runs anywhere and is trivially unit-testable.
enum FrameSelector {

    /// Hamming distance between two dHashes: the number of differing bits.
    /// Used both by `select` (dedup) and by the tests.
    nonisolated static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Chooses which candidates to encode at full resolution, returning their
    /// `index`es in ascending time order, unique, and never exceeding
    /// `maxKeyframes`.
    ///
    /// Algorithm (see the file header for the why):
    ///   • Skip everything before `startOffsetSeconds`.
    ///   • Seed with the FIRST settled candidate at/after the offset.
    ///   • Accumulate `motion` since the last kept frame; keep candidate i
    ///     when enough has changed (`accum >= changeThreshold`), it's settled
    ///     (`motion_i <= stabilityThreshold`), and it isn't a near-duplicate
    ///     of the last kept frame (`hamming > dedupHamming`). On a keep,
    ///     reset the accumulator and remember the new hash.
    ///   • Stop at `maxKeyframes`.
    ///   • If fewer than `minKeyframes` survived (a very static screen),
    ///     top up with evenly-spaced fallback candidates until the floor is
    ///     met.
    ///
    /// Scroll-settle is implicit: during a scroll `motion` stays above
    /// `stabilityThreshold`, so nothing is emitted until it drops (settled),
    /// at which point one clean frame is kept.
    nonisolated static func select(_ candidates: [Candidate], config: SelectionParams) -> [Int] {
        var kept: [Int] = []
        var accum = 0.0
        var lastHash: UInt64 = 0

        for candidate in candidates {
            // Session pre-roll: not worth a keyframe, and the motion against
            // it would be noise. (Phase 2b: a future audio-onset anchor would
            // feed in here, biasing keyframe selection toward the moments the
            // narrator is actually speaking about.)
            if candidate.timestampSeconds < config.startOffsetSeconds { continue }
            if kept.count >= config.maxKeyframes { break }

            if kept.isEmpty {
                // Seek the initial keyframe: the first SETTLED candidate at or
                // after the offset. A scroll that starts at t=0 simply defers
                // the seed until the page comes to rest.
                if candidate.motion <= config.stabilityThreshold {
                    kept.append(candidate.index)
                    lastHash = candidate.hash
                    accum = 0
                }
                continue
            }

            // Everything that moved since the last keyframe counts toward the
            // next one — including the high-motion frames we reject below, so a
            // scroll or scene cut still "pays into" the next settled frame.
            accum += candidate.motion

            if accum >= config.changeThreshold
                && candidate.motion <= config.stabilityThreshold
                && hamming(candidate.hash, lastHash) > config.dedupHamming {
                kept.append(candidate.index)
                lastHash = candidate.hash
                accum = 0
            }
        }

        // Floor: a fully static, narrated screen accumulates no motion and so
        // keeps only the seed (or nothing). Top up with evenly-spaced
        // candidates so the prompt still has a few frames to interleave. The
        // fallbacks bypass the change/dedup gates by design — there's nothing
        // to detect, we just want coverage — but they DO honor the start
        // offset, spanning only the post-pre-roll candidates so a fallback
        // can't land on the session pre-roll the offset exists to skip.
        let eligible = candidates.filter { $0.timestampSeconds >= config.startOffsetSeconds }
        if kept.count < config.minKeyframes && !eligible.isEmpty {
            let target = min(config.minKeyframes, eligible.count)
            var keptSet = Set(kept)
            let lastPos = eligible.count - 1
            for k in 0..<target {
                if kept.count >= target { break }
                // Evenly spaced across the eligible stream (itself evenly
                // spaced in time), endpoints included.
                let fraction = target == 1 ? 0.5 : Double(k) / Double(target - 1)
                let pos = Int((Double(lastPos) * fraction).rounded())
                let idx = eligible[pos].index
                if keptSet.insert(idx).inserted {
                    kept.append(idx)
                }
            }
        }

        // Time-ordered + unique: walk the (time-ordered) candidates and emit
        // those we kept. This also collapses any duplicate the floor might
        // have re-proposed.
        let chosen = Set(kept)
        return candidates.filter { chosen.contains($0.index) }.map { $0.index }
    }
}
