//
//  DevRingActiveTests.swift
//  ZerroTests
//
//  Dev Mode — the pulsing green screen-edge ring's single source of truth,
//  `AppState.devRingActive` (driven by `DevRingWindowController`). The ring must
//  be visible while, and ONLY while, the agent is actually allowed to edit:
//  from `.devAgentDispatching` (emitted right after the confirm gate resolves and
//  the checkpoint is taken, for BOTH permission modes) through `.devAgentRunning`.
//  It must be hidden everywhere else — crucially during `.devCheckpointing` and
//  `.reviewingPrompt` (BEFORE dispatch, so it never shows while the Ask Permission
//  review card is up) and on every stop side (done/failed/reverting/idle), so the
//  ring can never appear outside an active run or outlive it.
//

import XCTest
@testable import Zerro

@MainActor
final class DevRingActiveTests: XCTestCase {

    func testRingActiveOnlyDuringDispatchAndRunningWindow() {
        let app = AppState()
        // The active agent-run window — the ring pulses here.
        for s in [RecordingState.devAgentDispatching, .devAgentRunning] {
            app.state = s
            XCTAssertTrue(app.devRingActive, "\(s) must show the ring")
        }
    }

    func testRingHiddenBeforeDispatchAndOnEveryStopSide() {
        let app = AppState()
        // BEFORE dispatch (checkpointing + the Ask Permission review gate) and
        // every stop side (completion, failure, revert, idle/teardown).
        let hidden: [RecordingState] = [
            .idle, .recording, .processing, .done,
            .devCheckpointing,   // before dispatch
            .reviewingPrompt,    // review card up — not yet accepted
            .devDone, .devFailed, .devReverting,
            .confirmingDevRecovery,
        ]
        for s in hidden {
            app.state = s
            XCTAssertFalse(app.devRingActive, "\(s) must NOT show the ring")
        }
    }
}
