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
//  • SCStreamOutput delivers VIDEO sample buffers on `videoQueue` and
//    MICROPHONE sample buffers on `audioQueue` (both background,
//    dedicated). ScreenCaptureKit requires the handler to be on a queue
//    you supply; the main queue is wrong. As of Phase 18 the mic is
//    captured through ScreenCaptureKit too (not a side AVCaptureSession)
//    — see "Audio source" below.
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
//  Audio source (Phase 18) — read this before touching capture setup
//  -------------------------------------------------------------------
//  The microphone is captured THROUGH ScreenCaptureKit
//  (`config.captureMicrophone = true`, delivered as the `.microphone`
//  output type), NOT via a separate AVCaptureSession. The reason is the
//  clock domain: SCStream video and an AVCaptureSession mic are stamped
//  on two independent clocks with no shared origin. The old design
//  anchored the writer to the first VIDEO frame and dropped any audio
//  whose PTS fell before that anchor — and on a STATIC screen (sparse
//  video frames) the mic clock could sit behind the anchor and every
//  mic buffer was silently discarded: silent track → empty transcript →
//  a prompt generated from frames only. Capturing the mic through SCK
//  puts video + mic on ONE clock, so the comparison below is always
//  coherent. This is the macOS-native pattern modern recorders use.
//
//  Session start anchor
//  --------------------
//  AVAssetWriter has ONE session-start timestamp shared by both inputs.
//  We anchor it to the FIRST sample buffer of EITHER track (whichever
//  arrives first) via `ensureSessionStarted` — never gated on one track
//  specifically. A straggler from the other track with PTS < the anchor
//  is dropped (at most one buffer, a few tens of ms), which is the
//  canonical first-buffer-wins pattern for muxing into one writer.
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
import os
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
    /// Throttled live-mic peak level (0...1). Emitted ~12.5Hz from the
    /// audioQueue handler so the pill's waveform can animate against
    /// real input without hammering the MainActor — see
    /// `handleAudioSampleBuffer`. Optional so non-pill consumers
    /// (tests, future headless modes) don't pay the cost. `nonisolated`
    /// because the audioQueue handler reads it from outside MainActor;
    /// `@MainActor @Sendable` on the closure because it's invoked from
    /// inside a `Task { @MainActor }` hop so the call site can touch
    /// MainActor-isolated state (AppState).
    nonisolated private let onAudioLevel: (@MainActor @Sendable (Float) -> Void)?
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
    private var streamOutput: StreamSampleOutput?
    private var lifecycleState: LifecycleState = .idle

    /// Wall-clock anchor for the elapsed publish task. Set in start()
    /// once both capture pipelines are running; read by the publish
    /// loop. The file's actual duration comes from video PTS (which
    /// can lag wall clock when the screen is static and SCStream
    /// throttles frame delivery) — anchoring the UI on wall clock
    /// gives the user a smooth stopwatch tick regardless.
    private var sessionStartWallClock: CFAbsoluteTime?
    private var elapsedPublishTask: Task<Void, Never>?

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

    /// Diagnostic counters for the mic-append path (writerQueue-only, so
    /// single-writer-safe like the rest of this block). Logged at
    /// finalize so a silent recording is immediately distinguishable from
    /// a dropped-buffer recording — the exact ambiguity that made the
    /// pre-Phase-18 AVCaptureSession bug hard to spot. Counts only, never
    /// content.
    nonisolated(unsafe) private var audioAppendCount = 0
    nonisolated(unsafe) private var audioDropCount = 0

    // MARK: - AudioQueue-only state (live waveform throttle)
    //
    // Touched only from `audioQueue` (which is serial) inside
    // `handleAudioSampleBuffer`. Same single-writer guarantee as the
    // writer-queue state above.
    nonisolated(unsafe) private var audioLevelPeakAccumulator: Float = 0
    nonisolated(unsafe) private var audioLevelLastEmit: CFAbsoluteTime = 0
    /// Emit interval for `onAudioLevel`. ~12.5Hz — slow enough that the
    /// MainActor isn't flooded, fast enough that the waveform reads as
    /// "alive" during normal speech. `nonisolated` since the audioQueue
    /// handler that reads it lives outside MainActor.
    nonisolated private static let audioLevelEmitInterval: CFAbsoluteTime = 0.08

    // MARK: - Immutable

    let outputURL: URL

    // MARK: - Init

    init(
        selection: SelectionRect?,
        microphoneDeviceID: String,
        onElapsed: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (Outcome) -> Void,
        onAudioLevel: (@MainActor @Sendable (Float) -> Void)? = nil,
        clockMultiplier: Double = 1.0
    ) {
        self.selection = selection
        self.microphoneDeviceID = microphoneDeviceID
        self.onElapsed = onElapsed
        self.onFinish = onFinish
        self.onAudioLevel = onAudioLevel
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

        // Phase 18: capture the microphone THROUGH ScreenCaptureKit so
        // narration shares the screen stream's clock domain (see the file
        // header "Audio source"). `captureMicrophone` /
        // `microphoneCaptureDeviceID` are macOS 15+; the deployment target
        // is well above that, so no availability fence is needed. We do
        // NOT set `capturesAudio` — system audio is not part of the
        // narration signal and would only invite echo. Resolve the mic up
        // front so a machine with no input device fails fast on the same
        // `.noMicrophoneAvailable` path as before.
        guard let micDeviceID = Self.resolveMicrophoneDeviceID(preferred: microphoneDeviceID) else {
            throw SessionError.noMicrophoneAvailable
        }
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = micDeviceID

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
        // since narration is the only signal we care about. The mic's
        // native PCM (from the SCK `.microphone` output) is converted to
        // AAC by the writer's internal AudioConverter — no manual downmix
        // or resample needed.
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

        // One output object routes both stream types by `outputType`;
        // registered per-type with its own delivery queue so video lands
        // on videoQueue and mic on audioQueue (matching the threading
        // boundary in the file header). Both feed the same serial
        // writerQueue downstream, which keeps the writer single-threaded.
        let streamOutput = StreamSampleOutput { [weak self] sampleBuffer, outputType in
            switch outputType {
            case .screen:     self?.handleVideoSampleBuffer(sampleBuffer)
            case .microphone: self?.handleAudioSampleBuffer(sampleBuffer)
            default:          break
            }
        }
        self.streamOutput = streamOutput
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(streamOutput, type: .microphone, sampleHandlerQueue: audioQueue)

        try await stream.startCapture()

        self.stream = stream
        self.lifecycleState = .running

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
        // Error description marked .private — capture errors can embed
        // file paths (writer output URL), display device IDs, or AVFoundation
        // diagnostic strings that include user-derived metadata.
        Log.capture.error("failSession: \(error.localizedDescription, privacy: .private)")
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
        let outputURL = self.outputURL
        let writerQueue = self.writerQueue

        // Stop the UI ticker before the capture pipelines drain so
        // the pill freezes at its final elapsed value rather than
        // ticking through the (brief) finalize window.
        elapsedPublishTask?.cancel()
        elapsedPublishTask = nil
        sessionStartWallClock = nil

        Task { @MainActor in
            // Stop the stream first so no more sample buffers (video OR
            // mic — both now flow through SCK) arrive mid-teardown.
            // stopCapture() awaits SCK's drain.
            if let stream { try? await stream.stopCapture() }

            // Marshal writer teardown onto writerQueue so it sees any
            // in-flight appends complete first (serial queue ordering).
            writerQueue.async { [weak self] in
                guard let self else { return }
                guard let writer = self.writer, let videoInput = self.videoInput else {
                    Task { @MainActor in
                        // Tear down whatever WAS constructed (the stream
                        // may exist even though the writer path never
                        // completed) after onFinish — see
                        // teardownCaptureStack.
                        defer { self.teardownCaptureStack() }
                        self.lifecycleState = .finished
                        self.onFinish(deletingFile ? .cancelled : .failed(SessionError.writerFailedToStart(underlying: nil)))
                    }
                    return
                }
                // Mic-append health, counts only (.public). A healthy
                // recording reads e.g. "appended=N dropped=0"; a near-zero
                // append count points straight at the capture stack rather
                // than at Whisper.
                Log.capture.info(
                    "mic buffers appended=\(self.audioAppendCount, privacy: .public) dropped=\(self.audioDropCount, privacy: .public)"
                )
                videoInput.markAsFinished()
                self.audioInput?.markAsFinished()
                let writerShim = UncheckedSendable(writer)
                writer.finishWriting {
                    Task { @MainActor in
                        // finishWriting's completion has now fired, so the
                        // writer is done and nothing more will append —
                        // the genuine end of finalize. Release the capture
                        // stack after onFinish is delivered on every
                        // branch below (defer runs on each return). Only
                        // releases in-memory objects; the recorded .mov is
                        // never touched here. See teardownCaptureStack.
                        defer { self.teardownCaptureStack() }
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

    /// Releases the in-memory capture stack (SCStream + its registered
    /// output, AVAssetWriter + its two inputs) from the session's OWN
    /// code, so the stack is torn down on every exit path rather than
    /// surviving until AppState nils the session or relying on SCK's
    /// internal weak-delegate policy to break a potential session ⇄
    /// stream cycle. Defense-in-depth: if SCK ever retained its delegate
    /// strongly, the omission of this teardown would leak the full
    /// capture stack per recording.
    ///
    /// Ordering: only ever invoked at the genuine END of `finalize`,
    /// after `stopCapture()` has drained SCK and (on the writer path)
    /// `finishWriting`'s completion has fired — i.e. nothing more will
    /// append, so releasing the writer/inputs here cannot tear them down
    /// mid-finalize.
    ///
    /// Idempotent and safe on partially-constructed state: every
    /// reference is optional (a `start()` that threw before assigning
    /// `stream` leaves them nil), `removeStreamOutput` is tolerated via
    /// `try?` (already-removed or never-registered is fine), and niling
    /// an already-nil reference is a no-op — so a double-`finalize`
    /// cannot crash here.
    @MainActor
    private func teardownCaptureStack() {
        // ONE output object was registered for BOTH stream types in
        // start() (addStreamOutput type: .screen + type: .microphone),
        // so unregister it for both before releasing the stream.
        if let stream = self.stream, let streamOutput = self.streamOutput {
            try? stream.removeStreamOutput(streamOutput, type: .screen)
            try? stream.removeStreamOutput(streamOutput, type: .microphone)
        }
        self.stream = nil
        self.streamOutput = nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
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

    /// Runs on writerQueue (serial). Starts the writer's session on the
    /// FIRST sample of either track and appends video. `startSession`
    /// must run before any append; appends must have pts >= the anchor.
    nonisolated private func ensureSessionStarted(at pts: CMTime) {
        guard sessionStartPTS == nil, let writer = writer else { return }
        writer.startSession(atSourceTime: pts)
        sessionStartPTS = pts
    }

    /// Runs on writerQueue.
    nonisolated private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let videoInput = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        ensureSessionStarted(at: pts)
        // Drop the rare straggler whose pts predates the anchor (e.g. the
        // mic buffer won the race and started the session a hair later) —
        // AVAssetWriter rejects pts < session start by entering .failed.
        guard let start = sessionStartPTS, CMTimeCompare(pts, start) >= 0 else { return }
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

        // Sample the peak amplitude on every audio buffer (audioQueue is
        // serial, so the accumulator + emit-time fields are
        // single-writer-safe), then emit at most every
        // `audioLevelEmitInterval`. This gives the pill waveform a
        // smooth ~12.5Hz feed without hammering MainActor on every
        // ~23ms audio buffer.
        if onAudioLevel != nil {
            let peak = Self.audioPeakLevel(sampleBuffer)
            if peak > audioLevelPeakAccumulator { audioLevelPeakAccumulator = peak }
            let now = CFAbsoluteTimeGetCurrent()
            if now - audioLevelLastEmit >= Self.audioLevelEmitInterval {
                let levelToEmit = audioLevelPeakAccumulator
                audioLevelLastEmit = now
                audioLevelPeakAccumulator = 0
                Task { @MainActor [weak self] in
                    self?.onAudioLevel?(levelToEmit)
                }
            }
        }

        let buffer = UncheckedSendable(sampleBuffer)
        writerQueue.async { [weak self] in
            self?.appendAudio(buffer.value)
        }
    }

    /// Reads the loudest sample in `sampleBuffer` and returns its
    /// magnitude normalized to 0...1. Handles the two PCM formats the
    /// macOS mic pipeline produces in practice: signed 16-bit integer
    /// and 32-bit float. Anything exotic returns 0 so the waveform
    /// floors out instead of feeding garbage into the UI.
    nonisolated private static func audioPeakLevel(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 0
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else {
            return 0
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSigned = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        if isFloat && asbd.mBitsPerChannel == 32 {
            let count = totalLength / MemoryLayout<Float>.size
            return dataPointer.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                var maxAbs: Float = 0
                for i in 0..<count {
                    let v = ptr[i]
                    let a = v < 0 ? -v : v
                    if a > maxAbs { maxAbs = a }
                }
                return min(maxAbs, 1.0)
            }
        } else if isSigned && asbd.mBitsPerChannel == 16 {
            let count = totalLength / MemoryLayout<Int16>.size
            return dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                var maxAbs: Int32 = 0
                for i in 0..<count {
                    let v = Int32(ptr[i])
                    let a = v < 0 ? -v : v
                    if a > maxAbs { maxAbs = a }
                }
                return Float(maxAbs) / Float(Int16.max)
            }
        }
        return 0
    }

    /// Runs on writerQueue. Phase 18: the mic now shares SCK's clock with
    /// video, and the session is anchored on the first sample of EITHER
    /// track — so audio is no longer gated on a video frame arriving
    /// first (the bug that silently dropped narration on static-screen
    /// recordings). Buffers with pts before the anchor are still dropped
    /// (≤ one straggler), since AVAssetWriter rejects pts < session start.
    nonisolated private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput = audioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        ensureSessionStarted(at: pts)
        guard let start = sessionStartPTS, CMTimeCompare(pts, start) >= 0 else {
            audioDropCount += 1
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            audioDropCount += 1
            return
        }
        audioInput.append(sampleBuffer)
        audioAppendCount += 1
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
            // Display name is .private — it's the user's monitor name
            // (e.g. "Colin's MacBook Pro Display"), an identifier they
            // chose or that their hardware vendor set.
            Log.capture.notice(
                "selection screen '\(name, privacy: .private)' found in NSScreen but not in SCShareableContent — falling back to main"
            )
        } else if let name = selection?.screenLocalizedName {
            Log.capture.notice(
                "selection screen '\(name, privacy: .private)' no longer present — falling back to main"
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

    /// Resolves the user's stored mic preference to a concrete device
    /// uniqueID for `SCStreamConfiguration.microphoneCaptureDeviceID`.
    /// Empty `preferred` is the "system default" sentinel
    /// (PreferencesStore convention). If the persisted device has since
    /// been disconnected, falls back to the system default and logs —
    /// silently swapping the device is better than failing the recording,
    /// and the Settings UI reflects the real selection next time it's
    /// opened. Returns nil only when the machine has no audio input at
    /// all, which `start()` maps to `.noMicrophoneAvailable`.
    ///
    /// We still resolve through AVCaptureDevice (rather than handing the
    /// raw string to SCK) so a stale/unplugged preference degrades
    /// gracefully to the default instead of capturing silence.
    private static func resolveMicrophoneDeviceID(preferred: String) -> String? {
        if !preferred.isEmpty {
            if let device = AVCaptureDevice(uniqueID: preferred) {
                return device.uniqueID
            }
            // preferred is .private — AVCaptureDevice unique IDs can contain
            // serial numbers (especially for USB mics) that uniquely
            // identify the user's hardware.
            Log.capture.notice(
                "persisted mic uniqueID '\(preferred, privacy: .private)' not found — falling back to system default"
            )
        }
        return AVCaptureDevice.default(for: .audio)?.uniqueID
    }
}

// MARK: - SCStreamDelegate

extension RecordingSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // SCK invoked this because something stopped capture out from
        // under us (permission revoked mid-session, display
        // disconnected, system pressure). Hop to MainActor so the
        // failSession guard sees coherent lifecycleState.
        Log.capture.error("SCStream didStopWithError: \(error.localizedDescription, privacy: .private)")
        Task { @MainActor [weak self] in
            self?.failSession(with: error)
        }
    }
}

// MARK: - StreamSampleOutput
//
// Thin SCStreamOutput conformer so RecordingSession itself doesn't take
// on the conformance (keeps the session's surface focused on lifecycle;
// this owns per-buffer fanout). A single instance is registered for both
// the `.screen` and `.microphone` output types — it forwards the
// `outputType` so RecordingSession can route to the right handler. All
// callbacks fire on the queue passed to `addStreamOutput` for that type
// (videoQueue for screen, audioQueue for microphone).

private final class StreamSampleOutput: NSObject, SCStreamOutput {
    nonisolated let onSampleBuffer: @Sendable (CMSampleBuffer, SCStreamOutputType) -> Void

    nonisolated init(onSampleBuffer: @escaping @Sendable (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        onSampleBuffer(sampleBuffer, outputType)
    }
}

// MARK: - UncheckedSendable
//
// Generic shim for handing a non-Sendable reference (CMSampleBuffer,
// AVAssetWriter, AVAssetWriterInput) across an isolation boundary when
// we can argue safety by other means:
//   • CMSampleBuffer: owned by exactly one queue at a time, never
//     shared (SCK delivery queue → writerQueue hop).
//   • AVAssetWriter: documented as thread-safe by Apple even though the
//     Sendable conformance is absent. We hop onto known background
//     queues for start/stop/append calls.
// Documents the promise rather than silently disabling the warning
// at every call site with @preconcurrency import. nonisolated init
// so it can be constructed from background queue contexts (sample
// buffer handlers).

private struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
    nonisolated init(_ value: T) { self.value = value }
}
