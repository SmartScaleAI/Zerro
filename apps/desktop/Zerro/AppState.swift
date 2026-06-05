//
//  AppState.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Overview
//  --------
//  This file owns the global state for the menu-bar app and the state
//  machine that drives the UI between idle, recording, processing, and
//  done.
//
//  Sections:
//    1. RecordingState  — the discrete UI states the app can be in.
//    2. AppState        — @Observable @MainActor class that holds live
//                          state, owns the per-session RecordingSession,
//                          and exposes the transitions (start/stop/
//                          cancel/reset).
//
//  Phase 7 changed how elapsed time flows. Pre-Phase-7 a 0.1s Timer
//  fired tick() which incremented elapsedSeconds by 0.1 * DEMO_TIME_SCALE.
//  Now elapsedSeconds is driven by the real video PTS published from
//  RecordingSession.onElapsed (~5Hz). The 150s wrappingUp + 180s
//  autoStop thresholds moved out of tick() (deleted) and into
//  handleElapsedUpdate(_:). For dev-time threshold testing without a
//  real 3-minute recording, pass clockMultiplier to RecordingSession —
//  it scales the published elapsed without affecting the file duration.
//

import AVFoundation
import CoreMedia
import Foundation
import os
import SwiftUI

// MARK: - RecordingState

public enum RecordingState: Equatable {
    case idle
    case recording
    case wrappingUp
    case autoStopped
    case processing
    /// Phase 17 — paused between transcription and generation, awaiting the
    /// user's answer on the mode-switch confirmation pill. `suggested` is
    /// the opposite mode the (stubbed) detector flagged. Resolving via
    /// `resolveModeSwitch(switchTo:)` returns to `.processing` and runs the
    /// single generation with the effective mode. Lives between
    /// `.processing` and `.done` and only ever entered when a match fires.
    case confirmingMode(suggested: OutputMode)
    case done
    case failed(reason: RecordingFailureReason)
}

// MARK: - RecordingFailureReason

/// The shape of every way a recording can end badly. Each case carries
/// the underlying details if there are any (for logging) and ther
/// `userMessage` projection renders the single-line string the pill
/// shows. Kept narrow — Phase 7 surfaces these as a flat message; a
/// later phase can branch on the case for richer recovery affordances.
public enum RecordingFailureReason: Equatable {
    // Phase 7 — capture-side failures
    case screenRecordingRevoked
    case microphoneRevoked
    case microphoneUnavailable
    case streamStartFailed
    case writerStartFailed
    case captureInterrupted

    // Phase 8 — local processing failures
    /// The local processing pipeline (audio isolation / frame extraction /
    /// manifest) threw. Routed here so failures surface on the amber pill
    /// instead of being swallowed.
    case processingFailed
    /// The recording was empty or too short to analyze (zero/corrupt
    /// duration, or shorter than a single frame-sample interval). Split
    /// from `.processingFailed` because the cause is actionable by the
    /// user — record for a bit longer — rather than an opaque internal
    /// failure. Maps from `ProcessingError.emptyRecording`.
    case recordingTooShort
    /// A write failed because the disk is out of space — the capture
    /// `.mov`, the audio export, or the manifest. Split from
    /// `.processingFailed`/`.captureInterrupted` because the user can fix
    /// it directly (free up space) instead of being told something
    /// opaque went wrong. Detected via `isOutOfSpace(_:)` across both
    /// the capture and processing failure sites.
    case diskFull

    // Phase 9 — API failures
    /// User hasn't entered an OpenAI key in Settings, or the stored key
    /// is blank. Distinguished from `.apiAuth` so the message can guide
    /// them to the right Settings panel rather than "check your key".
    case apiKeyMissing
    /// The provider rejected our key (401). Different copy from
    /// `.apiKeyMissing` — points to the key itself, not its absence.
    case apiAuth
    /// Network couldn't reach OpenAI (offline, DNS failure, timeout).
    /// Distinct from `.providerError` so the user knows it's a local-
    /// connectivity issue rather than something OpenAI-side.
    case networkOffline
    /// Provider returned 429 even after our single in-flight retry.
    /// Suggests sustained rate-limiting, not a transient burst.
    case rateLimited
    /// Catch-all for provider-side failures (5xx, schema drift, empty
    /// content, decode errors). Single user-facing copy on purpose —
    /// the user can't act on the distinction between "5xx" and "the
    /// JSON shape changed"; what matters is "try again later".
    case providerError

    // Phase E — Managed proxy failures
    /// Managed: the month's credits are spent (`generate` returned 402).
    /// Non-punitive — the user keeps library access and the menu-bar / Billing
    /// surfaces show "resets {date}" + an upgrade CTA. NOT retryable (another
    /// attempt fails identically until credits reset or the plan upgrades).
    case outOfCredits
    /// Managed: the subscription is no longer active (cancelled/expired, or the
    /// session resolved to nothing — `generate` returned 403/404). Routes the
    /// user back toward the paywall on their next record attempt; the
    /// entitlement layer drops them out of `.managed` on the next refresh.
    case subscriptionInactive

    // Phase F — trial server-funded credits
    /// Trial: the user (mid-trial, no own OpenAI key) tried to generate but
    /// hasn't verified an email yet, OR the trial token was rejected/expired and
    /// needs re-verifying. Non-punitive — the recording is discarded and the
    /// capture sheet is the way forward; the next record attempt re-offers it.
    case trialVerificationRequired
    /// Trial: the server-funded trial credits are spent (`generate` returned
    /// 402). The trial is over (one of the two expiry conditions) — the next
    /// record attempt routes to the paywall. Non-punitive, non-retryable.
    case trialCreditsExhausted

    /// Whether the failure is worth re-running the API stage against the
    /// already-processed artifacts. True only for transient API-side
    /// failures — the local audio/frames/manifest on disk are still good,
    /// the request just needs another shot. Everything else (auth needs
    /// Settings, permissions need System Settings, disk needs cleanup,
    /// capture failures need a fresh recording) routes the user out to
    /// the cause; a Retry button there would be a trap that always fails
    /// the same way. The Retry button only appears on the pill when this
    /// is true AND the per-failure-chain retry count is under
    /// `AppState.maxFailureRetries`.
    var isRetryable: Bool {
        switch self {
        case .networkOffline, .rateLimited, .providerError:
            return true
        case .screenRecordingRevoked, .microphoneRevoked, .microphoneUnavailable,
             .streamStartFailed, .writerStartFailed, .captureInterrupted,
             .processingFailed, .recordingTooShort, .diskFull,
             .apiKeyMissing, .apiAuth,
             .outOfCredits, .subscriptionInactive,
             .trialVerificationRequired, .trialCreditsExhausted:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .screenRecordingRevoked:
            return "Screen Recording permission was revoked."
        case .microphoneRevoked:
            return "Microphone permission was revoked."
        case .microphoneUnavailable:
            return "Selected microphone isn\u{2019}t available."
        case .streamStartFailed:
            return "Couldn\u{2019}t start screen capture."
        case .writerStartFailed:
            return "Couldn\u{2019}t open the recording file."
        case .captureInterrupted:
            return "Recording was interrupted."
        case .processingFailed:
            return "Couldn\u{2019}t process the recording."
        case .recordingTooShort:
            return "Recording was too short \u{2014} try again."
        case .diskFull:
            return "Your Mac is out of storage \u{2014} free up space and try again."
        case .apiKeyMissing:
            return "Add your OpenAI API key in Settings to generate prompts."
        case .apiAuth:
            return "OpenAI rejected your API key \u{2014} check it in Settings."
        case .networkOffline:
            return "Couldn\u{2019}t connect \u{2014} check your connection."
        case .rateLimited:
            return "Hit a rate limit \u{2014} try again in a minute."
        case .providerError:
            return "Generation failed \u{2014} try again."
        case .outOfCredits:
            return "You\u{2019}re out of credits this month. Your library stays open \u{2014} credits reset on your renewal date."
        case .subscriptionInactive:
            return "Your subscription isn\u{2019}t active right now \u{2014} check Billing in Settings."
        case .trialVerificationRequired:
            return "Verify your email to use your free trial generations."
        case .trialCreditsExhausted:
            return "You\u{2019}ve used all your free trial credits \u{2014} subscribe or add your own OpenAI key to keep going."
        }
    }
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {

    // MARK: Live State

    var state: RecordingState = .idle
    var elapsedSeconds: Double = 0
    var frameCount: Int = 0

    /// Rolling buffer of live mic-input peak levels (0...1, after a
    /// display-side gain). Fed at ~12.5Hz by RecordingSession's
    /// `onAudioLevel` callback during an active capture; each emit
    /// shifts the array left and appends the latest sample. Sized to
    /// match the pill waveform's 22 bars so the view can render
    /// directly against this without resampling.
    var audioLevels: [CGFloat] = Array(repeating: 0, count: AppState.waveformBarCount)

    /// Bar count for the recording-pill waveform. Kept here so the
    /// rolling buffer above and the WaveformView call site agree on
    /// length without crossing module boundaries.
    static let waveformBarCount = 22

    /// The region selected by the user via the area-selector overlay,
    /// stored at startRecording time and held for the duration of the
    /// session. Consumed by Phase 7's RecordingSession to scope the
    /// capture; `nil` started without a selection (e.g. tests).
    var activeSelection: SelectionRect?

    /// Phase 17: the output mode selected for THIS recording — captured at
    /// `startRecording` time from the overlay toggle (which also writes it
    /// back to `PreferencesStore.defaultOutputMode` as the last-used
    /// default). This is the source of truth for prompt composition; the
    /// generation path reads it (or a per-recording pill override) and
    /// never re-reads the persisted default, so an override can't be
    /// silently undone. Defaults to `.instruct` so test/menu-bar call
    /// sites that don't pass a mode still compose a valid prompt.
    var recordingOutputMode: OutputMode = .instruct

    /// Phase 17: the mode a pill override actually ran with, when the user
    /// tapped "Switch" on the confirmation pill. Transient and per-recording
    /// — it drives the menu-bar "ran as X" indicator and is cleared on every
    /// return to idle, so it can never imply the persisted default changed.
    /// `nil` whenever no override fired (the common case), which the
    /// indicator reads as "ran with the selected mode."
    var effectiveOutputMode: OutputMode?

    /// Path to the most recently finalized recording on disk. Set by
    /// `handleSessionFinish` when the writer completes successfully;
    /// cleared on cancel and on every new startRecording.
    var lastRecordingURL: URL?

    /// The Phase 8 processed output (isolated audio + downsampled
    /// frames + manifest, all colocated in a working directory). Set
    /// when `runProcessing` completes successfully; cleared on cancel,
    /// reset, and at the start of every new recording. Phase 9 reads
    /// this for STT + multimodal prompt generation. The working
    /// directory IS the unit of cleanup — Phase 8 Step 5 will own the
    /// delete policy on cancel + the launch-sweep for orphans.
    var processedRecording: ProcessedRecording?

    /// The label shown on the .processing pill. Driven by real stage
    /// transitions from the Phase 8 ProcessingPipeline (via its
    /// `onStage` callback), not a canned rotation. Default placeholder
    /// matches the first pipeline stage so the brief gap (~ms) before
    /// `onStage` fires doesn't show a generic "Processing…" flash.
    var processingStageLabel: String = "Saving your narration\u{2026}"

    /// User-driven toggle for the result pill's expanded variant.
    /// Reset on every new recording.
    var isResultExpanded: Bool = false

    // MARK: Result

    /// The structured prompt produced by Phase 9's two-step API flow
    /// (Whisper transcribe → GPT-4o generate). Set when the .processing
    /// → .done transition fires; nil at all other times. The pill's
    /// expanded result body reads this; Phase 9 Step 6 copies it to
    /// the clipboard on the Copy button click.
    var generatedPrompt: String?

    /// True when the result was generated from the screen alone because
    /// Whisper returned no usable narration (silent recording / muted
    /// mic). We still produce a prompt (the system prompt has a
    /// frames-only fallback), but the result pill surfaces a note so the
    /// user understands why it reads generically rather than silently
    /// shipping a guessed prompt. Set alongside `generatedPrompt` when
    /// entering .done; reset wherever `generatedPrompt` is.
    var resultHadNoNarration: Bool = false

    // MARK: Recents
    //
    // Phase 11: history moved off AppState onto a dedicated
    // RecentPromptStore. AppState reaches into it via `recentPromptStore`
    // (wired by ZerroApp.init) on a successful prompt-generation run; the
    // menu-bar surfaces + Settings History tab read the store directly
    // from the SwiftUI environment.

    @ObservationIgnored weak var recentPromptStore: RecentPromptStore?

    // Phase E (billing): the entitlement source of truth and the Managed proxy
    // client, wired by `ZerroApp.init` (same lifetime + weak-ref contract as
    // `permissions` / `recentPromptStore`). The generation pipeline reads
    // `entitlements.routesThroughManagedProxy` to pick its single branch point:
    // `.managed` → upload audio+frames to the proxy (no local transcription);
    // everything else → the direct BYOK OpenAI path. A `nil` entitlements (not
    // yet wired, or in a unit test) keeps the existing local path — fail-safe.
    @ObservationIgnored weak var entitlements: EntitlementStore?
    @ObservationIgnored var managedProxyClient: ManagedProxyClient?

    // Phase F (billing): the server-funded trial-credits layer, wired by
    // `ZerroApp.init`. Used as the proxy's token provider for a trial generation
    // and read for trial-credit display. Weak — owned by ZerroApp @State for the
    // app's lifetime (same contract as `entitlements`). A `nil` trialCredits
    // means the trial proxy path is unavailable and generation falls back to
    // local (fail-safe), exactly like a `nil` entitlements.
    @ObservationIgnored weak var trialCredits: TrialCreditsManager?

    /// Whether the user has their own OpenAI key on file — decides whether a
    /// trial user funds generation locally (their key) or via server credits.
    /// A closure so tests can drive the routing without touching the Keychain;
    /// production reads the real `KeychainStore.openAIAPIKey` slot.
    @ObservationIgnored var hasOwnAPIKeyProvider: () -> Bool = {
        if case .found(let key) = KeychainStore.openAIAPIKey.readResult() {
            return !key.isEmpty
        }
        return false
    }

    // MARK: Internal

    /// The live capture session. Held strongly while recording so its
    /// callbacks (onElapsed, onFinish) stay valid; cleared on session
    /// completion / cancel so memory is reclaimed.
    private var recordingSession: RecordingSession?

    /// The in-flight processing/prompt-generation work, held so a cancel
    /// during the .processing phase can actually abort it. runProcessing
    /// and runPromptGeneration run sequentially (the latter is called
    /// from inside the former's Task on success), so a single handle —
    /// reassigned when the second stage starts — covers both. Cancelling
    /// it tears down the OpenAI request (URLSession's async API is
    /// cancellation-aware) so we stop billing for a result the user
    /// already walked away from. Nil whenever no pipeline is running.
    private var processingTask: Task<Void, Never>?

    /// Phase 17: everything needed to resume prompt generation after the
    /// confirmation pill pauses the pipeline. Stashed when we enter
    /// `.confirmingMode` so `resolveModeSwitch(switchTo:)` can run the
    /// single generation with the effective mode — without re-transcribing
    /// (no double API spend). Cleared on resolution and on every reset path.
    private struct PendingGeneration {
        let timeline: InterleavedTimeline
        let transcript: Transcript
        let processed: ProcessedRecording
    }
    @ObservationIgnored private var pendingGeneration: PendingGeneration?

    #if DEBUG
    /// Debug-only arming flag for the mode-switch confirmation pill. Set by
    /// the menu-bar dropdown's debug row; consumed (one-shot) by the next
    /// recording's generation pass to force the stub detector to "match" so
    /// the pill flow can be exercised end to end without real detection.
    /// DEFERRED Phase 18: real string-match detection replaces the need for
    /// this manual trigger.
    var debugForceModeSwitchPill: Bool = false
    #endif

    /// Consecutive Retry presses against the current failure chain. Cap
    /// keeps a "Retry → fail → Retry" loop from running forever on a
    /// sustained outage — after the cap the Retry button hides and the
    /// only affordance left is Dismiss (which throws the artifacts away
    /// and returns to idle). Reset on every transition out of .failed via
    /// a non-retry path (resetToIdle, cancelRecording, startRecording).
    private var failureRetryAttempts: Int = 0

    /// How many times in a row the user can press Retry on the same
    /// processed-recording chain before the affordance hides. 2 was
    /// chosen as the smallest cap that still tolerates a single
    /// genuinely-transient blip plus a "give it one more shot" without
    /// trapping the user on a sustained outage.
    static let maxFailureRetries = 2

    /// Minimum free bytes on the temp-directory volume required before
    /// `startRecording` will proceed. Below this we refuse upfront with
    /// `.diskFull` so the user isn't asked to narrate for 3 minutes only
    /// to lose the recording at finalize.
    ///
    /// Sizing rationale: a 3-min ScreenCaptureKit capture at typical
    /// region bitrates lands around 600 MB; the working dir adds the
    /// extracted audio.m4a (a few MB), the JPEG frames (~150 frames at
    /// ~150 KB each ≈ 25 MB), and the manifest. 1.5 GB gives roughly
    /// 2× headroom over the worst real recording we've measured —
    /// enough to absorb a high-bitrate full-screen 3-min capture without
    /// being so conservative we'd block users on tight disks who could
    /// have safely recorded a shorter session. The reactive disk-full
    /// chain walk in `isOutOfSpace` still backstops cases where another
    /// process eats the disk between this check and finalize.
    static let minimumFreeBytesToRecord: Int64 = 1_500_000_000

    /// Wired by ZerroApp.init to the shared `PermissionsManager`. AppState
    /// uses it to start/stop the mid-session TCC monitor around an active
    /// recording so a revocation in System Settings turns into a clean
    /// `.failed(.screenRecordingRevoked)` / `.microphoneRevoked` pill
    /// within ~1s instead of waiting for the writer to fail. Weak so the
    /// AppState ↔ PermissionsManager pair doesn't form a retain cycle
    /// (both are held by ZerroApp's @State for the app's lifetime, so the
    /// weak ref stays valid).
    @ObservationIgnored weak var permissions: PermissionsManager?

    // MARK: - Derived

    /// True while the menu-bar icon and pill should both reflect the
    /// "active recording" identity. Defined in one place so the
    /// MenuBarExtra label and the pill bridge agree.
    var isRecordingActive: Bool {
        state == .recording || state == .wrappingUp || state == .autoStopped
    }

    /// Total recording budget, pre-formatted for the pill timer chip.
    /// Matches the 180s threshold handleElapsedUpdate enforces.
    var totalDisplay: String { "3:00" }

    // MARK: - Transitions

    /// Kicks off a real capture session via RecordingSession.
    /// `selection` scopes the capture to that screen rectangle;
    /// `microphoneDeviceID` is the uniqueID from PreferencesStore
    /// (empty string = system default per PreferencesStore convention).
    /// Both are read at session-start time, not at app-launch time, so
    /// the user can change either between recordings.
    ///
    /// Behavior on async failure (SCStream.start() / writer fails to
    /// open / mic unavailable): logs and resets to .idle. C5 will route
    /// these into a dedicated .failed state with user-visible feedback.
    func startRecording(
        selection: SelectionRect? = nil,
        microphoneDeviceID: String = "",
        outputMode: OutputMode = .instruct
    ) {
        guard state == .idle else {
            // State name is .public — RecordingState case names contain
            // no user content.
            Log.state.notice("startRecording ignored — state is \(String(describing: self.state), privacy: .public)")
            return
        }
        // Phase 10: pre-flight free-space check. Refuse upfront with the
        // existing .diskFull copy ("Your Mac is out of storage — free up
        // space and try again.") so the user isn't asked to narrate for
        // 3 minutes only to lose the recording at finalize. A nil
        // capacity read is treated as "assume OK" — the reactive
        // chain-walk in isOutOfSpace still catches a genuine ENOSPC at
        // write time, so a false-positive refuse here is worse than a
        // false-positive proceed.
        if let free = WorkingDirectory.freeBytes(), free < Self.minimumFreeBytesToRecord {
            // Byte counts are .public — capacity metrics, not user content.
            Log.state.notice(
                "startRecording refused — only \(free, privacy: .public) bytes free (need \(Self.minimumFreeBytesToRecord, privacy: .public))"
            )
            state = .failed(reason: .diskFull)
            return
        }
        // Clean prior session artifacts before clearing the references.
        // Anything still on disk from the previous session (last source
        // .mov, last processed working dir) is dead now — Phase 9 has
        // already had its window to consume the prior result, and
        // keeping them would just leak disk between recordings.
        if let priorRecording = lastRecordingURL {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorRecording) }
        }
        if let priorWorkingDir = processedRecording?.workingDirectory {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorWorkingDir) }
        }
        isResultExpanded = false
        activeSelection = selection
        recordingOutputMode = outputMode
        effectiveOutputMode = nil
        pendingGeneration = nil
        lastRecordingURL = nil
        processedRecording = nil
        generatedPrompt = nil
        resultHadNoNarration = false
        failureRetryAttempts = 0
        elapsedSeconds = 0
        frameCount = 0
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)

        let session = RecordingSession(
            selection: selection,
            microphoneDeviceID: microphoneDeviceID,
            onElapsed: { [weak self] seconds in
                // Already on MainActor — RecordingSession.onElapsed
                // is invoked from inside a `Task { @MainActor in ... }`.
                self?.handleElapsedUpdate(seconds)
            },
            onFinish: { [weak self] outcome in
                self?.handleSessionFinish(outcome)
            },
            onAudioLevel: { [weak self] level in
                // Throttled to ~12.5Hz inside RecordingSession; safe to
                // mutate @Observable state on every emit. MainActor-
                // hopped on the session side.
                self?.handleAudioLevel(level)
            }
        )
        recordingSession = session

        // Transition to .recording AFTER session.start() succeeds, not
        // before — otherwise a start failure leaves the pill stuck in
        // recording until the user manually cancels. start() is async
        // but reads at most ~100ms (writer + SCStream + audio session
        // warm-up); during that window the pill stays at .idle.
        Task { @MainActor [weak self] in
            do {
                try await session.start()
                guard let self, self.recordingSession === session else { return }
                self.state = .recording
                // Phase 13A: breadcrumb the .idle → .recording transition
                // so it appears in the trail attached to any subsequent
                // crash or non-fatal capture. StaticString literal —
                // never interpolated runtime content.
                Log.breadcrumb(category: .stateMachine, message: "recording started")
                // Phase 10: watch for TCC revocation during the live
                // session so we surface .screenRecordingRevoked /
                // .microphoneRevoked the moment the user toggles the
                // permission off, rather than waiting for the writer to
                // fail on its next sample append. Stopped on every
                // recording-exit path (handleSessionFinish, the inline
                // cancel paths) so the timer can't outlive the session.
                self.permissions?.startMonitoring { [weak self] reason in
                    self?.handleMidSessionRevocation(reason)
                }
            } catch {
                // Error description is .private — capture errors carry
                // file paths and device-identifying strings.
                Log.state.error("session.start() failed: \(error.localizedDescription, privacy: .private)")
                // Delete the orphaned output .mov. startWriting() created the
                // file at outputURL before startCapture() threw, so a failed
                // start leaves an empty/header-only zerro-*.mov on disk. It's
                // the same orphan class the launch sweep() reclaims, but
                // there's no reason to let it outlive a known-failed session.
                // Off the main actor via the M1-era nonisolated remove path,
                // capturing the URL first for Sendable cleanliness.
                let orphanedURL = session.outputURL
                Task.detached(priority: .utility) { WorkingDirectory.remove(at: orphanedURL) }
                guard let self, self.recordingSession === session else { return }
                self.recordingSession = nil
                self.activeSelection = nil
                let reason = Self.failureReason(from: error)
                // Phase 13B: report engineering-signal failures to
                // Sentry. shouldCapture(_:) filters out user /
                // environment failures so we don't ship noise.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Recording start failed",
                        stage: "recording",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                self.state = .failed(reason: reason)
            }
        }
    }

    /// Fired by PermissionsManager.startMonitoring when Screen Recording
    /// or Microphone TCC flips away from .granted during an active
    /// recording. Tears down the writer (which writes whatever it can
    /// finalize, then no-ops the partial file) and sets the dedicated
    /// failure state directly so the user sees the right copy
    /// immediately. We don't wait for handleSessionFinish(.cancelled) to
    /// drive the state — that branch is guarded so it won't overwrite
    /// the failure we set here.
    private func handleMidSessionRevocation(_ kind: RecordingFailureReason) {
        guard isRecordingActive, let session = recordingSession else { return }
        // Failure-reason case name is .public — no user content.
        Log.state.notice("permission revoked mid-session: \(String(describing: kind), privacy: .public)")
        // Phase 13A: breadcrumb at .warning level. The trail will read
        // "...recording started → permission revoked mid-session → ..."
        // which is exactly the lead-up signal you'd want before a
        // related crash or capture lands.
        Log.breadcrumb(category: .permissionChange, level: .warning, message: "permission revoked mid-session")
        permissions?.stopMonitoring()
        session.cancel()
        recordingSession = nil
        elapsedSeconds = 0
        frameCount = 0
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
        isResultExpanded = false
        effectiveOutputMode = nil
        pendingGeneration = nil
        activeSelection = nil
        lastRecordingURL = nil
        state = .failed(reason: kind)
    }

    /// Surfaces a record-start PRE-FLIGHT block: a failure that is knowable
    /// before the user records (out of credits, inactive subscription, missing
    /// BYOK key) is shown NOW with the same copy the post-recording path uses,
    /// instead of after a wasted capture. Called by the gate (`handleHotkey`)
    /// only when no recording is in flight (it has already returned for
    /// recording/processing/confirming states), so this just sets the failure
    /// state directly — the same mechanism as `handleMidSessionRevocation`.
    ///
    /// Returns the surfaced reason (for the gate's log line). For an inactive
    /// subscription it also kicks the async, non-blocking entitlement refresh so
    /// a confirmed-lapsed subscription drops out of `.managed` for the next
    /// attempt — exactly as the post-recording `.subscriptionInactive` path does.
    @discardableResult
    func presentPreflightBlock(_ block: EntitlementStore.PreflightBlock) -> RecordingFailureReason {
        let reason: RecordingFailureReason
        switch block {
        case .outOfCredits: reason = .outOfCredits
        case .subscriptionInactive: reason = .subscriptionInactive
        case .apiKeyMissing: reason = .apiKeyMissing
        }
        state = .failed(reason: reason)
        if block == .subscriptionInactive, let entitlements {
            Task { await entitlements.refreshManagedEntitlement() }
        }
        return reason
    }

    /// Manual stop. State stays at .recording (or .wrappingUp) during
    /// finalize — the pill keeps showing the recording chrome for the
    /// few hundred ms it takes finishWriting to complete; on
    /// completion `handleSessionFinish(.finished)` transitions to
    /// .processing. No-op outside a recording state.
    func stopRecording() {
        guard let session = recordingSession,
              state == .recording || state == .wrappingUp || state == .autoStopped else {
            return
        }
        session.stop()
    }

    /// Tears down the live session and discards the partial file.
    /// Transition to .idle happens in handleSessionFinish(.cancelled)
    /// after the writer has actually closed — keeps file cleanup
    /// ordered before UI reset. If there's no live session (e.g.
    /// cancel-during-processing), reset immediately.
    func cancelRecording() {
        if let session = recordingSession,
           state == .recording || state == .wrappingUp || state == .autoStopped {
            session.cancel()
            return
        }
        // No live session — cancelling from .processing/.done just
        // resets the UI. Abort any in-flight pipeline / OpenAI work so
        // a cancel during .processing stops billing for a result the
        // user is discarding (the Task's awaits are cancellation-aware).
        processingTask?.cancel()
        processingTask = nil
        // Delete the on-disk artifacts before clearing the refs: a
        // cancel-during-.done means the user is throwing away the result
        // they were looking at, so the working dir is garbage now
        // (Phase 9 won't run on a discarded result).
        if let priorRecording = lastRecordingURL {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorRecording) }
        }
        if let priorWorkingDir = processedRecording?.workingDirectory {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorWorkingDir) }
        }
        recordingSession = nil
        elapsedSeconds = 0
        frameCount = 0
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
        isResultExpanded = false
        effectiveOutputMode = nil
        pendingGeneration = nil
        activeSelection = nil
        lastRecordingURL = nil
        processedRecording = nil
        generatedPrompt = nil
        resultHadNoNarration = false
        failureRetryAttempts = 0
        state = .idle
    }

    func resetToIdle() {
        recordingSession?.cancel()
        processingTask?.cancel()
        processingTask = nil
        if let priorRecording = lastRecordingURL {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorRecording) }
        }
        if let priorWorkingDir = processedRecording?.workingDirectory {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: priorWorkingDir) }
        }
        recordingSession = nil
        elapsedSeconds = 0
        frameCount = 0
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
        isResultExpanded = false
        effectiveOutputMode = nil
        pendingGeneration = nil
        activeSelection = nil
        lastRecordingURL = nil
        processedRecording = nil
        generatedPrompt = nil
        resultHadNoNarration = false
        failureRetryAttempts = 0
        state = .idle
    }

    // MARK: - Session callbacks

    /// Fired ~12.5Hz from `RecordingSession.onAudioLevel`. Each call
    /// shifts the rolling buffer left and appends the latest mic peak
    /// (after a display-side gain so conversational speech reads as
    /// active rather than near-zero) so the pill's WaveformView can
    /// render directly against `audioLevels`.
    private func handleAudioLevel(_ rawPeak: Float) {
        // Speech peaks usually sit in the 0.05–0.3 range; multiply so
        // normal speaking volume drives bars to ~60–80% height, and
        // clamp at 1.0. A small floor keeps every bar slightly tall so
        // a silent moment doesn't look like a dead waveform.
        let gained = min(1.0, rawPeak * 4.0)
        let floor: CGFloat = 0.08
        let level = max(floor, CGFloat(gained))

        var next = audioLevels
        if next.count != AppState.waveformBarCount {
            next = Array(repeating: 0, count: AppState.waveformBarCount)
        }
        next.removeFirst()
        next.append(level)
        audioLevels = next
    }

    /// Fired ~5Hz from RecordingSession.onElapsed (every 6th video
    /// sample at 30fps). Drives the pill timer and the 150s/180s
    /// auto-transitions. Replaces what the deleted `tick()` did.
    private func handleElapsedUpdate(_ seconds: TimeInterval) {
        elapsedSeconds = seconds
        frameCount = Int(seconds / 3.0)

        if state == .recording && seconds >= 150 {
            state = .wrappingUp
        }
        if state == .wrappingUp && seconds >= 180 {
            state = .autoStopped
            // Initiate finalize. The transition to .processing
            // happens when the writer reports .finished — see the
            // architecture brief's "auto-stop edge" section for why
            // the 1s cosmetic delay (mock pre-Phase-7) is gone.
            recordingSession?.stop()
        }
    }

    /// Fired on MainActor from RecordingSession when the writer has
    /// fully closed (success, cancel, or failure). Owns the cleanup
    /// of recordingSession and the transition into the next state.
    private func handleSessionFinish(_ outcome: RecordingSession.Outcome) {
        recordingSession = nil
        // Mid-session revocation already set state = .failed and tore
        // down everything we'd reset here. The writer's tail callback
        // (.cancelled because we called session.cancel(); or .failed
        // because the writer noticed the revocation first) would
        // otherwise stomp our specific .screenRecordingRevoked /
        // .microphoneRevoked copy with .idle or a generic capture
        // failure. Short-circuit to preserve the proactive classification.
        if case .failed = state {
            permissions?.stopMonitoring()
            return
        }
        permissions?.stopMonitoring()
        switch outcome {
        case .finished(let url):
            lastRecordingURL = url
            // Phase 8 Step 1: run real audio isolation in place of the
            // old mock 4s sleep. Frame extraction (Step 2), manifest
            // (Step 3), and the proper per-stage pill mapping (Step 4)
            // slot into runProcessing as they land; for now the pill
            // keeps its timer-based step rotation and we end on the
            // existing placeholder result. The working-dir path is
            // logged so the isolated audio can be played + verified.
            state = .processing
            runProcessing(sourceURL: url)
        case .cancelled:
            elapsedSeconds = 0
            frameCount = 0
            audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
            isResultExpanded = false
            effectiveOutputMode = nil
            pendingGeneration = nil
            activeSelection = nil
            lastRecordingURL = nil
            processedRecording = nil
            generatedPrompt = nil
            resultHadNoNarration = false
            failureRetryAttempts = 0
            state = .idle
        case .failed(let error):
            Log.state.error("session failed: \(error.localizedDescription, privacy: .private)")
            elapsedSeconds = 0
            frameCount = 0
            audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
            isResultExpanded = false
            effectiveOutputMode = nil
            pendingGeneration = nil
            activeSelection = nil
            lastRecordingURL = nil
            processedRecording = nil
            generatedPrompt = nil
        resultHadNoNarration = false
            state = .failed(reason: Self.failureReason(from: error))
        }
    }

    // MARK: - Processing pipeline (Phase 8 → Phase 9)

    /// Runs the local processing pipeline against the finished
    /// recording (isolate audio → extract frames → write manifest),
    /// then hands off to `runPromptGeneration` which calls Whisper +
    /// GPT-4o. The .processing → .done transition fires from inside
    /// runPromptGeneration after the model returns; we never stop at
    /// the pipeline result. Failures at either step route to the
    /// amber pill via `.processingFailed` (Phase 9 Step 5 will split
    /// this into per-failure-mode cases).
    ///
    /// The work runs in `processingTask` so a cancel during processing
    /// can abort it (OpenAI request included). As a second line of
    /// defense, the `state == .processing` guards after each await mean
    /// a cancel that resets to .idle wins — we never stomp a newer state
    /// with a late-arriving pipeline result, even if the abort raced.
    private func runProcessing(sourceURL: URL) {
        // Reset the placeholder explicitly — handleSessionFinish set
        // state = .processing before this Task starts running, so for
        // ~ms before the pipeline fires its first onStage the pill
        // would otherwise show whatever label survived the prior run.
        processingStageLabel = "Saving your narration\u{2026}"
        // Phase 13A: marks the .recording → .processing handoff in the
        // Sentry breadcrumb trail.
        Log.breadcrumb(category: .pipelineStage, message: "processing started")
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ProcessingPipeline().process(
                    sourceURL: sourceURL,
                    onStage: { [weak self] stage in
                        self?.processingStageLabel = stage.userMessage
                    }
                )
                // A cancel that lands after the pipeline finished but
                // before this guard means the working dir the pipeline
                // just wrote is now orphaned — cancelRecording/resetToIdle
                // already cleared their refs, so clean it here rather than
                // leaking it until the next launch-sweep.
                guard self.state == .processing else {
                    let orphanedDir = result.workingDirectory
                    Task.detached(priority: .utility) { WorkingDirectory.remove(at: orphanedDir) }
                    return
                }
                self.processedRecording = result
                // Source .mov is no longer needed — the audio + frames
                // + manifest in the working dir are everything Phase 9
                // will consume. Drop the .mov so a 3-min recording
                // doesn't double-occupy tmp until the next sweep.
                Task.detached(priority: .utility) { WorkingDirectory.remove(at: sourceURL) }
                self.lastRecordingURL = nil
                // Phase 8 done → kick off Phase 9 API work. The
                // .processing → .done transition fires from inside
                // runPromptGeneration after the model returns. Stage
                // labels for the two API stages continue updating the
                // pill in place.
                self.runPromptGeneration(processed: result)
            } catch {
                Log.processing.error("failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .processing else { return }
                // Disk-full and too-short/empty recordings get actionable
                // copy; every other pipeline failure stays on the generic
                // processing message.
                let reason: RecordingFailureReason
                if Self.isOutOfSpace(error) {
                    reason = .diskFull
                } else if case ProcessingError.emptyRecording = error {
                    reason = .recordingTooShort
                } else {
                    reason = .processingFailed
                }
                // Phase 13B: report engineering-signal failures to
                // Sentry. .diskFull and .recordingTooShort are gated
                // out by shouldCapture; .processingFailed (a real
                // pipeline bug) is the one we want to triage.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Processing pipeline failed",
                        stage: "processing",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                self.state = .failed(reason: reason)
            }
        }
    }

    /// Phase 9 + 17: Whisper transcribe → Interleaver → mode-switch check →
    /// GPT-4o generate. The pill shows `.transcribing` while Whisper runs.
    /// After transcription the (Phase 17-stubbed) detector decides whether
    /// the user verbally asked for the opposite output mode; on a match we
    /// pause at `.confirmingMode` for the confirmation pill and resume from
    /// `resolveModeSwitch(switchTo:)`. Otherwise generation runs straight
    /// through with the recording's selected mode. The `.processing → .done`
    /// transition fires from `runGeneration`.
    /// Phase E — the SINGLE routing branch point between the two generation
    /// architectures. A `.managed` user uploads the recording's audio + frames
    /// to the proxy, which transcribes + composes server-side; everyone else
    /// (BYOK / trial-on-own-key) runs the existing fully-local path (Whisper +
    /// interleaving + direct OpenAI). Reading the decision off
    /// `EntitlementStore.routesThroughManagedProxy` here — rather than inline in
    /// the pipeline — keeps the two paths from entangling, and crucially keeps
    /// the Managed path from DOUBLE-TRANSCRIBING (the server does Whisper).
    ///
    /// Fail-safe: if entitlements/proxy aren't wired (unit tests, or a managed
    /// state without a proxy), fall back to the local path rather than failing.
    private func runPromptGeneration(processed: ProcessedRecording) {
        // Phase F made this a four-way decision (was Managed-vs-local in Phase E).
        // The policy lives in `EntitlementStore.generationRoute`; this is just the
        // mechanism. A nil entitlements falls back to local (fail-safe).
        let route = entitlements?.generationRoute(hasOwnAPIKey: hasOwnAPIKeyProvider()) ?? .local
        switch route {
        case .managedProxy:
            if let proxy = managedProxyClient {
                // Managed subscription → proxy with the subscription session token
                // (the proxy's default provider).
                runProxyGeneration(processed: processed, proxy: proxy, tokenProvider: nil, isTrial: false)
            } else {
                runLocalPromptGeneration(processed: processed)
            }
        case .trialProxy:
            if let proxy = managedProxyClient, let trial = trialCredits {
                // Trial with a live token → SAME proxy, trial token.
                runProxyGeneration(processed: processed, proxy: proxy, tokenProvider: trial, isTrial: true)
            } else {
                runLocalPromptGeneration(processed: processed)
            }
        case .trialNeedsEmail:
            // Trial, no own key, not verified yet. Email verification is now a
            // REQUIRED onboarding step (Phase F revised), so for a normally
            // onboarded user this never happens. It's reachable only by an
            // existing user (onboarded before the email step) or one who took the
            // infra-failure fallback — surface a gentle, non-abrupt failure that
            // points them to the Settings/Billing "verify email" affordance. NO
            // mid-task popup.
            state = .failed(reason: .trialVerificationRequired)
        case .local:
            runLocalPromptGeneration(processed: processed)
        }
    }

    /// Phase E/F — the proxy generation path (Managed subscription OR trial).
    /// Uploads audio + frames + the effective mode (NEVER a transcript or system
    /// prompt — the server owns those, §6.1) to the proxy and lands the returned
    /// prompt on the same `.done` tail the local path uses (pill + clipboard +
    /// history unchanged). Does NOT run local Whisper or mode-switch detection —
    /// both need a transcript the client never has on this path.
    ///
    /// `tokenProvider` nil = the Managed subscription token (proxy default);
    /// non-nil = the trial token (`isTrial == true`). The two differ only in how
    /// the post-success credit balance is applied and how failures are mapped;
    /// the upload + result tail are identical.
    private func runProxyGeneration(
        processed: ProcessedRecording,
        proxy: ManagedProxyClient,
        tokenProvider: ProxyTokenProviding?,
        isTrial: Bool
    ) {
        let mode = recordingOutputMode
        let audioURL = processed.workingDirectory.appendingPathComponent("audio.m4a")
        let durationSeconds = CMTimeGetSeconds(processed.duration)
        let label = isTrial ? "trial" : "managed"
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // One server round-trip covers upload → STT → generation; the
                // "Writing your prompt…" label is the honest single stage.
                self.processingStageLabel = ProcessingPipeline.Stage.writingPrompt.userMessage
                Log.breadcrumb(category: .pipelineStage, message: "proxy generation started")
                let managed = try await proxy.generate(
                    audioURL: audioURL,
                    frames: processed.frames,
                    mode: mode,
                    durationSeconds: durationSeconds.isFinite ? durationSeconds : nil,
                    tokenProvider: tokenProvider
                )
                let result = managed.result
                Log.promptGen.info(
                    "\(label, privacy: .public) OK — model=\(result.usage.model, privacy: .public) in=\(result.usage.inputTokens, privacy: .public) out=\(result.usage.outputTokens, privacy: .public) prompt.count=\(result.prompt.count, privacy: .public) creditsRemaining=\(managed.creditsRemaining ?? -1, privacy: .public)"
                )

                guard self.state == .processing else { return }
                self.generatedPrompt = result.prompt
                // The proxy path has no client transcript, so the no-narration
                // note (a BYOK affordance) doesn't apply — never flag it here.
                self.resultHadNoNarration = false
                self.recentPromptStore?.add(prompt: result.prompt)
                self.state = .done
                Log.breadcrumb(category: .pipelineStage, message: "proxy generation completed")

                // Reflect the spent credit immediately. For a subscription, also
                // refresh the authoritative /entitlement snapshot in the
                // background; for a trial, applying the balance recomputes the
                // entitlement (and flips it to `.expired` once credits hit zero,
                // for the NEXT record attempt — the current result is unaffected).
                if let remaining = managed.creditsRemaining {
                    if isTrial {
                        self.entitlements?.applyTrialCreditsRemaining(remaining)
                    } else {
                        self.entitlements?.applyCreditsRemaining(remaining)
                    }
                }
                if !isTrial, let entitlements = self.entitlements {
                    Task { await entitlements.refreshManagedEntitlement() }
                }
            } catch {
                guard self.state == .processing else { return }
                let reason = isTrial
                    ? self.trialFailureReason(from: error)
                    : Self.managedFailureReason(from: error)
                Log.promptGen.error("\(label, privacy: .public) generation failed: \(String(describing: reason), privacy: .public)")
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Proxy generation failed",
                        stage: "proxyGeneration",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                self.state = .failed(reason: reason)
                // A definitive Managed not-entitled means the subscription lapsed
                // mid-use — recompute so the app drops out of `.managed`.
                if !isTrial, reason == .subscriptionInactive, let entitlements = self.entitlements {
                    Task { await entitlements.refreshManagedEntitlement() }
                }
            }
        }
    }

    /// Maps a trial `/generate` failure to the user-facing taxonomy and performs
    /// the trial-side state side effects (credit-exhaustion → `.expired` next
    /// attempt; a rejected token → re-verify). Non-trial errors fall back to the
    /// shared `failureReason(from:)`.
    private func trialFailureReason(from error: Error) -> RecordingFailureReason {
        guard let managed = error as? ManagedGenerationError else {
            return Self.failureReason(from: error)
        }
        switch managed {
        case .outOfCredits:
            // Trial credits spent → the trial is over. Zero the balance so the
            // entitlement recomputes to `.expired` (→ paywall on the next record).
            entitlements?.applyTrialCreditsRemaining(0)
            return .trialCreditsExhausted
        case .notEntitled, .authFailed:
            // Grant gone / token rejected → drop the trial token so the next
            // attempt re-triggers the email capture.
            entitlements?.resetTrialToken()
            return .trialVerificationRequired
        case .rateLimited:
            return .rateLimited
        case .providerUnavailable, .malformedResponse, .inputRejected:
            return .providerError
        case .network(let desc):
            return desc.isEmpty ? .providerError : .networkOffline
        case .artifactUnreadable:
            return .processingFailed
        }
    }

    // MARK: - Trial email verification (Phase F)

    /// Called after a successful email verification (the required onboarding step,
    /// or the Settings/Billing "verify email" affordance for existing /
    /// infra-fallback users). The trial token + email + credits are already
    /// stored by `TrialCreditsManager`; this just recomputes the entitlement so
    /// the new trial credits are reflected in the menu-bar line / Billing readout
    /// and the gate. There is no longer any mid-recording capture to resume —
    /// verification happens up front in onboarding, not after a recording.
    func handleTrialVerified() {
        entitlements?.refresh()
    }

    /// Maps a `ManagedGenerationError` to the user-facing failure taxonomy.
    /// Anything that isn't a managed error falls back to the shared
    /// `failureReason(from:)` (covers offline/disk/etc. raised before the
    /// request).
    private static func managedFailureReason(from error: Error) -> RecordingFailureReason {
        guard let managed = error as? ManagedGenerationError else {
            return failureReason(from: error)
        }
        switch managed {
        case .outOfCredits:
            return .outOfCredits
        case .notEntitled:
            return .subscriptionInactive
        case .rateLimited:
            return .rateLimited
        case .providerUnavailable, .malformedResponse, .inputRejected, .authFailed:
            // Server-side / transient-ish — the retryable provider path. (A real
            // recording can't trip the input fuse; treat a stray one as provider.)
            return .providerError
        case .network(let desc):
            // Reuse the offline-class heuristic so a true offline shows the
            // connectivity copy, everything else the generic provider copy.
            return desc.isEmpty ? .providerError : .networkOffline
        case .artifactUnreadable:
            return .processingFailed
        }
    }

    /// The BYOK/local generation path (Phase 9 + 17): Whisper transcribe →
    /// Interleaver → mode-switch check → GPT-4o generate. (Renamed from
    /// `runPromptGeneration` in Phase E, which is now the routing branch above.)
    private func runLocalPromptGeneration(processed: ProcessedRecording) {
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.processingStageLabel = ProcessingPipeline.Stage.transcribing.userMessage
                // Phase 13A: breadcrumb each API stage so a Whisper-vs-GPT
                // failure can be triaged by the breadcrumb sequence
                // alone, without having to look at the failure event.
                Log.breadcrumb(category: .pipelineStage, message: "transcription started")
                let audioURL = processed.workingDirectory.appendingPathComponent("audio.m4a")
                let transcript = try await OpenAITranscriptionService().transcribe(
                    audioFileURL: audioURL
                )
                // Counts are .public — segment count and char count
                // are metrics, not content. The transcript TEXT itself
                // never enters a log call anywhere.
                Log.transcription.info(
                    "segments=\(transcript.segments.count, privacy: .public) fullText.count=\(transcript.fullText.count, privacy: .public)"
                )
                guard self.state == .processing else { return }

                let timeline = Interleaver.merge(
                    frames: processed.frames,
                    transcript: transcript
                )

                // Phase 17: decide the effective mode BEFORE composing the
                // prompt, so the single generation runs with it. Phase 18
                // replaced the stub with local opposite-mode string
                // matching; the debug trigger still forces a (high) match
                // so the pill is testable without saying the magic words.
                var detection = ModeSwitchDetector.detect(
                    transcript: transcript,
                    selectedMode: self.recordingOutputMode
                )
                #if DEBUG
                if self.debugForceModeSwitchPill {
                    self.debugForceModeSwitchPill = false
                    detection = ModeSwitchDetection(
                        didMatch: true,
                        suggestedMode: self.recordingOutputMode.opposite,
                        matchedCue: nil,
                        matchedTarget: nil,
                        region: nil,
                        confidence: .high
                    )
                }
                #endif

                // Phase 18 telemetry: record EVERY match (high or low) as a
                // local breadcrumb — cue/target/region/confidence, never
                // any transcript text. Low-confidence (mid-recording)
                // matches are logged here but deliberately fall through the
                // gate below without interrupting. The Sentry crash-trail
                // marker ("mode-switch confirm shown") and the user's
                // confirm/cancel choice (resolveModeSwitch) cover the
                // surfaced case; cancel-rate is read from those.
                if detection.didMatch {
                    Log.modeSwitch.info(
                        "match cue=\(detection.matchedCue ?? "-", privacy: .public) target=\(detection.matchedTarget ?? "-", privacy: .public) region=\(detection.region?.rawValue ?? "-", privacy: .public) confidence=\(detection.confidence.rawValue, privacy: .public)"
                    )
                }

                // Only HIGH-confidence matches surface the pill (Phase 18).
                if detection.didMatch,
                   detection.confidence == .high,
                   let suggested = detection.suggestedMode,
                   suggested != self.recordingOutputMode {
                    // Pause for the confirmation pill. Stash everything the
                    // resume needs so we don't re-transcribe (no double API
                    // spend). Keep / Switch both route through
                    // resolveModeSwitch(switchTo:).
                    self.pendingGeneration = PendingGeneration(
                        timeline: timeline,
                        transcript: transcript,
                        processed: processed
                    )
                    Log.breadcrumb(category: .stateMachine, message: "mode-switch confirm shown")
                    self.state = .confirmingMode(suggested: suggested)
                    return
                }

                // No switch suggested — generate with the selected mode.
                self.runGeneration(
                    timeline: timeline,
                    transcript: transcript,
                    processed: processed,
                    mode: self.recordingOutputMode
                )
            } catch {
                Log.transcription.error("failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .processing else { return }
                let reason = Self.failureReason(from: error)
                // Phase 13B: transcription-stage failures worth triaging
                // (provider decode / 5xx) reach Sentry; user/environment
                // failures are gated out by shouldCapture.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Transcription failed",
                        stage: "transcription",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                self.state = .failed(reason: reason)
            }
        }
    }

    /// Phase 17: the generation half of the API flow, split out so it runs
    /// either straight after transcription (no switch) or on resume from the
    /// confirmation pill. Takes the EFFECTIVE output mode as a parameter —
    /// the recording's selected mode, or the suggested opposite when the
    /// user tapped "Switch" — and composes the prompt for exactly that mode.
    /// Never re-reads the persisted default. The `.processing → .done`
    /// transition fires here on success.
    private func runGeneration(
        timeline: InterleavedTimeline,
        transcript: Transcript,
        processed: ProcessedRecording,
        mode: OutputMode
    ) {
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.processingStageLabel = ProcessingPipeline.Stage.writingPrompt.userMessage
                Log.breadcrumb(category: .pipelineStage, message: "prompt generation started")
                let result = try await OpenAIPromptGenerationService().generatePrompt(
                    timeline: timeline,
                    systemPrompt: PromptGenerationSystemPrompt.composed(for: mode)
                )
                // Model name (.public — "gpt-4o", a constant we control)
                // and token counts (.public — metrics, not content).
                // result.prompt.count is the LENGTH of the generated
                // prompt, not the text itself.
                Log.promptGen.info(
                    "OK — model=\(result.usage.model, privacy: .public) in=\(result.usage.inputTokens, privacy: .public) out=\(result.usage.outputTokens, privacy: .public) prompt.count=\(result.prompt.count, privacy: .public)"
                )
                Self.logCost(
                    audioDuration: processed.duration,
                    usage: result.usage
                )

                guard self.state == .processing else { return }
                self.generatedPrompt = result.prompt
                self.resultHadNoNarration = Self.isNarrationEmpty(transcript)
                // Phase 11: persist successful prompts to the history
                // store so the menu-bar Recent Prompts submenu, Paste-
                // last row, and Settings History tab can surface them.
                // Wired via a weak ref on AppState set by ZerroApp.init.
                self.recentPromptStore?.add(prompt: result.prompt)
                self.state = .done
                // Phase 13A: terminal-success breadcrumb. If a crash
                // lands during result presentation (UI bug, copy
                // affordance), the trail makes it obvious the pipeline
                // itself completed first.
                Log.breadcrumb(category: .pipelineStage, message: "prompt generation completed")
            } catch {
                Log.promptGen.error("failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .processing else { return }
                let reason = Self.failureReason(from: error)
                // Phase 13B: report engineering-signal failures to Sentry.
                // The remaining .providerError (decode failures, 5xx floods,
                // empty content) is the bucket we want to triage.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Prompt generation failed",
                        stage: "promptGeneration",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                self.state = .failed(reason: reason)
            }
        }
    }

    /// Phase 17: resolves the mode-switch confirmation pill. `switchTo ==
    /// true` applies the suggested opposite mode to THIS recording only — a
    /// per-recording override that does NOT touch the persisted default;
    /// `false` (and, equivalently, dismissing or ignoring the pill) keeps
    /// the recording's selected mode. Either way generation resumes from the
    /// stashed timeline with the effective mode; the persisted default is
    /// never re-read. A no-op outside `.confirmingMode`, so a stray or
    /// double call can't double-run generation.
    func resolveModeSwitch(switchTo: Bool) {
        guard case .confirmingMode(let suggested) = state,
              let pending = pendingGeneration else { return }
        pendingGeneration = nil

        let effectiveMode: OutputMode = switchTo ? suggested : recordingOutputMode
        if switchTo {
            // Transient — drives the menu-bar "ran as X" indicator, cleared
            // on the next return to idle. Never persisted: an override is
            // per-recording, it does not become the new default.
            effectiveOutputMode = suggested
            Log.breadcrumb(category: .stateMachine, message: "mode-switch accepted")
        } else {
            Log.breadcrumb(category: .stateMachine, message: "mode-switch kept")
        }

        // Set the stage label before flipping to .processing so the morph
        // out of the confirm pill lands directly on "Writing your prompt…"
        // rather than briefly showing the stale transcription label.
        processingStageLabel = ProcessingPipeline.Stage.writingPrompt.userMessage
        state = .processing
        runGeneration(
            timeline: pending.timeline,
            transcript: pending.transcript,
            processed: pending.processed,
            mode: effectiveMode
        )
    }

    /// User-driven dismissal of the failure pill. Same as cancel —
    /// returns to .idle so the next hotkey press starts cleanly.
    func dismissFailure() {
        guard case .failed = state else { return }
        resetToIdle()
    }

    /// True when the current failure is transient AND we have a processed
    /// recording on disk to re-run AND we haven't already exhausted
    /// `maxFailureRetries`. The pill reads this via the bridge to decide
    /// whether the error pill renders a Retry button alongside Dismiss.
    var canRetryFailure: Bool {
        guard case .failed(let reason) = state else { return false }
        return reason.isRetryable
            && processedRecording != nil
            && failureRetryAttempts < Self.maxFailureRetries
    }

    /// User-driven Retry from the error pill. Re-runs the API stage
    /// (Whisper → Interleaver → GPT-4o) against the already-processed
    /// audio + frames + manifest still on disk in `processedRecording`'s
    /// working directory. Bumps the per-chain attempt counter so the
    /// affordance hides after `maxFailureRetries` consecutive failures —
    /// prevents a loop on sustained outages.
    func retryFailedPrompt() {
        guard canRetryFailure, let processed = processedRecording else { return }
        failureRetryAttempts += 1
        state = .processing
        // runPromptGeneration starts at the `.transcribing` stage and
        // walks through `.writingPrompt` — exactly the work that needs to
        // re-run. The working dir's artifacts are untouched by the prior
        // failure (both runProcessing's and runPromptGeneration's catch
        // blocks leave them in place), so the second attempt reads the
        // same audio.m4a + frames + manifest the first one did.
        runPromptGeneration(processed: processed)
    }

    /// Below this many non-whitespace characters, the transcript is
    /// treated as "no usable narration" — almost certainly a silent
    /// recording (muted mic, user never spoke) where Whisper either
    /// returned empty text or hallucinated a short fragment ("you",
    /// "Thank you.") on the silence. Set deliberately low so a genuinely
    /// terse-but-real command ("delete this", "make it bigger") stays
    /// above it: the cost of a false positive here is only a soft note
    /// on the result, never a blocked prompt, so we bias toward NOT
    /// crying wolf on real narration.
    private static let minNarrationCharacters = 10

    /// Whether `transcript` carries no usable narration. Trims to the
    /// non-whitespace content (Whisper pads silence-hallucinations with
    /// spaces/newlines) and compares against `minNarrationCharacters`.
    private static func isNarrationEmpty(_ transcript: Transcript) -> Bool {
        let trimmed = transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < minNarrationCharacters
    }

    // MARK: - Sentry capture gating (Phase 13B)

    /// Whether a given mapped failure is worth reporting to Sentry as a
    /// non-fatal event. Split from `failureReason` so the policy of
    /// "what counts as an engineering signal" lives in one place.
    ///
    /// Captured: reasons that indicate Zerro misbehaved (capture stack
    /// failed to start / interrupted mid-stream, local processing
    /// pipeline blew up, provider returned malformed/decode-failing
    /// content). These are the ones we'd want to triage.
    ///
    /// NOT captured: reasons that are user- or environment-driven and
    /// already surfaced to the user with actionable copy (permission
    /// revoked, disk full, recording too short, missing/invalid API
    /// key, network offline, provider rate-limit). Reporting those
    /// would be noise — they're not bugs in Zerro.
    private static func shouldCapture(_ reason: RecordingFailureReason) -> Bool {
        switch reason {
        case .streamStartFailed, .writerStartFailed, .captureInterrupted,
             .microphoneUnavailable,
             .processingFailed,
             .providerError:
            return true
        case .screenRecordingRevoked, .microphoneRevoked,
             .recordingTooShort, .diskFull,
             .apiKeyMissing, .apiAuth, .networkOffline, .rateLimited,
             .outOfCredits, .subscriptionInactive,
             .trialVerificationRequired, .trialCreditsExhausted:
            return false
        }
    }

    /// Safe stringification of `reason` for the Sentry `errorCode` tag.
    /// Every `RecordingFailureReason` case is value-less, so
    /// `String(describing:)` yields just the case name
    /// ("processingFailed", "providerError", etc.) — a compile-time-
    /// bounded value with zero user content.
    private static func errorCodeString(_ reason: RecordingFailureReason) -> String {
        String(describing: reason)
    }

    /// Maps a RecordingSession.SessionError (or anything else) into the
    /// user-facing failure taxonomy. Centralized here so the SessionError
    /// → RecordingFailureReason mapping doesn't drift across the two
    /// failure sites (start-time + mid-session).
    private static func failureReason(from error: Error) -> RecordingFailureReason {
        // Disk-full is checked first because it can hide inside several
        // shapes — a raw AVError from the capture writer, or a typed
        // wrapper's underlying error — that the branches below would
        // otherwise misclassify as a generic capture/processing failure.
        if Self.isOutOfSpace(error) {
            return .diskFull
        }
        if let sessionError = error as? RecordingSession.SessionError {
            switch sessionError {
            case .noDisplaysAvailable, .alreadyStarted:
                return .streamStartFailed
            case .noMicrophoneAvailable, .audioInputSetupFailed:
                return .microphoneUnavailable
            case .writerFailedToStart:
                return .writerStartFailed
            }
        }
        // Phase 9 API failures. TranscriptionError and PromptGenerationError
        // share a shape but aren't Equatable (associated values on the
        // .network/.server/.decodeFailure cases), so we pattern-match
        // each rather than compare with ==.
        if let txError = error as? TranscriptionError {
            switch txError {
            case .missingAPIKey: return .apiKeyMissing
            case .auth:          return .apiAuth
            case .rateLimited:   return .rateLimited
            case .network(let underlying):
                return Self.isOfflineClass(underlying) ? .networkOffline : .providerError
            case .server, .decodeFailure:
                return .providerError
            }
        }
        if let pgError = error as? PromptGenerationError {
            switch pgError {
            case .missingAPIKey: return .apiKeyMissing
            case .auth:          return .apiAuth
            case .rateLimited:   return .rateLimited
            case .network(let underlying):
                return Self.isOfflineClass(underlying) ? .networkOffline : .providerError
            case .server, .decodeFailure, .emptyContent:
                return .providerError
            }
        }

        // Anything else came from the capture stack (SCStream /
        // AVCaptureSession), either at start or mid-session. Re-read live
        // TCC state to surface the most actionable message — see
        // captureFailureReason for why we re-check rather than match codes.
        return captureFailureReason()
    }

    /// Turns a generic capture-stack failure into the most actionable
    /// reason by re-reading live TCC authorization at the moment of
    /// failure. Reached only from `failureReason`'s fallback, where the
    /// error came from SCStream / AVCaptureSession rather than a typed
    /// SessionError or API error.
    ///
    /// Why re-check instead of matching error codes: revocation surfaces
    /// as different SCStreamError / AVError codes depending on the macOS
    /// version and on whether it lands at start or mid-stream. The
    /// authorization state right now is the dependable signal. Screen
    /// Recording is checked first — it's the dominant track, so if it's
    /// gone the mic state is moot — via PermissionsManager's canonical
    /// check (CGPreflight + CGWindowList) so dev-time CGPreflight drift
    /// doesn't misreport a mic revocation as a screen-recording one. For
    /// the mic, any state other than `.authorized` means the capture the
    /// SCStream was configured for couldn't run, so all of
    /// `.denied`/`.restricted`/`.notDetermined` route to `.microphoneRevoked`.
    /// `.notDetermined` is included specifically for the start-time path:
    /// the mic is captured THROUGH ScreenCaptureKit
    /// (`config.captureMicrophone`), which doesn't always drive
    /// AVFoundation's own TCC prompt, so a start blocked on the mic can
    /// land here with the status still `.notDetermined` rather than
    /// `.denied`. Without `.notDetermined`, that case fell through to the
    /// generic `.captureInterrupted` ("Recording was interrupted.") — a
    /// dead end that never points the user at the mic permission.
    private static func captureFailureReason() -> RecordingFailureReason {
        // Use the dev-drift-tolerant variant here: at this point we
        // just had an active SCStream (we got far enough to fail
        // mid-capture), so the binary really did have permission a
        // moment ago. The CGWindowList second opinion catches
        // dev-time CGPreflight drift; the strict variant would
        // misreport a mic revocation as a screen-recording one.
        if !PermissionsManager.isScreenRecordingGrantedWithDevDriftFallback() {
            return .screenRecordingRevoked
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted, .notDetermined:
            return .microphoneRevoked
        case .authorized:
            return .captureInterrupted
        @unknown default:
            return .captureInterrupted
        }
    }

    /// Detects URLError codes that mean "the local machine couldn't
    /// reach the network" vs. "the network reached an unhappy server".
    /// Offline-class codes go to .networkOffline (actionable: check
    /// connection); others fall through to .providerError.
    private static func isOfflineClass(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// True if `error` — or anything in its underlying-error chain, or
    /// the underlying carried by one of our typed wrappers — is an
    /// out-of-disk-space failure. Out-of-space arrives under several
    /// guises depending on which layer did the write: Foundation's
    /// `NSFileWriteOutOfSpaceError` (manifest write), POSIX `ENOSPC`
    /// nested in `NSUnderlyingError`, and AVFoundation's
    /// `AVError.diskFull` (the capture `.mov` writer + the audio export).
    /// Walking the whole chain catches whichever layer reported it.
    private static func isOutOfSpace(_ error: Error) -> Bool {
        // Typed wrappers carry the real error as an associated value the
        // NSError bridge can't see — unwrap those first.
        if let sessionError = error as? RecordingSession.SessionError {
            switch sessionError {
            case .writerFailedToStart(let underlying),
                 .audioInputSetupFailed(let underlying):
                return underlying.map(Self.isOutOfSpace) ?? false
            default:
                return false
            }
        }
        if let processingError = error as? ProcessingError {
            switch processingError {
            case .audioExportFailed(let underlying):
                return underlying.map(Self.isOutOfSpace) ?? false
            case .manifestWriteFailed(let underlying):
                return Self.isOutOfSpace(underlying)
            default:
                return false
            }
        }

        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return true
        }
        if ns.domain == AVFoundationErrorDomain, ns.code == AVError.Code.diskFull.rawValue {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return Self.isOutOfSpace(underlying)
        }
        return false
    }

    // MARK: - Cost logging

    /// Emits a one-line-per-stage cost estimate to the console after a
    /// successful run. Whisper is per-minute (round up to nearest
    /// fractional minute, the OpenAI billing model). GPT-4o is per-
    /// token (input + output priced separately). Pricing constants
    /// pinned with a date comment in their respective service files —
    /// when OpenAI changes pricing, those are the two places to update.
    private static func logCost(audioDuration: CMTime, usage: TokenUsage) {
        let durationSeconds = CMTimeGetSeconds(audioDuration)
        let whisperCost = OpenAITranscriptionService.estimatedCost(audioDurationSeconds: durationSeconds)
        let gptCost = OpenAIPromptGenerationService.estimatedCost(usage: usage)
        // All cost lines: durations, model names, token counts, and
        // dollar amounts are .public — operational metrics with no user
        // content. Pre-format Doubles with String(format:) for terse
        // interpolation that's SDK-stable across Xcode versions.
        let durStr = String(format: "%.1fs", durationSeconds)
        let whisperStr = String(format: "$%.4f", whisperCost)
        let gptStr = String(format: "$%.4f", gptCost)
        let totalStr = String(format: "$%.4f", whisperCost + gptCost)
        Log.cost.info("whisper-1: audio=\(durStr, privacy: .public) → \(whisperStr, privacy: .public)")
        Log.cost.info(
            "\(usage.model, privacy: .public): in=\(usage.inputTokens, privacy: .public) out=\(usage.outputTokens, privacy: .public) → \(gptStr, privacy: .public)"
        )
        Log.cost.info("total: \(totalStr, privacy: .public)")
    }

    func toggleResultExpanded() {
        isResultExpanded.toggle()
    }

    // MARK: - Display

    var elapsedDisplay: String {
        let total = Int(elapsedSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
