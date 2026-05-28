//
//  AppState.swift
//  VisualFlowAI
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
//    2. RecentPrompt    — model for an entry in the recent-prompts list.
//    3. AppState        — @Observable @MainActor class that holds live
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

import Foundation
import SwiftUI

// MARK: - RecordingState

public enum RecordingState: Equatable {
    case idle
    case recording
    case wrappingUp
    case autoStopped
    case processing
    case done
    case failed(reason: RecordingFailureReason)
}

// MARK: - RecordingFailureReason

/// The shape of every way a recording can end badly. Each case carries
/// the underlying details if there are any (for logging) and the
/// `userMessage` projection renders the single-line string the pill
/// shows. Kept narrow — Phase 7 surfaces these as a flat message; a
/// later phase can branch on the case for richer recovery affordances.
public enum RecordingFailureReason: Equatable {
    case screenRecordingRevoked
    case microphoneRevoked
    case microphoneUnavailable
    case streamStartFailed
    case writerStartFailed
    case captureInterrupted

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
        }
    }
}

// MARK: - RecentPrompt

struct RecentPrompt: Identifiable {
    var id: UUID = UUID()
    var title: String
    var timestamp: Date
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {

    // MARK: Live State

    var state: RecordingState = .idle
    var elapsedSeconds: Double = 0
    var frameCount: Int = 0

    /// The region selected by the user via the area-selector overlay,
    /// stored at startRecording time and held for the duration of the
    /// session. Consumed by Phase 7's RecordingSession to scope the
    /// capture; `nil` started without a selection (e.g. tests).
    var activeSelection: SelectionRect?

    /// Path to the most recently finalized recording on disk. Set by
    /// `handleSessionFinish` when the writer completes successfully;
    /// cleared on cancel and on every new startRecording. Phase 8's
    /// processing pipeline reads this to drive frame extraction +
    /// audio analysis. For Phase 7 it's just held.
    var lastRecordingURL: URL?

    /// Index into `Self.processingSteps` for the currently-shown
    /// processing label. Cycled by a Task while `state == .processing`.
    var processingStepIndex: Int = 0

    /// User-driven toggle for the result pill's expanded variant.
    /// Reset on every new recording.
    var isResultExpanded: Bool = false

    // MARK: Result

    var resultPrompt: String = """
    Refactor the `UserProfileCard` React component in `src/components/profile/UserProfileCard.tsx` to address the following:

    1. Split the avatar, header, and stats sections into their own subcomponents under `src/components/profile/parts/`.
    2. Replace the local `useState` hooks tracking `isFollowing` and `followerCount` with a single `useReducer` so optimistic updates can be rolled back on API failure.
    3. Extract the inline `fetchUser` call into a new `useUserProfile(userId)` hook in `src/hooks/useUserProfile.ts` that returns `{ data, error, isLoading, refresh }`.
    4. Memoize the formatted join-date string with `useMemo` keyed on `user.createdAt`.
    5. Replace the existing CSS modules with Tailwind classes, matching the spacing tokens defined in `tailwind.config.ts`.
    6. Add a `Skeleton` loading state that mirrors the final layout instead of the current spinner.
    7. Ensure the component is fully accessible: avatar `<img>` needs an `alt`, the follow button needs `aria-pressed`, and stats should be in a `<dl>`.
    8. Add unit tests in `UserProfileCard.test.tsx` covering the loading, error, and follow/unfollow optimistic-update paths.

    Keep the public props API unchanged so existing call sites in `ProfilePage` and `UserSearchResult` continue to work without edits.
    """

    // MARK: Recents

    var recentPrompts: [RecentPrompt] = [
        RecentPrompt(
            title: "Refactor login flow to use OAuth",
            timestamp: Date().addingTimeInterval(-60 * 60 * 2)
        ),
        RecentPrompt(
            title: "Add dark mode toggle to settings",
            timestamp: Date().addingTimeInterval(-60 * 60 * 26)
        ),
        RecentPrompt(
            title: "Fix race condition in upload queue",
            timestamp: Date().addingTimeInterval(-60 * 60 * 49)
        ),
        RecentPrompt(
            title: "Migrate analytics events to new schema",
            timestamp: Date().addingTimeInterval(-60 * 60 * 72)
        ),
    ]

    // MARK: Internal

    /// The live capture session. Held strongly while recording so its
    /// callbacks (onElapsed, onFinish) stay valid; cleared on session
    /// completion / cancel so memory is reclaimed.
    private var recordingSession: RecordingSession?
    private var processingStepTask: Task<Void, Never>?

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

    /// The current processing-step label, cycled by `startProcessingStepRotation`.
    var processingStepLabel: String {
        Self.processingSteps[processingStepIndex % Self.processingSteps.count]
    }

    private static let processingSteps: [String] = [
        "Listening to your narration\u{2026}",
        "Looking at your screen\u{2026}",
        "Writing your prompt\u{2026}"
    ]

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
        microphoneDeviceID: String = ""
    ) {
        guard state == .idle else {
            NSLog("[AppState] startRecording ignored — state is %@", String(describing: state))
            return
        }
        cancelProcessingStepRotation()
        isResultExpanded = false
        activeSelection = selection
        lastRecordingURL = nil
        elapsedSeconds = 0
        frameCount = 0

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
            } catch {
                NSLog("[AppState] session.start() failed: %@", String(describing: error))
                guard let self, self.recordingSession === session else { return }
                self.recordingSession = nil
                self.activeSelection = nil
                self.state = .failed(reason: Self.failureReason(from: error))
            }
        }
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
        // resets the UI.
        recordingSession = nil
        cancelProcessingStepRotation()
        elapsedSeconds = 0
        frameCount = 0
        isResultExpanded = false
        activeSelection = nil
        lastRecordingURL = nil
        state = .idle
    }

    func resetToIdle() {
        recordingSession?.cancel()
        recordingSession = nil
        cancelProcessingStepRotation()
        elapsedSeconds = 0
        frameCount = 0
        isResultExpanded = false
        activeSelection = nil
        lastRecordingURL = nil
        state = .idle
    }

    // MARK: - Session callbacks

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
        switch outcome {
        case .finished(let url):
            lastRecordingURL = url
            // Move into the mock processing flow. Phase 8 replaces
            // this fake 4s sleep with real frame extraction +
            // model calls; for Phase 7 the placeholder result is
            // still the right user-visible outcome.
            state = .processing
            startProcessingStepRotation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
                guard let self, self.state == .processing else { return }
                self.cancelProcessingStepRotation()
                self.state = .done
            }
        case .cancelled:
            cancelProcessingStepRotation()
            elapsedSeconds = 0
            frameCount = 0
            isResultExpanded = false
            activeSelection = nil
            lastRecordingURL = nil
            state = .idle
        case .failed(let error):
            NSLog("[AppState] session failed: %@", String(describing: error))
            cancelProcessingStepRotation()
            elapsedSeconds = 0
            frameCount = 0
            isResultExpanded = false
            activeSelection = nil
            lastRecordingURL = nil
            state = .failed(reason: Self.failureReason(from: error))
        }
    }

    /// User-driven dismissal of the failure pill. Same as cancel —
    /// returns to .idle so the next hotkey press starts cleanly.
    func dismissFailure() {
        guard case .failed = state else { return }
        resetToIdle()
    }

    /// Maps a RecordingSession.SessionError (or anything else) into the
    /// user-facing failure taxonomy. Centralized here so the SessionError
    /// → RecordingFailureReason mapping doesn't drift across the two
    /// failure sites (start-time + mid-session).
    private static func failureReason(from error: Error) -> RecordingFailureReason {
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
        // Anything else came from SCStream / AVCaptureSession runtime
        // — treat as a generic capture interruption. The most common
        // path here is the user revoking Screen Recording mid-session,
        // which SCStream reports as a permission-domain NSError; a
        // later phase can branch on the error code to surface the
        // .screenRecordingRevoked / .microphoneRevoked variants.
        return .captureInterrupted
    }

    func toggleResultExpanded() {
        isResultExpanded.toggle()
    }

    // MARK: - Processing step rotation

    private func startProcessingStepRotation() {
        processingStepTask?.cancel()
        processingStepIndex = 0
        processingStepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard let self, !Task.isCancelled, self.state == .processing else { return }
                self.processingStepIndex += 1
            }
        }
    }

    private func cancelProcessingStepRotation() {
        processingStepTask?.cancel()
        processingStepTask = nil
    }

    // MARK: - Display

    var elapsedDisplay: String {
        let total = Int(elapsedSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
