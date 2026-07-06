//
//  UpdaterRelaunchGateTests.swift
//  ZerroTests
//
//  I-02 — the Sparkle relaunch idle gate. The delegate's postpone core is
//  driven through injected fakes (a busy predicate + an idle-notifier that
//  records armed callbacks), so no SPUUpdater is constructed: busy postpones
//  and the relaunch block waits for the idle callback (then fires exactly
//  once, guarded against double idle-fires and overlapping postpone
//  requests); idle doesn't postpone. A selector-presence check pins the
//  Swift witness to Sparkle 2.9.2's ObjC selector — a signature drift would
//  otherwise silently unhook the gate (optional @objc protocol methods
//  don't get compiler-checked). AppState.onNextIdle is covered separately:
//  one-shot fire on the transition to .idle, immediate fire when already
//  idle.
//

import XCTest
@testable import Zerro

@MainActor
final class UpdaterRelaunchGateTests: XCTestCase {

    private func makeDelegate(
        isBusy: @escaping @MainActor () -> Bool,
        onNextIdle: @escaping @MainActor (_ callback: @escaping @MainActor () -> Void) -> Void
    ) -> UpdateWindowUpdaterDelegate {
        UpdateWindowUpdaterDelegate(
            currentWindowEnd: { nil },
            isBusy: isBusy,
            onNextIdle: onNextIdle
        )
    }

    // MARK: Delegate postpone core

    func testBusyPostponesUntilIdleThenRelaunchesExactlyOnce() {
        var armed: [@MainActor () -> Void] = []
        var relaunches = 0
        let delegate = makeDelegate(isBusy: { true }, onNextIdle: { armed.append($0) })

        XCTAssertTrue(delegate.shouldPostponeRelaunch(untilInvoking: { relaunches += 1 }))
        XCTAssertEqual(relaunches, 0, "the relaunch must wait for the idle transition")
        XCTAssertEqual(armed.count, 1)

        armed[0]() // AppState returns to .idle
        XCTAssertEqual(relaunches, 1)

        armed[0]() // a defensive double idle-fire must not relaunch twice
        XCTAssertEqual(relaunches, 1)
    }

    func testIdleDoesNotPostpone() {
        var relaunches = 0
        let delegate = makeDelegate(
            isBusy: { false },
            onNextIdle: { _ in XCTFail("no idle callback should be armed when already idle") }
        )
        XCTAssertFalse(delegate.shouldPostponeRelaunch(untilInvoking: { relaunches += 1 }))
        // Returning false means Sparkle itself performs the relaunch — the
        // delegate must not also invoke the handler.
        XCTAssertEqual(relaunches, 0)
    }

    func testSecondPostponeWhilePendingRelaunchesExactlyOnce() {
        var armed: [@MainActor () -> Void] = []
        var firstRelaunches = 0
        var secondRelaunches = 0
        let delegate = makeDelegate(isBusy: { true }, onNextIdle: { armed.append($0) })

        XCTAssertTrue(delegate.shouldPostponeRelaunch(untilInvoking: { firstRelaunches += 1 }))
        XCTAssertTrue(delegate.shouldPostponeRelaunch(untilInvoking: { secondRelaunches += 1 }))
        XCTAssertEqual(armed.count, 1, "an already-pending relaunch must not arm a second idle callback")

        armed.forEach { $0() }
        XCTAssertEqual(firstRelaunches + secondRelaunches, 1, "exactly one relaunch fires")
        XCTAssertEqual(secondRelaunches, 1, "the latest update cycle's handler wins")
    }

    func testPostponeAfterCompletedCycleArmsAgain() {
        var armed: [@MainActor () -> Void] = []
        var relaunches = 0
        let delegate = makeDelegate(isBusy: { true }, onNextIdle: { armed.append($0) })

        XCTAssertTrue(delegate.shouldPostponeRelaunch(untilInvoking: { relaunches += 1 }))
        armed[0]()
        XCTAssertEqual(relaunches, 1)

        // A fresh update cycle after the first completed is a new pending
        // relaunch — it arms its own idle callback.
        XCTAssertTrue(delegate.shouldPostponeRelaunch(untilInvoking: { relaunches += 1 }))
        XCTAssertEqual(armed.count, 2)
        armed[1]()
        XCTAssertEqual(relaunches, 2)
    }

    // MARK: Sparkle selector pin

    func testDelegateWitnessesSparklePostponeSelector() {
        let delegate = makeDelegate(isBusy: { false }, onNextIdle: { $0() })
        XCTAssertTrue(
            delegate.responds(to: Selector(("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:"))),
            "the Swift witness must match Sparkle's ObjC selector exactly or Sparkle never consults the gate"
        )
    }

    // MARK: AppState.onNextIdle

    func testOnNextIdleFiresOnIdleTransitionExactlyOnce() {
        let app = AppState()
        app.state = .recording
        var fired = 0
        app.onNextIdle { fired += 1 }
        XCTAssertEqual(fired, 0, "must wait for the idle transition")

        app.state = .idle
        XCTAssertEqual(fired, 1)

        // One-shot: not re-armed for later idle transitions.
        app.state = .recording
        app.state = .idle
        XCTAssertEqual(fired, 1)
    }

    func testOnNextIdleFiresImmediatelyWhenAlreadyIdle() {
        let app = AppState()
        var fired = 0
        app.onNextIdle { fired += 1 }
        XCTAssertEqual(fired, 1)
    }

    func testOnNextIdleFiresMultipleCallbacksInRegistrationOrder() {
        let app = AppState()
        app.state = .recording
        var order: [Int] = []
        app.onNextIdle { order.append(1) }
        app.onNextIdle { order.append(2) }
        app.state = .idle
        XCTAssertEqual(order, [1, 2])
    }
}
