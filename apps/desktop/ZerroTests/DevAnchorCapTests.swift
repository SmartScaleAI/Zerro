//
//  DevAnchorCapTests.swift
//  ZerroTests
//
//  F-05 — Dev Mode appends a native-res anchor frame per referring expression,
//  which used to be UNCAPPED: a narration full of "this / here / the button"
//  could push total frames (keyframes + anchors) far past the 28-frame budget.
//  `DevAnchorPipeline.cappedCandidates` now bounds the anchors at
//  `ProcessingConfig.maxAnchorFrames`, keeping the highest-confidence ones and
//  preserving each survivor's ORIGINAL refIndex (the model pairs anchors back
//  by that index). The cap is pure, so it's testable with synthetic candidates
//  and no source video.
//

import XCTest
@testable import Zerro

@MainActor
final class DevAnchorCapTests: XCTestCase {

    private func candidate(
        source: CandidateAnchor.Source,
        dwellConfidence: Double,
        phrase: String = "this"
    ) -> CandidateAnchor {
        CandidateAnchor(
            phrase: phrase,
            phraseStart: 1.0,
            phraseEnd: 1.2,
            targetSeconds: 1.0,
            point: source == .none ? nil : DeixisPoint(x: 0.5, y: 0.5),
            source: source,
            dwellConfidence: dwellConfidence
        )
    }

    /// At or under the cap, the candidate list is untouched (identity, original
    /// order and indices).
    func testUnderCapIsIdentity() {
        let candidates = (0..<ProcessingConfig.maxAnchorFrames).map { _ in
            candidate(source: .dwell, dwellConfidence: 0.5)
        }
        let capped = DevAnchorPipeline.cappedCandidates(candidates)
        XCTAssertEqual(capped.count, candidates.count)
        XCTAssertEqual(capped.map(\.refIndex), Array(0..<candidates.count))
    }

    /// The F-05 regression: N references beyond the cap yield at most
    /// `maxAnchorFrames` candidates.
    func testOverCapIsBounded() {
        let candidates = (0..<30).map { _ in candidate(source: .dwell, dwellConfidence: 0.9) }
        let capped = DevAnchorPipeline.cappedCandidates(candidates)
        XCTAssertEqual(capped.count, ProcessingConfig.maxAnchorFrames)
    }

    /// The highest-confidence candidates survive: clicks (1.0) beat dwells,
    /// dwells beat last-known / none — and survivors keep their ORIGINAL
    /// refIndex, in transcript order.
    func testHighestConfidenceKeptWithOriginalIndices() {
        // 4 weak candidates, then `maxAnchorFrames` strong clicks, then 4 more
        // weak ones — only the clicks should survive.
        let cap = ProcessingConfig.maxAnchorFrames
        var candidates: [CandidateAnchor] = []
        candidates.append(contentsOf: (0..<2).map { _ in candidate(source: .none, dwellConfidence: 0.0) })
        candidates.append(contentsOf: (0..<2).map { _ in candidate(source: .lastKnown, dwellConfidence: 0.9) })
        candidates.append(contentsOf: (0..<cap).map { _ in candidate(source: .click, dwellConfidence: 1.0) })
        candidates.append(contentsOf: (0..<4).map { _ in candidate(source: .dwell, dwellConfidence: 0.1) })

        let capped = DevAnchorPipeline.cappedCandidates(candidates)
        XCTAssertEqual(capped.count, cap)
        // The clicks occupy original indices 4..<(4 + cap).
        XCTAssertEqual(capped.map(\.refIndex), Array(4..<(4 + cap)))
        XCTAssertTrue(capped.allSatisfy { $0.candidate.source == .click })
    }

    /// Among equal pre-extraction confidences, the tighter dwell wins; ties
    /// break toward the earlier reference.
    func testDwellStillnessBreaksTies() {
        let cap = ProcessingConfig.maxAnchorFrames
        // cap + 2 dwells all above the no-label 0.45 clamp (equal pre-rank
        // confidence) with two clearly looser ones mixed in at the front.
        var candidates: [CandidateAnchor] = [
            candidate(source: .dwell, dwellConfidence: 0.50),
            candidate(source: .dwell, dwellConfidence: 0.46),
        ]
        candidates.append(contentsOf: (0..<cap).map { _ in candidate(source: .dwell, dwellConfidence: 0.95) })

        let capped = DevAnchorPipeline.cappedCandidates(candidates)
        XCTAssertEqual(capped.count, cap)
        XCTAssertEqual(capped.map(\.refIndex), Array(2..<(2 + cap)))
    }

    /// End-to-end through `build` (no source video, so per-anchor extraction
    /// degrades gracefully): the RESOLVED anchor count honors the cap and the
    /// surviving refIndexes are the originals.
    func testBuildHonorsCap() async {
        let candidates = (0..<20).map { i in
            candidate(source: i % 2 == 0 ? .click : .dwell, dwellConfidence: 0.8)
        }
        let resolved = await DevAnchorPipeline.build(
            candidates: candidates,
            sourceVideoURL: nil,
            redactSecrets: false
        )
        XCTAssertEqual(resolved.count, ProcessingConfig.maxAnchorFrames)
        // Clicks (even indices) outrank dwells, so the survivors are the first
        // `maxAnchorFrames` even refIndexes — original numbering preserved.
        XCTAssertEqual(
            resolved.map(\.refIndex),
            Array(stride(from: 0, to: 2 * ProcessingConfig.maxAnchorFrames, by: 2))
        )
    }
}
