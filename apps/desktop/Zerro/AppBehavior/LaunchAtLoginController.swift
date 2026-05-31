//
//  LaunchAtLoginController.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — wraps `SMAppService.mainApp` so the App Behavior section
//  has a single source of truth for "is launch-at-login on right now"
//  that observes the real OS state (not just a mirrored @AppStorage
//  flag, which can drift if the user disables the login item via
//  System Settings → General → Login Items).
//
//  Why SMAppService instead of NSLoginItems: SMAppService.mainApp is
//  Apple's recommended path post-macOS-13 — uses LaunchServices behind
//  the scenes, no Helper-app target needed, and respects the user
//  toggling it off in System Settings without us having to poll.
//
//  We DON'T persist the toggle ourselves — `service.status` is the
//  authoritative read. The "refresh" call after toggling is what makes
//  the published `isEnabled` reflect the real OS state immediately,
//  including the case where the OS silently rejects the registration
//  (insufficient signing, sandbox issue, etc.) and the toggle should
//  snap back off.
//

import Foundation
import os
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    /// Live mirror of `SMAppService.mainApp.status == .enabled`. The
    /// toggle in App Behavior binds to this; the setter routes through
    /// `setEnabled(_:)` so the OS call always happens before the
    /// observed value flips.
    private(set) var isEnabled: Bool = false

    init() {
        refresh()
    }

    /// Re-reads the live status from SMAppService. Called from init,
    /// after every toggle, and whenever the App Behavior section
    /// appears (in case the user changed it via System Settings).
    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// Attempts to flip the login-item registration to `newValue` and
    /// refreshes `isEnabled` from the OS afterwards. If the registration
    /// fails for any reason (signing drift, sandbox refusal), the
    /// observed value snaps back to whatever the OS actually accepted —
    /// no stale UI claiming "on" when the OS says no.
    func setEnabled(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Error description marked .private — SMAppService errors
            // can embed bundle paths and signing identity strings.
            Log.launchAtLogin.error(
                "toggle to \(newValue ? "on" : "off", privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        refresh()
    }
}
