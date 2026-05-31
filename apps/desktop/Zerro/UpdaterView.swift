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

import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init() {
        // startingUpdater: true → Sparkle begins its automatic-check
        // schedule immediately (per the user's preference plist). nil
        // delegates → we accept the default user-driver UI and default
        // updater behavior; custom delegates are explicitly out of scope.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
