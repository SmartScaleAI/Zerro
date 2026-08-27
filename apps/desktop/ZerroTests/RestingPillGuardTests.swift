//
//  RestingPillGuardTests.swift
//  ZerroTests
//
//  The record-hotkey "resting pill" guard. The hotkey may only start a new
//  session from a clean slate (`.idle`); in any terminal pill state it must
//  flash the existing pill instead of tearing it down. `handleHotkey` reads
//  `AppState.isShowingRestingPill` to make that call, so these pin the four
//  blocking states (`.done`, `.failed`, `.devDone`, `.devFailed`) and confirm
//  the non-terminal/in-flight states (covered by other guards) are NOT caught
//  here — particularly `.idle`, which must still start a new session.
//

import XCTest
@testable import Zerro

@MainActor
final class RestingPillGuardTests: XCTestCase {

    func testRestingPillStatesBlock() {
        let app = AppState()

        // The four terminal "resolve the pill first" states.
        app.state = .done
        XCTAssertTrue(app.isShowingRestingPill, ".done (success result pill) must block")

        app.state = .failed(reason: .apiKeyMissing)
        XCTAssertTrue(app.isShowingRestingPill, ".failed (error pill) must block")

        app.state = .devDone
        XCTAssertTrue(app.isShowingRestingPill, ".devDone (changes-applied card) must block")

        app.state = .devFailed
        XCTAssertTrue(app.isShowingRestingPill, ".devFailed (agent-failure card) must block")
    }

    func testFailedBlocksRegardlessOfReason() {
        let app = AppState()
        // Every `.failed` payload renders an error pill (compact, expanded, or
        // open-settings) — the reason must not change the guard's verdict.
        for reason in [RecordingFailureReason.networkOffline,
                       .apiKeyMissing,
                       .recordingTooShort] {
            app.state = .failed(reason: reason)
            XCTAssertTrue(app.isShowingRestingPill, "\(reason) must block")
        }
    }

    func testNonRestingStatesDoNotBlock() {
        let app = AppState()

        // The clean slate — the hotkey must start a new session from here.
        app.state = .idle
        XCTAssertFalse(app.isShowingRestingPill, ".idle must NOT block — it starts a new session")

        // In-flight / active states are caught by their own guards
        // (isRecordingActive, .processing, isDevBusy), never by this one.
        for state in [RecordingState.recording,
                      .wrappingUp,
                      .autoStopped,
                      .processing,
                      .confirmingRecovery,
                      .devCheckpointing,
                      .reviewingPrompt,
                      .devAgentDispatching,
                      .devAgentRunning,
                      .devReverting,
                      .confirmingDevRecovery] {
            app.state = state
            XCTAssertFalse(app.isShowingRestingPill, "\(state) is not a resting pill")
        }
    }
}
