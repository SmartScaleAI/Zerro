//
//  DiagnosticsCollector.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — builds the human-readable diagnostic blob the "Copy
//  Diagnostic Info" button in About & Support places on the clipboard
//  for users to attach to bug reports. Phase 13 will replace this with
//  structured `os_log` collection; for v1 a flat text dump is the
//  right altitude (low engineering cost, immediately useful in a
//  support email).
//
//  What's collected: app version + macOS version, the user's current
//  permission disposition, the selected microphone, the bound hotkey,
//  the default output mode. Intentionally NOT collected: API key,
//  prompt history bodies, anything PII-shaped beyond what System
//  Information would already reveal.
//

import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts

@MainActor
enum DiagnosticsCollector {
    /// Snapshot the live state and return a flat text block ready to
    /// drop into a support email. Format is intentionally not machine-
    /// readable — the audience is the human reading the bug report.
    static func snapshot(
        permissions: PermissionsManager,
        preferences: PreferencesStore
    ) -> String {
        var lines: [String] = []
        lines.append("Zerro \(appVersionString())")
        lines.append("macOS \(osVersionString())")
        lines.append("")
        lines.append("Permissions:")
        lines.append("  Screen Recording: \(permissions.screenRecordingStatus)")
        lines.append("  Microphone:       \(permissions.microphoneStatus)")
        lines.append("  Accessibility:    \(permissions.accessibilityStatus)")
        lines.append("")
        lines.append("Capture:")
        lines.append("  Microphone: \(selectedMicrophoneDescription(deviceID: preferences.microphoneDeviceID))")
        lines.append("  Hotkey:     \(currentHotkeyDescription())")
        lines.append("")
        lines.append("Output:")
        lines.append("  Default mode: \(preferences.defaultOutputMode.displayName)")
        // Phase 13 (Part B) — include the most recent Sentry event ID
        // so a support email correlates to a captured crash / non-fatal
        // event in the Sentry dashboard. Reads `nil` if no event has
        // been sent this launch OR if the user has the crash-reporting
        // toggle OFF (in which case `beforeSend` drops everything and
        // never populates this). DEFERRED: wire into the structured
        // diagnostic blob that the Phase 13 logging task is building.
        lines.append("")
        lines.append("Support:")
        lines.append("  Crash report ID: \(CrashReporting.lastEventId ?? "(none this launch)")")
        return lines.joined(separator: "\n")
    }

    /// Writes `snapshot(…)` to the general pasteboard.
    static func copyToPasteboard(
        permissions: PermissionsManager,
        preferences: PreferencesStore
    ) {
        let text = snapshot(permissions: permissions, preferences: preferences)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Pieces

    static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func selectedMicrophoneDescription(deviceID: String) -> String {
        if deviceID.isEmpty { return "System Default" }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        if let device = session.devices.first(where: { $0.uniqueID == deviceID }) {
            return device.localizedName
        }
        // Stored ID didn't resolve — diagnostic value includes the
        // disconnect signal so the user/support sees why capture might
        // be falling back to the OS default.
        return "Not connected (stored: \(deviceID))"
    }

    private static func currentHotkeyDescription() -> String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return shortcut.description
        }
        return "(none)"
    }
}
