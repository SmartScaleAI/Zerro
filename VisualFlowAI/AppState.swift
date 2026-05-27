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

    // MARK: - Transitions

    func startRecording() {
        timer?.invalidate()
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

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
            self.state = .done
        }
    }

    func cancelRecording() {
        timer?.invalidate()
        timer = nil
        elapsedSeconds = 0
        frameCount = 0
        state = .idle
    }

    func resetToIdle() {
        timer?.invalidate()
        timer = nil
        elapsedSeconds = 0
        frameCount = 0
        state = .idle
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
