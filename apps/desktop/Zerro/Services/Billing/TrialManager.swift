//
//  TrialManager.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Overview
//  --------
//  The local free-trial clock for OFFICIAL builds. A small, testable type
//  that OWNS the trial's two persisted dates and derives a `TrialStatus`
//  from them. It holds no UI state: `EntitlementStore` calls `evaluate()`
//  and maps the result onto an `EntitlementState`. Community builds never
//  construct a use for it — their entitlement store never starts, reads,
//  or evaluates the clock (see `EntitlementEnforcementMode`).
//
//  Everything here is LOCAL. No networking, no account, no email, no card,
//  no LemonSqueezy, no license validation — the clock is two Keychain reads
//  plus arithmetic.
//
//  Persistence (Keychain — see `KeychainStore.trialStartDate` /
//  `.trialMaxDateSeen`)
//  --------------------------------------------------------------------
//  • trialStartDate — the instant the trial began. Written ONCE, on first
//    launch, only if absent; NEVER overwritten. It lives in the Keychain
//    (not UserDefaults / @AppStorage) precisely so it survives an app
//    uninstall/reinstall: the OS keeps generic-password items past app
//    deletion, so reinstalling resumes the same trial rather than granting
//    a fresh clock. (Same signing identity required — see the KeychainStore
//    header for the signing-scope caveat.)
//  • maxDateSeen — the latest wall-clock instant the app has ever observed.
//    Updated to `max(stored, now)` on every `evaluate()`. This is the
//    clock-ROLLBACK hardening: elapsed time is measured against
//    `max(now, maxDateSeen)`, so winding the system clock backward cannot
//    rewind the trial, and winding it far forward correctly expires it (and
//    pins the higher ceiling so it stays expired).
//
//  Both values are stored as EPOCH SECONDS encoded as a decimal string
//  (e.g. "1717200000"). Epoch seconds is locale-proof and trivially
//  comparable; whole-second granularity is far finer than the whole-DAY
//  granularity the trial counts in, so the truncation is irrelevant.
//
//  Day counting (documented so the boundary is unambiguous)
//  --------------------------------------------------------
//  A "day" is a whole 86 400-second block measured from the start instant.
//  `daysRemaining = trialLengthDays − floor(elapsed / 86 400)`, and the
//  trial is `.expired` exactly when `elapsed >= trialLengthDays × 86 400`.
//  So a trial started at ANY time on day 0 reads "14 days left" until a full
//  24 h passes, then "13", … and "1 day left" through the final 24-h block,
//  flipping straight to `.expired` at the 14-day instant. There is no
//  "0 days left but still recordable" state, and no "1 day left" lingering
//  the instant of expiry. (`TrialManagerTests` pins both sides of the
//  boundary.)
//
//  Fail-open (binding, mirrors `EntitlementStore.refresh()`'s contract)
//  --------------------------------------------------------------------
//  For BOTH slots: a read that GENUINELY FAILS (a `.failure` result, not a
//  `.absent` one) and a present-but-unparseable value (corruption) each
//  resolve TOWARD granting the trial (a full `trialLengthDays`), never
//  `.expired`, and the stored value is never overwritten — the truth may
//  merely be momentarily unreadable. Only `.absent` means "nothing stored":
//  first launch for the start date, and a fresh ceiling initialization for
//  maxDateSeen. A false lockout over a transiently-unreadable Keychain is
//  far more corrosive than a few extra free days. Only a real elapsed-time
//  expiry yields `.expired`.
//

import Foundation
import os

@MainActor
final class TrialManager {

    // MARK: - Constants

    /// Trial length in whole days. The single source of truth — never write
    /// `14` inline elsewhere.
    static let trialLengthDays = 14

    /// Seconds in a trial "day". Named so the day-counting math reads clearly.
    private static let secondsPerDay: TimeInterval = 86_400

    // MARK: - TrialStatus

    /// The clock's verdict, internal to the billing layer. `EntitlementStore`
    /// maps this onto `EntitlementState` (`.active` → `.localTrial`,
    /// `.expired` → `.localTrialExpired`); nothing outside billing sees this
    /// type.
    enum TrialStatus: Equatable {
        /// Trial is live with `daysRemaining` whole days left (1…trialLengthDays).
        case active(daysRemaining: Int)
        /// Trial has elapsed.
        case expired
    }

    // MARK: - Dependencies

    private let startDateSlot: KeychainSlot
    private let maxDateSeenSlot: KeychainSlot
    /// Injectable wall clock. Production passes `Date.init`; tests pass a
    /// controllable closure so rollback / far-forward / boundary cases are
    /// deterministic.
    private let clock: () -> Date

    // MARK: - Init

    /// `nil` slot arguments resolve to the real Keychain slots inside the
    /// (MainActor) body — passing the `KeychainStore` statics as default
    /// argument *expressions* would evaluate them in a nonisolated context
    /// and trip MainActor isolation. Tests/previews pass in-memory fakes.
    /// Construction performs NO Keychain access; only `startTrialIfNeeded()`
    /// and `evaluate()` touch the slots.
    init(
        startDateSlot: KeychainSlot? = nil,
        maxDateSeenSlot: KeychainSlot? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.startDateSlot = startDateSlot ?? KeychainStore.trialStartDate
        self.maxDateSeenSlot = maxDateSeenSlot ?? KeychainStore.trialMaxDateSeen
        self.clock = clock
    }

    // MARK: - Public API

    /// Establishes the trial start on first launch. If `trialStartDate` is
    /// absent, writes `now` to BOTH slots. Idempotent: a present (or even an
    /// unreadable) start date is a no-op, so the trial is never reset.
    ///
    /// On a `.failure` read we deliberately do NOT write: the value may
    /// actually exist but be momentarily unreadable, and writing would
    /// silently reset the trial (and could hand a lapsed user a fresh clock
    /// on every flaky read). `evaluate()` handles the grant side of
    /// fail-open; this side just refuses to clobber.
    func startTrialIfNeeded() {
        switch startDateSlot.readResult() {
        case .found:
            return
        case .failure(let status):
            Log.state.error("trial: start-date read failed (\(status, privacy: .public)) — not initializing, deferring to fail-open")
            return
        case .absent:
            let stamp = encode(clock())
            startDateSlot.write(stamp)
            maxDateSeenSlot.write(stamp)
            Log.state.notice("trial: first launch — started \(Self.trialLengthDays, privacy: .public)-day trial")
        }
    }

    /// The heart of the clock. Reads the persisted dates, applies the
    /// rollback ceiling, and returns whole-day `.active` / `.expired`.
    /// See the file header for the fail-open and day-counting rules.
    func evaluate() -> TrialStatus {
        // 1. Resolve the start date, honoring fail-open.
        let startDate: Date
        switch startDateSlot.readResult() {
        case .failure(let status):
            // Genuine read error → fail OPEN. Grant the full trial; touch
            // nothing (we don't want to pin a ceiling off a bad read).
            Log.state.error("trial: start-date read failed (\(status, privacy: .public)) — failing open, granting full trial")
            return .active(daysRemaining: Self.trialLengthDays)

        case .absent:
            // Effectively first launch. Establish the clock, then read it
            // back; if the write didn't take, fail open rather than guess.
            startTrialIfNeeded()
            guard case .found(let raw) = startDateSlot.readResult(),
                  let date = decode(raw) else {
                Log.state.error("trial: start-date still unreadable after init — failing open")
                return .active(daysRemaining: Self.trialLengthDays)
            }
            startDate = date

        case .found(let raw):
            guard let date = decode(raw) else {
                // Present but unparseable — corruption. Fail open (and do
                // not overwrite: see `startTrialIfNeeded`).
                Log.state.error("trial: start-date unparseable — failing open")
                return .active(daysRemaining: Self.trialLengthDays)
            }
            startDate = date
        }

        // 2. Rollback hardening: effectiveNow = max(now, maxDateSeen), and
        // persist the (non-decreasing) ceiling. Same fail-open contract as
        // the start date: a genuine read failure or a corrupted value grants
        // the full trial and never overwrites the slot; only a definitive
        // `.absent` initializes the ceiling at `now`.
        var effectiveNow = clock()
        switch maxDateSeenSlot.readResult() {
        case .failure(let status):
            Log.state.error("trial: maxDateSeen read failed (\(status, privacy: .public)) — failing open, granting full trial")
            return .active(daysRemaining: Self.trialLengthDays)
        case .found(let raw):
            guard let seen = decode(raw) else {
                Log.state.error("trial: maxDateSeen unparseable — failing open")
                return .active(daysRemaining: Self.trialLengthDays)
            }
            if seen > effectiveNow { effectiveNow = seen }
            maxDateSeenSlot.write(encode(effectiveNow))
        case .absent:
            maxDateSeenSlot.write(encode(effectiveNow))
        }

        // 3. Whole-day arithmetic.
        let elapsed = effectiveNow.timeIntervalSince(startDate)
        let status = Self.status(forElapsed: elapsed)
        Log.state.info("trial: evaluate → \(String(describing: status), privacy: .public) (elapsed \(Int(elapsed), privacy: .public)s)")
        return status
    }

    // MARK: - Day math

    /// Pure elapsed-seconds → status mapping. Factored out (and `static`) so
    /// the boundary is unit-testable without any Keychain. See the file
    /// header for the exact day-counting contract.
    static func status(forElapsed elapsed: TimeInterval) -> TrialStatus {
        let total = TimeInterval(trialLengthDays) * secondsPerDay
        guard elapsed < total else { return .expired }
        // Subtract only WHOLE elapsed days, so any partial day in progress
        // still counts as remaining: [0, 86 400) → 14, [86 400, 172 800) → 13…
        let fullDaysElapsed = Int(floor(elapsed / secondsPerDay))
        let remaining = trialLengthDays - fullDaysElapsed
        // Clamp defensively: a negative `elapsed` (start in the future,
        // shouldn't happen under the rollback ceiling) reads as a full trial
        // rather than something nonsensical.
        return .active(daysRemaining: min(max(remaining, 1), trialLengthDays))
    }

    // MARK: - Encoding

    /// Epoch seconds as a decimal string. Whole seconds — finer than the
    /// day granularity we count in, and locale-independent.
    private func encode(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private func decode(_ raw: String) -> Date? {
        guard let seconds = Int(raw) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: - Preview / test support
    //
    // Non-`#if DEBUG` because `#Preview` blocks compile in every build
    // configuration. Constructs a clock backed by fresh in-memory slots so
    // SwiftUI previews never read or write the real Keychain.

    /// An in-memory trial clock that reads as `startedDaysAgo` days into the
    /// trial (0 → fresh full trial, ≥ trialLengthDays → expired).
    static func inMemory(startedDaysAgo: Int = 0) -> TrialManager {
        let startSlot = InMemoryKeychainSlot()
        let maxSlot = InMemoryKeychainSlot()
        let manager = TrialManager(startDateSlot: startSlot, maxDateSeenSlot: maxSlot)
        let start = manager.clock().addingTimeInterval(-TimeInterval(startedDaysAgo) * secondsPerDay)
        startSlot.write(manager.encode(start))
        maxSlot.write(manager.encode(manager.clock()))
        return manager
    }

    // MARK: - Dev clock controls (DEBUG only)
    //
    // Manipulate the underlying persisted clock so the REAL `evaluate()` can
    // be driven to any state without waiting days or hand-editing the
    // Keychain. Distinct from `EntitlementStore.devSetState`, which forces a
    // state directly; these move the clock so you can watch `refresh()`
    // derive the state.

    #if DEBUG
    /// Rewrites both slots to `now` — a clean, full-length trial.
    func devResetTrial() {
        let stamp = encode(clock())
        startDateSlot.write(stamp)
        maxDateSeenSlot.write(stamp)
        Log.state.notice("trial DEV: reset to \(Self.trialLengthDays, privacy: .public) days")
    }

    /// Forces expiry: start = now − (trialLengthDays days + 1 h slack), and
    /// pins maxDateSeen to `now` so the rollback ceiling can't un-expire it.
    func devExpireTrial() {
        let slack: TimeInterval = 3600
        let start = clock().addingTimeInterval(-(TimeInterval(Self.trialLengthDays) * Self.secondsPerDay + slack))
        startDateSlot.write(encode(start))
        maxDateSeenSlot.write(encode(clock()))
        Log.state.notice("trial DEV: expired now")
    }

    /// Deletes both slots — simulates a truly-fresh first launch (next
    /// `evaluate()`/`startTrialIfNeeded()` re-establishes the trial).
    func devClearKeychain() {
        startDateSlot.delete()
        maxDateSeenSlot.delete()
        Log.state.notice("trial DEV: cleared keychain slots")
    }

    /// Steps the countdown by one day by moving the start instant back 24 h.
    func devAdvanceOneDay() {
        let current: Date
        if case .found(let raw) = startDateSlot.readResult(), let date = decode(raw) {
            current = date
        } else {
            current = clock()
        }
        startDateSlot.write(encode(current.addingTimeInterval(-Self.secondsPerDay)))
        Log.state.notice("trial DEV: advanced by 1 day")
    }
    #endif
}
