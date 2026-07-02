//
//  TranscriptionSection.swift
//  Zerro
//
//  Phase 5 (Local Whisper) — the BYOK "Transcription" settings section:
//   • Engine picker (Auto / On-device / OpenAI cloud) bound to
//     `PreferencesStore.sttEngine`. Options that aren't usable yet are disabled
//     in the menu and explained in the row description (On-device until the model
//     is installed; OpenAI cloud until an OpenAI key is present).
//   • Model status row driven by the SHARED `LocalModelManager.state` — download /
//     progress+cancel / installed+remove+re-download / failed+retry.
//
//  Reads the same injected `LocalModelManager` the first-key consent prompt uses
//  (see `ZerroApp` / `APIAuthSection`). Lives in the BYOK pane next to API Keys.
//

import AppKit
import SwiftUI

struct TranscriptionSection: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(LocalModelManager.self) private var modelManager
    // UX-C: OBSERVABLE key presence. Reading `ProviderKeys.resolveKey` directly is
    // a one-shot Keychain read that SwiftUI can't track, so the "OpenAI cloud"
    // option stayed disabled after a key was added above. Deriving through this
    // shared @Observable (refreshed by the API Keys section on write/delete) makes
    // the picker + caveat re-render live.
    @Environment(ProviderKeyPresence.self) private var keyPresence

    var body: some View {
        SettingsSection("Transcription") {
            SettingsRow(
                label: "Engine",
                description: engineDescription,
                verticalPadding: RowMetrics.verticalPaddingTall
            ) {
                enginePicker
            }
            SettingsRowDivider()
            modelStatusRow
        }
        // UX-C: if the selected engine becomes unusable after an availability
        // change (e.g. `.cloud` selected, then the OpenAI key removed; or `.local`
        // after the model is removed), fall back to `.auto` so the picker never
        // shows a selected-but-disabled engine.
        .onChange(of: openAIKeyPresent) { _, _ in resetSelectedEngineIfUnusable() }
        .onChange(of: modelInstalled) { _, _ in resetSelectedEngineIfUnusable() }
    }

    // MARK: - Availability signals (cheap, hash-free)

    /// The model is installed iff the shared manager is `.ready` (set by the cheap
    /// launch reconcile / a finished download — never a per-recording hash).
    private var modelInstalled: Bool {
        if case .ready = modelManager.state { return true } else { return false }
    }

    private var openAIKeyPresent: Bool {
        keyPresence.openAIKeyPresent
    }

    /// Falls the selected engine back to `.auto` when it's no longer selectable
    /// (delegates the "is it usable" decision to the shared `STTEnginePicker` rule).
    private func resetSelectedEngineIfUnusable() {
        if let fallback = STTEnginePicker.fallbackIfUnusable(
            current: preferences.sttEngine,
            modelInstalled: modelInstalled,
            openAIKeyPresent: openAIKeyPresent
        ) {
            preferences.sttEngine = fallback
        }
    }

    // MARK: - Engine picker

    private var engineDescription: String {
        var text = "Auto uses on-device when the model is ready, otherwise OpenAI cloud."
        var caveats: [String] = []
        if !modelInstalled { caveats.append("On-device needs the model downloaded below.") }
        if !openAIKeyPresent { caveats.append("OpenAI cloud needs an OpenAI key.") }
        if !caveats.isEmpty { text += " " + caveats.joined(separator: " ") }
        return text
    }

    private var enginePicker: some View {
        Menu {
            ForEach(STTEngine.allCases, id: \.self) { engine in
                Button {
                    selectEngine(engine)
                } label: {
                    if engine == preferences.sttEngine {
                        Label(engine.displayName, systemImage: "checkmark")
                    } else {
                        Text(engine.displayName)
                    }
                }
                .disabled(!STTEnginePicker.isSelectable(
                    engine,
                    modelInstalled: modelInstalled,
                    openAIKeyPresent: openAIKeyPresent
                ))
            }
        } label: {
            HStack(spacing: 6) {
                Text(preferences.sttEngine.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.vfPillBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func selectEngine(_ engine: STTEngine) {
        guard engine != preferences.sttEngine else { return }
        preferences.sttEngine = engine
        Analytics.capture("stt_engine_changed", ["engine": engine.rawValue])
    }

    // MARK: - Model status row

    @ViewBuilder
    private var modelStatusRow: some View {
        switch modelManager.state {
        case .notDownloaded:
            SettingsRow(label: "On-device model", description: "Not downloaded \u{2014} a one-time ~1 GB download.") {
                Button("Download") { modelManager.download() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }

        case let .downloading(progress, downloaded, total):
            SettingsStackedRow(label: "On-device model") {
                Button("Cancel") { modelManager.cancel() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            } below: {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.vfAccentBlue)
                    Text("\(Self.megabytes(downloaded)) / \(Self.megabytes(total))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }

        case let .ready(version):
            SettingsRow(label: "On-device model", description: "Installed \u{2014} \(version).") {
                HStack(spacing: VFSpacing.sm) {
                    Button("Re-download") { modelManager.download() }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    Button("Remove") { confirmRemove() }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                }
            }

        case let .failed(reason):
            SettingsRow(label: "On-device model", description: reason) {
                Button("Retry") { modelManager.download() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove the on-device model?"
        alert.informativeText = "This deletes the ~1 GB transcription model. You can re-download it any time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            modelManager.removeModel()
        }
    }

    /// Whole megabytes (1 MB = 1,048,576 bytes), e.g. "523 MB".
    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Engine selectability (pure)

/// Which engine options the picker offers. Pure + extracted so the disabled-state
/// rules are unit-testable. `.auto` is ALWAYS selectable (it degrades to whatever
/// is available); `.local`/`.cloud` require their respective prerequisite.
enum STTEnginePicker {
    static func isSelectable(_ engine: STTEngine, modelInstalled: Bool, openAIKeyPresent: Bool) -> Bool {
        switch engine {
        case .auto:  return true
        case .local: return modelInstalled
        case .cloud: return openAIKeyPresent
        }
    }

    /// The engine the picker should fall back to when `current` is no longer
    /// selectable — always `.auto` (which is always selectable) — or `nil` to keep
    /// the current selection. Pure so the selected-but-disabled reset is
    /// unit-testable (UX-C).
    static func fallbackIfUnusable(current: STTEngine, modelInstalled: Bool, openAIKeyPresent: Bool) -> STTEngine? {
        isSelectable(current, modelInstalled: modelInstalled, openAIKeyPresent: openAIKeyPresent) ? nil : .auto
    }
}
