//
//  LocalModelManagerTests.swift
//  ZerroTests
//
//  Phase 2 (Local Whisper) — `LocalModelManager` download / verify / install /
//  state machine. The download source is injected as a `ModelSpec` pointing at a
//  small `file://` fixture with its own REAL SHA-256 + byte size, so these tests
//  never touch the 547 MB production URL or the real Application Support folder
//  (the models directory is a per-test temp dir).
//

import CryptoKit
import Foundation
import XCTest
@testable import Zerro

@MainActor
final class LocalModelManagerTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Install happy path

    func testDownloadInstallsModelAndTransitionsToReady() async throws {
        let fixture = try makeFixtureFile()
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: fixture.size)
        let (manager, modelsDir, prefs) = try makeManager(spec: spec)

        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertFalse(manager.isModelReady)

        var observed: [LocalModelManager.State] = []
        let terminal = expectation(description: "terminal state")
        terminal.assertForOverFulfill = false
        manager.stateDidChange = { state in
            observed.append(state)
            if Self.isReady(state) || Self.isFailed(state) { terminal.fulfill() }
        }

        manager.download()
        // download() flips to .downloading synchronously, before any async work.
        XCTAssertTrue(Self.isDownloading(manager.state), "expected .downloading right after download()")

        await fulfillment(of: [terminal], timeout: 30)

        // notDownloaded → downloading → ready
        XCTAssertEqual(manager.state, .ready(version: spec.id))
        XCTAssertTrue(observed.first.map(Self.isDownloading) ?? false, "first transition is .downloading")
        XCTAssertTrue(observed.contains(where: Self.isReady), "reached .ready")
        // Progress callbacks fired (a .downloading state reported bytes written).
        XCTAssertTrue(
            observed.contains { (Self.downloadedBytes($0) ?? 0) > 0 },
            "expected at least one progress update with bytes > 0; got \(observed)"
        )

        // The file landed atomically at modelFileURL and verifies.
        XCTAssertEqual(manager.modelFileURL, modelsDir.appendingPathComponent(spec.fileName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.modelFileURL.path))
        XCTAssertTrue(manager.isModelReady)
        // No staging leftovers in the models directory.
        XCTAssertEqual(try modelsDirEntries(modelsDir), [spec.fileName])

        // Preferences recorded the install.
        XCTAssertEqual(prefs.localModelVersion, spec.id)
        XCTAssertNotNil(prefs.localModelDownloadedAt)
    }

    // MARK: - Integrity failures

    func testChecksumMismatchFailsDeletesTempAndStaysNotReady() async throws {
        let fixture = try makeFixtureFile()
        // Correct size, WRONG hash → fails the SHA-256 check after download.
        let spec = makeSpec(source: fixture.url, sha256: String(repeating: "0", count: 64), size: fixture.size)
        let (manager, modelsDir, prefs) = try makeManager(spec: spec)

        try await runToTerminal(manager)

        guard case .failed = manager.state else {
            return XCTFail("expected .failed, got \(manager.state)")
        }
        XCTAssertFalse(manager.isModelReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.modelFileURL.path), "no file installed")
        XCTAssertEqual(try modelsDirEntries(modelsDir), [], "no staging leftovers")
        XCTAssertEqual(prefs.localModelVersion, "", "preferences untouched on failure")
        XCTAssertNil(prefs.localModelDownloadedAt)
    }

    func testSizeMismatchFails() async throws {
        let fixture = try makeFixtureFile()
        // Right hash but WRONG size → fails the cheap size fast-path.
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: fixture.size + 1)
        let (manager, modelsDir, _) = try makeManager(spec: spec)

        try await runToTerminal(manager)

        guard case .failed = manager.state else {
            return XCTFail("expected .failed, got \(manager.state)")
        }
        XCTAssertFalse(manager.isModelReady)
        XCTAssertEqual(try modelsDirEntries(modelsDir), [])
    }

    // MARK: - isModelReady reflects disk

    func testIsModelReadyReflectsFileState() throws {
        let fixture = try makeFixtureFile()
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: fixture.size)
        let (manager, modelsDir, _) = try makeManager(spec: spec)

        XCTAssertFalse(manager.isModelReady, "no file present → not ready")

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.url, to: manager.modelFileURL)
        XCTAssertTrue(manager.isModelReady, "verified file present → ready")

        // Corrupt it: size + hash no longer match.
        try Data([0x00, 0x01, 0x02]).write(to: manager.modelFileURL)
        XCTAssertFalse(manager.isModelReady, "corrupt file → not ready")
    }

    func testEnsureModelUsesInstalledModelWithoutDownloading() throws {
        let fixture = try makeFixtureFile()
        // A deliberately unreachable source proves ensureModel() did NOT download.
        let spec = makeSpec(source: URL(fileURLWithPath: "/nonexistent/model.bin"),
                            sha256: fixture.sha256, size: fixture.size)
        let (manager, modelsDir, _) = try makeManager(spec: spec)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.url, to: manager.modelFileURL)

        manager.ensureModel()

        XCTAssertEqual(manager.state, .ready(version: spec.id))
    }

    // MARK: - Cheap, hash-free readiness (installedModelURL, P2-1)

    func testInstalledModelURLNilWhenAbsent() throws {
        let fixture = try makeFixtureFile(byteCount: 2_048)
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: 2_048)
        let dir = try makeTempDir()
        XCTAssertNil(LocalModelManager.installedModelURL(spec: spec, directory: dir))
    }

    /// The hot-path check is SIZE-ONLY: a file of the right size but WRONG content
    /// (so its SHA-256 does NOT match) still returns the URL — proving it never
    /// hashes. The full-integrity `isModelReady` rejects the same file.
    func testInstalledModelURLIsSizeOnlyNeverHashes() throws {
        let dir = try makeTempDir()
        // spec demands 4096 bytes with some sha256 that won't match zero-bytes.
        let spec = makeSpec(
            source: URL(fileURLWithPath: "/unused"),
            sha256: String(repeating: "a", count: 64),
            size: 4_096
        )
        let url = dir.appendingPathComponent(spec.fileName)
        try Data(count: 4_096).write(to: url)   // right SIZE, content (hash) won't match

        // Cheap check: returns the URL (no hashing).
        XCTAssertEqual(LocalModelManager.installedModelURL(spec: spec, directory: dir), url)

        // Full-integrity check on the SAME file would reject it (hash mismatch),
        // confirming the cheap path deliberately skipped the hash.
        let manager = LocalModelManager(
            spec: spec, preferences: PreferencesStore(defaults: .ephemeralPreview()),
            directory: dir, diskHeadroom: 0
        )
        XCTAssertFalse(manager.isModelReady)
    }

    func testInstalledModelURLNilWhenSizeMismatch() throws {
        let dir = try makeTempDir()
        let spec = makeSpec(source: URL(fileURLWithPath: "/unused"), sha256: "", size: 4_096)
        try Data(count: 1_024).write(to: dir.appendingPathComponent(spec.fileName))   // wrong size
        XCTAssertNil(LocalModelManager.installedModelURL(spec: spec, directory: dir))
    }

    // MARK: - Disk space

    func testDiskSpaceComparison() {
        XCTAssertTrue(LocalModelManager.hasEnoughSpace(availableBytes: 1_000, requiredBytes: 1_000), "exactly enough")
        XCTAssertTrue(LocalModelManager.hasEnoughSpace(availableBytes: 2_000, requiredBytes: 1_000), "more than enough")
        XCTAssertFalse(LocalModelManager.hasEnoughSpace(availableBytes: 999, requiredBytes: 1_000), "one byte short")
    }

    func testHasEnoughDiskSpaceTrueForTinyRequirement() throws {
        let fixture = try makeFixtureFile(byteCount: 1_024)
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: 1_024)
        let (manager, _, _) = try makeManager(spec: spec)   // diskHeadroom: 0
        XCTAssertTrue(manager.hasEnoughDiskSpace(), "a 1 KB model trivially fits on the test volume")
    }

    // MARK: - Cancel guard

    func testCancelWhenIdleIsNoOp() throws {
        let spec = makeSpec(source: URL(fileURLWithPath: "/nonexistent"), sha256: "", size: 0)
        let (manager, _, _) = try makeManager(spec: spec)
        manager.cancel()   // not downloading → safe no-op
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: - removeModel (Phase 5)

    func testRemoveModelDeletesFileClearsPrefsAndResetsState() throws {
        let fixture = try makeFixtureFile()
        let spec = makeSpec(source: fixture.url, sha256: fixture.sha256, size: fixture.size)
        let (manager, modelsDir, prefs) = try makeManager(spec: spec)
        // Simulate a completed install: verified file in place + prefs recorded.
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.url, to: manager.modelFileURL)
        prefs.localModelVersion = spec.id
        prefs.localModelDownloadedAt = Date(timeIntervalSince1970: 1_750_000_000)

        manager.removeModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.modelFileURL.path), "file deleted")
        XCTAssertEqual(prefs.localModelVersion, "", "version cleared")
        XCTAssertNil(prefs.localModelDownloadedAt, "timestamp cleared")
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: - Cheap launch reconcile (Phase 5, P2-1)

    /// With a correctly-SIZED file + a recorded version, the manager reports
    /// `.ready` from init WITHOUT hashing — proven by a wrong-content (right-size)
    /// file that the full-integrity check would reject.
    func testReconcileReportsReadyForSizeMatchWithoutHashing() throws {
        let dir = try makeTempDir()
        let spec = makeSpec(
            source: URL(fileURLWithPath: "/unused"),
            sha256: String(repeating: "b", count: 64),
            size: 4_096
        )
        try Data(count: 4_096).write(to: dir.appendingPathComponent(spec.fileName))
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        prefs.localModelVersion = spec.id

        // init runs reconcile(): cheap size + version match → .ready.
        let manager = LocalModelManager(spec: spec, preferences: prefs, directory: dir, diskHeadroom: 0)

        XCTAssertEqual(manager.state, .ready(version: spec.id))
        XCTAssertFalse(manager.isModelReady, "the cheap path did NOT hash (wrong content)")
    }

    /// A stray right-size file without a recorded `localModelVersion` is NOT
    /// trusted — reconcile leaves `.notDownloaded`.
    func testReconcileStaysNotDownloadedWhenVersionUnrecorded() throws {
        let dir = try makeTempDir()
        let spec = makeSpec(source: URL(fileURLWithPath: "/unused"), sha256: "z", size: 4_096)
        try Data(count: 4_096).write(to: dir.appendingPathComponent(spec.fileName))
        let prefs = PreferencesStore(defaults: .ephemeralPreview())   // localModelVersion == ""

        let manager = LocalModelManager(spec: spec, preferences: prefs, directory: dir, diskHeadroom: 0)

        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: - Cancel-during-install race (P2-2)

    /// A `cancel()` that races a verify+install — arriving after the download
    /// finished but before install completes — must WIN: even a SUCCESSFUL install
    /// resolves to `.notDownloaded`, never `.ready`, so a user who cancelled isn't
    /// left with a silently-installed model. (`handleFinished` additionally removes
    /// the installed file and skips the version write on this path.)
    func testStateAfterInstallCancelBeatsSuccessfulInstall() {
        XCTAssertEqual(
            LocalModelManager.stateAfterInstall(outcome: .success, isCancelling: true, version: "v1"),
            .notDownloaded,
            "a cancel racing a successful install resolves to .notDownloaded, not .ready"
        )
    }

    /// Without a cancel, a successful install resolves to `.ready` as before.
    func testStateAfterInstallSuccessWithoutCancelIsReady() {
        XCTAssertEqual(
            LocalModelManager.stateAfterInstall(outcome: .success, isCancelling: false, version: "v1"),
            .ready(version: "v1")
        )
    }

    /// A cancel also suppresses a FAILURE resolution — the user asked to stop.
    func testStateAfterInstallCancelBeatsFailure() {
        XCTAssertEqual(
            LocalModelManager.stateAfterInstall(outcome: .integrityFailed, isCancelling: true, version: "v1"),
            .notDownloaded
        )
    }

    /// Without a cancel, install failures surface their reasons unchanged.
    func testStateAfterInstallFailuresWithoutCancel() {
        XCTAssertEqual(
            LocalModelManager.stateAfterInstall(outcome: .integrityFailed, isCancelling: false, version: "v1"),
            .failed(reason: "The downloaded model failed verification.")
        )
        XCTAssertEqual(
            LocalModelManager.stateAfterInstall(outcome: .installFailed, isCancelling: false, version: "v1"),
            .failed(reason: "The model couldn't be installed.")
        )
    }

    // MARK: - Helpers

    private func runToTerminal(_ manager: LocalModelManager, timeout: TimeInterval = 30) async throws {
        let terminal = expectation(description: "terminal state")
        terminal.assertForOverFulfill = false
        manager.stateDidChange = { state in
            if Self.isReady(state) || Self.isFailed(state) { terminal.fulfill() }
        }
        manager.download()
        await fulfillment(of: [terminal], timeout: timeout)
    }

    private func makeManager(spec: ModelSpec) throws -> (LocalModelManager, URL, PreferencesStore) {
        let modelsDir = try makeTempDir().appendingPathComponent("models", isDirectory: true)
        let preferences = PreferencesStore(defaults: .ephemeralPreview())
        let manager = LocalModelManager(
            spec: spec,
            preferences: preferences,
            directory: modelsDir,
            diskHeadroom: 0
        )
        return (manager, modelsDir, preferences)
    }

    private func makeSpec(source: URL, sha256: String, size: Int,
                          id: String = "test-model", fileName: String = "test-model.bin") -> ModelSpec {
        ModelSpec(id: id, fileName: fileName, sourceURL: source, sha256: sha256, byteSize: size)
    }

    /// Writes a deterministic byte pattern to a temp file and returns its path +
    /// the REAL SHA-256 / size (so a `ModelSpec` built from these verifies).
    private func makeFixtureFile(byteCount: Int = 1_048_576) throws -> (url: URL, sha256: String, size: Int) {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("fixture-model.bin")
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let data = Data(bytes)
        try data.write(to: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, hex, byteCount)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Visible (non-dot) entries in the models directory, sorted — used to assert
    /// the only file is the installed model (no `.install-…` staging leftovers).
    private func modelsDirEntries(_ dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func isDownloading(_ s: LocalModelManager.State) -> Bool {
        if case .downloading = s { true } else { false }
    }
    private static func isReady(_ s: LocalModelManager.State) -> Bool {
        if case .ready = s { true } else { false }
    }
    private static func isFailed(_ s: LocalModelManager.State) -> Bool {
        if case .failed = s { true } else { false }
    }
    private static func downloadedBytes(_ s: LocalModelManager.State) -> Int64? {
        if case .downloading(_, let bytes, _) = s { bytes } else { nil }
    }
}
