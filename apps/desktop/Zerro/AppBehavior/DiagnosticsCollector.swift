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
import OSLog

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
        // never populates this).
        lines.append("")
        lines.append("Support:")
        lines.append("  Crash report ID: \(CrashReporting.lastEventId ?? "(none this launch)")")

        // Phase 13A — last 60s of the app's own log entries (notice
        // level and above). Pulled lazily via OSLogStore on click; no
        // in-memory ring buffer overhead at runtime. Privacy:
        // OSLogStore at .currentProcessIdentifier scope returns
        // .private values UNREDACTED (the OS only redacts when read
        // from another process). The header flags this so a user can
        // review before sending — and we deliberately filter to
        // notice+ to keep volume down and reduce the chance of
        // routine .info / .debug noise carrying anything sensitive.
        lines.append("")
        lines.append("Recent log entries (last 60s, level=notice+) — REVIEW BEFORE SHARING:")
        let logLines = recentLogLines(durationSeconds: 60)
        if logLines.isEmpty {
            lines.append("  (no entries)")
        } else {
            for line in logLines {
                lines.append("  \(line)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Reads the app's own log entries from the OS log store, filtered
    /// to our subsystem and to `notice` level and above, over the last
    /// `durationSeconds` seconds. Returns formatted lines ready to
    /// concatenate into the diagnostic blob. Empty array on any read
    /// failure (the store can throw on first-launch / fresh-install
    /// edge cases) — diagnostic info is best-effort, never blocking.
    private static func recentLogLines(durationSeconds: TimeInterval) -> [String] {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.cbreeding.Zerro"
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let startDate = Date(timeIntervalSinceNow: -durationSeconds)
            let position = store.position(date: startDate)
            // Pre-filter by subsystem in the predicate so we don't pull
            // every system log into memory and discard most of it.
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var out: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                // Filter to notice+ — drops the high-volume .info / .debug
                // chatter (cost lines, working-dir paths, transcript
                // counts). What's left is genuinely operational signal.
                guard log.level == .notice || log.level == .error || log.level == .fault else {
                    continue
                }
                let ts = formatter.string(from: log.date)
                out.append("[\(ts)] [\(log.category)] [\(Self.levelString(log.level))] \(log.composedMessage)")
            }
            return out
        } catch {
            // OSLogStore failures are silent — diagnostic copy must
            // never break because the log store wasn't available.
            return ["(log entries unavailable: \(error.localizedDescription))"]
        }
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "UNDEFINED"
        case .debug:     return "DEBUG"
        case .info:      return "INFO"
        case .notice:    return "NOTICE"
        case .error:     return "ERROR"
        case .fault:     return "FAULT"
        @unknown default: return "?"
        }
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
