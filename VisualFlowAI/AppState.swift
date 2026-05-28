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
//    1. DEMO_TIME_SCALE — global time-compression knob for demos.
//    2. RecordingState  — the discrete UI states the app can be in.
//    3. RecentPrompt    — model for an entry in the recent-prompts list.
//    4. AppState        — @Observable @MainActor class that holds live
//                          state, drives a 0.1s ticker, and exposes the
//                          transitions (start/stop/cancel/reset).
//

import Foundation
import SwiftUI

// MARK: - Demo Time Scale

/// Multiplier applied to the elapsed-time ticker.
/// Set to 1.0 for real 3-minute timing.
/// Set to 12.0 for fast demo (a 3-minute recording compresses to ~15 seconds).
let DEMO_TIME_SCALE: Double = 12.0

// MARK: - RecordingState

public enum RecordingState {
    case idle
    case recording
    case wrappingUp
    case autoStopped
    case processing
    case done
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

    private var timer: Timer?
    private var processingStepTask: Task<Void, Never>?

    // MARK: - Derived

    /// True while the menu-bar icon and pill should both reflect the
    /// "active recording" identity. Defined in one place so the
    /// MenuBarExtra label and the pill bridge agree.
    var isRecordingActive: Bool {
        state == .recording || state == .wrappingUp || state == .autoStopped
    }

    /// Total recording budget, pre-formatted for the pill timer chip.
    /// Matches the 180s threshold the ticker enforces below.
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

    func startRecording() {
        timer?.invalidate()
        cancelProcessingStepRotation()
        isResultExpanded = false
        state = .recording
        elapsedSeconds = 0
        frameCount = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stopRecording() {
        timer?.invalidate()
        timer = nil
        state = .processing
        startProcessingStepRotation()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
            guard let self else { return }
            self.cancelProcessingStepRotation()
            self.state = .done
        }
    }

    func cancelRecording() {
        timer?.invalidate()
        timer = nil
        cancelProcessingStepRotation()
        elapsedSeconds = 0
        frameCount = 0
        isResultExpanded = false
        state = .idle
    }

    func resetToIdle() {
        timer?.invalidate()
        timer = nil
        cancelProcessingStepRotation()
        elapsedSeconds = 0
        frameCount = 0
        isResultExpanded = false
        state = .idle
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

    // MARK: - Ticker

    private func tick() {
        elapsedSeconds += 0.1 * DEMO_TIME_SCALE
        frameCount = Int(elapsedSeconds / 3.0)

        if state == .recording && elapsedSeconds >= 150 {
            state = .wrappingUp
        }

        if state == .wrappingUp && elapsedSeconds >= 180 {
            state = .autoStopped
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.stopRecording()
            }
        }
    }

    // MARK: - Display

    var elapsedDisplay: String {
        let total = Int(elapsedSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
