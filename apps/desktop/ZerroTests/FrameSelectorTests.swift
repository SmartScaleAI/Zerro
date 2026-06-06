//
//  FrameSelectorTests.swift
//  ZerroTests
//
//  Phase 2 — the safety net for content-driven keyframing.
//
//  FrameSelector is the pure core of the new sampler: it takes the cheap
//  per-candidate measurements Pass 1 produces (motion + dHash) and returns the
//  candidate indices worth encoding at full resolution. Because it imports no
//  AVFoundation and touches no main-actor state, we can exercise its whole
//  decision surface with synthetic candidate sequences — no recording, no
//  network. These tests are the contract; the thresholds in ProcessingConfig
//  are free to be tuned against the eval harness as long as these behaviors
//  hold.
//

import XCTest
@testable import Zerro

final class FrameSelectorTests: XCTestCase {

    // MARK: - Fixtures

    /// Default params used by most tests. `minKeyframes` is deliberately small
    /// (2) so the floor doesn't mask the change-detection behavior under test;
    /// the floor itself is exercised by `testStaticScreen`. Thresholds mirror
    /// ProcessingConfig's starting points.
    private func params(
        startOffsetSeconds: Double = 1.0,
        changeThreshold: Double = 0.10,
        stabilityThreshold: Double = 0.03,
        dedupHamming: Int = 8,
        maxKeyframes: Int = 28,
        minKeyframes: Int = 2
    ) -> SelectionParams {
        SelectionParams(
            startOffsetSeconds: startOffsetSeconds,
            changeThreshold: changeThreshold,
            stabilityThreshold: stabilityThreshold,
            dedupHamming: dedupHamming,
            maxKeyframes: maxKeyframes,
            minKeyframes: minKeyframes
        )
    }

    /// Builds a candidate at the analysis cadence (0.5s/candidate), so index i
    /// sits at t = i * 0.5s.
    private func candidate(_ index: Int, motion: Double, hash: UInt64) -> Candidate {
        Candidate(index: index, timestampSeconds: Double(index) * 0.5, motion: motion, hash: hash)
    }

    /// Five 64-bit fingerprints chosen to be pairwise far apart (Hamming ≫ 8),
    /// so "distinct scene" is unambiguous and dedup never fires between them.
    private let sceneHashes: [UInt64] = [
        0x0000_0000_0000_0000,
        0xFFFF_FFFF_FFFF_FFFF,
        0x0000_0000_FFFF_FFFF,
        0xFFFF_0000_FFFF_0000,
        0x0F0F_0F0F_0F0F_0F0F,
    ]

    /// Asserts the invariants every result must satisfy.
    private func assertWellFormed(_ result: [Int], _ p: SelectionParams, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result, result.sorted(), "result not time-ordered", file: file, line: line)
        XCTAssertEqual(result.count, Set(result).count, "result not unique", file: file, line: line)
        XCTAssertLessThanOrEqual(result.count, p.maxKeyframes, "exceeded maxKeyframes", file: file, line: line)
    }

    // MARK: - Hamming helper

    func testHammingDistance() {
        XCTAssertEqual(FrameSelector.hamming(0, 0), 0)
        XCTAssertEqual(FrameSelector.hamming(0b1011, 0b0001), 2)
        XCTAssertEqual(FrameSelector.hamming(.max, 0), 64)
        XCTAssertEqual(FrameSelector.hamming(0xFFFF_FFFF_FFFF_FF0F, 0xFFFF_FFFF_FFFF_FFFF), 4)
    }

    // MARK: - Static screen → floor only

    func testStaticScreen_returnsOnlyTheFloor() {
        // 30 candidates, zero motion throughout, identical hash. Without a
        // floor this would keep exactly one frame (the seed); with the floor it
        // tops up to minKeyframes — and crucially NOT one-per-analysis-tick.
        let p = params(minKeyframes: 4)
        let candidates = (0..<30).map { candidate($0, motion: 0.0, hash: 0xAAAA_AAAA_AAAA_AAAA) }

        let result = FrameSelector.select(candidates, config: p)

        assertWellFormed(result, p)
        XCTAssertEqual(result.count, 4, "static screen should yield exactly the floor count")
        XCTAssertLessThan(result.count, 10, "must not approach one-per-tick")
    }

    // MARK: - Periodic scene cuts → ~one keyframe per cut

    func testPeriodicSceneCuts_keepsOnePerScene() {
        // Five scenes of 6 candidates each. Motion spikes once at the boundary
        // into each new scene (high, blurry transition frame — rejected), then
        // calms; the SETTLED frame just after each cut is the keyframe. Each
        // scene gets its own well-separated hash so dedup never interferes.
        let sceneLength = 6
        let sceneCount = 5
        var candidates: [Candidate] = []
        for i in 0..<(sceneLength * sceneCount) {
            let scene = i / sceneLength
            let isBoundary = (i % sceneLength == 0) && i > 0
            let motion = isBoundary ? 0.5 : 0.0   // spike at each cut, calm otherwise
            candidates.append(candidate(i, motion: motion, hash: sceneHashes[scene]))
        }

        let result = FrameSelector.select(candidates, config: params())

        assertWellFormed(result, params())
        // Seed (scene 0) + one settled frame after each of the 4 cuts.
        XCTAssertEqual(result, [2, 7, 13, 19, 25])
    }

    // MARK: - Scroll run → nothing mid-scroll, one frame after it settles

    func testScrollRun_emitsNothingDuringMotionThenOneAfter() {
        // Seed, brief calm, then a sustained scroll (8 high-motion candidates),
        // then it settles. Expect the seed and exactly one frame after settle —
        // and NOTHING from inside the scroll window.
        var candidates: [Candidate] = []
        let calmHash: UInt64 = 0x0000_0000_0000_0000
        let settledHash: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        for i in 0..<20 {
            let motion: Double
            let hash: UInt64
            if (5...12).contains(i) {
                motion = 0.2          // mid-scroll: above stability, never kept
                hash = 0xAAAA_5555_AAAA_5555
            } else if i == 13 {
                motion = 0.0          // settled, lots accumulated, new content
                hash = settledHash
            } else {
                motion = 0.0
                hash = calmHash
            }
            candidates.append(candidate(i, motion: motion, hash: hash))
        }

        let result = FrameSelector.select(candidates, config: params())

        assertWellFormed(result, params())
        XCTAssertEqual(result, [2, 13])
        for i in 5...12 {
            XCTAssertFalse(result.contains(i), "kept a blurry mid-scroll frame at index \(i)")
        }
    }

    // MARK: - Near-duplicate end-states → deduped

    func testNearDuplicateEndStates_areDeduped() {
        // Sequence reaches three distinct settled end-states via motion spikes.
        // The middle two settle on hashes within dedupHamming of the last KEPT
        // frame, so they're dropped despite having accumulated enough change.
        let hashA: UInt64 = 0x0000_0000_0000_0000
        let hashB: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        let hashBNear: UInt64 = 0xFFFF_FFFF_FFFF_FF0F   // Hamming 4 from B → near-dup
        let hashC: UInt64 = 0x0000_0000_0000_0000       // far from B (64) → kept

        let candidates: [Candidate] = [
            candidate(0, motion: 0.0, hash: hashA),      // pre-roll (skipped, < offset 1.0)
            candidate(1, motion: 0.0, hash: hashA),      // pre-roll (t=0.5, skipped)
            candidate(2, motion: 0.0, hash: hashA),      // seed (t=1.0)
            candidate(3, motion: 0.5, hash: hashA),      // spike (not settled)
            candidate(4, motion: 0.0, hash: hashA),      // settled but same hash as seed → dedup drop
            candidate(5, motion: 0.0, hash: hashB),      // settled, far from A → KEEP
            candidate(6, motion: 0.5, hash: hashBNear),  // spike
            candidate(7, motion: 0.0, hash: hashBNear),  // settled but near B → dedup drop
            candidate(8, motion: 0.5, hash: hashBNear),  // spike
            candidate(9, motion: 0.0, hash: hashBNear),  // settled but near B → dedup drop
            candidate(10, motion: 0.0, hash: hashC),     // settled, far from B → KEEP
        ]

        let result = FrameSelector.select(candidates, config: params())

        assertWellFormed(result, params())
        XCTAssertEqual(result, [2, 5, 10])
        XCTAssertFalse(result.contains(4), "kept a same-as-seed duplicate")
        XCTAssertFalse(result.contains(7), "kept a near-duplicate end-state")
        XCTAssertFalse(result.contains(9), "kept a near-duplicate end-state")
    }

    // MARK: - maxKeyframes ceiling

    func testNeverExceedsMaxKeyframes() {
        // Many well-separated scene cuts that would each earn a keyframe; the
        // ceiling must clamp the result.
        let p = params(maxKeyframes: 5)
        var candidates: [Candidate] = []
        for i in 0..<60 {
            let isBoundary = (i % 2 == 0) && i > 0
            // Alternate between two far-apart hashes so every settled frame is a
            // genuine non-duplicate change.
            let hash: UInt64 = (i / 2) % 2 == 0 ? 0x0000_0000_0000_0000 : 0xFFFF_FFFF_FFFF_FFFF
            candidates.append(candidate(i, motion: isBoundary ? 0.5 : 0.0, hash: hash))
        }

        let result = FrameSelector.select(candidates, config: p)

        assertWellFormed(result, p)
        XCTAssertEqual(result.count, 5, "should be clamped to maxKeyframes")
    }

    // MARK: - Floor is met even with a single high-motion (never-settling) clip

    func testFloorMetWhenNothingEverSettles() {
        // Every candidate is above the stability threshold (a clip that never
        // comes to rest), so the change-detection path keeps nothing — the
        // floor must still top up to minKeyframes with evenly-spaced fallbacks.
        let p = params(minKeyframes: 3)
        let candidates = (0..<20).map { candidate($0, motion: 0.5, hash: UInt64($0)) }

        let result = FrameSelector.select(candidates, config: p)

        assertWellFormed(result, p)
        XCTAssertEqual(result.count, 3, "floor must be met even when nothing settles")
    }

    // MARK: - Degenerate inputs

    func testEmptyCandidates_returnsEmpty() {
        XCTAssertEqual(FrameSelector.select([], config: params()), [])
    }

    func testStartOffsetSkipsPreRoll() {
        // With a 2.0s offset, candidates at t < 2.0 (indices 0..3) are never
        // eligible — the first keyframe is at index 4 (t=2.0) at the earliest.
        let p = params(startOffsetSeconds: 2.0, minKeyframes: 1)
        let candidates = (0..<10).map { candidate($0, motion: 0.0, hash: 0x1234_5678_9ABC_DEF0) }

        let result = FrameSelector.select(candidates, config: p)

        assertWellFormed(result, p)
        XCTAssertEqual(result.first, 4, "pre-roll before the offset must be skipped")
    }
}
