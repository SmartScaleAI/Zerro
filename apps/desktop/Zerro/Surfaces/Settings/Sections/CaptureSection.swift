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

/// H-13: the mic picker's device list, refreshed on hot-plug. The Picker
/// previously loaded devices once in `.onAppear`, so plugging/unplugging a
/// mic while Settings sat open left a stale list. This model re-runs the
/// discovery whenever AVFoundation posts a device
/// connected/disconnected notification, scoped to the row's appearance
/// (observers installed on appear, removed on disappear — no long-lived
/// observers from a Settings row).
///
/// Selection re-validation is inherited from the Phase 3 contract the row
/// already implements: the picker binding falls back VISUALLY to "System
/// Default" whenever the stored ID isn't in the refreshed list, without
/// overwriting the stored value — so a vanished device degrades gracefully
/// here (the display name disappears, System Default shows) while a live
/// recording's disconnect is RecordingSession's pinned-device observer's
/// job (it fails the session with `.microphoneDisconnected`).
///
/// The device source is injected so unit tests can drive refreshes without
/// constructing `AVCaptureDevice`s (which can't be faked in a test).
@MainActor
@Observable
final class MicDeviceList {

    /// The two fields the picker renders — decoupled from AVCaptureDevice
    /// so tests can inject a fake source.
    struct Device: Equatable {
        let id: String
        let name: String
    }

    private(set) var devices: [Device] = []

    @ObservationIgnored private let provider: () -> [Device]
    @ObservationIgnored private var hotPlugObservers: [NSObjectProtocol] = []

    init(provider: @escaping () -> [Device] = MicDeviceList.liveDevices) {
        self.provider = provider
    }

    deinit {
        for observer in hotPlugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The production device source — the same discovery session the row
    /// has always used.
    static func liveDevices() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    func refresh() {
        devices = provider()
    }

    /// Installs the hot-plug observers (idempotent). Deliberately NOT
    /// scoped to a specific device (unlike RecordingSession's pinned-mic
    /// observer): the picker cares about ANY audio device coming or going.
    func startObserving() {
        guard hotPlugObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ]
        for name in names {
            hotPlugObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hop to MainActor — the closure stored in NotificationCenter
                // isn't isolated; MicDeviceList is @MainActor.
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            })
        }
    }

    func stopObserving() {
        for observer in hotPlugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        hotPlugObservers.removeAll()
    }
}

private struct MicrophoneRow: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(PermissionsManager.self) private var permissions

    @State private var deviceList = MicDeviceList()

    var body: some View {
        @Bindable var preferences = preferences

        SettingsRow(
            label: "Microphone Source",
            description: descriptionLine
        ) {
            Picker("Microphone", selection: pickerBinding) {
                Text("System Default").tag("")
                if !deviceList.devices.isEmpty {
                    Divider()
                    ForEach(deviceList.devices, id: \.id) { device in
                        Text(device.name).tag(device.id)
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
        .onAppear {
            deviceList.refresh()
            // H-13: keep the list live while the row is on screen.
            deviceList.startObserving()
        }
        .onDisappear {
            deviceList.stopObserving()
        }
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
                return deviceList.devices.contains(where: { $0.id == stored }) ? stored : ""
            },
            set: { preferences.microphoneDeviceID = $0 }
        )
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
