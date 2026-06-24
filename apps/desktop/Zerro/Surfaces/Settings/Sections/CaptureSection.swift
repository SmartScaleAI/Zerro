//
//  CaptureSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — Capture section of the redesigned Settings layout. Two rows:
//    1. Microphone Source — popup over the live device list, persisted
//       by uniqueID through PreferencesStore. Falls back visually to
//       "System Default" when the stored ID isn't connected, without
//       overwriting the stored value (matches the prior Phase 3 contract).
//    2. Global Hotkey — KeyboardShortcuts.Recorder bound to the existing
//       `.toggleRecording` name. The library handles persistence + the
//       resting/recording visual states natively.
//
//  Mic-permission hint: when the user hasn't granted Microphone TCC,
//  the picker would show an empty device list with no explanation. We
//  surface a small caption so the cause is visible without leaving the
//  pane.
//

import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct CaptureSection: View {
    var body: some View {
        SettingsSection("Capture") {
            MicrophoneRow()
            SettingsRowDivider()
            HotkeyRow()
            SettingsRowDivider()
            RedactSecretsRow()
        }
    }
}

// MARK: - Microphone

private struct MicrophoneRow: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(PermissionsManager.self) private var permissions

    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        @Bindable var preferences = preferences

        SettingsRow(
            label: "Microphone Source",
            description: descriptionLine
        ) {
            Picker("Microphone", selection: pickerBinding) {
                Text("System Default").tag("")
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // Round 3: 200pt fixed width per design. When the popup's
            // intrinsic size is narrower than the slot, .trailing pins
            // its right edge against the row's 20pt right padding so it
            // lines up with the other trailing controls (segmented
            // mode picker, model menu) instead of floating centered.
            .frame(width: 200, alignment: .trailing)
        }
        .onAppear(perform: refreshDevices)
    }

    /// "Input device used to record your narration." normally; switches
    /// to a permission hint when Mic TCC isn't granted so the empty
    /// picker reads as actionable instead of broken.
    private var descriptionLine: String {
        if permissions.microphoneStatus != .granted {
            return "Microphone access isn't granted \u{2014} re-run setup to enable it."
        }
        return "Input device used to record your narration."
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: {
                let stored = preferences.microphoneDeviceID
                if stored.isEmpty { return "" }
                return devices.contains(where: { $0.uniqueID == stored }) ? stored : ""
            },
            set: { preferences.microphoneDeviceID = $0 }
        )
    }

    private func refreshDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = session.devices
    }
}

// MARK: - Hotkey
//
// Verified working in Phase 11: the Recorder and the global hotkey are
// coupled through the `.toggleRecording` shortcut NAME (see
// AppShortcuts.swift); when the user records a new binding here the
// library swaps the underlying Carbon HotKey registration in place, and
// the `onKeyDown(for: .toggleRecording)` handler registered in
// ZerroApp.init stays bound. No restart, no extra wiring.
//
// Revision 2 swapped the library's default pill out for HotkeyDisplay,
// which renders one dark keycap per modifier + key at rest and only
// surfaces the library's native "Type a shortcut..." UI while the user
// is actively rebinding.

private struct HotkeyRow: View {
    var body: some View {
        SettingsRow(
            label: "Global Hotkey",
            description: "Press anywhere to start a recording."
        ) {
            HotkeyDisplay(name: .toggleRecording)
        }
    }
}

// MARK: - Redact Secrets
//
// Phase 3: on-device OCR scans each kept keyframe for high-confidence secrets
// (API keys, tokens, private-key headers, passwords, cards). When ON (the
// default), it paints opaque boxes over them in the frame AND masks them as
// [REDACTED] in the on-screen text sent alongside — the two stay in lock step,
// so nothing hidden in pixels leaks via text. Read fresh at recording start
// (ZerroApp) so a change here applies to the next recording.

private struct RedactSecretsRow: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        SettingsRow(
            label: "Redact Detected Secrets",
            description: "Tries to detect and black out common on-screen secrets \u{2014} API keys, tokens, passwords, and card numbers \u{2014} in both the captured image and the extracted text before upload. Best-effort, so it can miss some, and it never redacts your spoken audio."
        ) {
            Toggle("Redact Detected Secrets", isOn: $preferences.redactSecrets)
                .labelsHidden()
                .toggleStyle(VFSwitchToggleStyle())
        }
    }
}

#Preview {
    CaptureSection()
        .environment(PreferencesStore())
        .environment(PermissionsManager())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
