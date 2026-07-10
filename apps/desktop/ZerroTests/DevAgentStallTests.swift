//
//  DevAgentStallTests.swift
//  ZerroTests
//
//  G-08 — the hung-agent stall notification is wired to a Cancel affordance.
//  The runner fires `onStall(true)` after `timeouts.stall` seconds of agent
//  silence (and `false` on the next output); AppState now forwards that into
//  the observable `devAgentStalled` flag, and the `.devAgentRunning` pill
//  swaps its substatus for a non-alarming "Agent seems stuck — Cancel?" nudge
//  toward the pill's EXISTING Cancel (the SIGTERM→SIGKILL safe cancel).
//  Advisory by contract: nothing is ever auto-killed on a stall.
//
//  Pins the unit-reachable core — the flag/state logic and the pill-model
//  mapping. The runner→coordinator→AppState closure plumbing and the PillView
//  button wiring are review-verified (they need a live agent process).
//

import XCTest
@testable import Zerro

@MainActor
final class DevAgentStallTests: XCTestCase {

    // MARK: - The observable flag

    func testStallHandlerTogglesFlag() {
        let app = AppState()
        XCTAssertFalse(app.devAgentStalled, "no stall at rest")
        app.applyDevAgentStall(true)
        XCTAssertTrue(app.devAgentStalled, "a stall notification raises the flag")
        app.applyDevAgentStall(false)
        XCTAssertFalse(app.devAgentStalled, "the next output clears it")
    }

    // MARK: - The pill affordance

    func testStalledRunningPillShowsCancelNudge() {
        let app = AppState()
        app.state = .devAgentRunning
        app.applyDevAgentStall(true)
        guard case .devProgress(let label, let cancellable)? = app.pillState else {
            return XCTFail("expected .devProgress for .devAgentRunning")
        }
        XCTAssertTrue(label.contains("seems stuck"), "the stalled pill nudges, got: \(label)")
        XCTAssertTrue(label.contains("Cancel?"), "…toward Cancel, got: \(label)")
        XCTAssertTrue(cancellable, "the existing Cancel control IS the affordance — it must stay")
    }

    func testResumeRestoresTheSubstatusLabel() {
        let app = AppState()
        app.state = .devAgentRunning
        app.applyDevAgentStall(true)
        app.applyDevAgentStall(false)   // the agent produced output again
        guard case .devProgress(let label, _)? = app.pillState else {
            return XCTFail("expected .devProgress for .devAgentRunning")
        }
        XCTAssertFalse(label.contains("stuck"), "resume restores the normal label, got: \(label)")
    }

    // MARK: - Advisory only (notify, never kill)

    func testStallLeavesTheRunRunning() {
        let app = AppState()
        app.state = .devAgentRunning
        app.applyDevAgentStall(true)
        XCTAssertEqual(app.state, .devAgentRunning, "a stall is advisory — it must not end the run")
    }

    // MARK: - Cancel-path interplay

    func testCancelFromStalledPillRoutesToSafeCancelAndDropsLateStalls() {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .devAgentRunning
        app.applyDevAgentStall(true)

        // The pill's Cancel invokes cancelRecording (PillWindowController
        // wiring), which routes an active dispatch to the safe cancel.
        app.cancelRecording()
        XCTAssertEqual(app.state, .devReverting, "Cancel routes to the SIGTERM→SIGKILL safe cancel")
        XCTAssertFalse(app.devAgentStalled, "the cancel supersedes the stall nudge")

        // A late stall notification from the SIGTERM grace window is dropped —
        // it must not resurrect the nudge mid-cancel.
        app.applyDevAgentStall(true)
        XCTAssertFalse(app.devAgentStalled, "mid-cancel stall notifications are ignored")
    }

    // MARK: - Teardown hygiene

    func testTeardownClearsTheFlag() {
        let app = AppState()
        app.devAgentStalled = true
        app.state = .idle
        app.resetToIdle()
        XCTAssertFalse(app.devAgentStalled, "every teardown clears the stall flag")
    }
}
