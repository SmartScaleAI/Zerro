//
//  PendingPaidGenerationTests.swift
//  ZerroTests
//
//  M5 (resume after purchase). Covers the deterministic units behind holding
//  a paid-blocked recording and resuming it once the user pays:
//    • PendingPaidGenerationStore persistence + the in-working-dir marker.
//    • WorkingDirectory.sweep() sparing a marked dir while still reclaiming
//      unmarked orphans.
//    • Manifest round-trip → ProcessedRecording reconstruction that preserves
//      the original idempotency key (so resume can't double-charge).
//    • AppState's canResumePaidGeneration gate, the launch restore path, and
//      paid-block dismissal clearing the held recording.
//
//  The full "resume re-runs generation" / "still not entitled opens the
//  paywall" flows spawn async generation against live entitlement/proxy state
//  and are exercised by the manual smoke test in the handoff, not here.
//

import CoreMedia
import XCTest
@testable import Zerro

@MainActor
final class PendingPaidGenerationTests: XCTestCase {

    private var workingDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in workingDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        workingDirs = []
    }

    /// Creates a real `zerro-work-<UUID>` directory under the temp dir (so
    /// `workingDirectoryName` resolution + the sweep behave exactly as in
    /// production) and tracks it for teardown.
    private func makeWorkingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(WorkingDirectory.workingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        workingDirs.append(url)
        return url
    }

    private func makePending(
        dir: URL,
        key: String = UUID().uuidString,
        reason: PaidBlockReason = .trialCreditsExhausted,
        createdAt: Date = Date()
    ) -> PendingPaidGeneration {
        PendingPaidGeneration(
            workingDirectoryName: dir.lastPathComponent,
            idempotencyKey: key,
            modelID: ModelRegistry.defaultModelID,
            reason: reason,
            createdAt: createdAt
        )
    }

    private func markerURL(_ dir: URL) -> URL {
        dir.appendingPathComponent(WorkingDirectory.pendingPaidMarkerName)
    }

    // MARK: - PaidBlockReason mapping

    func testPaidBlockReasonMapsOnlyPaidReasons() {
        XCTAssertEqual(PaidBlockReason(.trialCreditsExhausted), .trialCreditsExhausted)
        XCTAssertEqual(PaidBlockReason(.outOfCredits), .outOfCredits)
        XCTAssertEqual(PaidBlockReason(.subscriptionInactive), .subscriptionInactive)
        // A non-paid failure has no PaidBlockReason — the resume feature ignores it.
        XCTAssertNil(PaidBlockReason(.networkOffline))
        XCTAssertNil(PaidBlockReason(.apiKeyMissing))
        // Round-trips back to the matching failure reason.
        XCTAssertEqual(PaidBlockReason.outOfCredits.failureReason, .outOfCredits)
    }

    // MARK: - Store persistence + marker

    func testSaveWritesPointerAndMarkerThenLoadReturnsIt() throws {
        let dir = try makeWorkingDir()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        let pending = makePending(dir: dir, key: "idem-123")

        store.save(pending)

        // UserDefaults pointer round-trips. (createdAt compared with accuracy —
        // the cache encodes dates as epoch seconds, so sub-second precision can
        // shift slightly; the identifying fields must match exactly.)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.workingDirectoryName, pending.workingDirectoryName)
        XCTAssertEqual(loaded.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(loaded.modelID, pending.modelID)
        XCTAssertEqual(loaded.reason, pending.reason)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970,
                       pending.createdAt.timeIntervalSince1970, accuracy: 0.001)
        // Marker written inside the working dir — what protects it from sweep.
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL(dir).path))
        XCTAssertTrue(WorkingDirectory.containsPendingPaidMarker(dir))
    }

    func testClearRemovesPointerAndMarker() throws {
        let dir = try makeWorkingDir()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        store.save(makePending(dir: dir))
        XCTAssertNotNil(store.load())

        store.clear()

        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL(dir).path))
    }

    // MARK: - Sweep

    func testSweepPreservesMarkedDirAndDeletesUnmarked() throws {
        let marked = try makeWorkingDir()
        let unmarked = try makeWorkingDir()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        store.save(makePending(dir: marked))

        WorkingDirectory.sweep()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marked.path),
                      "a working dir holding the pending-paid marker must survive the sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unmarked.path),
                       "an unmarked orphan working dir must still be reclaimed")
    }

    /// F-16: a marker whose record has outlived any plausible checkout no
    /// longer shields its directory — the sweep reclaims it instead of sparing
    /// it on every launch forever (the orphaned-marker leak: a pointer lost
    /// without the marker's delete).
    func testSweepReclaimsStaleMarkedDir() throws {
        let dir = try makeWorkingDir()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        let old = Date().addingTimeInterval(-(PendingPaidGenerationStore.maxAge + 60))
        store.save(makePending(dir: dir, createdAt: old))
        XCTAssertTrue(WorkingDirectory.containsPendingPaidMarker(dir))
        XCTAssertFalse(WorkingDirectory.hasFreshPendingPaidMarker(dir))

        WorkingDirectory.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "a stale paid-block working dir must be reclaimed, not spared forever")
    }

    /// F-16: an unreadable/garbage marker (which no restore path can use —
    /// restore reads the UserDefaults pointer, never the marker) reads as
    /// stale, so the sweep errs toward reclaiming.
    func testSweepReclaimsDirWithGarbageMarker() throws {
        let dir = try makeWorkingDir()
        try Data("not json".utf8).write(to: markerURL(dir))
        XCTAssertFalse(WorkingDirectory.hasFreshPendingPaidMarker(dir))

        WorkingDirectory.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// F-16 guard-rail: a freshly-saved marker still spares its dir — the
    /// staleness gate must not weaken the quit-during-checkout protection.
    func testFreshMarkerStillSparesDir() throws {
        let dir = try makeWorkingDir()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        store.save(makePending(dir: dir))
        XCTAssertTrue(WorkingDirectory.hasFreshPendingPaidMarker(dir))

        WorkingDirectory.sweep()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Manifest round-trip + reconstruction

    func testManifestRoundTripReconstructsRecordingWithInjectedKey() throws {
        let dir = try makeWorkingDir()
        // Write a real manifest via the production writer.
        let audioURL = dir.appendingPathComponent("audio.m4a")
        let frames = [
            ExtractedFrame(
                url: dir.appendingPathComponent("frame-000.jpg"),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600),
                index: 0,
                ocrText: "Hello"
            ),
            ExtractedFrame(
                url: dir.appendingPathComponent("frame-001.jpg"),
                timestamp: CMTime(seconds: 3, preferredTimescale: 600),
                index: 1,
                ocrText: nil
            ),
        ]
        let clicks = [ResolvedClick(seconds: 1.5, label: "Submit")]
        try ProcessingPipeline().writeManifest(
            audioURL: audioURL,
            frames: frames,
            duration: CMTime(seconds: 6, preferredTimescale: 600),
            clicks: clicks,
            hasSpeech: false,
            into: dir
        )

        let reconstructed = try ProcessedRecording.reconstruct(
            workingDirectory: dir,
            idempotencyKey: "original-key-xyz"
        )

        // The injected key is carried through — this is what lets the resumed
        // /generate replay the charged-but-blocked response instead of charging
        // a second credit.
        XCTAssertEqual(reconstructed.idempotencyKey, "original-key-xyz")
        XCTAssertEqual(reconstructed.audioURL.lastPathComponent, "audio.m4a")
        XCTAssertEqual(reconstructed.frames.count, 2)
        XCTAssertEqual(reconstructed.frames[0].ocrText, "Hello")
        XCTAssertEqual(reconstructed.frames[0].url.lastPathComponent, "frame-000.jpg")
        XCTAssertEqual(reconstructed.frames[1].index, 1)
        XCTAssertEqual(CMTimeGetSeconds(reconstructed.duration), 6, accuracy: 0.001)
        XCTAssertEqual(reconstructed.hasSpeech, false)
        XCTAssertEqual(reconstructed.clicks.count, 1)
        XCTAssertEqual(reconstructed.clicks.first?.label, "Submit")
    }

    func testReconstructThrowsWhenManifestMissing() throws {
        let dir = try makeWorkingDir() // no manifest written
        XCTAssertThrowsError(
            try ProcessedRecording.reconstruct(workingDirectory: dir, idempotencyKey: "k")
        )
    }

    // MARK: - AppState: canResumePaidGeneration

    func testCanResumeTrueForPaidBlockWithHeldRecording() throws {
        let appState = AppState()
        appState.pendingPaidStore = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.processedRecording = makeInMemoryRecording()
        appState.state = .failed(reason: .outOfCredits)
        XCTAssertTrue(appState.canResumePaidGeneration)
    }

    func testCanResumeFalseForNonPaidFailure() throws {
        let appState = AppState()
        appState.pendingPaidStore = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.processedRecording = makeInMemoryRecording()
        appState.state = .failed(reason: .networkOffline)
        XCTAssertFalse(appState.canResumePaidGeneration)
    }

    func testCanResumeFalseWhenNothingHeld() throws {
        let appState = AppState()
        appState.pendingPaidStore = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.processedRecording = nil
        appState.state = .failed(reason: .trialCreditsExhausted)
        XCTAssertFalse(appState.canResumePaidGeneration,
                       "no in-memory recording and no persisted pointer → nothing to resume")
    }

    // MARK: - AppState: dismissal clears the held recording

    func testDismissPaidBlockClearsPendingPointer() throws {
        let dir = try makeWorkingDir()
        let appState = AppState()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.pendingPaidStore = store
        store.save(makePending(dir: dir))
        appState.processedRecording = makeInMemoryRecording(workingDirectory: dir)
        appState.state = .failed(reason: .outOfCredits)

        appState.dismissFailure()

        XCTAssertNil(store.load(), "dismissing a paid block must clear the persisted pointer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL(dir).path),
                       "the marker must be gone after an intentional dismiss")
    }

    // MARK: - AppState: launch restore

    func testRestoreRebuildsFailedStateFromDisk() throws {
        let dir = try makeWorkingDir()
        try writeMinimalManifest(into: dir)
        let appState = AppState()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.pendingPaidStore = store
        store.save(makePending(dir: dir, key: "restore-key", reason: .subscriptionInactive))

        let restored = appState.restorePendingPaidGenerationIfAny()

        XCTAssertTrue(restored)
        guard case .failed(let reason) = appState.state else {
            return XCTFail("restore should re-enter .failed, got \(appState.state)")
        }
        XCTAssertEqual(reason, .subscriptionInactive)
        XCTAssertEqual(appState.processedRecording?.idempotencyKey, "restore-key",
                       "the restored recording must carry the original key for replay")
        XCTAssertTrue(appState.canResumePaidGeneration)
    }

    func testRestoreClearsStaleRecord() throws {
        let dir = try makeWorkingDir()
        try writeMinimalManifest(into: dir)
        let appState = AppState()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.pendingPaidStore = store
        let old = Date().addingTimeInterval(-(PendingPaidGenerationStore.maxAge + 60))
        store.save(makePending(dir: dir, createdAt: old))

        let restored = appState.restorePendingPaidGenerationIfAny()

        XCTAssertFalse(restored)
        XCTAssertNil(store.load(), "a stale pending record must be cleared")
        XCTAssertEqual(appState.state, .idle)
    }

    func testRestoreClearsRecordWhenWorkingDirMissing() throws {
        let appState = AppState()
        let store = PendingPaidGenerationStore(defaults: .ephemeralPreview())
        appState.pendingPaidStore = store
        // Point at a dir that was never created (no manifest, no marker).
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(WorkingDirectory.workingPrefix)\(UUID().uuidString)", isDirectory: true)
        store.save(makePending(dir: phantom))

        let restored = appState.restorePendingPaidGenerationIfAny()

        XCTAssertFalse(restored)
        XCTAssertNil(store.load())
    }

    // MARK: - Helpers

    private func makeInMemoryRecording(workingDirectory: URL? = nil) -> ProcessedRecording {
        let dir = workingDirectory ?? URL(fileURLWithPath: "/tmp/zerro-work-test")
        return ProcessedRecording(
            audioURL: dir.appendingPathComponent("audio.m4a"),
            frames: [],
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            workingDirectory: dir,
            clicks: [],
            hasSpeech: true
        )
    }

    private func writeMinimalManifest(into dir: URL) throws {
        try ProcessingPipeline().writeManifest(
            audioURL: dir.appendingPathComponent("audio.m4a"),
            frames: [
                ExtractedFrame(
                    url: dir.appendingPathComponent("frame-000.jpg"),
                    timestamp: CMTime(seconds: 0, preferredTimescale: 600),
                    index: 0
                )
            ],
            duration: CMTime(seconds: 4, preferredTimescale: 600),
            clicks: [],
            hasSpeech: true,
            into: dir
        )
    }
}
