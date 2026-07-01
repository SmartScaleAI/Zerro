//
//  LocalModelManager.swift
//  Zerro
//
//  Downloads, stores, verifies, and tracks the on-device whisper model.
//
//  Phase 2 scope: this type is implemented and unit-tested but is NOT wired into
//  any UI or the recording pipeline — nothing constructs it outside tests, so the
//  app's behavior is unchanged. Later phases trigger `ensureModel()` from the
//  first-key consent prompt and read `state` / `isModelReady` for routing + UX.
//
//  Storage: the model lives at
//    ~/Library/Application Support/Zerro/models/<spec.fileName>
//  resolved the same way `RecentPromptStore` resolves its file. The directory is
//  created on demand.
//
//  Install is integrity-gated and atomic: the file is downloaded to a temp
//  location, its SHA-256 + byte size are verified against the `ModelSpec` OFF the
//  main actor, and only then is it swapped into place with a same-directory
//  rename. A mismatch deletes the temp and reports `.failed`; `modelFileURL`
//  never sees a partial or unverified file.
//
//  Testability: the download source is a `ModelSpec` injected at init (defaulting
//  to the production model). Tests pass a spec pointing at a small `file://`
//  fixture with its own real checksum/size, and override the models directory, so
//  they never touch the ~547 MB production download or the real Application
//  Support folder.
//

import Foundation
import os

@MainActor
@Observable
final class LocalModelManager {

    // MARK: - State

    enum State: Equatable {
        /// No verified model installed and no download in flight.
        case notDownloaded
        /// A download is running. `progress` is 0...1; byte counts are for UX copy
        /// ("X MB / Y MB"). `totalBytes` falls back to the spec's size until the
        /// server reports a content length.
        case downloading(progress: Double, downloadedBytes: Int64, totalBytes: Int64)
        /// A verified model is installed. `version` is the model id.
        case ready(version: String)
        /// The last download/verify/install attempt failed. `reason` is a short,
        /// already-user-readable message (no raw provider/system detail).
        case failed(reason: String)
    }

    /// The observable download/install state. Mutated only on the main actor via
    /// `setState`.
    private(set) var state: State = .notDownloaded

    /// Fires AFTER every `state` change. Provided for logging/analytics in later
    /// phases and for tests to observe the full transition sequence deterministically
    /// (SwiftUI Observation coalesces rapid changes; this callback does not).
    @ObservationIgnored var stateDidChange: (@MainActor (State) -> Void)?

    // MARK: - Dependencies

    @ObservationIgnored private let spec: ModelSpec
    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager
    /// Free-space cushion required ON TOP of the model size before a download is
    /// considered safe (temp copy + install headroom + OS breathing room).
    @ObservationIgnored private let diskHeadroom: Int

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    /// Set while a user-initiated `cancel()` is in flight, so the resulting
    /// `URLError.cancelled` is reported as a return-to-`.notDownloaded`, not a failure.
    @ObservationIgnored private var isCancelling = false

    // MARK: - Init

    /// - Parameters:
    ///   - spec: WHICH model to fetch + how to verify it. Defaults to the
    ///     production model; tests inject a small `file://` fixture spec.
    ///   - preferences: written on a verified install (`localModelVersion` +
    ///     `localModelDownloadedAt`).
    ///   - directory: the models directory. Defaults to
    ///     `~/Library/Application Support/Zerro/models`; tests inject a temp dir.
    ///   - fileManager: injectable for tests.
    ///   - diskHeadroom: free-space cushion required beyond the model size.
    init(
        spec: ModelSpec = WhisperCppTranscriptionService.ProductionModel.spec,
        preferences: PreferencesStore,
        directory: URL? = nil,
        fileManager: FileManager = .default,
        diskHeadroom: Int = 512 * 1024 * 1024
    ) {
        self.spec = spec
        self.preferences = preferences
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultModelsDirectory(fileManager)
        self.diskHeadroom = diskHeadroom
        // Cheap, hash-free launch reconcile so a previously-installed model shows
        // `.ready` immediately (e.g. the Settings status row) without a 547 MB hash.
        reconcile()
    }

    // MARK: - Paths / readiness

    /// Absolute path the verified model lives at once installed.
    var modelFileURL: URL { directory.appendingPathComponent(spec.fileName) }

    /// Whether a VERIFIED copy of the model is installed (file exists AND size +
    /// SHA-256 match the spec).
    ///
    /// NOTE: this runs the full integrity check, so for the production model it
    /// hashes ~547 MB on the calling actor — call it sparingly (and prefer off the
    /// main actor). Tests use a tiny fixture where it's instant.
    var isModelReady: Bool { spec.matches(fileAt: modelFileURL, fileManager: fileManager) }

    /// CHEAP, hash-free readiness (punchlist P2-1) — the installed model's URL, or
    /// `nil` when not installed. Returns the URL iff a file exists at the expected
    /// path AND its byte size equals `spec.byteSize`. It deliberately does NOT
    /// re-hash: the full SHA-256 already ran at install time (`verifyAndInstall`),
    /// so the hot path (Phase 3 STT routing, Phase 5 UI) must use THIS — never
    /// `isModelReady` / `spec.matches`, which re-hash ~547 MB on the calling actor.
    ///
    /// `nonisolated` + `static` so the router can call it off the main actor
    /// without holding a manager instance.
    nonisolated static func installedModelURL(
        spec: ModelSpec = WhisperCppTranscriptionService.ProductionModel.spec,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let dir = directory ?? defaultModelsDirectory(fileManager)
        let url = dir.appendingPathComponent(spec.fileName)
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size == spec.byteSize else {
            return nil
        }
        return url
    }

    // MARK: - Entry points

    /// If a verified model is already installed, transition to `.ready`; otherwise
    /// start a download. The idempotent entry point a caller invokes on launch /
    /// after consent.
    func ensureModel() {
        if isModelReady {
            setState(.ready(version: spec.id))
        } else {
            download()
        }
    }

    /// Begin downloading the model. No-op if a download is already running.
    func download() {
        if case .downloading = state { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            setState(.failed(reason: "Couldn't create the models folder."))
            Log.transcription.error("models dir create failed: \(error.localizedDescription, privacy: .private)")
            return
        }

        isCancelling = false
        setState(.downloading(progress: 0, downloadedBytes: 0, totalBytes: Int64(spec.byteSize)))

        let forwarder = DownloadForwarder(
            onProgress: { [weak self] written, total in
                guard let self else { return }
                Task { @MainActor in self.handleProgress(written: written, total: total) }
            },
            onFinish: { [weak self] staged, errorMessage in
                guard let self else { return }
                Task { @MainActor in self.handleFinished(staged: staged, moveError: errorMessage) }
            },
            onComplete: { [weak self] kind in
                guard let self else { return }
                Task { @MainActor in self.handleComplete(kind) }
            }
        )

        let config = URLSessionConfiguration.default
        // The production model is large; a per-request quiet-gap timeout is fine but
        // the whole-transfer ceiling must be generous.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        config.urlCache = nil

        let session = URLSession(configuration: config, delegate: forwarder, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: spec.sourceURL)
        self.downloadTask = task
        task.resume()
    }

    /// Cancel an in-flight download. Returns the state to `.notDownloaded`.
    func cancel() {
        guard case .downloading = state else { return }
        isCancelling = true
        downloadTask?.cancel()
        // `handleComplete(.cancelled)` performs the state transition + cleanup.
    }

    /// CHEAP, hash-free launch/first-access reconcile (punchlist P2-1). If a
    /// correctly-SIZED model file is present AND preferences recorded this exact
    /// version, reflect `.ready` WITHOUT re-hashing (the full SHA-256 already ran
    /// at install). Only upgrades from the initial `.notDownloaded` — it never
    /// disturbs an in-flight download or an already-resolved state.
    func reconcile() {
        guard case .notDownloaded = state else { return }
        guard preferences.localModelVersion == spec.id,
              Self.installedModelURL(spec: spec, directory: directory, fileManager: fileManager) != nil
        else { return }
        setState(.ready(version: spec.id))
    }

    /// Delete the installed model and reset tracking — the Settings "Remove"
    /// action. Clears the preferences fields and returns to `.notDownloaded`. A
    /// no-op-safe `removeItem` (a missing file is fine).
    func removeModel() {
        try? fileManager.removeItem(at: modelFileURL)
        preferences.localModelVersion = ""
        preferences.localModelDownloadedAt = nil
        setState(.notDownloaded)
    }

    // MARK: - Disk space

    /// Whether the volume backing the models directory has room for the model plus
    /// the configured headroom. Advisory — a caller warns the user ("needs ~1 GB
    /// free") before starting. Returns `true` when capacity can't be determined,
    /// so an unknowable volume never hard-blocks the download.
    func hasEnoughDiskSpace() -> Bool {
        let required = Int64(spec.byteSize) + Int64(diskHeadroom)

        // The models dir may not exist yet; probe its nearest existing ancestor
        // (same volume) for capacity.
        var probe = directory
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent == probe { break }
            probe = parent
        }

        guard let available = try? probe
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else {
            return true
        }
        return Self.hasEnoughSpace(availableBytes: available, requiredBytes: required)
    }

    /// Pure threshold comparison, factored out so it's unit-testable without
    /// touching the filesystem.
    nonisolated static func hasEnoughSpace(availableBytes: Int64, requiredBytes: Int64) -> Bool {
        availableBytes >= requiredBytes
    }

    // MARK: - Delegate handling (main actor)

    private func handleProgress(written: Int64, total: Int64) {
        guard case .downloading = state else { return }
        let totalBytes = total > 0 ? total : Int64(spec.byteSize)
        let progress = totalBytes > 0 ? min(1.0, max(0.0, Double(written) / Double(totalBytes))) : 0
        setState(.downloading(progress: progress, downloadedBytes: written, totalBytes: totalBytes))
    }

    private func handleFinished(staged: URL?, moveError: String?) {
        // A cancel/reset may have moved us out of `.downloading` already.
        guard case .downloading = state else {
            if let staged { try? fileManager.removeItem(at: staged) }
            return
        }
        guard let staged, moveError == nil else {
            if let staged { try? fileManager.removeItem(at: staged) }
            setState(.failed(reason: "The download couldn't be saved to disk."))
            cleanupSession()
            return
        }

        // Verify + atomically install OFF the main actor (SHA-256 over a large
        // file), then resolve the state back here.
        let spec = self.spec
        let dest = self.modelFileURL
        let dir = self.directory
        Task { [weak self] in
            let outcome = await Self.verifyAndInstall(staged: staged, into: dest, directory: dir, spec: spec)
            guard let self else { return }
            switch outcome {
            case .success:
                self.preferences.localModelVersion = spec.id
                self.preferences.localModelDownloadedAt = Date()
                self.setState(.ready(version: spec.id))
            case .integrityFailed:
                self.setState(.failed(reason: "The downloaded model failed verification."))
            case .installFailed:
                self.setState(.failed(reason: "The model couldn't be installed."))
            }
            self.cleanupSession()
        }
    }

    private func handleComplete(_ kind: DownloadForwarder.Completion) {
        switch kind {
        case .success:
            // The success transition is driven by `handleFinished` (which fires
            // first); nothing to do here.
            return
        case .cancelled:
            cleanupSession()
            isCancelling = false
            if case .downloading = state { setState(.notDownloaded) }
        case .failed(let message):
            cleanupSession()
            // Don't clobber a terminal state the finish path already set.
            if case .downloading = state { setState(.failed(reason: message)) }
        }
    }

    // MARK: - Verify + install (off the main actor)

    private enum InstallOutcome: Sendable {
        case success
        case integrityFailed
        case installFailed
    }

    private static func verifyAndInstall(
        staged: URL,
        into dest: URL,
        directory: URL,
        spec: ModelSpec
    ) async -> InstallOutcome {
        // Heavy hashing + file IO — keep it off the main actor.
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            guard spec.matches(fileAt: staged, fileManager: fm) else {
                try? fm.removeItem(at: staged)
                return InstallOutcome.integrityFailed
            }

            // Stage the verified file INSIDE the destination directory, then
            // atomically rename it into place (a same-directory rename is atomic).
            let inDir = directory.appendingPathComponent(".\(spec.fileName).install-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try fm.moveItem(at: staged, to: inDir)
                } catch {
                    // Cross-volume fallback (temp on a different volume than the
                    // models dir): copy, then drop the source.
                    try fm.copyItem(at: staged, to: inDir)
                    try? fm.removeItem(at: staged)
                }
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: inDir, to: dest)
                return .success
            } catch {
                try? fm.removeItem(at: staged)
                try? fm.removeItem(at: inDir)
                return .installFailed
            }
        }.value
    }

    // MARK: - Helpers

    private func setState(_ newState: State) {
        state = newState
        stateDidChange?(newState)
    }

    private func cleanupSession() {
        downloadTask = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    private nonisolated static func defaultModelsDirectory(_ fileManager: FileManager) -> URL {
        let base: URL
        do {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            // Application Support unreachable is exceptional; fall back to temp so
            // the app still functions (the model just won't persist across launches).
            Log.transcription.error("applicationSupport unreachable for models dir: \(error.localizedDescription, privacy: .private)")
            return fileManager.temporaryDirectory.appendingPathComponent("Zerro/models", isDirectory: true)
        }
        return base
            .appendingPathComponent("Zerro", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }
}

// MARK: - URLSession download delegate (separate object)

/// Bridges `URLSessionDownloadDelegate` (called on a background delegate queue)
/// to the main-actor `LocalModelManager` via `@Sendable` closures. Kept separate
/// so the manager needn't be an `NSObject`. Everything crossing the closure
/// boundary is `Sendable` (the download's temp file is moved out synchronously
/// and passed as a `URL`; errors are reduced to a `Completion`/`String`).
private final class DownloadForwarder: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Terminal disposition reported by `didCompleteWithError`, reduced to Sendable
    /// values so no raw `Error` crosses an isolation boundary.
    nonisolated enum Completion: Sendable {
        case success
        case cancelled
        case failed(String)
    }

    private nonisolated let onProgress: @Sendable (_ written: Int64, _ total: Int64) -> Void
    /// `(stagedTempURL, errorMessage)` — exactly one is non-nil.
    private nonisolated let onFinish: @Sendable (URL?, String?) -> Void
    private nonisolated let onComplete: @Sendable (Completion) -> Void

    nonisolated init(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinish: @escaping @Sendable (URL?, String?) -> Void,
        onComplete: @escaping @Sendable (Completion) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        self.onComplete = onComplete
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted when this method returns — move it out synchronously
        // to a stable temp the manager can verify + install at its leisure.
        let staged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zerro-model-download-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            onFinish(staged, nil)
        } catch {
            onFinish(nil, "The download couldn't be saved to disk.")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            onComplete(.success)
            return
        }
        if (error as? URLError)?.code == .cancelled {
            onComplete(.cancelled)
        } else {
            onComplete(.failed(Self.message(for: error)))
        }
    }

    private nonisolated static func message(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "The download failed." }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection."
        case .timedOut:
            return "The download timed out."
        case .cancelled:
            return "The download was cancelled."
        default:
            return "The download failed."
        }
    }
}
