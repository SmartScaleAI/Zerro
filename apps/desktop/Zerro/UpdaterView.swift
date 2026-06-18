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

    init(currentWindowEnd: @escaping () -> Date?) {
        self.currentWindowEnd = currentWindowEnd
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
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    /// Held strongly for the controller's lifetime — Sparkle keeps only a
    /// weak delegate reference.
    private let updaterDelegate: UpdateWindowUpdaterDelegate
    private var cancellable: AnyCancellable?

    init() {
        // startingUpdater: true → Sparkle begins its automatic-check
        // schedule immediately (per the user's preference plist). The
        // updater delegate applies the E7 BYOK update-window filter (and
        // nothing else); nil userDriverDelegate → default update UI.
        let delegate = UpdateWindowUpdaterDelegate(currentWindowEnd: {
            UpdateWindowPolicy.currentWindowEnd(
                kindSlot: KeychainStore.licenseProductKind,
                createdAtSlot: KeychainStore.byokLicenseCreatedAt
            )
        })
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
