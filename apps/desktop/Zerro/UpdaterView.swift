//
//  UpdaterView.swift
//  Zerro
//
//  Phase 14 / C3.4 — Sparkle integration. Owns the SPUStandardUpdaterController
//  for the app's lifetime and exposes a SwiftUI "Check for Updates…" button.
//
//  Lifetime contract (Phase 4 learning): the updater controller MUST be
//  owned at @main-App lifetime via @StateObject, not inside the
//  MenuBarExtra content closure. The closure's objects only live while
//  the dropdown is open, which would tear down the updater on every
//  close — anything Sparkle has scheduled (automatic checks, in-flight
//  download UI) would die with it.
//
//  DEFERRED C4: appcast.xml + release publishing pipeline. The feed URL
//  and EdDSA public key are already declared in the target's Info
//  settings; once the feed is live, no code change should be needed
//  here — the controller will simply start finding entries.
//
//  E7 / Appendix F: the updater delegate filters appcast items to the BYOK
//  license's 1-year update window (silently — out-of-window users see
//  "you're up to date", never a refusal). The decision itself is the pure
//  `UpdateWindowPolicy`; the delegate only adapts `SUAppcastItem`s to it.
//

import Combine
import Sparkle
import SwiftUI

// MARK: - Update-window delegate (E7)

/// `SPUUpdaterDelegate` implementing the BYOK update-window filter via
/// `bestValidUpdate(in:for:)`. The window source is an injected closure
/// (read fresh on every check, so a renewal key pasted mid-session takes
/// effect on the next check); production reads the real Keychain slots.
/// Everything else about updating is untouched — Sparkle's default behavior
/// applies whenever the policy defers.
final class UpdateWindowUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let currentWindowEnd: () -> Date?
    /// I-02: whether the app is mid-work (recording, processing, or any
    /// Dev-Mode dispatch state) — i.e. anything but a fully idle state
    /// machine. Read fresh on each relaunch request.
    private let isBusy: @MainActor () -> Bool
    /// I-02: schedules a one-shot callback for the app's next return to
    /// idle (production: `AppState.onNextIdle`).
    private let onNextIdle: @MainActor (_ callback: @escaping @MainActor () -> Void) -> Void

    /// The install-and-relaunch block Sparkle handed over while the app was
    /// busy, waiting for the next idle transition. Non-nil also means an
    /// idle callback is already armed — a second postpone request while one
    /// is pending just replaces the stashed block (the latest update cycle
    /// wins) without arming a second callback, so the relaunch still fires
    /// exactly once.
    private var pendingRelaunch: (() -> Void)?

    init(
        currentWindowEnd: @escaping () -> Date?,
        isBusy: @escaping @MainActor () -> Bool,
        onNextIdle: @escaping @MainActor (_ callback: @escaping @MainActor () -> Void) -> Void
    ) {
        self.currentWindowEnd = currentWindowEnd
        self.isBusy = isBusy
        self.onNextIdle = onNextIdle
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let candidates = appcast.items.map {
            UpdateWindowPolicy.Candidate(date: $0.date, version: $0.versionString)
        }
        switch UpdateWindowPolicy.decide(candidates: candidates, windowEnd: currentWindowEnd()) {
        case .deferToSparkle:
            return nil
        case .noUpdate:
            // Sparkle's explicit "no valid item" sentinel — the check reports
            // "you're up to date" (decision F.0: silent, never a refusal).
            return SUAppcastItem.empty()
        case .bestInWindow(let index):
            return appcast.items[index]
        }
    }

    // MARK: - Idle-gated relaunch (I-02)

    /// Sparkle's postpone-relaunch hook (Sparkle 2.9.2 selector
    /// `updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:`).
    /// Without this, an automatic update can install-and-relaunch the app
    /// mid-recording or mid-Dev-run, killing the in-flight work. Sparkle
    /// invokes delegate callbacks on the main thread (same `assumeIsolated`
    /// pattern as `didAbortWithError` below).
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            shouldPostponeRelaunch(untilInvoking: installHandler)
        }
    }

    /// Sparkle-free core of the postpone decision, split out so tests can
    /// drive it without constructing an `SPUUpdater`. Idle → false (Sparkle
    /// relaunches immediately, unchanged behavior). Busy → true, stashing
    /// `installHandler` to run on the next idle transition. The stash-then-arm
    /// order guarantees at most one armed idle callback per pending relaunch,
    /// and the take-before-invoke in the callback guards against a double
    /// fire ever running the handler twice.
    func shouldPostponeRelaunch(untilInvoking installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        let alreadyArmed = pendingRelaunch != nil
        pendingRelaunch = installHandler
        if !alreadyArmed {
            onNextIdle { [weak self] in
                guard let self, let handler = self.pendingRelaunch else { return }
                self.pendingRelaunch = nil
                handler()
            }
        }
        return true
    }

    // MARK: - Auto-update failure reporting

    /// Reports genuine auto-update failures to error tracking so a broken
    /// updater surfaces instead of silently stranding users on an old build.
    ///
    /// Sparkle drives the whole check through this one catch-all callback —
    /// download, unarchive, signature and install failures all land here — but
    /// so do two routine, non-failure outcomes that fire on ordinary launches.
    /// `SPUUpdaterDelegate.h` documents exactly those two as the "special
    /// possible values" for `didAbortWithError`, and we return early on them:
    /// capturing either would mint a PostHog issue (and trip the Slack alert)
    /// every time a user launches with nothing to update.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError

        // Benign outcomes Sparkle routes through this same callback — ignore.
        if nsError.domain == SUSparkleErrorDomain,
           let suError = SUError(rawValue: OSStatus(nsError.code)) {
            switch suError {
            case .noUpdateError,             // no newer build in the feed
                 .installationCanceledError: // user cancelled the install/auth prompt
                return
            default:
                break
            }
        }

        // Genuine failure. Sparkle invokes delegate callbacks on the main
        // thread; under `-default-isolation=MainActor` the @objc delegate
        // witness is nonisolated, so hop onto MainActor to reach
        // `CrashReporting.capture`. `assumeIsolated` is safe — we are already
        // on main. Only "errorCode" is allowlisted by the privacy contract;
        // the error itself rides along for its type + code, never its text.
        MainActor.assumeIsolated {
            _ = CrashReporting.capture(
                error,
                message: "Sparkle auto-update failed",
                stage: "update",
                context: ["errorCode": String(nsError.code)]
            )
        }
    }
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    /// Held strongly for the controller's lifetime — Sparkle keeps only a
    /// weak delegate reference.
    private let updaterDelegate: UpdateWindowUpdaterDelegate
    private var cancellable: AnyCancellable?

    /// The busy/idle pair feeds the I-02 relaunch gate and is wired to the
    /// live `AppState` by `ZerroApp`. The defaults ("never busy", "idle now")
    /// reproduce the ungated behavior for the bare `UpdaterViewModel()`
    /// call sites (`#Preview`s), which have no state machine to consult.
    init(
        isBusy: @escaping @MainActor () -> Bool = { false },
        onNextIdle: @escaping @MainActor (_ callback: @escaping @MainActor () -> Void) -> Void = { $0() }
    ) {
        // startingUpdater: true → Sparkle begins its automatic-check
        // schedule immediately (per the user's preference plist). The
        // updater delegate applies the E7 BYOK update-window filter and
        // the I-02 idle relaunch gate (and nothing else); nil
        // userDriverDelegate → default update UI.
        let delegate = UpdateWindowUpdaterDelegate(
            currentWindowEnd: {
                UpdateWindowPolicy.currentWindowEnd(
                    kindSlot: KeychainStore.licenseProductKind,
                    createdAtSlot: KeychainStore.byokLicenseCreatedAt
                )
            },
            isBusy: isBusy,
            onNextIdle: onNextIdle
        )
        self.updaterDelegate = delegate
        // `startingUpdater: true` kicks off Sparkle's automatic-check
        // schedule (appcast network fetch + first-launch permission flow) the
        // instant this @StateObject is built — which happens on EVERY launch,
        // including the one Xcode performs to host a `#Preview`. In the preview
        // agent that startup work is what stalls the launch and surfaces as
        // "Failed to launch app in reasonable time". Under previews we still
        // build the controller (the stored property must exist) but DON'T start
        // it; real launches are unchanged.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: !ZerroApp.isRunningInXcodePreview,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        // KVO-publish `canCheckForUpdates` into Combine so the SwiftUI
        // button can react when Sparkle is mid-check (briefly false) or
        // disabled by policy. Initial value is captured synchronously
        // so the first render reflects current state.
        let updater = controller.updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.cancellable = updater
            .publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesView: View {
    @EnvironmentObject private var updater: UpdaterViewModel

    var body: some View {
        // Render via the shared MenuRow so this item is visually
        // indistinguishable from "Open Zerro", "Start Recording", etc.
        // MenuRow's built-in isDisabled handles the greyed/disabled
        // state when Sparkle is mid-check or otherwise can't check.
        MenuRow(
            label: "Check for Updates\u{2026}",
            isDisabled: !updater.canCheckForUpdates,
            action: { updater.checkForUpdates() }
        )
    }
}
