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
    /// M2 — a recording that a system sleep interrupted was found recoverable
    /// on disk (at wake or launch) and we're asking the user whether to
    /// generate from it. Entered by `recoverOrphanedRecordingIfAny`; resolved
    /// by `resolveRecovery(generate:)` — Generate (→ `.processing`) or Discard
    /// (→ `.idle`, deleting the orphan). Dismissing the pill any other way also
    /// routes to Discard, so the recording is never silently retained once the
    /// user engages. Recovery never auto-generates — it always passes through
    /// here first.
    case confirmingRecovery
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
    /// No usable input device at start (`SessionError.noMicrophoneAvailable`)
    /// — a Mac mini with nothing plugged in, AirPods out of the case, etc.
    /// Environment-driven, NOT a Zerro bug; excluded from error-tracker capture.
    /// Split from `.audioSetupFailed` (Phase 13B follow-up) which IS an
    /// engineering signal.
    case microphoneUnavailable
    /// A microphone WAS present but wiring it into the capture stack threw
    /// (`SessionError.audioInputSetupFailed`). Unlike
    /// `.microphoneUnavailable` this points at our audio-graph setup, so it
    /// IS reported to the error tracker. Same user-facing copy family — the user's
    /// next step (check the mic, try again) is identical.
    case audioSetupFailed
    /// M4 — the microphone captured at start disconnected mid-recording
    /// (AirPods removed, USB mic unplugged). Distinct from
    /// `.microphoneRevoked` (a permission flip, not connectivity) and from
    /// `.microphoneUnavailable` (no device at start): here narration was
    /// being captured fine until the device vanished. Retryable — the user
    /// reconnects the device and records again.
    case microphoneDisconnected
    case streamStartFailed
    case writerStartFailed
    case captureInterrupted
    /// L1 — the display the user selected was gone by the time capture
    /// started (unplugged between selection-confirm and start). Distinct
    /// from `.streamStartFailed` so the copy can name the cause and point
    /// the user to re-select. Not retryable: there are no processed
    /// artifacts to re-run — the user records again.
    case displayUnavailable
    /// M3 — the display being recorded changed mid-session (unplugged, or
    /// its resolution/size changed so the fixed capture region went wrong).
    /// Distinct from `.captureInterrupted` so the copy can say specifically
    /// that the display changed. Not retryable, for the same reason as
    /// `.displayUnavailable`.
    case displayChanged

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
    /// The provider answered but the CONTENT was wrong: decode failures,
    /// schema drift, empty content, the proxy's `malformedResponse` /
    /// `inputRejected`. These mean our contract with the provider broke —
    /// an engineering signal, reported to the error tracker. User-facing copy is
    /// shared with `.providerUnavailable` on purpose: the user can't act
    /// on the distinction; what matters is "try again later".
    case providerError
    /// The provider (or the managed proxy) is having an outage: 5xx,
    /// 502/503, transport-level URLError weather that isn't offline-class.
    /// Third-party weather, NOT a Zerro bug — excluded from error-tracker capture
    /// so a regional OpenAI outage can't flood the dashboard (Phase 13B
    /// follow-up: split out of `.providerError`). Same copy + retryability
    /// as `.providerError`.
    case providerUnavailable
    /// The generation hit the provider's output-token limit and was cut off
    /// before finishing (BYOK `PromptGenerationError.truncated`; Managed
    /// `ManagedGenerationError.responseTruncated` via the server's 422). The
    /// partial output is withheld rather than rendered, because a cut-off
    /// response can carry an unterminated `<<<ZERRO_ARTIFACT` fence that would
    /// otherwise leak into the pill as raw wire syntax
    /// (handoff-artifact-fence-leak). NOT retryable: a re-run at the same
    /// output-token cap truncates identically — the copy points the user at a
    /// shorter recording instead of dangling a Retry that always fails the same
    /// way. Frequency is tracked via the `generation_failed` analytics event, so
    /// it is gated out of error-tracker capture (a known, explainable condition,
    /// not a bug to triage).
    case responseTooLong
    /// A locally-stored artifact (frame JPEG, audio.m4a) could not be read
    /// off disk when building the provider request — the BYOK services
    /// wrap this in their `.network` case, and the managed client surfaces
    /// it as `ManagedGenerationError.artifactUnreadable`. Local I/O on
    /// files Zerro itself wrote, so it IS reported to the error tracker, under its
    /// own errorCode rather than polluting the provider or processing
    /// buckets. (Out-of-space is detected earlier and routes to
    /// `.diskFull`.)
    case artifactUnreadable

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
        case .networkOffline, .rateLimited, .providerError, .providerUnavailable,
             .microphoneDisconnected:
            return true
        case .screenRecordingRevoked, .microphoneRevoked, .microphoneUnavailable,
             .audioSetupFailed,
             .streamStartFailed, .writerStartFailed, .captureInterrupted,
             .displayUnavailable, .displayChanged,
             .processingFailed, .recordingTooShort, .diskFull,
             .artifactUnreadable,
             .apiKeyMissing, .apiAuth,
             .responseTooLong,
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
            return "Microphone permission is off."
        case .microphoneUnavailable:
            return "Selected microphone isn\u{2019}t available."
        case .audioSetupFailed:
            return "Couldn\u{2019}t record from your microphone \u{2014} try again."
        case .microphoneDisconnected:
            return "Your microphone disconnected \u{2014} recording stopped."
        case .streamStartFailed:
            return "Couldn\u{2019}t start screen capture."
        case .writerStartFailed:
            return "Couldn\u{2019}t open the recording file."
        case .captureInterrupted:
            return "Recording was interrupted."
        case .displayUnavailable:
            return "The display you selected is no longer available."
        case .displayChanged:
            return "The display you were recording changed."
        case .processingFailed:
            return "Couldn\u{2019}t process the recording."
        case .recordingTooShort:
            return "Recording was too short \u{2014} try again."
        case .diskFull:
            return "Your Mac is out of storage \u{2014} free up space and try again."
        case .apiKeyMissing:
            return "Add your API keys in Settings to generate prompts \u{2014} an OpenAI key is required for transcription."
        case .apiAuth:
            return "Your API key was rejected \u{2014} check it in Settings."
        case .networkOffline:
            return "Couldn\u{2019}t connect \u{2014} check your connection."
        case .rateLimited:
            return "Hit a rate limit \u{2014} try again in a minute."
        case .providerError, .providerUnavailable:
            return "Generation failed \u{2014} try again."
        case .responseTooLong:
            return "The response was too long to finish \u{2014} try a shorter recording."
        case .artifactUnreadable:
            return "Couldn\u{2019}t process the recording."
        case .outOfCredits:
            return "Not enough credits for this model. Top up from the menu bar, or wait for your monthly reset \u{2014} your library stays open."
        case .subscriptionInactive:
            return "Your subscription isn\u{2019}t active right now \u{2014} check Billing in Settings."
        case .trialVerificationRequired:
            return "Verify your email to use your free trial generations."
        case .trialCreditsExhausted:
            return "You\u{2019}ve used all your free trial credits \u{2014} subscribe or add your own API keys to keep going."
        }
    }
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {

    // MARK: Live State

    var state: RecordingState = .idle {
        didSet {
            // The processing pill's elapsed timer + phrase rotation live
            // exactly as long as the `.processing` state. Drive their
            // lifecycle centrally here so every entry and every exit (success,
            // failure, cancel, reset) is covered without threading start/stop
            // through each call site.
            switch (oldValue, state) {
            case (.processing, .processing):
                break
            case (_, .processing):
                startProcessingTimer()
            case (.processing, _):
                stopProcessingTimer()
                stopThinkingRotation()
            default:
                break
            }
            // M5: a delivered result (including a resumed paid generation that
            // succeeded) no longer needs the held-recording pointer. Clearing on
            // every `.done` also reaps any stale pending record left by a normal
            // success. Removes the UserDefaults pointer + the marker; the working
            // dir stays for the normal result lifecycle (next record / dismiss).
            if case .done = state {
                pendingPaidStore.clear()
            }
        }
    }
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

    /// Phase 3: whether to redact detected secrets (pixels + OCR text) for THIS
    /// recording. Captured at `startRecording` time from
    /// `PreferencesStore.redactSecrets` (same fresh-read pattern as the mic
    /// device / output mode) and handed to the processing pipeline in
    /// `runProcessing`, so a Settings change applies to the next recording.
    /// Defaults to the privacy-on config default for call sites that don't pass
    /// one (tests, menu-bar paths).
    var recordingRedactSecrets: Bool = ProcessingConfig.redactSecretsDefault

    /// Multi-model: the generation model for THIS recording — the capture
    /// toolbar's chip selection, captured at `startRecording` time. A
    /// PER-RECORDING override: the toolbar never writes it back to
    /// `PreferencesStore.selectedModelID`, so the generation path reads
    /// `recordingModelID ?? preferences.selectedModelID` — the override
    /// when the recording came through the overlay, else the persisted
    /// default. Holding it for the session also pins retries to the model
    /// the recording was priced against. `nil` for call sites that don't
    /// pass one (tests, recovered recordings).
    var recordingModelID: String?

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

    /// Typed-artifact refactor (Phase 4): the §2 parse of `generatedPrompt` —
    /// chat text plus at most one typed artifact. Set alongside
    /// `generatedPrompt` on BOTH generation paths (Managed and BYOK) and
    /// reset wherever it is. The pill's rendering shim and the Copy button's
    /// per-type payload read this; `generatedPrompt` stays the raw fallback.
    var parsedResponse: ParsedResponse?

    /// The assembled §2 Attached Context block for the result currently
    /// shown, built ONCE from the processed recording when the result is
    /// accepted (the recording's frames/clicks never change after that).
    /// Internal-only (revision 2026-06-12: the card's context drawer was
    /// removed): never rendered and never part of any copy payload — it
    /// survives solely as the convert request's model input. Reset wherever
    /// `parsedResponse` is.
    var attachedContextBlock: String?

    /// True when the result was generated from the screen alone because
    /// Whisper returned no usable narration (silent recording / muted
    /// mic). We still produce a prompt (the system prompt has a
    /// frames-only fallback), but the result pill surfaces a note so the
    /// user understands why it reads generically rather than silently
    /// shipping a guessed prompt. Set alongside `generatedPrompt` when
    /// entering .done; reset wherever `generatedPrompt` is.
    var resultHadNoNarration: Bool = false

    /// M2 — true when the result currently being shown was RECOVERED from a
    /// recording that a system sleep interrupted (lid closed mid-recording),
    /// after the user accepted the recovery offer. Set by `resolveRecovery`
    /// before it runs the recovered `.mov` through processing, and carried to
    /// `.done`, where
    /// the result pill surfaces a one-line "recovered from a recording stopped
    /// when your Mac slept" note alongside the prompt. Reset on every new
    /// recording and on every exit-to-idle path, exactly like
    /// `resultHadNoNarration`. (In-session sleep no longer produces a result
    /// directly — it abandons the file for launch recovery; see
    /// RecordingSession.abandon.)
    var stoppedBySleep: Bool = false

    /// Multi-model 6B — the SERVER-reported spend of the result currently
    /// shown: `(credits_charged, credits_remaining)` from the `/generate` 200
    /// (D2). Drives the result pill's "−N credits · M left" toast line.
    /// `charged` is exact (the circuit-breaker can meter above the fixed
    /// price; an idempotent replay reports the original charge) — never
    /// derived from the local price table. `nil` for BYOK/local results, on a
    /// pre-D2 backend, and outside `.done`; reset wherever `generatedPrompt`
    /// is.
    var lastGenerationCharge: GenerationCharge?

    /// The toast payload, as a value type so the pill stays a pure renderer.
    struct GenerationCharge: Equatable {
        let charged: Int
        let remaining: Int
    }

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

    // M5 (resume after purchase): owner of the persisted "pending paid
    // generation" pointer. When generation is blocked for a paid reason
    // (trial credits exhausted / out of credits / inactive subscription) the
    // processed recording is held so the failure pill can offer Continue.
    // Owned (not weak) and `var` so tests can inject an ephemeral
    // `UserDefaults`-backed store; the default uses `.standard`.
    @ObservationIgnored var pendingPaidStore = PendingPaidGenerationStore()

    // Phase 6 (multi-model): the preferences store, wired by `ZerroApp.init`
    // (same lifetime + weak-ref contract as `entitlements`). The proxy
    // generation path reads `selectedModelID` fresh at request time — the same
    // fresh-read pattern as `redactSecrets` — so a picker change applies to
    // the next generation. `nil` (tests) falls back to the registry default,
    // which matches what the server resolves for an absent field (D1).
    @ObservationIgnored weak var preferences: PreferencesStore?

    // Phase F (billing): the server-funded trial-credits layer, wired by
    // `ZerroApp.init`. Used as the proxy's token provider for a trial generation
    // and read for trial-credit display. Weak — owned by ZerroApp @State for the
    // app's lifetime (same contract as `entitlements`). A `nil` trialCredits
    // means the trial proxy path is unavailable and generation falls back to
    // local (fail-safe), exactly like a `nil` entitlements.
    @ObservationIgnored weak var trialCredits: TrialCreditsManager?

    /// Whether the user has their own OpenAI key on file — decides whether a
    /// trial user funds generation locally (their key) or via server credits.
    /// DELIBERATELY OpenAI-only even under multi-provider BYOK (6C): the local
    /// path transcribes via Whisper before any chat call, so without an OpenAI
    /// key it cannot run at all — a Gemini/Anthropic-only keyholder keeps
    /// routing through server credits. A closure so tests can drive the
    /// routing without touching the Keychain.
    @ObservationIgnored var hasOwnAPIKeyProvider: () -> Bool = {
        if case .found(let key) = KeychainStore.openAIAPIKey.readResult() {
            return !key.isEmpty
        }
        return false
    }

    /// Whether onboarding is complete — gates launch/wake recovery (we only
    /// offer to recover an interrupted recording once the user is set up). A
    /// closure (like `hasOwnAPIKeyProvider`) so AppState can own the wake
    /// observer without holding the OnboardingStore; wired by `ZerroApp.init`
    /// to read the real store. Defaults to `true` so tests/previews that don't
    /// wire it aren't gated.
    @ObservationIgnored var onboardingCompleteProvider: () -> Bool = { true }

    /// M2 (rev 3): token for the app-lifetime `NSWorkspace.didWakeNotification`
    /// observer that triggers recovery on wake (the common lid-close case never
    /// relaunches the app). Distinct from the capture-duration observers in
    /// RecordingSession — this one lives for the whole app run. Held so
    /// registration is idempotent (no double-register / leak); never removed
    /// before process exit.
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// M2 (rev 3): the orphaned recording currently being OFFERED for recovery
    /// (state `.confirmingRecovery`). Set by `recoverOrphanedRecordingIfAny`,
    /// consumed by `resolveRecovery` (Generate or Discard). Nil otherwise.
    @ObservationIgnored private var pendingRecoveryURL: URL?

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

    /// Drives the witty "thinking" pill rotation during the generation
    /// stage (see `startThinkingRotation`). Scoped strictly to that stage:
    /// started where the label is set and cancelled on every exit path so
    /// it never outlives the generation or leaks a timer. Nil when idle.
    private var thinkingRotationTask: Task<Void, Never>?

    /// The global 1-second ticker for the whole `.processing` state — drives
    /// the live "· Xs" elapsed counter on every stage label (see
    /// `startProcessingTimer`). Started/stopped centrally from `state`'s
    /// `didSet`. Nil when not processing.
    private var processingTimerTask: Task<Void, Never>?

    /// When the current `.processing` run began, for the elapsed counter.
    private var processingElapsedStart: ContinuousClock.Instant?

    /// Tier 1 analytics: when the current generation request was dispatched,
    /// set in `runPromptGeneration` alongside `generation_started`. Read by the
    /// success/failure tails to attach `latency_ms`. Reset on each generation
    /// start (including a retry), so the latency is measured per-attempt.
    private var generationStartInstant: ContinuousClock.Instant?

    /// Tier 1 analytics (Tier 2 fix): the model id resolved ONCE at generation
    /// start, reused by `generation_started` and its matching
    /// `generation_succeeded`/`_failed` so a single generation is always
    /// reported under one model — including when a per-recording override
    /// (`recordingModelID`) differs from the persisted `selectedModelID`. Reset
    /// per attempt, alongside `generationStartInstant`.
    private var generationModelID: String?

    /// The phrase part of the processing pill label, without the trailing
    /// "· Xs" the timer appends. Updated by every stage; the ticker reads it.
    private var processingBaseLabel: String = "Saving your narration\u{2026}"

    /// Consecutive Retry presses against the current failure chain. Cap
    /// keeps a "Retry → fail → Retry" loop from running forever on a
    /// sustained outage — after the cap the Retry button hides and the
    /// only affordance left is Dismiss (which throws the artifacts away
    /// and returns to idle). Reset on every transition out of .failed via
    /// a non-retry path (resetToIdle, cancelRecording, startRecording).
    private var failureRetryAttempts: Int = 0

    /// The underlying error text behind the current `.failed` state, captured
    /// at the generation catch sites BEFORE the error is mapped down to a
    /// value-less `RecordingFailureReason`. The expanded failure card
    /// (`canRetryFailure == true`) surfaces this so the user can read the real
    /// reason instead of a generic one-liner; `RecordingFailureReason.userMessage`
    /// is the fallback when this is nil. Privacy: only ever holds transport /
    /// server error descriptions (see `failureDetail(from:)`) — never transcript
    /// or response content. Cleared on every path out of `.failed`
    /// (`resetTransientRecordingState`, a new recording, and `retryFailedPrompt`)
    /// so a stale detail can't leak into a later state.
    var lastFailureDetail: String?

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
        redactSecrets: Bool = ProcessingConfig.redactSecretsDefault,
        modelID: String? = nil
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
        // M5: a brand-new recording supersedes any held paid-block recording —
        // clear its persisted pointer (its working dir is the prior one removed
        // just above) so we never restore or resume a stale recording.
        pendingPaidStore.clear()
        isResultExpanded = false
        activeSelection = selection
        recordingRedactSecrets = redactSecrets
        recordingModelID = modelID
        lastRecordingURL = nil
        processedRecording = nil
        generatedPrompt = nil
        parsedResponse = nil
        attachedContextBlock = nil
        conversionTask?.cancel()
        conversionTask = nil
        conversionStatus = .idle
        lastGenerationCharge = nil
        resultHadNoNarration = false
        stoppedBySleep = false
        failureRetryAttempts = 0
        lastFailureDetail = nil
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
                Analytics.capture("recording_started", [
                    "model": self.preferences?.selectedModelID ?? "unknown"
                ])
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
                // the error tracker. shouldCapture(_:) filters out user /
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
        resetTransientRecordingState()
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
        // Tier 3 analytics: stash the gate reason so a paywall opened off this
        // block carries the right `paywall_shown.trigger` (read + cleared in
        // PaywallView). Harmless when the failure pill is shown instead.
        entitlements?.paywallTrigger = {
            switch block {
            case .outOfCredits: return .outOfCredits
            case .subscriptionInactive: return .subscriptionInactive
            case .apiKeyMissing: return .apiKeyMissing
            }
        }()
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

    /// Resets the full set of transient per-recording state back to its idle
    /// defaults — the properties that accumulate over a record → process →
    /// result cycle. Centralized so the teardown paths (cancel, reset-to-idle,
    /// mid-session revocation, and the three `handleSessionFinish` outcomes)
    /// can't drift in WHICH properties they clear: the next transient property
    /// added is reset everywhere by construction. Deliberately does NOT set
    /// `state` or perform path-specific work (on-disk artifact removal, task
    /// cancellation, the failure reason) — those stay at each call site because
    /// they legitimately differ between paths.
    private func resetTransientRecordingState() {
        recordingSession = nil
        elapsedSeconds = 0
        frameCount = 0
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
        isResultExpanded = false
        activeSelection = nil
        lastRecordingURL = nil
        processedRecording = nil
        generatedPrompt = nil
        parsedResponse = nil
        attachedContextBlock = nil
        conversionTask?.cancel()
        conversionTask = nil
        conversionStatus = .idle
        lastGenerationCharge = nil
        resultHadNoNarration = false
        stoppedBySleep = false
        pendingRecoveryURL = nil
        failureRetryAttempts = 0
        lastFailureDetail = nil
        // M5: every teardown path that runs through here (cancel, reset-to-idle,
        // mid-session revocation, the cancelled/interrupted session finishes) is
        // a "no longer holding this" point — reap any persisted paid-block
        // pointer + marker. The working dir itself is removed by the call sites
        // that own disk cleanup (they key on `processedRecording.workingDirectory`).
        pendingPaidStore.clear()
    }

    /// Tears down the live session and discards the partial file.
    /// Transition to .idle happens in handleSessionFinish(.cancelled)
    /// after the writer has actually closed — keeps file cleanup
    /// ordered before UI reset. If there's no live session (e.g.
    /// cancel-during-processing), reset immediately.
    func cancelRecording() {
        if let session = recordingSession,
           state == .recording || state == .wrappingUp || state == .autoStopped {
            // Tier 1 analytics: only a LIVE recording is "cancelled". A cancel
            // from .processing/.done below is discarding an already-completed
            // recording (which already fired `recording_completed`), so it stays
            // silent — keeping completed/cancelled mutually exclusive per session.
            Analytics.capture("recording_cancelled", [
                "duration_seconds": Int(elapsedSeconds.rounded())
            ])
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
        resetTransientRecordingState()
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
        resetTransientRecordingState()
        state = .idle
    }

    // MARK: - App termination (M1)

    /// Routes a quit (⌘Q / menu "Quit Zerro" → `NSApplication.terminate`) by
    /// the current state so on-disk artifacts are left in the right shape, then
    /// returns promptly so `applicationShouldTerminate` can answer
    /// `.terminateNow` without hanging quit. Reuses M2's sleep-abandon and the
    /// existing processing-cancel cleanup — it adds no parallel teardown.
    ///
    /// • `.recording` / `.wrappingUp` / `.autoStopped`: abandon via the SAME
    ///   no-finalize path sleep uses (`RecordingSession.abandon`),
    ///   leaving a recoverable fragmented `.mov` on disk. The abandon returns
    ///   immediately (its writer release is dispatched onto writerQueue) and the
    ///   fragment is already flushed (`movieFragmentInterval`), so terminating
    ///   before that async tail runs neither corrupts nor loses it — the next
    ///   launch's recovery OFFERS it exactly as it does a sleep-interrupted
    ///   recording. If a finalize is already in flight (a stop() mid-flight, the
    ///   narrow window where state is still active but `lifecycleState` is
    ///   `.finishing`), the abandon's `== .running` guard makes this a safe
    ///   no-op — same double-fire convergence as sleep.
    /// • `.processing`: cancel the in-flight pipeline / proxy work (its awaits
    ///   are cancellation-aware) and DELETE the source `.mov` synchronously. A
    ///   .processing-stage recording is a post-recording artifact the user is
    ///   abandoning, NOT a recoverable recording, and only a surviving `.mov`
    ///   could be wrongly picked up by the next launch's recovery scan
    ///   (`orphanedRecordings()` matches `.mov` only — the `zerro-work-*`
    ///   working dir is never offered). Deletion is synchronous (not the usual
    ///   detached task) because `.terminateNow` may exit before a detached
    ///   delete runs. We accept that an in-flight proxy generation already sent
    ///   to the server may spend a credit server-side without the user
    ///   receiving the result — a rare, narrow case; blocking quit to salvage it
    ///   is the worse tradeoff.
    /// • everything else: nothing to do. In particular a `.confirmingRecovery`
    ///   offer open at quit must NOT delete its un-acted-on orphan — left
    ///   untouched, it is simply re-offered on the next launch.
    func prepareForTermination() {
        switch state {
        case .recording, .wrappingUp, .autoStopped:
            recordingSession?.abandon()
        case .processing:
            processingTask?.cancel()
            processingTask = nil
            if let source = lastRecordingURL {
                WorkingDirectory.remove(at: source)
            }
            if let workingDir = processedRecording?.workingDirectory {
                WorkingDirectory.remove(at: workingDir)
            }
        case .idle, .done, .failed, .confirmingRecovery:
            break
        }
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

        if state == .recording && seconds >= ProcessingConfig.wrappingUpSeconds {
            state = .wrappingUp
        }
        if state == .wrappingUp && seconds >= ProcessingConfig.maxRecordingSeconds {
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
        case .finished(let url, let clicks):
            // Tier 1 analytics: the recording loop's terminal event. Read the
            // pre-transition state for `end_reason` — the auto-stop path set
            // `.autoStopped` before finalizing; a manual stop leaves
            // `.recording`/`.wrappingUp`. `elapsedSeconds` still holds the final
            // capture duration here (reset only happens on the next start).
            // Fires only for a live session reaching processing, so it's
            // mutually exclusive with `recording_cancelled`.
            Analytics.capture("recording_completed", [
                "duration_seconds": Int(elapsedSeconds.rounded()),
                "end_reason": state == .autoStopped ? "auto_stop" : "manual",
            ])
            lastRecordingURL = url
            // Phase 8 Step 1: run real audio isolation in place of the
            // old mock 4s sleep. Frame extraction (Step 2), manifest
            // (Step 3), and the proper per-stage pill mapping (Step 4)
            // slot into runProcessing as they land; for now the pill
            // keeps its timer-based step rotation and we end on the
            // existing placeholder result. The working-dir path is
            // logged so the isolated audio can be played + verified.
            state = .processing
            runProcessing(sourceURL: url, clicks: clicks)
        case .interrupted:
            // M2 (rev 2): the recording was abandoned for sleep WITHOUT
            // finalizing, leaving a recoverable fragmented `.mov` on disk
            // (RecordingSession did NOT delete it). Reset the UI to idle
            // cleanly — the pill was .recording when the lid closed — and do
            // NOT track or delete the file: it stays orphaned for recovery
            // (recoverOrphanedRecordingIfAny), which OFFERS it on the next wake
            // (the common lid-close case) or launch.
            Log.breadcrumb(category: .stateMachine, message: "recording interrupted by sleep — left for recovery")
            resetTransientRecordingState()
            state = .idle
        case .cancelled:
            resetTransientRecordingState()
            state = .idle
        case .failed(let error):
            Log.state.error("session failed: \(error.localizedDescription, privacy: .private)")
            resetTransientRecordingState()
            let reason = Self.failureReason(from: error)
            // Phase 13B follow-up: mirror the start-failure path. A
            // mid-recording writer/stream failure is exactly the class of
            // capture-stack bug we want to triage; previously this path
            // never reached the error tracker at all. shouldCapture gates out the
            // user/environment reasons (revocation, disk full, …) the
            // same way it does everywhere else.
            if Self.shouldCapture(reason) {
                CrashReporting.capture(
                    error,
                    message: "Recording failed mid-session",
                    stage: "recording",
                    context: ["errorCode": Self.errorCodeString(reason)]
                )
            }
            state = .failed(reason: reason)
        }
    }

    // MARK: - Sleep-interrupted recording recovery (M2 rev 2/3)

    /// Why recovery is triggered, which decides the no-recovery fallback.
    enum RecoveryTrigger {
        /// App launch (crash/force-quit/relaunch). Safe to blanket-sweep junk
        /// when there's nothing to offer — single-instance, this run's own
        /// recordings don't exist yet.
        case launch
        /// System wake (the common lid-close case never relaunches). Must NOT
        /// blanket-sweep — the app is live and may hold a recording or pending
        /// recovery file the prefix sweep would clobber; just no-op.
        case wake
    }

    /// Registers the app-lifetime `NSWorkspace.didWakeNotification` observer so
    /// an interrupted recording is offered for recovery when the user reopens
    /// the lid — not only at some unrelated future launch. Idempotent: a second
    /// call is a no-op (the one-shot launch block already guards this, but the
    /// `wakeObserver != nil` check makes double-register impossible regardless).
    /// App-lifetime by design (NOT capture-scoped like the willSleep/mic
    /// observers) — never removed before process exit, so it can't miss a wake.
    func startWakeRecoveryObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.recoverOrphanedRecordingIfAny(trigger: .wake)
            }
        }
    }

    /// Detect a recording that a prior/just-interrupted session abandoned for
    /// sleep (`RecordingSession.abandon` left a fragmented `.mov` on
    /// disk WITHOUT finalizing it — readable up to its last flushed fragment).
    /// Instead of auto-generating (rev 2) — which would silently spend a
    /// possibly-trial credit on a recording the user may have been abandoning —
    /// we OFFER it: enter `.confirmingRecovery` and let the user choose Generate
    /// / Discard / dismiss. Generation (the credit spend) happens only on an
    /// explicit Generate (`resolveRecovery`).
    ///
    /// Double-recovery / preemption safety: gated on `state == .idle`, so a wake
    /// during an active recording, an in-progress recovery offer, processing, a
    /// shown result, or a failure pill is a safe no-op — recovery never preempts
    /// what the user is doing, and the same orphan can't be offered twice (once
    /// offered, state is `.confirmingRecovery`; once resolved, the file is
    /// processed/deleted/left, never re-entering until a fresh wake/launch finds
    /// it). The post-`await` `state == .idle` re-check bails if the user started
    /// something during the readability probe. Single-instance (no
    /// `LSMultipleInstances`) means any orphan here is from a prior/own
    /// interrupted session, never a file another instance is writing live.
    func recoverOrphanedRecordingIfAny(trigger: RecoveryTrigger) async {
        guard onboardingCompleteProvider(), state == .idle else {
            sweepIfLaunch(trigger)
            return
        }
        guard let newest = WorkingDirectory.orphanedRecordings().first else {
            sweepIfLaunch(trigger)
            return
        }
        // Validate readable (fragments present) — the same duration > 0 gate
        // the pipeline opens with. Interrupted-but-fragmented passes; truly
        // empty/corrupt doesn't.
        let durationOK: Bool
        do {
            let seconds = CMTimeGetSeconds(try await AVURLAsset(url: newest).load(.duration))
            durationOK = seconds.isFinite && seconds > 0
        } catch {
            durationOK = false
        }
        // If the user started something during the await, DON'T sweep (would
        // delete the now-live file) — leave the orphan for the next offer.
        guard state == .idle else { return }
        guard durationOK else {
            sweepIfLaunch(trigger)
            return
        }
        // One offer at a time: clear the OTHER orphans + work-dir junk now,
        // keeping only the one we're about to offer. Then OFFER (do not
        // auto-generate). The credit is spent only if the user picks Generate.
        Task.detached(priority: .utility) { WorkingDirectory.sweep(keeping: newest) }
        Log.breadcrumb(category: .stateMachine, message: "offering sleep-interrupted recording recovery")
        pendingRecoveryURL = newest
        state = .confirmingRecovery
        // Tier 2 analytics: the recovery offer was presented. `trigger`
        // distinguishes the wake path (common lid-close) from a launch scan.
        Analytics.capture("recovery_offered", [
            "trigger": trigger == .wake ? "wake" : "launch"
        ])
    }

    /// Blanket-sweep junk only on the launch trigger; on wake we never sweep
    /// (the running app may hold live/pending files the prefix sweep would
    /// clobber).
    private func sweepIfLaunch(_ trigger: RecoveryTrigger) {
        guard trigger == .launch else { return }
        Task.detached(priority: .utility) { WorkingDirectory.sweep() }
    }

    /// Resolve the recovery offer. `generate == true` runs the recovered
    /// recording through the normal finished-recording path (processing →
    /// generation → result, with the "recovered after sleep" note) — this is
    /// where the credit/API call is spent, now with explicit consent. `false`
    /// (Discard) deletes the orphan and returns to idle, spending nothing.
    /// No-op outside `.confirmingRecovery`. Discard (and any non-Generate
    /// dismissal of the pill, which the UI routes here) deletes the orphan —
    /// there is no leave-on-disk path once the user engages the offer.
    func resolveRecovery(generate: Bool) {
        guard case .confirmingRecovery = state, let url = pendingRecoveryURL else { return }
        pendingRecoveryURL = nil
        if generate {
            // Tier 2 analytics: accepted/discarded are mutually exclusive per
            // offer. An accepted recovery flows on through processing/generation,
            // so it also emits the `processing_*`/`generation_*` events.
            Analytics.capture("recovery_accepted")
            Log.breadcrumb(category: .stateMachine, message: "recovery accepted — generating")
            stoppedBySleep = true
            lastRecordingURL = url
            state = .processing
            runProcessing(sourceURL: url)
        } else {
            Analytics.capture("recovery_discarded")
            Log.breadcrumb(category: .stateMachine, message: "recovery discarded")
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: url) }
            state = .idle
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
    private func runProcessing(sourceURL: URL, clicks: [RecordedClick] = []) {
        // Reset the placeholder explicitly — handleSessionFinish set
        // state = .processing before this Task starts running, so for
        // ~ms before the pipeline fires its first onStage the pill
        // would otherwise show whatever label survived the prior run.
        // (The .processing didSet already started the elapsed timer.)
        setProcessingLabel("Saving your narration\u{2026}")
        // Phase 13A: marks the .recording → .processing handoff in the
        // local breadcrumb trail.
        Log.breadcrumb(category: .pipelineStage, message: "processing started")
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ProcessingPipeline().process(
                    sourceURL: sourceURL,
                    clicks: clicks,
                    redactSecrets: self.recordingRedactSecrets,
                    onStage: { [weak self] stage in
                        self?.setProcessingLabel(stage.userMessage)
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
                // Tier 1 analytics: the local pipeline finished and generation
                // is about to start. Best-effort metadata already at hand —
                // pipeline elapsed off the processing clock, frame/audio counts
                // off the result. No extra work computed for these.
                let audioSeconds = CMTimeGetSeconds(result.duration)
                Analytics.capture("processing_completed", [
                    "duration_seconds": self.processingElapsedStart
                        .map { Int((ContinuousClock.now - $0).components.seconds) } ?? 0,
                    "frame_count": result.frames.count,
                    "audio_seconds": audioSeconds.isFinite ? Int(audioSeconds.rounded()) : 0,
                ])
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
                // Tier 1 analytics: a too-short/empty recording is its own
                // terminal recording event (with the capture duration); every
                // other pipeline failure is a `processing_failed` carrying the
                // bounded reason enum. Mutually exclusive — exactly one fires.
                if reason == .recordingTooShort {
                    Analytics.capture("recording_too_short", [
                        "duration_seconds": Int(self.elapsedSeconds.rounded())
                    ])
                } else {
                    Analytics.capture("processing_failed", [
                        "reason": Self.errorCodeString(reason)
                    ])
                }
                // Phase 13B: report engineering-signal failures to
                // the error tracker. .diskFull and .recordingTooShort are gated
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

    /// Phase 9: Whisper transcribe → Interleaver → generate. The pill shows
    /// `.transcribing` while Whisper runs; generation then runs straight
    /// through (the v1 mode-switch pause is gone with modes themselves).
    /// The `.processing → .done` transition fires from `runGeneration`.
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
        // Tier 1 analytics: mark the start (for latency_ms on the outcome) and
        // fire the funnel-entry event — but only for the routes that actually
        // dispatch a request. `.trialNeedsEmail` dispatches nothing (it routes
        // to email capture), so it gets no start event and no latency clock.
        if let analyticsRoute = Self.analyticsRoute(for: route) {
            let model = recordingModelID ?? preferences?.selectedModelID ?? ModelRegistry.defaultModelID
            generationStartInstant = ContinuousClock.now
            generationModelID = model
            Analytics.capture("generation_started", [
                "model": model,
                "route": analyticsRoute,
                "provider": ModelRegistry.entry(id: model)?.provider.rawValue ?? "unknown",
            ])
        }
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
    /// Uploads audio + frames (NEVER a transcript or system prompt — the
    /// server owns those, §6.1; since the typed-artifact refactor there is no
    /// mode either) to the proxy and lands the returned result on the same
    /// `.done` tail the local path uses (pill + history unchanged). Does NOT
    /// run local Whisper — the server transcribes on this path.
    ///
    /// `tokenProvider` nil = the Managed subscription token (proxy default);
    /// non-nil = the trial token (`isTrial == true`). The two differ only in how
    /// the post-success credit balance is applied and how failures are mapped;
    /// the upload + result tail are identical.
    // MARK: - Processing pill label + elapsed timer

    /// Starts the global elapsed timer for the `.processing` state. Driven
    /// from `state`'s `didSet`, so it spans every stage — the static pipeline
    /// stages ("Saving your narration", "Capturing key moments", "Wrapping
    /// up") AND the generation rotation — appending a live "· Xs" to whatever
    /// phrase is current. One continuous clock for the whole request.
    private func startProcessingTimer() {
        stopProcessingTimer()
        processingElapsedStart = ContinuousClock.now
        // "Saving your narration" is always the first processing stage; reset
        // the base so a phrase left over from a prior run never flashes.
        setProcessingLabel("Saving your narration\u{2026}")
        processingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                // Recompose from the current phrase so the seconds tick up
                // even while the phrase itself is unchanged.
                self.setProcessingLabel(self.processingBaseLabel)
            }
        }
    }

    /// Stops the global elapsed timer. Idempotent.
    private func stopProcessingTimer() {
        processingTimerTask?.cancel()
        processingTimerTask = nil
        processingElapsedStart = nil
    }

    /// Sets the pill's phrase and immediately composes the visible label with
    /// the running elapsed timer appended. All processing-stage label updates
    /// funnel through here so every phrase carries the "· Xs" counter.
    private func setProcessingLabel(_ phrase: String) {
        processingBaseLabel = phrase
        let elapsed = processingElapsedStart
            .map { Int((ContinuousClock.now - $0).components.seconds) } ?? 0
        processingStageLabel = "\(phrase) \u{00B7} \(Self.thinkingElapsedText(elapsed))"
    }

    /// Begins the generation rotation: an immediate random Category-1 starter,
    /// then a fresh random Category-2 continuation on a
    /// `ProcessingPipeline.thinkingRotationIntervalRange` cadence (never the
    /// same phrase twice in a row). Only swaps the phrase — the global timer
    /// (`startProcessingTimer`) owns the live "· Xs" counter. Paired with
    /// `stopThinkingRotation()` on the generation success/failure/cancel exits.
    private func startThinkingRotation() {
        stopThinkingRotation()
        setProcessingLabel(ProcessingPipeline.thinkingStarters.randomElement() ?? "Working on it")
        thinkingRotationTask = Task { @MainActor [weak self] in
            var last: String?
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Double.random(in: ProcessingPipeline.thinkingRotationIntervalRange))
                )
                guard !Task.isCancelled, let self else { return }
                let next = Self.nextContinuation(avoiding: last)
                last = next
                self.setProcessingLabel(next ?? "Working on it")
            }
        }
    }

    /// Cancels the phrase rotation. Idempotent — safe to call on every exit
    /// path and when no rotation is running.
    private func stopThinkingRotation() {
        thinkingRotationTask?.cancel()
        thinkingRotationTask = nil
    }

    /// Picks a continuation phrase distinct from `previous` (so the pill
    /// never shows the same line twice in a row).
    static func nextContinuation(avoiding previous: String?) -> String? {
        let pool = ProcessingPipeline.thinkingContinuations
        guard pool.count > 1 else { return pool.first }
        var next = pool.randomElement()
        while next == previous { next = pool.randomElement() }
        return next
    }

    /// Formats an elapsed duration for the pill: whole seconds under a
    /// minute ("12s"), whole minutes once past it ("2min").
    private static func thinkingElapsedText(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)min"
    }

    private func runProxyGeneration(
        processed: ProcessedRecording,
        proxy: ManagedProxyClient,
        tokenProvider: ProxyTokenProviding?,
        isTrial: Bool
    ) {
        let audioURL = processed.workingDirectory.appendingPathComponent("audio.m4a")
        let durationSeconds = CMTimeGetSeconds(processed.duration)
        let label = isTrial ? "trial" : "managed"
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The generation stage is one opaque round-trip: rotate witty
            // "thinking" sayings instead of a static label, and tear the
            // rotation down on every exit (success, failure, cancellation).
            defer { self.stopThinkingRotation() }
            do {
                // One server round-trip covers upload → STT → generation; the
                // rotating "thinking" sayings stand in for the single stage.
                self.startThinkingRotation()
                Log.breadcrumb(category: .pipelineStage, message: "proxy generation started")
                let managed = try await proxy.generate(
                    audioURL: audioURL,
                    frames: processed.frames,
                    durationSeconds: durationSeconds.isFinite ? durationSeconds : nil,
                    clicks: processed.clicks,
                    // Phase 6: tell the server whether to bother with Whisper. On
                    // false it short-circuits STT (empty segments) — no transcript
                    // round-trip — and composes from frames/OCR/clicks alone.
                    hasSpeech: processed.hasSpeech,
                    // Multi-model 6B: the toolbar's per-recording pick when
                    // the recording came through the overlay, else the user's
                    // persisted picker selection (registry-validated in
                    // PreferencesStore). Selects the provider + per-model
                    // price SERVER-side; never steers the prompt.
                    model: self.recordingModelID
                        ?? self.preferences?.selectedModelID
                        ?? ModelRegistry.defaultModelID,
                    tokenProvider: tokenProvider,
                    // M1: the recording's stable key — reused across every retry
                    // (here and `retryFailedPrompt`) so a charged-but-dropped
                    // response is replayed, not re-billed.
                    idempotencyKey: processed.idempotencyKey
                )
                let result = managed.result
                Log.promptGen.info(
                    "\(label, privacy: .public) OK — model=\(result.usage.model, privacy: .public) in=\(result.usage.inputTokens, privacy: .public) out=\(result.usage.outputTokens, privacy: .public) prompt.count=\(result.prompt.count, privacy: .public) creditsRemaining=\(managed.creditsRemaining ?? -1, privacy: .public)"
                )

                guard self.state == .processing else { return }
                self.acceptGenerationResult(rawPrompt: result.prompt)
                // Multi-model 6B: the exact server spend for the result pill's
                // "−N credits · M left" line (both fields or no toast — a
                // pre-D2 backend omits credits_charged).
                if let charged = managed.creditsCharged, let remaining = managed.creditsRemaining {
                    self.lastGenerationCharge = GenerationCharge(charged: charged, remaining: remaining)
                }
                // The proxy path has no client transcript, so the no-narration
                // note (a BYOK affordance) doesn't apply — never flag it here.
                self.resultHadNoNarration = false
                self.state = .done
                Analytics.capture("generation_succeeded", [
                    "route": "managed",
                    "model": self.generationModelID ?? "unknown",
                    "artifact_type": self.parsedResponse?.artifact?.type.rawValue ?? "chat",
                    "latency_ms": self.generationLatencyMs() ?? 0
                ])
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
                Analytics.capture("generation_failed", [
                    "route": isTrial ? "trial" : "managed",
                    "reason": Self.errorCodeString(reason),
                    "latency_ms": self.generationLatencyMs() ?? 0,
                    "model": self.generationModelID ?? "unknown"
                ])
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Proxy generation failed",
                        stage: "proxyGeneration",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                // Carry the real error for the expanded failure card BEFORE
                // mapping down to the value-less reason (decision 1).
                self.lastFailureDetail = Self.failureDetail(from: error)
                self.state = .failed(reason: reason)
                // M5: if this is a PAID block (trial credits exhausted / out of
                // credits / inactive subscription), hold the processed recording
                // so the failure pill can offer Continue once the user pays. The
                // recording's artifacts are still intact on disk (this catch left
                // them in place), so resume re-runs generation with no re-record.
                self.capturePendingPaidGenerationIfNeeded(reason: reason, processed: processed)
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
        case .providerUnavailable:
            // 502/503 from the proxy or OpenAI — weather, not captured.
            return .providerUnavailable
        case .responseTruncated:
            // 422 — output-token truncation; partial prompt withheld
            // (handoff-artifact-fence-leak).
            return .responseTooLong
        case .malformedResponse, .inputRejected:
            // Contract broke between client and proxy — captured.
            return .providerError
        case .network:
            // Transport failure (offline/DNS/timeout). The description is
            // display-only — there's no underlying URLError to classify, so
            // treat the whole class as connectivity. Not captured.
            return .networkOffline
        case .artifactUnreadable:
            return .artifactUnreadable
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
        case .providerUnavailable:
            // 502/503 — proxy/OpenAI weather, retryable, not captured.
            return .providerUnavailable
        case .responseTruncated:
            // 422 — the server's chat hit the output-token limit; the partial
            // prompt is withheld (handoff-artifact-fence-leak).
            return .responseTooLong
        case .malformedResponse, .inputRejected, .authFailed:
            // Contract/token machinery broke — engineering signal, captured.
            // (A real recording can't trip the input fuse; a managed-path
            // authFailed means OUR session plumbing rejected a token the
            // entitlement layer thought was valid.)
            return .providerError
        case .network:
            // Transport failure (offline/DNS/timeout). The description is
            // display-only — there's no underlying URLError to classify, so
            // treat the whole class as connectivity. Not captured.
            return .networkOffline
        case .artifactUnreadable:
            return .artifactUnreadable
        }
    }

    /// The BYOK/local generation path (Phase 9 + 17): Whisper transcribe →
    /// Interleaver → generate. (Renamed from `runPromptGeneration` in
    /// Phase E, which is now the routing branch above.)
    private func runLocalPromptGeneration(processed: ProcessedRecording) {
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // BYOK path: start the thinking rotation here, so the
                // transcription wait shows the same random phrases + elapsed
                // timer as generation (one continuous timer) instead of a
                // static "Transcribing…" label. runGeneration keeps it
                // running and stops it when generation finishes; the
                // failure/early-return paths below stop it if we never get
                // that far.
                self.startThinkingRotation()
                // Phase 6 no-speech gate: when the pipeline detected no
                // speech-level energy in the audio, skip the Whisper call
                // entirely (saves the round-trip + its cost) and proceed on an
                // empty transcript. The timeline is then frames + OCR + clicks
                // only; the prompt's empty-narration rule covers the output
                // (one brief chat line, no artifact).
                let transcript: Transcript
                if processed.hasSpeech {
                    // Phase 13A: breadcrumb each API stage so a Whisper-vs-GPT
                    // failure can be triaged by the breadcrumb sequence
                    // alone, without having to look at the failure event.
                    Log.breadcrumb(category: .pipelineStage, message: "transcription started")
                    let audioURL = processed.workingDirectory.appendingPathComponent("audio.m4a")
                    transcript = try await OpenAITranscriptionService().transcribe(
                        audioFileURL: audioURL
                    )
                    // Counts are .public — segment count and char count
                    // are metrics, not content. The transcript TEXT itself
                    // never enters a log call anywhere.
                    Log.transcription.info(
                        "segments=\(transcript.segments.count, privacy: .public) fullText.count=\(transcript.fullText.count, privacy: .public)"
                    )
                } else {
                    Log.breadcrumb(category: .pipelineStage, message: "transcription skipped (no speech)")
                    Log.transcription.info("skipped — no detectable speech (Phase 6 gate)")
                    transcript = Transcript(segments: [], fullText: "")
                }
                guard self.state == .processing else {
                    self.stopThinkingRotation()
                    return
                }

                let timeline = Interleaver.merge(
                    frames: processed.frames,
                    transcript: transcript,
                    clicks: processed.clicks
                )

                self.runGeneration(
                    timeline: timeline,
                    transcript: transcript,
                    processed: processed
                )
            } catch {
                // Transcription failed before we reached generation, so stop
                // the rotation here (runGeneration's defer never runs).
                self.stopThinkingRotation()
                Log.transcription.error("failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .processing else { return }
                let reason = Self.failureReason(from: error)
                // Phase 13B: transcription-stage failures worth triaging
                // (provider decode failures, unreadable local artifacts)
                // reach the error tracker; user/environment failures AND provider
                // 5xx outages are gated out by shouldCapture.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Transcription failed",
                        stage: "transcription",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                // Carry the real error for the expanded failure card BEFORE
                // mapping down to the value-less reason (decision 1).
                self.lastFailureDetail = Self.failureDetail(from: error)
                self.state = .failed(reason: reason)
            }
        }
    }

    /// The generation half of the BYOK API flow. One unified v2 prompt since
    /// the typed-artifact refactor — no mode parameter. The
    /// `.processing → .done` transition fires here on success.
    private func runGeneration(
        timeline: InterleavedTimeline,
        transcript: Transcript,
        processed: ProcessedRecording
    ) {
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The thinking rotation was already started by
            // runLocalPromptGeneration so its elapsed timer spans the
            // transcription wait too (one continuous surface). We don't
            // restart it here — that would reset the timer — we just make
            // sure it stops on every exit path.
            defer { self.stopThinkingRotation() }
            do {
                Log.breadcrumb(category: .pipelineStage, message: "prompt generation started")
                // Multi-model 6C: route to the selected model's provider,
                // falling back to the cheapest model whose provider HAS a key
                // (the persisted selection may point at a keyless provider —
                // e.g. the recommended Gemini default on an OpenAI-only
                // setup). No chat key at all → the same missingAPIKey →
                // .apiKeyMissing pill the single-provider path used.
                let selectedID = self.recordingModelID
                    ?? self.preferences?.selectedModelID
                    ?? ModelRegistry.defaultModelID
                guard let entry = BYOKRouting.effectiveEntry(
                    selectedModelID: selectedID,
                    availableProviders: ProviderKeys.availableProviders()
                ) else {
                    throw PromptGenerationError.missingAPIKey
                }
                if entry.id != selectedID {
                    Log.promptGen.notice(
                        "BYOK fallback: selected \(selectedID, privacy: .public) has no provider key — using \(entry.id, privacy: .public)"
                    )
                }
                let result = try await BYOKRouting.service(for: entry).generatePrompt(
                    timeline: timeline,
                    systemPrompt: PromptGenerationSystemPrompt.composed()
                )
                // Model name (.public — a registry id we control) and token
                // counts (.public — metrics, not content). result.prompt.count
                // is the LENGTH of the generated prompt, not the text itself.
                Log.promptGen.info(
                    "OK — model=\(result.usage.model, privacy: .public) in=\(result.usage.inputTokens, privacy: .public) out=\(result.usage.outputTokens, privacy: .public) prompt.count=\(result.prompt.count, privacy: .public)"
                )
                Self.logCost(
                    audioDuration: processed.duration,
                    usage: result.usage,
                    requestedModelID: entry.id
                )

                guard self.state == .processing else { return }
                self.acceptGenerationResult(rawPrompt: result.prompt)
                self.resultHadNoNarration = Self.isNarrationEmpty(transcript)
                self.state = .done
                Analytics.capture("generation_succeeded", [
                    "route": "byok",
                    "model": self.generationModelID ?? "unknown",
                    "artifact_type": self.parsedResponse?.artifact?.type.rawValue ?? "chat",
                    "latency_ms": self.generationLatencyMs() ?? 0
                ])
                // Phase 13A: terminal-success breadcrumb. If a crash
                // lands during result presentation (UI bug, copy
                // affordance), the trail makes it obvious the pipeline
                // itself completed first.
                Log.breadcrumb(category: .pipelineStage, message: "prompt generation completed")
            } catch {
                Log.promptGen.error("failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .processing else { return }
                let reason = Self.failureReason(from: error)
                Analytics.capture("generation_failed", [
                    "route": "byok",
                    "reason": Self.errorCodeString(reason),
                    "latency_ms": self.generationLatencyMs() ?? 0,
                    "model": self.generationModelID ?? "unknown"
                ])
                // Phase 13B: report engineering-signal failures to the error
                // tracker. .providerError here is decode failures / empty
                // content — contract drift we want to triage. 5xx outages map
                // to .providerUnavailable and are gated out by shouldCapture.
                if Self.shouldCapture(reason) {
                    CrashReporting.capture(
                        error,
                        message: "Prompt generation failed",
                        stage: "promptGeneration",
                        context: ["errorCode": Self.errorCodeString(reason)]
                    )
                }
                // Carry the real error for the expanded failure card BEFORE
                // mapping down to the value-less reason (decision 1).
                self.lastFailureDetail = Self.failureDetail(from: error)
                self.state = .failed(reason: reason)
            }
        }
    }

    // MARK: - Typed-artifact result handling (Phase 4)

    /// The shared `.done` tail for BOTH generation paths (Managed and BYOK):
    /// parse the raw model output against the §2 contract, surface
    /// recovery/coercion telemetry, and persist the v2 history entry (model
    /// artifact title preferred). `generatedPrompt` keeps the raw text as
    /// the verbatim fallback; `parsedResponse` is what the pill renders.
    private func acceptGenerationResult(rawPrompt: String) {
        let parsed = ArtifactParser.parse(rawPrompt)
        generatedPrompt = rawPrompt
        parsedResponse = parsed
        // Tier 4 analytics: the activation signal — a usable result was produced.
        // Fired here (the shared generation `.done` tail), so it counts once per
        // generation and NOT on the "Write agent prompt" conversion re-parse,
        // which lands in `acceptConversionResult`. Metadata only.
        Analytics.capture("artifact_produced", [
            "artifact_type": parsed.artifact?.type.rawValue ?? "chat",
            "was_chat_only": parsed.artifact == nil,
        ])
        attachedContextBlock = processedRecording.flatMap {
            AttachedContextBuilder.build(frames: $0.frames, clicks: $0.clicks)
        }
        // Phase 5 (approved design): the result opens with the artifact card's
        // body visible — land in the expanded pill, not compact-with-"View".
        // The card's Hide chevron collapses back to the compact capsule.
        isResultExpanded = true

        // Production visibility for the §2 fail-safe tiers (.public — these
        // carry rule names / a type token, never response content). The
        // recovery rate was baselined at ~4% of flash artifacts in Phase 1;
        // these are the signals that tell us if it climbs in the wild.
        if !parsed.isValid {
            Log.artifacts.warning("malformed response degraded to chat text (fail-safe fallback)")
        }
        if parsed.wasRecovered {
            let rules = parsed.warnings
                .filter { $0.hasPrefix("recovered") }
                .joined(separator: "; ")
            Log.artifacts.warning("recovery tier fired: \(rules, privacy: .public)")
        }
        if let artifact = parsed.artifact, artifact.rawType != artifact.type.rawValue {
            Log.artifacts.warning("unknown artifact type \"\(artifact.rawType, privacy: .public)\" coerced to generic")
        }

        recentPromptStore?.add(
            prompt: rawPrompt,
            chatText: parsed.chatText,
            artifactType: parsed.artifact?.type.rawValue,
            artifactBody: parsed.artifact?.body,
            artifactTitle: parsed.artifact?.title
        )
    }

    /// Everything the result pill renders, in display form (Phase 5): chat
    /// text above the optional artifact card. Falls back to the raw output
    /// as chat text when parsing produced no structure, so the pill always
    /// has something to show.
    var resultPresentation: ResultPresentation? {
        guard let parsed = parsedResponse else {
            return generatedPrompt.map {
                ResultPresentation(chatText: $0, artifact: nil)
            }
        }
        guard let artifact = parsed.artifact else {
            let chat = parsed.chatText.isEmpty ? (generatedPrompt ?? "") : parsed.chatText
            return ResultPresentation(chatText: chat, artifact: nil)
        }
        return ResultPresentation(
            chatText: parsed.chatText,
            artifact: artifact
        )
    }

    /// The Copy button's payload per the §2 per-type table (revised
    /// 2026-06-12): the artifact body alone for EVERY type — the Attached
    /// Context is internal-only (convert model input) and is never copied. A chat-only
    /// response copies the chat text. Falls back to the raw output when
    /// parsing produced no structure.
    var resultCopyPayload: String? {
        guard let parsed = parsedResponse else { return generatedPrompt }
        guard let artifact = parsed.artifact else {
            return parsed.chatText.isEmpty ? generatedPrompt : parsed.chatText
        }
        return artifact.body
    }

    // MARK: - Conversion fallback (Phase 6 — "Write agent prompt")

    /// The ghost button's lifecycle. `.idle` with `canConvertToAgentPrompt`
    /// true renders the button; `.running` the inline spinner; `.failed` the
    /// unobtrusive "Couldn't write the prompt — try again" note (the button
    /// stays — it IS the retry affordance). Reset wherever `parsedResponse` is.
    enum ConversionStatus: Equatable {
        case idle, running, failed
    }

    var conversionStatus: ConversionStatus = .idle

    @ObservationIgnored private var conversionTask: Task<Void, Never>?

    /// The ghost "✎ Write agent prompt" button renders ONLY on artifact-less
    /// results: the model judged the response a question/diagnosis (or the
    /// fail-safe degraded a malformed response to chat text — there is still
    /// chat text worth converting). A result that already has a card never
    /// shows it.
    ///
    /// The one artifact-less case that must NOT show it is the empty case —
    /// the recording held no request at all. Generation signals that with the
    /// `<<<ZERRO_NO_REQUEST>>>` sentinel, which the parser turns into
    /// `requestPresent == false`; converting there has nothing to convert and
    /// would hallucinate a task from on-screen context. `!= false` (not
    /// `== true`) keeps the button for every other path, since `requestPresent`
    /// defaults true.
    var canConvertToAgentPrompt: Bool {
        state == .done && parsedResponse != nil && parsedResponse?.artifact == nil
            && parsedResponse?.requestPresent != false
    }

    /// Converts the current artifact-less response into an `agent_prompt`
    /// artifact via the free `convert` endpoint (Managed/trial) or a direct
    /// provider call with the same conversion prompt (BYOK). On success the
    /// converted artifact joins the EXISTING ParsedResponse (the chat text is
    /// never replaced) and updates the existing history entry. On any failure
    /// the result is left exactly as it was, with an inline retry state.
    func convertToAgentPrompt() {
        guard canConvertToAgentPrompt, conversionStatus != .running else { return }
        guard let parsed = parsedResponse else { return }
        let source = parsed.chatText.isEmpty ? (generatedPrompt ?? "") : parsed.chatText
        guard !source.isEmpty else { return }
        let context = attachedContextBlock
        let model = recordingModelID
            ?? preferences?.selectedModelID
            ?? ModelRegistry.defaultModelID
        // Plan Phase 6 step 4: the recording's stable key + ":convert". The
        // server has no dedup cache today; the suffix keeps the key disjoint
        // from the generation's if one is ever added.
        let idemKey = (processedRecording?.idempotencyKey ?? UUID().uuidString) + ":convert"

        conversionStatus = .running
        Log.artifacts.info("conversion started")

        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.performConversion(
                    source: source,
                    context: context,
                    model: model,
                    idempotencyKey: idemKey
                )
                // The user may have dismissed the result (or started a new
                // recording, which cancels this task) while we waited.
                guard self.state == .done, self.conversionStatus == .running else { return }
                self.acceptConversionResult(raw: raw)
            } catch is CancellationError {
                // A reset path cancelled us — state was already cleaned up.
            } catch {
                Log.artifacts.warning("conversion failed: \(error.localizedDescription, privacy: .private)")
                guard self.state == .done, self.conversionStatus == .running else { return }
                self.conversionStatus = .failed
            }
        }
    }

    /// Routes the conversion the same way generation routes (Managed proxy /
    /// trial proxy / BYOK), falling back to BYOK when the proxy isn't wired —
    /// the same fail-safe posture as `runPromptGeneration`.
    private func performConversion(
        source: String,
        context: String?,
        model: String,
        idempotencyKey: String
    ) async throws -> String {
        let route = entitlements?.generationRoute(hasOwnAPIKey: hasOwnAPIKeyProvider()) ?? .local
        switch route {
        case .managedProxy:
            if let proxy = managedProxyClient {
                return try await proxy.convert(
                    sourceText: source,
                    context: context,
                    model: model,
                    tokenProvider: nil,
                    idempotencyKey: idempotencyKey
                )
            }
        case .trialProxy:
            if let proxy = managedProxyClient, let trial = trialCredits {
                return try await proxy.convert(
                    sourceText: source,
                    context: context,
                    model: model,
                    tokenProvider: trial,
                    idempotencyKey: idempotencyKey
                )
            }
        case .trialNeedsEmail, .local:
            break
        }
        // BYOK (or proxy-unwired fallback): same model routing as generation;
        // the user text is composed exactly like the server composes it
        // (source, blank line, context block).
        guard let entry = BYOKRouting.effectiveEntry(
            selectedModelID: model,
            availableProviders: ProviderKeys.availableProviders()
        ) else {
            throw PromptGenerationError.missingAPIKey
        }
        let userText = context.map { "\(source)\n\n\($0)" } ?? source
        let result = try await BYOKRouting.service(for: entry).convert(
            userText: userText,
            systemPrompt: ConversionSystemPrompt.composed()
        )
        return result.prompt
    }

    /// The conversion's `.done` tail: parse, accept ONLY a well-formed
    /// `agent_prompt` artifact, and graft it onto the existing response. A
    /// malformed or off-contract result (chat-only, wrong type) flips the
    /// inline retry state and leaves the response untouched — the existing
    /// chat text is never destroyed or replaced.
    private func acceptConversionResult(raw: String) {
        let converted = ArtifactParser.parse(raw)
        guard let artifact = converted.artifact, artifact.type == .agentPrompt else {
            Log.artifacts.warning(
                "conversion returned no agent_prompt (got: \(converted.artifact?.rawType ?? "none", privacy: .public)) — inline retry offered"
            )
            conversionStatus = .failed
            return
        }
        if converted.wasRecovered {
            let rules = converted.warnings
                .filter { $0.hasPrefix("recovered") }
                .joined(separator: "; ")
            Log.artifacts.warning("conversion recovery tier fired: \(rules, privacy: .public)")
        }

        let original = parsedResponse
        parsedResponse = ParsedResponse(
            chatText: original?.chatText ?? "",
            artifact: artifact,
            isValid: true,
            wasRecovered: converted.wasRecovered,
            warnings: converted.warnings
        )
        conversionStatus = .idle
        // The conversion updates the EXISTING history entry — never a second
        // row (plan Phase 6; keyed on the original raw prompt the entry was
        // added with).
        if let originalPrompt = generatedPrompt {
            recentPromptStore?.attachConvertedArtifact(
                originalPrompt: originalPrompt,
                type: artifact.type.rawValue,
                body: artifact.body,
                title: artifact.title
            )
        }
        Log.artifacts.info("conversion attached an agent_prompt artifact")
    }

    /// User-driven dismissal of the failure pill. Same as cancel —
    /// returns to .idle so the next hotkey press starts cleanly.
    func dismissFailure() {
        guard case .failed(let reason) = state else { return }
        // M5: dismissing a PAID-blocked failure means "give up on this
        // recording" — delete the held working dir and clear the pending
        // pointer so it isn't restored at the next launch. (`resetToIdle` also
        // removes `processedRecording`'s working dir; this additionally covers a
        // recording restored at launch and clears the persisted pointer.)
        if PaidBlockReason(reason) != nil {
            discardPendingPaidGeneration()
        }
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
        // Tier 2 analytics: read the failure reason while state is still
        // `.failed`, and `attempt` after the increment, before re-entering
        // generation. The re-run fires a fresh `generation_started`, so a retry
        // reads as `generation_retried → generation_started → succeeded/failed`.
        let retriedReason: RecordingFailureReason? = {
            if case .failed(let reason) = state { return reason }
            return nil
        }()
        failureRetryAttempts += 1
        if let retriedReason {
            Analytics.capture("generation_retried", [
                "reason": Self.errorCodeString(retriedReason),
                "attempt": failureRetryAttempts,
            ])
        }
        // Drop the prior detail so a stale string can't leak if the retry
        // somehow lands in a state that reads it before the next catch site runs.
        lastFailureDetail = nil
        state = .processing
        // runPromptGeneration starts at the `.transcribing` stage and
        // walks through `.writingPrompt` — exactly the work that needs to
        // re-run. The working dir's artifacts are untouched by the prior
        // failure (both runProcessing's and runPromptGeneration's catch
        // blocks leave them in place), so the second attempt reads the
        // same audio.m4a + frames + manifest the first one did.
        runPromptGeneration(processed: processed)
    }

    // MARK: - Resume after purchase (M5)

    /// Persists a held-recording pointer when generation is blocked for a PAID
    /// reason, so the failure pill can offer Continue and survive a quit during
    /// checkout. No-op for any non-paid reason or when there's no processed
    /// recording to hold. Writes both the `UserDefaults` pointer and the
    /// in-working-dir marker (which spares the dir from the launch sweep).
    private func capturePendingPaidGenerationIfNeeded(
        reason: RecordingFailureReason,
        processed: ProcessedRecording
    ) {
        guard let paidReason = PaidBlockReason(reason) else { return }
        let model = recordingModelID
            ?? preferences?.selectedModelID
            ?? ModelRegistry.defaultModelID
        let pending = PendingPaidGeneration(
            workingDirectoryName: processed.workingDirectory.lastPathComponent,
            idempotencyKey: processed.idempotencyKey,
            modelID: model,
            reason: paidReason,
            createdAt: Date()
        )
        pendingPaidStore.save(pending)
        Log.billing.notice("paid block held for resume (reason=\(String(describing: paidReason), privacy: .public))")
    }

    /// True when the current failure is a PAID block AND we have a held
    /// recording to resume — either still in memory or persisted on disk. The
    /// pill reads this via the bridge to decide whether to render the Continue
    /// button alongside Dismiss.
    var canResumePaidGeneration: Bool {
        guard case .failed(let reason) = state, PaidBlockReason(reason) != nil else {
            return false
        }
        return processedRecording != nil || pendingPaidStore.load() != nil
    }

    /// User-driven Continue from a paid-blocked failure pill. Re-checks
    /// entitlement (the user may have just subscribed / added BYOK keys in the
    /// browser); if they can now generate, reconstructs the held recording if
    /// needed and re-runs generation reusing the original idempotency key (so the
    /// proxy replays a charged-but-blocked response instead of double-charging).
    /// If they still can't generate, opens the paywall and LEAVES the pending
    /// record intact so they can pay and tap Continue again.
    func resumePaidGeneration() {
        guard canResumePaidGeneration else { return }
        Analytics.capture("resume_paid_generation_tapped")
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-check entitlement against the freshest truth: refresh the
            // synchronous compute, and for a managed user also pull the
            // authoritative /entitlement snapshot (fail-open on a network blip).
            self.entitlements?.refresh()
            await self.entitlements?.refreshManagedEntitlement()
            // The user could have dismissed / started something during the await.
            guard self.canResumePaidGeneration else { return }

            // Still not entitled → route to the paywall, keep the held recording.
            guard self.entitlements?.canGenerate == true else {
                Analytics.capture("resume_paid_generation_paywalled")
                Log.billing.notice("resume: still not entitled — opening paywall, keeping held recording")
                AppDelegate.openPaywall()
                return
            }

            // Entitled now → reconstruct the recording from disk if it isn't
            // already in memory, then re-run generation. A missing/corrupt working
            // dir means the held recording is gone — clear it and fall back to idle.
            let processed: ProcessedRecording?
            if let inMemory = self.processedRecording {
                processed = inMemory
            } else if let pending = self.pendingPaidStore.load() {
                processed = try? ProcessedRecording.reconstruct(
                    workingDirectory: pending.workingDirectoryURL,
                    idempotencyKey: pending.idempotencyKey
                )
            } else {
                processed = nil
            }
            guard let processed else {
                Log.billing.error("resume: held recording missing/corrupt — clearing pending and resetting")
                self.discardPendingPaidGeneration()
                self.state = .idle
                return
            }

            Analytics.capture("resume_paid_generation_started")
            Log.billing.notice("resume: entitled — re-running generation against held recording")
            self.processedRecording = processed
            self.lastFailureDetail = nil
            // The success path clears the pending record (state didSet on `.done`);
            // a fresh paid block re-captures it.
            self.state = .processing
            self.runPromptGeneration(processed: processed)
        }
    }

    /// Deletes the held recording's working directory AND clears the persisted
    /// pointer + marker — the "give up on this recording" teardown. Resolves the
    /// directory from the in-memory recording when present, else from the
    /// persisted pointer (the restore-but-not-yet-reconstructed path). Best-effort.
    private func discardPendingPaidGeneration() {
        if let dir = processedRecording?.workingDirectory {
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: dir) }
        } else if let pending = pendingPaidStore.load() {
            let dir = pending.workingDirectoryURL
            Task.detached(priority: .utility) { WorkingDirectory.remove(at: dir) }
        }
        pendingPaidStore.clear()
    }

    /// Restores a held paid-blocked recording at launch (called from the launch
    /// path BEFORE the blanket sweep). If a pending record is persisted, fresh
    /// enough, and its working directory is intact with a readable manifest,
    /// rebuilds `processedRecording` and re-enters `.failed(reason:)` so the pill
    /// comes back up with Continue. Anything stale/missing/corrupt is cleared and
    /// we proceed normally. Returns true when a recording was restored (so the
    /// caller can skip the recovery/sweep that would otherwise run).
    @discardableResult
    func restorePendingPaidGenerationIfAny() -> Bool {
        guard state == .idle, let pending = pendingPaidStore.load() else { return false }
        // Drop a record that has outlived any plausible checkout.
        if Date().timeIntervalSince(pending.createdAt) > PendingPaidGenerationStore.maxAge {
            Log.billing.notice("restore: pending paid generation is stale — clearing")
            discardPendingPaidGeneration()
            return false
        }
        // Rebuild the recording from disk; a missing/corrupt working dir means the
        // held recording is gone.
        guard let processed = try? ProcessedRecording.reconstruct(
            workingDirectory: pending.workingDirectoryURL,
            idempotencyKey: pending.idempotencyKey
        ) else {
            Log.billing.notice("restore: held recording missing/corrupt — clearing pending")
            // Pointer clear only; if the dir exists but the manifest is unreadable
            // the launch sweep reclaims it (the marker no longer protects it).
            pendingPaidStore.clear()
            return false
        }
        processedRecording = processed
        recordingModelID = pending.modelID
        state = .failed(reason: pending.reason.failureReason)
        Log.billing.notice("restore: held paid recording restored — pill back with Continue")
        return true
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

    // MARK: - Error-tracker capture gating (Phase 13B)

    /// Whether a given mapped failure is worth reporting to the error tracker as a
    /// non-fatal event. Split from `failureReason` so the policy of
    /// "what counts as an engineering signal" lives in one place.
    ///
    /// Captured: reasons that indicate Zerro misbehaved (capture stack
    /// failed to start / interrupted mid-stream, audio-graph setup threw
    /// with a device present, local processing pipeline blew up, our own
    /// artifacts wouldn't read back off disk, provider returned
    /// malformed/decode-failing content). These are the ones we'd want
    /// to triage.
    ///
    /// NOT captured: reasons that are user- or environment-driven and
    /// already surfaced to the user with actionable copy (permission
    /// revoked, no microphone connected, disk full, recording too short,
    /// missing/invalid API key, network offline, provider rate-limit,
    /// provider 5xx outage). Reporting those would be noise — they're
    /// not bugs in Zerro, and an upstream outage must not be able to
    /// flood the dashboard.
    private static func shouldCapture(_ reason: RecordingFailureReason) -> Bool {
        switch reason {
        case .streamStartFailed, .writerStartFailed, .captureInterrupted,
             .audioSetupFailed,
             .processingFailed, .artifactUnreadable,
             .providerError:
            return true
        case .screenRecordingRevoked, .microphoneRevoked, .microphoneDisconnected,
             .microphoneUnavailable,
             .displayUnavailable, .displayChanged,
             .recordingTooShort, .diskFull,
             .apiKeyMissing, .apiAuth, .networkOffline, .rateLimited,
             .providerUnavailable, .responseTooLong,
             .outOfCredits, .subscriptionInactive,
             .trialVerificationRequired, .trialCreditsExhausted:
            return false
        }
    }

    /// Safe stringification of `reason` for the error-tracker `errorCode` property.
    /// Every `RecordingFailureReason` case is value-less, so
    /// `String(describing:)` yields just the case name
    /// ("processingFailed", "providerError", etc.) — a compile-time-
    /// bounded value with zero user content.
    private static func errorCodeString(_ reason: RecordingFailureReason) -> String {
        String(describing: reason)
    }

    // MARK: - Generation analytics helpers (Tier 1)

    /// Maps the internal `GenerationRoute` to the analytics `route` value
    /// (`managed` / `trial` / `byok`), or `nil` for `.trialNeedsEmail` — which
    /// dispatches no request, so it has no `generation_started`/latency.
    private static func analyticsRoute(for route: EntitlementStore.GenerationRoute) -> String? {
        switch route {
        case .managedProxy:    return "managed"
        case .trialProxy:      return "trial"
        case .local:           return "byok"
        case .trialNeedsEmail: return nil
        }
    }

    /// Milliseconds since `generationStartInstant`, for `latency_ms` on the
    /// generation outcomes. `nil` only if no start was recorded (defensive —
    /// every dispatched generation sets the instant first).
    private func generationLatencyMs() -> Int? {
        guard let start = generationStartInstant else { return nil }
        let components = (ContinuousClock.now - start).components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// A human-readable, privacy-safe description of a generation error, shown
    /// in the expanded failure card's body (decision 1 of the failure-card
    /// handoff). Pulls the carried detail out of a `ManagedGenerationError`
    /// where one exists; everything else falls back to `localizedDescription`.
    /// Privacy: every string returned here is a transport- or server-level
    /// error description — NEVER transcript or response content. Keep it that
    /// way; this is what gets rendered to the user.
    private static func failureDetail(from error: Error) -> String {
        if let managed = error as? ManagedGenerationError {
            switch managed {
            case .network(let detail):
                return detail
            case .inputRejected(let detail):
                return detail
            case .outOfCredits:
                return "The server reported your credits are spent."
            case .notEntitled:
                return "The server reported your subscription is no longer active."
            case .rateLimited:
                return "The generation service is rate-limiting requests right now."
            case .authFailed:
                return "Couldn\u{2019}t authenticate with the generation service."
            case .providerUnavailable:
                return "The generation service is temporarily unavailable."
            case .responseTruncated:
                return "The response was too long and got cut off before it finished."
            case .malformedResponse:
                return "The generation service returned an unexpected response."
            case .artifactUnreadable:
                return "Couldn\u{2019}t read the recording\u{2019}s files from disk."
            }
        }
        return error.localizedDescription
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
            case .noMicrophoneAvailable:
                // No device present — environmental, not captured.
                return .microphoneUnavailable
            case .audioInputSetupFailed:
                // Device present but our audio-graph setup threw —
                // engineering signal, captured.
                return .audioSetupFailed
            case .microphoneDisconnected:
                return .microphoneDisconnected
            case .selectedDisplayUnavailable:
                return .displayUnavailable
            case .recordedDisplayChanged:
                return .displayChanged
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
                return Self.networkClassReason(underlying)
            case .server:
                // 5xx — provider weather, not captured.
                return .providerUnavailable
            case .decodeFailure:
                // Response contract broke — captured.
                return .providerError
            }
        }
        if let pgError = error as? PromptGenerationError {
            switch pgError {
            case .missingAPIKey: return .apiKeyMissing
            case .auth:          return .apiAuth
            case .rateLimited:   return .rateLimited
            case .network(let underlying):
                return Self.networkClassReason(underlying)
            case .server:
                // 5xx — provider weather, not captured.
                return .providerUnavailable
            case .decodeFailure, .emptyContent:
                // Response contract broke — captured.
                return .providerError
            case .truncated:
                // Output-token limit hit — the partial output is withheld so a
                // half-formed fence can't leak (handoff-artifact-fence-leak).
                return .responseTooLong
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

    /// Classifies the `underlying` error of a BYOK service's `.network`
    /// case. That case is overloaded at the throw sites: URLSession
    /// transport failures AND local `Data(contentsOf:)` reads of our own
    /// frame/audio artifacts both arrive here, and they deserve opposite
    /// error-tracker treatment.
    ///
    ///   • URLError, offline-class  → `.networkOffline` (user's
    ///     connectivity; not captured)
    ///   • URLError, anything else  → `.providerUnavailable` (transport
    ///     weather between us and the provider; not captured)
    ///   • not a URLError           → `.artifactUnreadable` (local I/O on
    ///     files Zerro wrote — `Data(contentsOf:)` throws CocoaErrors,
    ///     never URLErrors; captured under its own errorCode)
    ///
    /// Out-of-space never reaches this: `failureReason` checks
    /// `isOutOfSpace` before any typed-error branch.
    private static func networkClassReason(_ underlying: Error) -> RecordingFailureReason {
        guard underlying is URLError else { return .artifactUnreadable }
        return isOfflineClass(underlying) ? .networkOffline : .providerUnavailable
    }

    /// Detects URLError codes that mean "the local machine couldn't
    /// reach the network" vs. "the network reached an unhappy server".
    /// Offline-class codes go to .networkOffline (actionable: check
    /// connection); other URLErrors fall through to .providerUnavailable
    /// via `networkClassReason`.
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
    /// successful run. Whisper is per-minute (round up to nearest fractional
    /// minute, the OpenAI billing model). Chat is per-token via
    /// `BYOKCostEstimator`, priced on the REQUESTED registry model id (a
    /// provider may report a dated alias the table doesn't carry — same rule
    /// as the server). An unpriced id logs honestly as unpriced.
    private static func logCost(audioDuration: CMTime, usage: TokenUsage, requestedModelID: String) {
        let durationSeconds = CMTimeGetSeconds(audioDuration)
        let whisperCost = OpenAITranscriptionService.estimatedCost(audioDurationSeconds: durationSeconds)
        let chatCost = BYOKCostEstimator.chatCostUSD(modelID: requestedModelID, usage: usage)
        // All cost lines: durations, model names, token counts, and
        // dollar amounts are .public — operational metrics with no user
        // content. Pre-format Doubles with String(format:) for terse
        // interpolation that's SDK-stable across Xcode versions.
        let durStr = String(format: "%.1fs", durationSeconds)
        let whisperStr = String(format: "$%.4f", whisperCost)
        let chatStr = chatCost.map { String(format: "$%.4f", $0) } ?? "unpriced"
        let totalStr = chatCost.map { String(format: "$%.4f", whisperCost + $0) } ?? "unpriced"
        Log.cost.info("whisper-1: audio=\(durStr, privacy: .public) → \(whisperStr, privacy: .public)")
        Log.cost.info(
            "\(usage.model, privacy: .public): in=\(usage.inputTokens, privacy: .public) out=\(usage.outputTokens, privacy: .public) → \(chatStr, privacy: .public)"
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
