//
//  DevModeTeardownSafetyTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 1, Milestone 7) — regression coverage for the teardown-safety
//  invariant surfaced by the adversarial review: a teardown that runs while an
//  agent dispatch is in flight must NEVER abandon the running agent or destroy
//  its undo. Concretely, `resetToIdle()` (reachable via the record-hotkey path)
//  must route through the safe terminate→revert, not the plain reset that only
//  cancels the (inert) Swift Task and discards the snapshot.
//

import XCTest
@testable import Zerro

@MainActor
final class DevModeTeardownSafetyTests: XCTestCase {

    func testIsDevBusyCoversDispatchAndReverting() {
        let app = AppState()
        // The dispatch tail + revert are all "busy" — the hotkey flashes instead
        // of starting a new recording over a live agent.
        for s in [RecordingState.devCheckpointing, .devAgentDispatching, .devAgentRunning, .devReverting] {
            app.state = s
            XCTAssertTrue(app.isDevBusy, "\(s) must read as dev-busy")
        }
        // Terminal + idle states are NOT busy.
        for s in [RecordingState.idle, .done, .devDone, .devFailed] {
            app.state = s
            XCTAssertFalse(app.isDevBusy, "\(s) must NOT read as dev-busy")
        }
    }

    func testResetToIdleDuringActiveDispatchRoutesThroughSafeCancel() async {
        let app = AppState()
        app.recordingIsDevMode = true
        app.state = .devAgentRunning

        // The OLD bug: resetToIdle() synchronously set `.idle` (abandoning the
        // agent + discarding the undo). The fix routes through the safe cancel,
        // which first flips to `.devReverting` (terminate → await → revert) — so
        // the state is NOT `.idle` immediately after the call.
        app.resetToIdle()
        XCTAssertEqual(app.state, .devReverting,
                       "reset during an active dispatch must route through safe-cancel, not plain-reset to idle")

        // With no checkpoint/agent to wait on, the async teardown then settles to
        // idle on its own.
        await settle { app.state == .idle }
        XCTAssertEqual(app.state, .idle)
        XCTAssertFalse(app.recordingIsDevMode, "dev state cleared after the safe teardown")
    }

    /// Spin the main actor until `condition` holds or a short budget elapses.
    private func settle(_ condition: () -> Bool, timeoutMs: Int = 1000) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }
}
