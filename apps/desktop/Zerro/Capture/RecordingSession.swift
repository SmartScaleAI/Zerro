//
//  RecordingSession.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Owns the ScreenCaptureKit + AVAssetWriter pair for a single
//  recording session. Constructed fresh per recording (mirrors the
//  AreaSelectorWindowController per-presentation pattern — no
//  long-lived global capture stack, no state bleed between recordings)
//  and discarded after finalization.
//
//  Threading boundary — read this before touching the file
//  -------------------------------------------------------
//  • Public API (init/start/stop/cancel) is @MainActor.
//  • SCStreamOutput delivers sample buffers on `videoQueue`
//    (background, dedicated). ScreenCaptureKit requires the handler
//    to be on a queue you supply; the main queue is wrong.
//  • AVAssetWriter is single-threaded — every writer mutation
//    (`startSession`, input.append, markAsFinished, finishWriting)
//    runs on `writerQueue` (background, serial). Sample buffers are
//    forwarded from videoQueue to writerQueue with writerQueue.async
//    before any writer touch. Decouples capture rate from writer
//    throughput and keeps the writer single-threaded without locking.
//  • Hops back to MainActor (publishing elapsed, firing onFinish)
//    are explicit `Task { @MainActor in ... }`.
//
//  Writer-touching state (writer, videoInput, sessionStartPTS) is
//  declared nonisolated(unsafe) and accessed only from writerQueue
//  after start() has populated it. Safety relies on three invariants:
//    1. start() finishes setting these before SCStream.startCapture()
//       returns — no sample buffer can arrive until after.
//    2. finalize() calls SCStream.stopCapture() before the writer
//       teardown block runs on writerQueue, so no in-flight buffers
//       race the markAsFinished call.
//    3. writerQueue is serial — append/finish/markAsFinished can
//       never interleave.
//
//  Audio session start dance
//  -------------------------
//  AVAssetWriter has ONE session-start timestamp shared by both inputs.
//  We anchor it to the first VIDEO sample buffer's PTS (video is the
//  dominant track and defines the timebase). Any audio buffers that
//  arrive before that first video buffer are dropped — the writer
//  rejects appends with PTS < session start. This is typically a few
//  tens of ms at session start and never affects the perceived audio
//  inside the recording.
//
//  Coordinate conversion (C3)
//  --------------------------
//  SelectionRect.rect is in points, global AppKit space, bottom-left
//  origin. SCStreamConfiguration.sourceRect is in points, display-
//  local, TOP-LEFT origin. This is the single conversion site in the
//  codebase — see `displayLocalSourceRect(_:on:)`. The conversion
//  involves two independent transforms: global→display-local (subtract
//  the screen's frame origin) and bottom-left→top-left (flip the y
//  axis using the screen's height). Both flips together.
//
//  Phase 7 checkpoint scope
//  ------------------------
//  C1: video-only of the primary display. C2: adds mic via
//  AVCaptureSession reading the system default audio device, writes a
//  second (audio) track to the same .mov. C3 (this form): honors
//  selection (rect-scoped capture at point resolution) + reads
//  microphoneDeviceID from PreferencesStore. C4 wires onElapsed +
//  onFinish into AppState. C5 adds failure paths.
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class RecordingSession: NSObject {

    // MARK: - Public types

    enum Outcome {
        case finished(URL)
        case cancelled
        case failed(Error)
    }

    enum SessionError: Error {
        case noDisplaysAvailable
        case noMicrophoneAvailable
        case writerFailedToStart(underlying: Error?)
        case audioInputSetupFailed(underlying: Error?)
        case alreadyStarted
    }

    // MARK: - Init parameters

    private let selection: SelectionRect?
    private let microphoneDeviceID: String
    private let onElapsed: (TimeInterval) -> Void
    private let onFinish: (Outcome) -> Void
    /// DEV-ONLY: multiplies the elapsed value reported via onElapsed
    /// before it reaches AppState's threshold checks. Lets the
    /// 150s/180s wrappingUp/autoStop transitions be exercised without
    /// recording for 3 real minutes. 1.0 = real time; production paths
    /// MUST construct with 1.0. The wall-clock file duration is
    /// unchanged — only the published "elapsed" reading is scaled.
    private let clockMultiplier: Double

    // MARK: - Queues

    private nonisolated let videoQueue = DispatchQueue(
        label: "vf.capture.video", qos: .userInteractive
    )
    private nonisolated let audioQueue = DispatchQueue(
        label: "vf.capture.audio", qos: .userInteractive
    )
    private nonisolated let writerQueue = DispatchQueue(
        label: "vf.capture.writer", qos: .userInteractive
    )

    // MARK: - MainActor-only state

    private var stream: SCStream?
    private var streamOutput: VideoStreamOutput?
    private var captureSession: AVCaptureSession?
    private var audioOutputAdapter: AudioCaptureOutput?
    private var lifecycleState: LifecycleState = .idle

    /// Wall-clock anchor for the elapsed publish task. Set in start()
    /// once both capture pipelines are running; read by the publish
    /// loop. The file's actual duration comes from video PTS (which
    /// can lag wall clock when the screen is static and SCStream
    /// throttles frame delivery) — anchoring the UI on wall clock
    /// gives the user a smooth stopwatch tick regardless.
    private var sessionStartWallClock: CFAbsoluteTime?
    private var elapsedPublishTask: Task<Void, Never>?

    /// NotificationCenter token for AVCaptureSession runtime errors
    /// (mic device pulled, format change, etc.). Registered in start(),
    /// removed in finalize().
    private var runtimeErrorObserver: NSObjectProtocol?

    private enum LifecycleState {
        case idle, running, finishing, finished
    }

    // MARK: - WriterQueue-only state

    /// Writer state lives nonisolated and is touched only from
    /// `writerQueue` after `start()` populates it. See the invariants
    /// in the file header for the safety argument.
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStartPTS: CMTime?

    // MARK: - Immutable

    let outputURL: URL

    // MARK: - Init

    init(
        selection: SelectionRect?,
        microphoneDeviceID: String,
        onElapsed: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (Outcome) -> Void,
        clockMultiplier: Double = 1.0
    ) {
        self.selection = selection
        self.microphoneDeviceID = microphoneDeviceID
        self.onElapsed = onElapsed
        self.onFinish = onFinish
        self.clockMultiplier = clockMultiplier
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerro-\(UUID().uuidString).mov")
        super.init()
    }

    // MARK: - Public API

    func start() async throws {
        guard lifecycleState == .idle else { throw SessionError.alreadyStarted }

        // Resolve display. With a `selection`, prefer the screen it
        // was made on (matched by localized name) and fall back to
        // main if that screen has since disappeared. Without one,
        // primary display.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let resolved = Self.resolveDisplay(for: selection, in: content)
        guard let display = resolved?.scDisplay, let screen = resolved?.nsScreen else {
            throw SessionError.noDisplaysAvailable
        }

        // SCStream config. Two paths:
        //   • No selection: full display, output at the display's full
        //     pixel dimensions (display.width/height are pixels).
        //   • Selection: rect-scoped via sourceRect, output at the
        //     selection's point dimensions (1pt → 1px, per the C0
        //     "point-resolution, not backing-pixel" decision).
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        // Three capture shapes, in priority order:
        //   1. Window target whose SCWindow is still on screen — clean
        //      per-window capture via desktopIndependentWindow (no
        //      overlapping windows bleed in, sized to the window).
        //   2. Any selection rect (area, or a window target whose window
        //      has since closed) — crop the display to the rect.
        //   3. No selection — full display.
        let filter: SCContentFilter
        if case let .window(windowID, _)? = selection?.target,
           let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            config.width = Int(scWindow.frame.width.rounded())
            config.height = Int(scWindow.frame.height.rounded())
        } else if let selection {
            let source = Self.displayLocalSourceRect(global: selection.rect, on: screen)
            config.sourceRect = source
            config.destinationRect = CGRect(origin: .zero, size: source.size)
            config.width = Int(source.width.rounded())
            config.height = Int(source.height.rounded())
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            config.width = display.width
            config.height = display.height
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // AVAssetWriter setup. Synchronous; failures here mean we never
        // entered .running, so callers can treat a throw as "no recording
        // happened" without cleanup.
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Without `expectsMediaDataInRealTime = true` the writer buffers
        // aggressively and isReadyForMoreMediaData returns false partway
        // through, causing dropped append()s. This flag is non-negotiable
        // for live capture.
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw SessionError.writerFailedToStart(underlying: writer.error)
        }
        writer.add(videoInput)

        // Audio input setup. AAC mono 44.1kHz / 64kbps — voice-grade,
        // since narration is the only signal we care about. Mic native
        // format (channels + sample rate) is converted by the writer
        // via its internal AudioConverter — no manual downmix needed.
        // C2: defaults to system audio device; C3 reads
        // microphoneDeviceID from PreferencesStore.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 64_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw SessionError.writerFailedToStart(underlying: writer.error)
        }
        writer.add(audioInput)

        // AVCaptureSession with the user's selected mic. Construction
        // is synchronous; startRunning() below is the blocking call
        // and we await it off the main queue. C3: resolves from
        // PreferencesStore.microphoneDeviceID, falling back to system
        // default if the persisted device is no longer connected.
        guard let audioDevice = Self.resolveAudioDevice(uniqueID: microphoneDeviceID) else {
            throw SessionError.noMicrophoneAvailable
        }
        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        let audioDeviceInput: AVCaptureDeviceInput
        do {
            audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            throw SessionError.audioInputSetupFailed(underlying: error)
        }
        guard captureSession.canAddInput(audioDeviceInput) else {
            throw SessionError.audioInputSetupFailed(underlying: nil)
        }
        captureSession.addInput(audioDeviceInput)

        let audioDataOutput = AVCaptureAudioDataOutput()
        let audioOutputAdapter = AudioCaptureOutput { [weak self] sampleBuffer in
            self?.handleAudioSampleBuffer(sampleBuffer)
        }
        audioDataOutput.setSampleBufferDelegate(audioOutputAdapter, queue: audioQueue)
        guard captureSession.canAddOutput(audioDataOutput) else {
            throw SessionError.audioInputSetupFailed(underlying: nil)
        }
        captureSession.addOutput(audioDataOutput)
        captureSession.commitConfiguration()

        guard writer.startWriting() else {
            throw SessionError.writerFailedToStart(underlying: writer.error)
        }

        // Hand off writer state to nonisolated storage BEFORE either
        // sample-buffer stream is allowed to start. SCStream.startCapture()
        // and AVCaptureSession.startRunning() below are the lines that
        // open the floodgates.
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        let videoStreamOutput = VideoStreamOutput { [weak self] sampleBuffer in
            self?.handleVideoSampleBuffer(sampleBuffer)
        }
        self.streamOutput = videoStreamOutput
        self.audioOutputAdapter = audioOutputAdapter
        try stream.addStreamOutput(videoStreamOutput, type: .screen, sampleHandlerQueue: videoQueue)

        try await stream.startCapture()

        // AVCaptureSession.startRunning() blocks for ~100ms while the
        // audio stack warms up. Hop off MainActor so the menu bar
        // dropdown stays responsive while it spins up.
        let sessionShim = UncheckedSendable(captureSession)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                sessionShim.value.startRunning()
                continuation.resume()
            }
        }

        self.stream = stream
        self.captureSession = captureSession
        self.lifecycleState = .running

        // Mid-session AVCaptureSession failures (mic unplugged, format
        // change refused, etc.) surface as a runtime-error notification
        // — observe and route to failSession. Posted off MainActor so
        // we hop explicitly. SCStream failures land in the delegate
        // method below, same routing.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.failSession(with: error ?? SessionError.audioInputSetupFailed(underlying: nil))
            }
        }

        // Anchor the UI-facing elapsed clock on wall time and start
        // publishing at 10Hz. The wall-clock anchor (not video PTS)
        // is intentional: SCStream's minimumFrameInterval is a CAP,
        // not a floor — when the screen is static, frames arrive
        // sparsely (sometimes <1fps), which would make a PTS-driven
        // pill timer freeze and lurch. The file's actual duration
        // still comes from video PTS via the writer; this clock is
        // strictly the UI ticker.
        sessionStartWallClock = CFAbsoluteTimeGetCurrent()
        elapsedPublishTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                guard let self else { return }
                guard let start = self.sessionStartWallClock else { continue }
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * self.clockMultiplier
                self.onElapsed(elapsed)
            }
        }
    }

    func stop() {
        guard lifecycleState == .running else { return }
        lifecycleState = .finishing
        finalize(deletingFile: false)
    }

    func cancel() {
        guard lifecycleState == .running else { return }
        lifecycleState = .finishing
        finalize(deletingFile: true)
    }

    /// Mid-session failure entry point — same teardown path as cancel
    /// (the partial file is presumed unusable when capture errored
    /// out), but the outcome carries the originating error so AppState
    /// can route to `.failed(reason)` instead of `.idle`. Guards
    /// against double-failure (e.g. SCStream error + AVCaptureSession
    /// error firing back-to-back).
    private func failSession(with error: Error) {
        guard lifecycleState == .running else { return }
        NSLog("[RecordingSession] failSession: %@", String(describing: error))
        lifecycleState = .finishing
        finalize(deletingFile: true, failureError: error)
    }

    // MARK: - Finalize

    /// `failureError` non-nil → mid-session failure path: ignore the
    /// writer's "completed/failed" status (the file is unusable
    /// regardless), delete the partial, emit `.failed(failureError)`.
    /// `failureError` nil → existing success/cancel paths.
    private func finalize(deletingFile: Bool, failureError: Error? = nil) {
        let stream = self.stream
        let captureSession = self.captureSession
        let outputURL = self.outputURL
        let writerQueue = self.writerQueue

        // Stop the UI ticker before the capture pipelines drain so
        // the pill freezes at its final elapsed value rather than
        // ticking through the (brief) finalize window.
        elapsedPublishTask?.cancel()
        elapsedPublishTask = nil
        sessionStartWallClock = nil

        // Drop the runtime-error observer before pipeline teardown so
        // the inevitable "session stopped" notifications don't loop
        // back through failSession.
        if let token = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(token)
            runtimeErrorObserver = nil
        }

        Task { @MainActor in
            // Stop both capture pipelines first so no more sample buffers
            // arrive mid-teardown. SCStream.stopCapture() awaits SCK's
            // drain; AVCaptureSession.stopRunning() blocks briefly while
            // the audio stack tears down — push off MainActor for the
            // same reason as startRunning().
            async let videoStop: Void = {
                if let stream { try? await stream.stopCapture() }
            }()
            async let audioStop: Void = withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let captureSession else { continuation.resume(); return }
                let sessionShim = UncheckedSendable(captureSession)
                DispatchQueue.global(qos: .userInteractive).async {
                    sessionShim.value.stopRunning()
                    continuation.resume()
                }
            }
            _ = await (videoStop, audioStop)

            // Marshal writer teardown onto writerQueue so it sees any
            // in-flight appends complete first (serial queue ordering).
            writerQueue.async { [weak self] in
                guard let self else { return }
                guard let writer = self.writer, let videoInput = self.videoInput else {
                    Task { @MainActor in
                        self.lifecycleState = .finished
                        self.onFinish(deletingFile ? .cancelled : .failed(SessionError.writerFailedToStart(underlying: nil)))
                    }
                    return
                }
                videoInput.markAsFinished()
                self.audioInput?.markAsFinished()
                let writerShim = UncheckedSendable(writer)
                writer.finishWriting {
                    Task { @MainActor in
                        // Re-unwrap inside the Task so writer isn't
                        // captured across the @Sendable Task boundary
                        // (AVAssetWriter isn't Sendable; writerShim is).
                        let writer = writerShim.value
                        // Mid-session failure: the file is presumed
                        // unusable, so delete it and emit the original
                        // error regardless of the writer's terminal
                        // status. Bypasses both the cancel and the
                        // success branches.
                        if let failureError {
                            try? FileManager.default.removeItem(at: outputURL)
                            self.lifecycleState = .finished
                            self.onFinish(.failed(failureError))
                            return
                        }
                        if deletingFile {
                            try? FileManager.default.removeItem(at: outputURL)
                            self.lifecycleState = .finished
                            self.onFinish(.cancelled)
                            return
                        }
                        switch writer.status {
                        case .completed:
                            self.lifecycleState = .finished
                            self.onFinish(.finished(outputURL))
                        default:
                            let err = writer.error
                                ?? SessionError.writerFailedToStart(underlying: nil)
                            self.lifecycleState = .finished
                            self.onFinish(.failed(err))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sample buffer handler (runs on videoQueue)

    nonisolated private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // ScreenCaptureKit delivers a status attachment on every frame
        // — only `.complete` frames carry a usable image. Idle frames
        // (no display change since last output) carry a different
        // status and must be skipped.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let buffer = UncheckedSendable(sampleBuffer)
        writerQueue.async { [weak self] in
            self?.appendVideo(buffer.value)
        }
    }

    /// Runs on writerQueue. Guards the first-sample session start and
    /// publishes throttled elapsed time back to MainActor.
    nonisolated private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = writer, let videoInput = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // First sample: start the writer's session at THIS pts.
        // startSession must run before the first append; subsequent
        // appends must have pts >= sessionStartPTS.
        if sessionStartPTS == nil {
            writer.startSession(atSourceTime: pts)
            sessionStartPTS = pts
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
        // Elapsed publishing is NOT tied to sample buffer arrival —
        // see `elapsedPublishTask` in start(). SCStream throttles
        // frame delivery when the screen is static, which would make
        // a sample-buffer-driven publish loop freeze the UI ticker.
    }

    // MARK: - Audio sample handler (runs on audioQueue)

    nonisolated private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let buffer = UncheckedSendable(sampleBuffer)
        writerQueue.async { [weak self] in
            self?.appendAudio(buffer.value)
        }
    }

    /// Runs on writerQueue. Drops samples that arrive before the
    /// writer's session has been started by the first video buffer —
    /// AVAssetWriter rejects appends with pts < sessionStartPTS, and
    /// "rejected" surfaces as the writer entering .failed which would
    /// kill the recording. Per the file header's session-start dance.
    nonisolated private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput = audioInput else { return }
        guard let start = sessionStartPTS else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if CMTimeCompare(pts, start) < 0 { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    // MARK: - C3 helpers (display + audio device resolution)
    //
    // All static so the construction logic stays callable from
    // `start()` without straddling the MainActor / nonisolated split.
    // NSScreen + AVCaptureDevice + SCShareableContent are all main-
    // thread-safe to read.

    /// Pairs the SCDisplay (what ScreenCaptureKit needs) with the
    /// NSScreen (what we need for the coordinate conversion). Keeping
    /// both halves together is cheaper than re-resolving the NSScreen
    /// downstream by display name.
    private struct ResolvedDisplay {
        let scDisplay: SCDisplay
        let nsScreen: NSScreen
    }

    private static func resolveDisplay(
        for selection: SelectionRect?,
        in content: SCShareableContent
    ) -> ResolvedDisplay? {
        if let name = selection?.screenLocalizedName,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }),
           let screenNumberKey = screen.deviceDescription[
               NSDeviceDescriptionKey("NSScreenNumber")
           ] as? NSNumber {
            let displayID = CGDirectDisplayID(screenNumberKey.uint32Value)
            if let scDisplay = content.displays.first(where: { $0.displayID == displayID }) {
                return ResolvedDisplay(scDisplay: scDisplay, nsScreen: screen)
            }
            NSLog(
                "[RecordingSession] selection screen '%@' found in NSScreen but not in SCShareableContent — falling back to main",
                name
            )
        } else if let name = selection?.screenLocalizedName {
            NSLog(
                "[RecordingSession] selection screen '%@' no longer present — falling back to main",
                name
            )
        }
        // Fallback: NSScreen.main paired with the first SCDisplay
        // (which is the primary display per ScreenCaptureKit ordering).
        guard let mainScreen = NSScreen.main,
              let scDisplay = content.displays.first else {
            return nil
        }
        return ResolvedDisplay(scDisplay: scDisplay, nsScreen: mainScreen)
    }

    /// Single conversion site for SelectionRect.rect (points, global
    /// AppKit space, bottom-left origin) → SCStreamConfiguration.
    /// sourceRect (points, display-local, top-left origin). Both flips
    /// in one place: subtract the screen's frame origin to move into
    /// display-local coords; subtract from the screen's height to
    /// invert the y axis. See the file header for the full convention.
    private static func displayLocalSourceRect(
        global selectionRect: CGRect,
        on screen: NSScreen
    ) -> CGRect {
        let xLocal = selectionRect.minX - screen.frame.minX
        let yBottomLocal = selectionRect.minY - screen.frame.minY
        let yTopLocal = screen.frame.height - yBottomLocal - selectionRect.height
        return CGRect(
            x: xLocal,
            y: yTopLocal,
            width: selectionRect.width,
            height: selectionRect.height
        )
    }

    /// Resolves the user's stored mic preference to a live device.
    /// Empty `uniqueID` is the "system default" sentinel
    /// (PreferencesStore convention). If the persisted device has
    /// since been disconnected, falls back to the system default and
    /// logs — silently swapping the device is better than failing the
    /// recording, and the Settings UI will reflect the real selection
    /// next time the user opens it.
    private static func resolveAudioDevice(uniqueID: String) -> AVCaptureDevice? {
        if uniqueID.isEmpty {
            return AVCaptureDevice.default(for: .audio)
        }
        if let device = AVCaptureDevice(uniqueID: uniqueID) {
            return device
        }
        NSLog(
            "[RecordingSession] persisted mic uniqueID '%@' not found — falling back to system default",
            uniqueID
        )
        return AVCaptureDevice.default(for: .audio)
    }
}

// MARK: - SCStreamDelegate

extension RecordingSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // SCK invoked this because something stopped capture out from
        // under us (permission revoked mid-session, display
        // disconnected, system pressure). Hop to MainActor so the
        // failSession guard sees coherent lifecycleState.
        NSLog("[RecordingSession] SCStream didStopWithError: %@", String(describing: error))
        Task { @MainActor [weak self] in
            self?.failSession(with: error)
        }
    }
}

// MARK: - VideoStreamOutput
//
// Thin SCStreamOutput conformer so RecordingSession itself doesn't
// take on the conformance (keeps the session's surface focused on
// lifecycle; this owns per-buffer fanout). All callbacks fire on the
// queue passed to `addStreamOutput`.

private final class VideoStreamOutput: NSObject, SCStreamOutput {
    nonisolated let onSampleBuffer: @Sendable (CMSampleBuffer) -> Void

    nonisolated init(onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        onSampleBuffer(sampleBuffer)
    }
}

// MARK: - AudioCaptureOutput
//
// Mirrors VideoStreamOutput for the AVCaptureSession audio pipeline.
// Owns no state; just forwards delegate callbacks to a closure so
// RecordingSession doesn't need to take on AVCaptureAudioDataOutput-
// SampleBufferDelegate conformance directly. Callbacks fire on the
// queue passed to setSampleBufferDelegate(_:queue:).

private final class AudioCaptureOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated let onSampleBuffer: @Sendable (CMSampleBuffer) -> Void

    nonisolated init(onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer(sampleBuffer)
    }
}

// MARK: - UncheckedSendable
//
// Generic shim for handing a non-Sendable reference (CMSampleBuffer,
// AVCaptureSession, AVAssetWriter, AVAssetWriterInput) across an
// isolation boundary when we can argue safety by other means:
//   • CMSampleBuffer: owned by exactly one queue at a time, never
//     shared (videoQueue → writerQueue hop).
//   • AVCaptureSession / AVAssetWriter: documented as thread-safe by
//     Apple even though the Sendable conformance is absent. We hop
//     onto known background queues for start/stop/append calls.
// Documents the promise rather than silently disabling the warning
// at every call site with @preconcurrency import. nonisolated init
// so it can be constructed from background queue contexts (sample
// buffer handlers).

private struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
    nonisolated init(_ value: T) { self.value = value }
}
