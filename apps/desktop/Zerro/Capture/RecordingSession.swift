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
        /// `clicks` (Phase 4) are the left-clicks captured live during the
        /// recording, normalized into the captured region — handed to the
        /// pipeline, which resolves each to the on-screen label under the cursor.
        /// `cursor` (Phase 2) is the continuous ~30Hz cursor track, captured ONLY
        /// for a Dev Mode recording (empty otherwise) and fed to the deixis
        /// resolver. Only the success path carries either; `.interrupted`
        /// (recovered later, both lost on sleep) and the failure/cancel paths none.
        case finished(URL, clicks: [RecordedClick], cursor: [CursorSample])
        case cancelled
        /// M2 (rev 2): the recording was abandoned because the system was
        /// about to sleep — deliberately WITHOUT finalizing the writer (a
        /// `finishWriting` interrupted by the suspend corrupts the file;
        /// device-confirmed). The fragmented `.mov` is left intact on disk at
        /// `outputURL`, readable up to the last flushed fragment, and is
        /// recovered at next wake/launch (see `AppState.recoverOrphanedRecordingIfAny`).
        /// The session reaches a clean terminal state without depending on
        /// `finishWriting`; AppState resets the UI to idle and does NOT delete
        /// the file. Distinct from `.cancelled` (which deletes) precisely so
        /// the file survives for recovery.
        case interrupted(URL)
        case failed(Error)
    }

    enum SessionError: Error {
        case noDisplaysAvailable
        case noMicrophoneAvailable
        case writerFailedToStart(underlying: Error?)
        case audioInputSetupFailed(underlying: Error?)
        case alreadyStarted
        /// M4: the microphone pinned at start (microphoneCaptureDeviceID)
        /// disconnected mid-recording — AirPods removed, USB mic unplugged.
        /// SCK silently stops delivering buffers from a pinned device that
        /// vanishes (no auto-failover, not always an error), so without
        /// this the rest of the recording loses narration and the user
        /// gets a truncated transcript with no signal anything went wrong.
        /// Distinct from `.noMicrophoneAvailable` (no device at start) and
        /// from `.microphoneRevoked` (a permission, not connectivity).
        case microphoneDisconnected
        /// L1: the display the user selected (matched by its stable
        /// CGDirectDisplayID) is not present at start() — it was unplugged
        /// or otherwise disappeared in the window between selection-confirm
        /// and capture-start. We deliberately do NOT fall back to the main
        /// display with the original selection's geometry (which was
        /// computed for the now-absent display and would record the wrong
        /// region, possibly out of bounds → clamped/black). Distinct from
        /// `.noDisplaysAvailable` (no display at all) so the copy can tell
        /// the user the specific display they picked is gone and to
        /// re-select.
        case selectedDisplayUnavailable
        /// M3: the display being recorded changed mid-session — unplugged,
        /// or its resolution/size changed such that the sourceRect fixed at
        /// start() no longer maps to a valid region. Scoped to THE recorded
        /// display by CGDirectDisplayID, so an unrelated display being added,
        /// removed, or rearranged does not trip this.
        case recordedDisplayChanged
    }

    // MARK: - Init parameters

    private let selection: SelectionRect?
    /// `CGWindowID`s (as `Int`, matching `NSWindow.windowNumber`) of this app's
    /// own overlay windows to keep OUT of the recording via the capture content
    /// filter's `excludingWindows`. On macOS 15+ ScreenCaptureKit composites all
    /// windows into one framebuffer and ignores `NSWindow.sharingType` / window
    /// level, so filter exclusion is the only reliable mechanism. Empty in
    /// Production; the Staging recording-marker frame populates it (see
    /// `AppState.startRecording`). The windows must already be on screen when
    /// `start()` enumerates `SCShareableContent`, or they won't be found to
    /// exclude.
    private let excludedWindowNumbers: [Int]
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

    /// Phase 2 (Dev Mode deixis) — when true, capture the continuous ~30Hz cursor
    /// track (the hover signal §7 needs). Set ONLY for a Dev Mode recording; a
    /// normal recording leaves the tracker nil and is byte-identical to before.
    private let capturesCursorTrack: Bool

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

    /// The microphone AVCaptureDevice pinned at start (resolved from the
    /// stored preference into `microphoneCaptureDeviceID`). Held so the
    /// disconnect observer below can be scoped to THIS exact device — see
    /// `micDisconnectObserver`. Released in `teardownCaptureStack`.
    private var capturedMicDevice: AVCaptureDevice?

    /// M4 observer token for the pinned mic's `wasDisconnectedNotification`.
    /// Installed at the end of `start()` (capture is live) and removed at
    /// the top of `finalize()` on every exit path, so it matches the
    /// capture lifetime exactly and cannot outlive the session or leak one
    /// observer per recording. `nil` whenever no observer is registered
    /// (before start, after finalize).
    private var micDisconnectObserver: NSObjectProtocol?

    /// M2 observer token for `NSWorkspace.willSleepNotification`. Installed
    /// at the end of `start()` (capture is live) and removed at the top of
    /// `finalize()` on every exit path — same capture-scoped lifetime as
    /// `micDisconnectObserver`, so it can't outlive the session or leak one
    /// observer per recording. `nil` whenever no observer is registered.
    /// NOTE: registered on `NSWorkspace.shared.notificationCenter` (NOT
    /// `NotificationCenter.default`), so the matching `removeObserver` in
    /// finalize must use that same center.
    private var sleepObserver: NSObjectProtocol?

    /// M3 observer token for `NSApplication.didChangeScreenParametersNotification`.
    /// Installed at the end of `start()` (capture is live) and removed at the
    /// top of `finalize()` / `abandon()` on every exit path — same
    /// capture-scoped lifetime as `micDisconnectObserver` / `sleepObserver`,
    /// so it can't outlive the session or leak one observer per recording.
    /// `nil` whenever no observer is registered. Registered on
    /// `NotificationCenter.default` (mirroring the selection-phase observer in
    /// `AreaSelectorWindowController`), so the matching `removeObserver` uses
    /// that same center. Only installed when `recordedDisplayID` is known.
    private var displayChangeObserver: NSObjectProtocol?

    /// M3: the stable hardware identity (`CGDirectDisplayID`) and point-size
    /// of the display being recorded, captured at `start()`. The
    /// display-change observer compares the live display set against these to
    /// decide whether THE recorded display (not some unrelated one) has gone
    /// away or had its resolution/size changed in a way that invalidates the
    /// fixed `sourceRect`. `nil` before start / after finalize. We store the
    /// size in POINTS (NSScreen.frame.size) — the same space the selection
    /// geometry math uses — and deliberately do NOT track the frame ORIGIN:
    /// the capture's `sourceRect` is display-LOCAL, so the recorded region
    /// stays valid when the display's global origin shifts because the user
    /// rearranged an unrelated monitor. Only a size/resolution change (or the
    /// display vanishing) invalidates it.
    private var recordedDisplayID: CGDirectDisplayID?
    private var recordedDisplaySize: CGSize?

    /// Phase 4 — global monitor token for left-mouse-down events, and the clicks
    /// it has appended. A GLOBAL NSEvent monitor for MOUSE events needs NO
    /// Accessibility / Input-Monitoring permission (only KEY-event monitors do),
    /// so this adds no entitlement. Installed at the end of `start()` (capture is
    /// live) and removed in `removeCaptureMonitors()` on every exit path, exactly
    /// mirroring the mic/sleep/display observers' capture-scoped lifetime. The
    /// handler only APPENDS to `recordedClicks` on the main actor; the array is
    /// read once at finalize. NEITHER touches the capture queues.
    private var clickMonitor: Any?
    private var recordedClicks: [RecordedClick] = []

    /// Phase 2 (Dev Mode deixis) — the continuous cursor poller, created at the
    /// end of `start()` ONLY when `capturesCursorTrack`, on the same clock/region
    /// as the click monitor, and stopped in `removeCaptureMonitors()` (its samples
    /// collected for the success Outcome). nil for a normal recording.
    private var cursorTracker: CursorTracker?
    private var recordedCursorSamples: [CursorSample] = []

    /// Phase 4 — the captured region in GLOBAL AppKit coords (points, bottom-left
    /// origin) that a click is normalized against: the selection rect when one
    /// was made, else the recorded display's full frame. Captured at `start()`
    /// from the same geometry `displayLocalSourceRect(global:on:)` uses; `nil`
    /// before start / after finalize.
    private var captureRegionGlobalRect: CGRect?

    /// Monotonic anchor for the elapsed publish task. A `SuspendingClock`
    /// instant — NOT wall clock (CFAbsoluteTime) — set in start() once both
    /// capture pipelines are running and read by the publish loop.
    ///
    /// SuspendingClock freezes while the Mac is asleep (unlike
    /// ContinuousClock / wall clock, which keep advancing). That's the M2
    /// fix: the 150s/180s cap must measure CAPTURED (awake) time, not
    /// wall-clock time that includes a sleep the user spent with the lid
    /// shut. With wall clock, closing the lid for a few minutes inflated the
    /// next post-wake tick by the full sleep duration — jumping the timer
    /// and silently auto-stopping past 180s while the user was away. The
    /// file's actual duration still comes from video PTS via the writer;
    /// this anchor drives the UI ticker AND the cap thresholds, now from one
    /// sleep-excluding clock.
    private var sessionStartInstant: SuspendingClock.Instant?
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
        clockMultiplier: Double = 1.0,
        capturesCursorTrack: Bool = false,
        excludedWindowNumbers: [Int] = []
    ) {
        self.selection = selection
        self.excludedWindowNumbers = excludedWindowNumbers
        self.microphoneDeviceID = microphoneDeviceID
        self.onElapsed = onElapsed
        self.onFinish = onFinish
        self.onAudioLevel = onAudioLevel
        self.clockMultiplier = clockMultiplier
        self.capturesCursorTrack = capturesCursorTrack
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerro-\(UUID().uuidString).mov")
        super.init()
    }

    // MARK: - Public API

    func start() async throws {
        guard lifecycleState == .idle else { throw SessionError.alreadyStarted }

        // Resolve display. With a `selection`, capture the EXACT display it
        // was made on, matched by its stable CGDirectDisplayID (L1). If that
        // display is gone we fail cleanly with `.selectedDisplayUnavailable`
        // rather than silently capturing main with the original display's
        // (now-wrong) geometry. Without a selection, the primary display.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let display: SCDisplay
        let screen: NSScreen
        switch Self.resolveDisplay(for: selection, in: content) {
        case .resolved(let r):
            display = r.scDisplay
            screen = r.nsScreen
        case .selectedDisplayGone:
            throw SessionError.selectedDisplayUnavailable
        case .noDisplays:
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
        guard let micDevice = Self.resolveMicrophoneDevice(preferred: microphoneDeviceID) else {
            throw SessionError.noMicrophoneAvailable
        }
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = micDevice.uniqueID
        // Hold the resolved device so the M4 disconnect observer (installed
        // once capture is live, below) can be scoped to this exact device.
        self.capturedMicDevice = micDevice

        // App-owned overlay windows to keep out of the recording (e.g. the
        // Staging recording-marker frame). Mapped from the requested window
        // numbers to the `SCWindow`s enumerated above; only windows that are
        // actually on screen resolve, so a stale number is silently a no-op. On
        // macOS 15+ this content-filter exclusion is the ONLY mechanism that
        // works — `NSWindow.sharingType`/level are ignored by ScreenCaptureKit.
        // Empty (the common case) ⇒ `excludingWindows: []`, unchanged behavior.
        let excludedWindows = excludedWindowNumbers.isEmpty
            ? []
            : content.windows.filter { excludedWindowNumbers.contains(Int($0.windowID)) }

        // Three capture shapes, in priority order:
        //   1. Full-screen target — capture the whole display, no crop,
        //      at its full pixel dimensions (menu bar included).
        //   2. Area selection rect — crop the display to the rect.
        //   3. No selection — full display.
        let filter: SCContentFilter
        if case .fullScreen? = selection?.target {
            config.width = display.width
            config.height = display.height
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        } else if let selection {
            let source = Self.displayLocalSourceRect(global: selection.rect, on: screen)
            config.sourceRect = source
            config.destinationRect = CGRect(origin: .zero, size: source.size)
            config.width = Int(source.width.rounded())
            config.height = Int(source.height.rounded())
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        } else {
            config.width = display.width
            config.height = display.height
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // AVAssetWriter setup. Synchronous; failures here mean we never
        // entered .running, so callers can treat a throw as "no recording
        // happened" without cleanup.
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        // M2 (revised): write the .mov in self-contained movie fragments so
        // the file on disk stays playable/recoverable up to the last flushed
        // fragment even if finishWriting never runs cleanly. Without this, a
        // .mov is only valid after a clean finishWriting writes the trailing
        // moov atom — and on a lid-close, macOS suspends the process before
        // the async finishWriting can finalize, leaving a truncated file that
        // AVFoundation rejects with "Cannot Open / media may be damaged"
        // (-11829), surfacing as .processingFailed (device-confirmed). With a
        // fragment interval the moov (+ mvex) is written UP FRONT and media
        // lands in periodic moof/mdat pairs flushed to disk, so AVURLAsset
        // can walk the fragments present at interruption time — covering
        // sleep, quit, and crash, not just sleep. Verified empirically: an
        // unclean fragmented file reads cleanly through every pipeline path
        // (duration, video track + AVAssetImageGenerator, AVAssetExportSession
        // AppleM4A), while the same unclean NON-fragmented file is
        // unreadable. Must be set BEFORE startWriting().
        //
        // 1s granularity: on interruption we lose at most the final <1s of
        // not-yet-flushed tail; the cost is one small moof box per second
        // (≤180 over a full 3-min capture) — negligible file/I/O overhead.
        // Coexists with expectsMediaDataInRealTime + the SCK sample handlers
        // (confirmed: real-time appends and clean finalize both unaffected).
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

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

        // M4: watch the pinned mic for a mid-recording disconnect (AirPods
        // pulled, USB mic unplugged). Scoped to THIS device via the
        // notification `object:`, so it fires ONLY for the resolved
        // captured device disappearing — not for an unrelated device being
        // unplugged, not for the user adding a device or switching the
        // system default while our device stays connected. Installed only
        // now (capture is live) and removed at the top of finalize() on
        // every exit path, mirroring elapsedPublishTask's lifetime so it
        // can't outlive the session or leak.
        //
        // On fire we route through `failSession` — the SAME machinery
        // SCStream's didStopWithError uses (failSession → finalize(
        // deletingFile: true) → onFinish(.failed) → handleSessionFinish) —
        // so the partial .mov is discarded and the state machine reaches
        // .failed through the existing guarded transitions, not a parallel
        // teardown. A disconnect can also trip SCStream didStopWithError;
        // whichever lands first flips lifecycleState to .finishing and the
        // other is a guarded no-op (failSession's `== .running` guard, plus
        // the observer being removed at finalize's top). The MainActor hop
        // mirrors the didStopWithError delegate path so failSession's guard
        // sees coherent state.
        if let capturedMicDevice {
            micDisconnectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: capturedMicDevice,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.failSession(with: SessionError.microphoneDisconnected)
                }
            }
        }

        // M2 (rev 2): watch for the system going to sleep mid-recording (lid
        // closed, idle sleep, Apple-menu → Sleep). willSleepNotification is
        // posted BEFORE the machine actually sleeps, so the handler gets to
        // run while we're still awake. Scoped to the capture lifetime exactly
        // like micDisconnectObserver above — installed only now (capture is
        // live), removed at the top of finalize() / abandon() on every
        // exit path.
        //
        // On fire we route through `abandon()`, NOT stop()/finalize.
        // The prior revision called stop() → finishWriting, but on a real
        // suspend macOS freezes the process mid-rewrite and the interrupted
        // finishWriting corrupts the otherwise-recoverable fragmented file
        // (device-confirmed: the recording came back as .processingFailed).
        // abandon deliberately does NOT finalize: it leaves the
        // fragmented .mov intact on disk (readable up to the last flushed
        // fragment) and emits `.interrupted`, so the recording is recovered at
        // next launch instead. A sleep can also trip SCStream
        // didStopWithError; willSleep fires first (pre-sleep) in the normal
        // case, and either ordering is safe — whichever lands first flips
        // lifecycleState off .running and the other's `== .running` guard
        // (failSession's and abandon's), plus the observer being
        // removed at the teardown top, makes it a no-op. Registered on
        // NSWorkspace.shared.notificationCenter — teardown removes it there.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.abandon()
            }
        }

        // M3: watch for the recorded display being unplugged or reconfigured
        // mid-capture. The selection phase already guards itself this way
        // (AreaSelectorWindowController's didChangeScreenParameters observer);
        // the capture phase had no equivalent, so it relied entirely on
        // SCStream voluntarily firing didStopWithError. If SCK instead keeps
        // delivering black/frozen frames (display gone) or stale-geometry
        // frames (the sourceRect/width/height are fixed at start() and never
        // reconfigured), the recording silently produces garbage with no error.
        //
        // Captured ONCE here from the resolved display so the observer can
        // scope strictly to it via CGDirectDisplayID (the L1 identity) — see
        // `handleScreenParametersChanged`. We only install the observer when
        // the recorded display's ID is known; without it we couldn't scope the
        // check and would risk over-firing on unrelated display events.
        // Installed only now (capture is live) and removed at the top of
        // finalize() / abandon() on every exit path, mirroring the mic
        // + sleep observers' capture-scoped lifetime so it can't leak.
        //
        // On fire we route through `failSession` — the SAME machinery
        // didStopWithError / the mic-disconnect observer use (failSession →
        // finalize(deletingFile: true) → onFinish(.failed)) — so the partial
        // .mov is discarded (the latter portion is black/wrong-geometry, so
        // the file is corrupt rather than "complete up to the interruption")
        // and the state machine reaches .failed through the existing guarded
        // transitions. A display change can ALSO trip SCStream
        // didStopWithError; whichever lands first flips lifecycleState to
        // .finishing and the other is a guarded no-op (failSession's
        // `== .running` guard, plus the observer being removed at finalize's
        // top). Registered on NotificationCenter.default — teardown removes it
        // from that same center.
        if let displayID = screen.displayID {
            self.recordedDisplayID = displayID
            self.recordedDisplaySize = screen.frame.size
            displayChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreenParametersChanged()
                }
            }
        }

        // Anchor the UI-facing elapsed clock AND the 150s/180s cap on a
        // SuspendingClock instant (see `sessionStartInstant`). NOT video PTS:
        // SCStream's minimumFrameInterval is a CAP, not a floor — when the
        // screen is static, frames arrive sparsely (sometimes <1fps), which
        // would make a PTS-driven pill timer freeze and lurch, AND a
        // PTS-driven cap would never fire if SCK silently stopped delivering
        // frames (removing the anti-wedge backstop). This self-driven 0.1s
        // timer is independent of frame arrival, so the cap still fires
        // within 3 minutes of AWAKE time even if frames stop — while
        // SuspendingClock keeps sleep from inflating it. The file's actual
        // duration still comes from video PTS via the writer.
        sessionStartInstant = SuspendingClock().now

        // Phase 4: capture left-clicks LIVE (they're not in the .mov). The region
        // to normalize against is the SAME geometry the capture uses — the
        // selection rect when one was made, else the recorded display's full
        // frame (both global, points, bottom-left). A GLOBAL mouse-event monitor
        // needs no permission. The handler runs on the main actor and only
        // appends to `recordedClicks`; it never touches the capture queues. We
        // install it last (capture is live, sessionStartInstant is set) and tear
        // it down in removeCaptureMonitors() like the other capture observers.
        captureRegionGlobalRect = selection?.rect ?? screen.frame
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            // Read the cursor location on the main actor and convert it into the
            // normalized region coords frames use (top-left origin). Clicks
            // outside the captured region are dropped.
            Task { @MainActor [weak self] in
                guard let self,
                      let start = self.sessionStartInstant,
                      let region = self.captureRegionGlobalRect,
                      let normalized = Self.normalizedClick(global: NSEvent.mouseLocation, in: region)
                else { return }
                let t = Self.seconds(since: start) * self.clockMultiplier
                self.recordedClicks.append(
                    RecordedClick(seconds: t, x: normalized.x, y: normalized.y)
                )
            }
        }

        // Phase 2 (Dev Mode deixis): start the continuous cursor poller on the
        // SAME anchor + region the click monitor just used, so cursor samples,
        // clicks, and frames share one clock + coordinate space (§7). Only for a
        // Dev Mode recording — a normal recording installs nothing here.
        if capturesCursorTrack, let anchor = sessionStartInstant {
            let tracker = CursorTracker(
                region: captureRegionGlobalRect ?? screen.frame,
                anchor: anchor,
                clockMultiplier: clockMultiplier
            )
            cursorTracker = tracker
            tracker.start()
        }

        elapsedPublishTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                guard let self else { return }
                guard let start = self.sessionStartInstant else { continue }
                let elapsed = Self.seconds(since: start) * self.clockMultiplier
                self.onElapsed(elapsed)
            }
        }
    }

    /// True while capture is live — from `start()` flipping `.running` until a
    /// terminal path (stop / cancel / fail / sleep-abandon) begins finalize.
    /// False before start and for the entire finalize window, INCLUDING a
    /// manual stop's (where AppState's `state` still reads `.recording` /
    /// `.wrappingUp` while the writer finishes). AppState's mid-session
    /// revocation guard reads this to tell a live capture (destructive
    /// teardown valid) from a completed one that must be preserved (F-11).
    var isCapturing: Bool { lifecycleState == .running }

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

    /// M3: a display-parameters change fired while we were recording. Decide
    /// whether it affects the SPECIFIC display being recorded — and only that
    /// display — before tearing anything down. Over-firing here would kill a
    /// valid recording when the user merely plugs in or rearranges an
    /// unrelated monitor, so the scoping discipline matches M4's pinned-device
    /// observer: identity-checked, never "any event of this kind".
    ///
    /// Invalidating changes (→ fail cleanly):
    ///   • The recorded display is no longer in `NSScreen.screens` — unplugged.
    ///   • Its point-size changed — a resolution/mode change that makes the
    ///     `sourceRect`/width/height fixed at start() wrong (a region that was
    ///     in bounds can now be partly/fully outside the display).
    /// Non-invalidating (→ ignore): the recorded display's frame ORIGIN moved
    /// but its size is unchanged. The capture's `sourceRect` is display-LOCAL,
    /// so the recorded region is still valid; the origin only shifts because
    /// the user rearranged some OTHER monitor. Likewise any change confined to
    /// a different display.
    ///
    /// Guarded by `== .running` (via `failSession`) so a concurrent
    /// didStopWithError / sleep / mic-disconnect that already moved us off
    /// `.running` makes this a no-op — same double-fire convergence as the
    /// other terminal paths.
    private func handleScreenParametersChanged() {
        guard lifecycleState == .running,
              let recordedDisplayID,
              let recordedDisplaySize else { return }

        guard let screen = NSScreen.screens.first(where: { $0.displayID == recordedDisplayID }) else {
            // The recorded display is gone.
            Log.capture.notice(
                "recorded display \(recordedDisplayID, privacy: .public) disappeared mid-capture — failing cleanly"
            )
            failSession(with: SessionError.recordedDisplayChanged)
            return
        }
        // Present but resized/reconfigured — the fixed sourceRect no longer
        // maps to a valid region. Compare size only (not origin); see the doc
        // comment above for why an origin-only shift is benign.
        if screen.frame.size != recordedDisplaySize {
            Log.capture.notice(
                "recorded display \(recordedDisplayID, privacy: .public) size changed mid-capture — failing cleanly"
            )
            failSession(with: SessionError.recordedDisplayChanged)
        }
    }

    /// M2 (rev 2): sleep teardown that deliberately does NOT finalize the
    /// writer. On a real lid-close, macOS suspends the process before the
    /// async `finishWriting` can finalize, and an interrupted finishWriting
    /// corrupts the otherwise-recoverable fragmented `.mov` (device-confirmed
    /// → `.processingFailed`). So instead of `stop()`/`finalize`, we abandon:
    ///   • Freeze the ticker + remove observers (shared `removeCaptureMonitors`).
    ///   • Release the writer WITHOUT `finishWriting` (the interrupted-finalize
    ///     that corrupts) and WITHOUT `cancelWriting` (which DELETES the file).
    ///     A plain release leaves the fragmented `.mov` on disk, readable up to
    ///     the last flushed fragment (harness-verified) — an orphan recovered
    ///     at next launch.
    ///   • Tear down the in-memory stack and emit `.interrupted(outputURL)` so
    ///     AppState resets the UI to idle WITHOUT deleting the file.
    /// The release is marshalled onto `writerQueue` (serial) so any in-flight
    /// appends complete first; after the inputs are niled, later SCK buffers
    /// no-op in append*(). Guarded on `.running` so it converges with a
    /// concurrent didStopWithError exactly like finalize/failSession.
    ///
    /// M1: also invoked at app-quit (`AppState.prepareForTermination`) for a
    /// recording in flight. Quit deliberately reuses this exact no-finalize
    /// abandon rather than a parallel teardown — the synchronous part returns
    /// immediately (the writer release is dispatched async) and the fragment is
    /// already flushed to disk, so terminating before the async tail runs leaves
    /// the identical recoverable `.mov` a sleep abandon would, and the next
    /// launch's recovery offers it the same way. The plain name `abandon()`
    /// reflects that this is the shared sleep+quit path — both callers want the
    /// writer released without finalizing, leaving a recoverable fragmented
    /// `.mov` on disk.
    func abandon() {
        guard lifecycleState == .running else { return }
        lifecycleState = .finishing
        removeCaptureMonitors()

        let outputURL = self.outputURL
        // Mark THIS fragment as deliberately abandoned so launch/wake recovery
        // offers it — and nothing else. Written synchronously, before the async
        // writer release, so it survives even if the app exits right after (the
        // quit-while-recording path). Without it, recovery can't tell this
        // fragment from a SIGKILL/crash leftover or an eval-retained completed
        // recording, and falsely offers those as "stopped when your Mac slept".
        WorkingDirectory.markRecoverable(outputURL)
        writerQueue.async { [weak self] in
            guard let self else { return }
            // In-flight appends have drained (serial queue). Release the writer
            // WITHOUT finishWriting/cancelWriting. The fragmented file survives.
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lifecycleState = .finished
                // teardownCaptureStack removes the stream outputs + releases the
                // SCStream (stopping delivery); it never touches the .mov.
                self.teardownCaptureStack()
                Log.capture.notice("recording abandoned for sleep — left intact for launch recovery")
                self.onFinish(.interrupted(outputURL))
            }
        }
    }

    /// Stops the UI ticker and removes both capture-duration observers (mic
    /// disconnect + sleep), from the centers they were registered on. Called
    /// at the top of every teardown path (finalize, abandon) so they
    /// can't leak or re-enter. Synchronous + MainActor-isolated.
    private func removeCaptureMonitors() {
        elapsedPublishTask?.cancel()
        elapsedPublishTask = nil
        sessionStartInstant = nil
        if let micDisconnectObserver {
            NotificationCenter.default.removeObserver(micDisconnectObserver)
        }
        self.micDisconnectObserver = nil
        // The sleep observer lives on NSWorkspace's center (NOT
        // NotificationCenter.default) — remove it from the same one.
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        self.sleepObserver = nil
        // M3: the display-change observer lives on NotificationCenter.default
        // (mirroring the selection-phase observer) — remove it from there.
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
        }
        self.displayChangeObserver = nil
        self.recordedDisplayID = nil
        self.recordedDisplaySize = nil
        // Phase 4: the global click monitor is removed via NSEvent (NOT a
        // NotificationCenter). `recordedClicks` is deliberately NOT cleared — it
        // is read once at finalize, after this runs.
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        self.clickMonitor = nil
        self.captureRegionGlobalRect = nil
        // Phase 2 (Dev Mode deixis): stop the cursor poller and KEEP its samples
        // (like `recordedClicks`, read once at finalize, after this runs). nil for
        // a normal recording — a no-op.
        if let cursorTracker {
            recordedCursorSamples = cursorTracker.stop()
        }
        self.cursorTracker = nil
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

        // Stop the UI ticker + remove the capture-duration observers up front
        // so they're gone on every exit path with no per-session leak, and
        // nothing can re-enter the teardown. Shared with abandon().
        removeCaptureMonitors()

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
                            // Phase 4: persist the clicks sidecar beside the .mov
                            // (eval re-extraction replays it) and hand the live
                            // clicks to the pipeline via the Outcome.
                            let clicks = self.recordedClicks
                            Self.writeClicksSidecar(clicks, beside: outputURL)
                            // Phase 2 (Dev Mode deixis): same for the cursor track
                            // (empty + no sidecar for a normal recording).
                            let cursor = self.recordedCursorSamples
                            Self.writeCursorSidecar(cursor, beside: outputURL)
                            self.onFinish(.finished(outputURL, clicks: clicks, cursor: cursor))
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
        self.capturedMicDevice = nil
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

    // MARK: - Elapsed clock

    /// Seconds elapsed (as a Double) between a `SuspendingClock` anchor and
    /// now. SuspendingClock excludes time the Mac spent asleep, so this is
    /// the captured/awake duration that drives the pill timer and the
    /// 150s/180s cap (M2). `Duration` carries seconds + attoseconds; fold
    /// both into one Double.
    nonisolated private static func seconds(since start: SuspendingClock.Instant) -> Double {
        let d = start.duration(to: SuspendingClock().now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
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

    /// Outcome of resolving the display to capture. Split into three so
    /// `start()` can map "the display you picked is gone" to a distinct,
    /// actionable failure (L1) rather than collapsing it into
    /// "no displays at all" or — worse — silently capturing the wrong one.
    private enum DisplayResolution {
        case resolved(ResolvedDisplay)
        /// A selection was made on a specific display (by CGDirectDisplayID)
        /// that is no longer present at start().
        case selectedDisplayGone
        /// No display is available at all (the no-selection primary path
        /// found nothing).
        case noDisplays
    }

    /// L1: match the selected display by its stable, unique
    /// `CGDirectDisplayID` — never by `localizedName` (not unique across
    /// two identical external monitors) and never with a silent fall back
    /// to `NSScreen.main`. If the selection's display is gone, return
    /// `.selectedDisplayGone` so the caller fails cleanly instead of
    /// applying the original display's geometry to the wrong panel.
    private static func resolveDisplay(
        for selection: SelectionRect?,
        in content: SCShareableContent
    ) -> DisplayResolution {
        if let selection {
            // A selection without a display ID predates L1 (or had no
            // backing screen at confirm time). We refuse to guess a display
            // and apply this selection's geometry to it — that IS the
            // stale-geometry bug. Treat it as "selected display gone".
            guard let displayID = selection.screenDisplayID else {
                Log.capture.notice(
                    "selection carries no display ID — cannot match a display, failing cleanly"
                )
                return .selectedDisplayGone
            }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }),
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                // The selected display disappeared between selection-confirm
                // and now (unplugged, etc.). Do NOT fall back to main with
                // this selection's sourceRect — it was computed for the
                // original display's geometry and would record the wrong
                // region (possibly out of bounds → SCK clamps or blacks).
                Log.capture.notice(
                    "selected display \(displayID, privacy: .public) no longer present — failing cleanly"
                )
                return .selectedDisplayGone
            }
            return .resolved(ResolvedDisplay(scDisplay: scDisplay, nsScreen: screen))
        }
        // No selection: full primary display — NSScreen.main paired with the
        // first SCDisplay (the primary display per ScreenCaptureKit ordering).
        guard let mainScreen = NSScreen.main,
              let scDisplay = content.displays.first else {
            return .noDisplays
        }
        return .resolved(ResolvedDisplay(scDisplay: scDisplay, nsScreen: mainScreen))
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

    /// Phase 4 — normalizes a GLOBAL cursor point (points, AppKit bottom-left
    /// origin, as `NSEvent.mouseLocation` returns) into `[0,1]` within the
    /// captured `region` (also global/points/bottom-left), with a TOP-LEFT origin
    /// so the result matches the frame images. Returns `nil` for a click outside
    /// the region (dropped) or a degenerate region. Mirrors the bottom-left→
    /// top-left flip in `displayLocalSourceRect`. `nonisolated` + static so it's
    /// pure and unit-testable.
    nonisolated static func normalizedClick(global point: CGPoint, in region: CGRect) -> (x: Double, y: Double)? {
        guard region.width > 0, region.height > 0 else { return nil }
        let nx = (point.x - region.minX) / region.width
        let nyTop = (region.maxY - point.y) / region.height // flip y to top-left origin
        guard nx >= 0, nx <= 1, nyTop >= 0, nyTop <= 1 else { return nil }
        return (Double(nx), Double(nyTop))
    }

    /// Phase 4 — writes the `<stem>.clicks.json` sidecar (a `[RecordedClick]`
    /// array) beside the finished `.mov` so the eval loop (`zerro-extract`) can
    /// replay the exact clicks on re-extraction. Local-only + gitignored, like
    /// the `.mov`. Best-effort: a failure is logged, never thrown — a missing
    /// sidecar just means re-extraction yields zero click lines (graceful).
    /// `nonisolated` so it can be called off the success branch without isolation
    /// friction; it only touches its arguments.
    nonisolated static func writeClicksSidecar(_ clicks: [RecordedClick], beside movURL: URL) {
        guard !clicks.isEmpty else { return }
        let sidecarURL = movURL.deletingPathExtension().appendingPathExtension("clicks.json")
        do {
            let data = try JSONEncoder().encode(clicks)
            try data.write(to: sidecarURL, options: .atomic)
            Log.capture.info("wrote \(clicks.count, privacy: .public) click(s) sidecar")
        } catch {
            Log.capture.error("clicks sidecar write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Phase 2 (Dev Mode deixis) — writes the `<stem>.cursor.json` sidecar (a
    /// `[CursorSample]` array) beside the finished `.mov`, mirroring the clicks
    /// sidecar so the eval loop can replay the exact track. Empty track (a normal
    /// recording, or a Dev Mode one where the cursor never entered the region) →
    /// no file. Best-effort: a failure is logged, never thrown.
    nonisolated static func writeCursorSidecar(_ samples: [CursorSample], beside movURL: URL) {
        guard !samples.isEmpty else { return }
        let sidecarURL = movURL.deletingPathExtension().appendingPathExtension("cursor.json")
        do {
            let data = try JSONEncoder().encode(samples)
            try data.write(to: sidecarURL, options: .atomic)
            Log.capture.info("wrote \(samples.count, privacy: .public) cursor sample(s) sidecar")
        } catch {
            Log.capture.error("cursor sidecar write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Resolves the user's stored mic preference to a concrete
    /// AVCaptureDevice — its `uniqueID` feeds
    /// `SCStreamConfiguration.microphoneCaptureDeviceID`, and the device
    /// itself is held so the M4 disconnect observer can be scoped to it.
    /// Empty `preferred` is the "system default" sentinel
    /// (PreferencesStore convention). If the persisted device has since
    /// been disconnected, falls back to the system default and logs —
    /// silently swapping the device is better than failing the recording,
    /// and the Settings UI reflects the real selection next time it's
    /// opened. Returns nil only when the machine has no audio input at
    /// all, which `start()` maps to `.noMicrophoneAvailable`.
    ///
    /// We resolve through AVCaptureDevice (rather than handing the raw
    /// string to SCK) so a stale/unplugged preference degrades gracefully
    /// to the default instead of capturing silence.
    private static func resolveMicrophoneDevice(preferred: String) -> AVCaptureDevice? {
        if !preferred.isEmpty {
            if let device = AVCaptureDevice(uniqueID: preferred) {
                return device
            }
            // preferred is .private — AVCaptureDevice unique IDs can contain
            // serial numbers (especially for USB mics) that uniquely
            // identify the user's hardware.
            Log.capture.notice(
                "persisted mic uniqueID '\(preferred, privacy: .private)' not found — falling back to system default"
            )
        }
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
