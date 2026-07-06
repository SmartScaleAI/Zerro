//
//  MidSessionRevocationGuardTests.swift
//  ZerroTests
//
//  F-11 — the mid-session revocation handler must never discard a COMPLETED
//  recording.
//
//  `AppState.handleMidSessionRevocation` used to tear down unconditionally:
//  a TCC flip observed during the auto-stop finalize window (`.autoStopped`,
//  where capture already completed and the writer is finishing the FULL
//  recording) cancelled the session, reset the transient state, and set
//  `.failed` — whose short-circuit in `handleSessionFinish` then orphaned the
//  finished file. Data loss for a fully-captured recording.
//
//  The guard set pinned here: destructive teardown runs ONLY while capture is
//  genuinely live — `state` is `.recording` or `.wrappingUp` (both still
//  appending samples) AND the session's capture is live (false during ANY
//  finalize, including a manual stop's, where `state` deliberately stays
//  `.recording`/`.wrappingUp`). `.autoStopped` is protected unconditionally.
//
//  Seams: `app.state` / `app.recordingSession` are set directly; the session
//  is a real but UNSTARTED `RecordingSession` (lifecycle `.idle`, so
//  `cancel()`/`stop()` on it are no-ops — it exists to satisfy the handler's
//  session guard and to observe whether teardown nils it out).
//  `captureLivenessProvider` injects the liveness read, since a genuinely
//  `.running` session needs TCC grants a unit test doesn't have.
//

import XCTest
@testable import Zerro

@MainActor
final class MidSessionRevocationGuardTests: XCTestCase {

    /// A real but never-started session: enough to pass the handler's
    /// `let session = recordingSession` guard, inert on cancel/stop.
    private func makeUnstartedSession() -> RecordingSession {
        RecordingSession(
            selection: nil,
            microphoneDeviceID: "",
            onElapsed: { _ in },
            onFinish: { _ in }
        )
    }

    private func makeApp(state: RecordingState, captureIsLive: Bool) -> AppState {
        let app = AppState()
        app.recordingSession = makeUnstartedSession()
        app.captureLivenessProvider = { captureIsLive }
        app.state = state
        app.elapsedSeconds = 180
        return app
    }

    // MARK: - The finalize window is protected

    /// The F-11 headline: a revocation landing in the auto-stop finalize
    /// window (`.autoStopped` — capture done, writer finishing) must NOT
    /// cancel the session and must NOT set `.failed`. The session survives so
    /// the normal finalize path (`handleSessionFinish` → `.processing`) can
    /// produce the completed recording. `captureIsLive` is false here exactly
    /// as in production (the `.autoStopped` transition already called
    /// `session.stop()`).
    func testAutoStopFinalizeRevocationDoesNotDiscard() {
        let app = makeApp(state: .autoStopped, captureIsLive: false)

        app.handleMidSessionRevocation(.screenRecordingRevoked)

        XCTAssertEqual(app.state, .autoStopped, "the completed recording must proceed to finalize, not fail")
        XCTAssertNotNil(app.recordingSession, "teardown must not run — the session is mid-finalize")
        // resetTransientRecordingState never ran: the elapsed clock is intact.
        XCTAssertEqual(app.elapsedSeconds, 180)
    }

    /// Belt-and-suspenders on the state check: `.autoStopped` is protected
    /// even if the liveness read were (wrongly) still true — the state-level
    /// guard alone must hold if the stop()-before-transition coupling ever
    /// loosens.
    func testAutoStoppedIsProtectedRegardlessOfLivenessRead() {
        let app = makeApp(state: .autoStopped, captureIsLive: true)

        app.handleMidSessionRevocation(.microphoneRevoked)

        XCTAssertEqual(app.state, .autoStopped)
        XCTAssertNotNil(app.recordingSession)
    }

    /// The same completed-capture invariant covers a MANUAL stop's finalize:
    /// `stopRecording` leaves `state == .recording`/`.wrappingUp` while the
    /// writer finishes, so only the liveness read distinguishes that window
    /// from live capture. A revocation there must also preserve the recording.
    func testManualStopFinalizeRevocationDoesNotDiscard() {
        for state in [RecordingState.recording, .wrappingUp] {
            let app = makeApp(state: state, captureIsLive: false)

            app.handleMidSessionRevocation(.screenRecordingRevoked)

            XCTAssertEqual(app.state, state, "finalizing after manual stop in \(state) must not fail")
            XCTAssertNotNil(app.recordingSession)
        }
    }

    // MARK: - Live capture still fails + discards

    /// A genuine revocation during live capture keeps the pre-F-11 behavior:
    /// the session is cancelled (partial discarded), transient state reset,
    /// and the dedicated failure copy shown immediately.
    func testLiveRecordingRevocationStillFailsAndDiscards() {
        let app = makeApp(state: .recording, captureIsLive: true)

        app.handleMidSessionRevocation(.screenRecordingRevoked)

        XCTAssertEqual(app.state, .failed(reason: .screenRecordingRevoked))
        XCTAssertNil(app.recordingSession, "the live session must be torn down")
        XCTAssertEqual(app.elapsedSeconds, 0, "transient recording state must be reset")
    }

    /// `.wrappingUp` (150–180s) is still live capture — samples are still
    /// being appended — so a genuine revocation there fails exactly like
    /// `.recording`, carrying the mic-specific copy through untouched.
    func testWrappingUpRevocationStillFailsAndDiscards() {
        let app = makeApp(state: .wrappingUp, captureIsLive: true)

        app.handleMidSessionRevocation(.microphoneRevoked)

        XCTAssertEqual(app.state, .failed(reason: .microphoneRevoked))
        XCTAssertNil(app.recordingSession)
    }

    // MARK: - The pure predicate

    /// The guard set, pinned exhaustively over the states the handler can see
    /// (its `isRecordingActive` guard already returns for everything else):
    /// destructive iff live-capture state AND capture live.
    func testShouldFailPredicateGuardSet() {
        XCTAssertTrue(AppState.shouldFailOnMidSessionRevocation(state: .recording, captureIsLive: true))
        XCTAssertTrue(AppState.shouldFailOnMidSessionRevocation(state: .wrappingUp, captureIsLive: true))
        // Any finalize (capture no longer live) is protected…
        XCTAssertFalse(AppState.shouldFailOnMidSessionRevocation(state: .recording, captureIsLive: false))
        XCTAssertFalse(AppState.shouldFailOnMidSessionRevocation(state: .wrappingUp, captureIsLive: false))
        // …and `.autoStopped` is protected no matter what liveness reads.
        XCTAssertFalse(AppState.shouldFailOnMidSessionRevocation(state: .autoStopped, captureIsLive: false))
        XCTAssertFalse(AppState.shouldFailOnMidSessionRevocation(state: .autoStopped, captureIsLive: true))
    }
}
