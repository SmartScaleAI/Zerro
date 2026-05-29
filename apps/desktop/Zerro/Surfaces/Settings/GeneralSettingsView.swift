//
//  GeneralSettingsView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The "General" tab of the Settings scene. Three rows:
//    1. OpenAI API key  — masked field with show/hide, persisted in
//                         Keychain (NOT UserDefaults), written on
//                         blur/submit so we don't spam keystrokes.
//    2. Microphone      — `AVCaptureDevice.DiscoverySession` over
//                         .microphone + .external, persisted by
//                         uniqueID. Falls back to "System Default"
//                         when the stored device isn't currently
//                         connected, without clobbering the stored ID.
//    3. Hotkey          — `KeyboardShortcuts.Recorder` bound to
//                         `.toggleRecording`. Persistence and capture
//                         UX are handled entirely by the library.
//

import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section {
                APIKeyRow()
                MicrophoneRow()
            }

            Section {
                HotkeyRow()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - API Key

private struct APIKeyRow: View {
    @State private var apiKey: String = ""
    @State private var isRevealed: Bool = false
    @State private var showSavedConfirmation: Bool = false
    @FocusState private var isFieldFocused: Bool

    private let keychain = KeychainStore.openAIAPIKey

    var body: some View {
        LabeledContent("OpenAI API Key") {
            HStack(spacing: VFSpacing.sm) {
                Group {
                    if isRevealed {
                        TextField("sk-\u{2026}", text: $apiKey)
                    } else {
                        SecureField("sk-\u{2026}", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide API key" : "Show API key")

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.vfSuccessGreen)
                    .opacity(showSavedConfirmation ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showSavedConfirmation)
                    .frame(width: 14)
            }
        }
        .onAppear {
            apiKey = keychain.read() ?? ""
        }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused { save() }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete()
        } else {
            keychain.write(trimmed)
        }
        showSavedConfirmation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showSavedConfirmation = false
        }
    }
}

// MARK: - Microphone

private struct MicrophoneRow: View {
    @Environment(PreferencesStore.self) private var preferences
    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        @Bindable var preferences = preferences

        LabeledContent("Microphone") {
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
        }
        .onAppear(perform: refreshDevices)
    }

    /// Maps the persisted device ID to the picker's selection. When the
    /// stored ID no longer resolves to a connected device, the picker
    /// displays "System Default" without overwriting the saved value —
    /// reconnecting the mic restores the selection.
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

private struct HotkeyRow: View {
    var body: some View {
        KeyboardShortcuts.Recorder("Hotkey", name: .toggleRecording)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(PreferencesStore())
        .frame(width: 520, height: 360)
}
