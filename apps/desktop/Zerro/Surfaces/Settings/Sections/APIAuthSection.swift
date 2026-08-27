//
//  APIAuthSection.swift
//  Zerro
//
//  Phase 11, generalized for multi-model 6C — the BYOK pane's API-key
//  section: ONE row per provider (OpenAI / Gemini / Anthropic), each an
//  independent masked monospace field (eye toggle) + live verification pill,
//  each backed by its own Keychain slot. Any subset may be filled — a model
//  is selectable in the picker only when its provider's key is present
//  (key-gating, 6C.3).
//
//  Any subset of keys works: each key unlocks its provider's chat models, and
//  the OpenAI key additionally powers CLOUD transcription. Since on-device
//  whisper.cpp landed, OpenAI is OPTIONAL — local transcription needs no key
//  (download the model under Transcription) — so no row is "required"; the
//  OpenAI row copy says it's optional.
//
//  Per-provider Keychain entries are the single source of truth; each field
//  loads from its slot on appear and writes on `.valid` results only — a
//  typo'd key never overwrites a working one. Inconclusive (network) results
//  still write through because the user's *intent* is to rotate. A blanked
//  field deletes the entry (independent remove).
//

import AppKit
import SwiftUI

struct APIAuthSection: View {
    // Phase 5 — needed to decide + present the one-time on-device-model consent
    // prompt when the user saves their first key. The field models stay focused
    // on Keychain/validation; this section owns the decision (it has the stores).
    @Environment(PreferencesStore.self) private var preferences
    @Environment(LocalModelManager.self) private var modelManager
    // UX-C: refreshed on every key write/delete so the Transcription engine
    // picker (which reads it) re-renders when an OpenAI key is added/removed.
    @Environment(ProviderKeyPresence.self) private var keyPresence

    @State private var openAIModel = APIKeyFieldModel(provider: .openai)
    @State private var geminiModel = APIKeyFieldModel(provider: .gemini)
    @State private var anthropicModel = APIKeyFieldModel(provider: .anthropic)

    var body: some View {
        SettingsSection("API Keys") {
            APIKeyRow(
                model: openAIModel,
                description: "Optional. Unlocks the OpenAI chat models, and powers cloud transcription. On-device transcription needs no key. Stored in macOS Keychain."
            )
            SettingsRowDivider()
            APIKeyRow(
                model: geminiModel,
                description: "Unlocks the Gemini models in the picker. Stored in macOS Keychain."
            )
            SettingsRowDivider()
            APIKeyRow(
                model: anthropicModel,
                description: "Unlocks the Claude models in the picker. Stored in macOS Keychain."
            )
            SettingsRowDivider()
            RevalidateRow(models: [openAIModel, geminiModel, anthropicModel])
        }
        .onAppear(perform: wireKeyVerifiedHandlers)
    }

    // MARK: - First-key consent prompt (Phase 5)

    /// Wire the first-key → consent handler onto each provider field. Done in
    /// `onAppear` (not at field construction) because the handler needs the
    /// environment stores, which aren't available when the @State models init.
    /// Captures the (reference-type) stores explicitly rather than the View self.
    private func wireKeyVerifiedHandlers() {
        let handler: (Bool) -> Void = { [preferences, modelManager] wasFirstKey in
            Self.handleKeyVerified(
                wasFirstKey: wasFirstKey,
                preferences: preferences,
                manager: modelManager
            )
        }
        openAIModel.onKeyVerified = handler
        geminiModel.onKeyVerified = handler
        anthropicModel.onKeyVerified = handler
        // UX-C: any key add/remove refreshes the shared presence signal, so the
        // Transcription picker's "OpenAI cloud" option enables/disables live.
        let refresh: () -> Void = { [keyPresence] in keyPresence.refresh() }
        openAIModel.onKeyStoreChanged = refresh
        geminiModel.onKeyStoreChanged = refresh
        anthropicModel.onKeyStoreChanged = refresh
    }

    /// Decide whether to present the one-time consent prompt and, if so, show it.
    /// `static` so the closure captures the stores explicitly (no View self).
    @MainActor
    private static func handleKeyVerified(
        wasFirstKey: Bool,
        preferences: PreferencesStore,
        manager: LocalModelManager
    ) {
        let modelReady: Bool = { if case .ready = manager.state { return true } else { return false } }()

        guard LocalModelConsent.shouldPrompt(
            isFirstKey: wasFirstKey,
            alreadyShown: preferences.localModelPromptShown,
            modelReady: modelReady
        ) else { return }

        // Set BEFORE presenting so the prompt fires at most once on EITHER choice.
        preferences.localModelPromptShown = true
        Analytics.capture("local_model_prompt_shown")
        presentConsentAlert(manager: manager)
    }

    /// The thin NSAlert presentation. "Download" kicks off the model download; the
    /// disk-space line is added only when the volume is short.
    @MainActor
    private static func presentConsentAlert(manager: LocalModelManager) {
        let alert = NSAlert()
        alert.messageText = "On-device transcription"
        var info = "Zerro transcribes your recordings locally so your audio never leaves your Mac. This needs a one-time ~1 GB download."
        if !manager.hasEnoughDiskSpace() {
            info += "\n\nYou\u{2019}ll need about 1 GB of free disk space."
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")   // default (first) button
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            manager.download()
        }
        // "Later" → do nothing; Phase 6 re-surfaces the need at record time.
    }
}

// MARK: - Shared model

/// One field model PER PROVIDER (multi-model 6C). Owns the provider's
/// Keychain slot + validator; the row binds to it so the pill updates in
/// lockstep whether validation was triggered by editing or by Revalidate.
@MainActor
@Observable
final class APIKeyFieldModel {
    enum State: Equatable {
        case unverified
        case checking
        case verified
        case invalid
    }

    let provider: ModelProvider
    var rawKey: String = ""
    var isRevealed: Bool = false
    var state: State = .unverified

    @ObservationIgnored private let keychain: KeychainSlot
    /// Injectable so tests can drive the pill without network.
    @ObservationIgnored var validator: (String) async -> OpenAIClient.KeyValidationResult
    /// Phase 5 — fired after a `.valid` save that WROTE the key, with `wasFirstKey`
    /// = whether this was the first API key across ALL providers (read BEFORE the
    /// write). `APIAuthSection` uses it to gate the one-time on-device-model consent
    /// prompt; this model stays focused on Keychain/validation.
    @ObservationIgnored var onKeyVerified: ((Bool) -> Void)?
    /// UX-C — fired after ANY change to this provider's Keychain slot (a validated
    /// write, an inconclusive write-through, or a blank-field delete). `APIAuthSection`
    /// wires it to `ProviderKeyPresence.refresh()` so the Settings Transcription
    /// picker re-renders when a key is added/removed. Distinct from `onKeyVerified`
    /// (which fires only on a first-key `.valid` write, for the consent prompt).
    @ObservationIgnored var onKeyStoreChanged: (() -> Void)?
    /// Whether NO provider key exists yet — the "is this the first key" signal,
    /// read BEFORE the write. Injectable (alongside `keychain`) so the first-key
    /// behavior is testable without reading the user's real Keychain slots.
    @ObservationIgnored private let firstKeyProbe: () -> Bool

    init(
        provider: ModelProvider,
        keychain: KeychainSlot? = nil,
        firstKeyProbe: (() -> Bool)? = nil
    ) {
        self.provider = provider
        let slot = keychain ?? ProviderKeys.slot(for: provider)
        self.keychain = slot
        self.firstKeyProbe = firstKeyProbe ?? { ProviderKeys.availableProviders().isEmpty }
        self.validator = { key in
            switch provider {
            case .openai: return await OpenAIClient.validateKey(key)
            case .gemini: return await GeminiPromptGenerationService.validateKey(key)
            case .anthropic: return await AnthropicPromptGenerationService.validateKey(key)
            }
        }
        let stored = slot.read() ?? ""
        rawKey = stored
        // A key already in Keychain came from a prior successful
        // validation — render `.verified` so the pill doesn't ask the
        // user to re-verify on every Settings open.
        state = stored.isEmpty ? .unverified : .verified
    }

    var trimmedKey: String {
        rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Editing demotes any resting state back to `.unverified`. Called
    /// from the field's `.onChange`.
    func handleEdit() {
        if state != .unverified && state != .checking {
            state = .unverified
        }
    }

    /// Save flow used when the user blurs the field or hits return.
    /// Empty input deletes the Keychain entry (the independent "remove");
    /// non-empty triggers validation against the provider.
    func saveAndValidate() {
        let trimmed = trimmedKey
        if trimmed.isEmpty {
            removeKey()
            return
        }
        // Skip the round-trip if nothing actually changed.
        if state == .verified, trimmed == (keychain.read() ?? "") {
            return
        }
        run(validating: trimmed, writeOnValid: true, writeOnInconclusive: true)
    }

    /// Commits a key REMOVAL — the shared "empty field means remove" path, used by
    /// `saveAndValidate()` on blur/return AND by `revalidate()` on an emptied
    /// field. Deletes the Keychain entry, drops to `.unverified`, fires
    /// `byok_key_removed` only on a genuine present→absent transition (presence
    /// only — the key value is never sent), and refreshes the shared
    /// `ProviderKeyPresence` via `onKeyStoreChanged`. It NEVER resurrects the
    /// stored key.
    private func removeKey() {
        let hadKey = !(keychain.read()?.isEmpty ?? true)
        keychain.delete()
        state = .unverified
        if hadKey {
            Analytics.capture("byok_key_removed", ["provider": provider.rawValue])
        }
        // UX-C: presence changed (a key was removed) — refresh the observable.
        onKeyStoreChanged?()
    }

    /// Triggered by the Revalidate button. An EMPTY field commits a REMOVE
    /// (consistent with `saveAndValidate` — the user cleared it but hasn't blurred
    /// yet), never a validation of the still-stored key: falling back to the stored
    /// key here is what flipped a just-cleared field to "Verified" (the bug). A
    /// non-empty field validates exactly what's typed (matching the user's stated
    /// intent), without writing through on inconclusive since the field hasn't been
    /// committed yet.
    func revalidate() {
        let candidate = trimmedKey
        guard !candidate.isEmpty else {
            removeKey()
            return
        }
        run(validating: candidate, writeOnValid: true, writeOnInconclusive: false)
    }

    /// Writes the validated key, firing `byok_key_added` only on a genuine
    /// empty→present transition (rotating an existing key is not an "add").
    /// Presence only — the key value is never sent.
    private func writeKeyTrackingAdd(_ candidate: String) {
        let hadKey = !(keychain.read()?.isEmpty ?? true)
        keychain.write(candidate)
        if !hadKey {
            Analytics.capture("byok_key_added", ["provider": provider.rawValue])
        }
        // UX-C: presence may have changed (a key was added) — refresh the observable.
        onKeyStoreChanged?()
    }

    private func run(validating candidate: String, writeOnValid: Bool, writeOnInconclusive: Bool) {
        state = .checking
        Task { @MainActor in
            let result = await validator(candidate)
            guard state == .checking else { return }
            switch result {
            case .valid:
                // Read first-key-ness BEFORE the write — writing makes this
                // provider's key present, which would flip `availableProviders`.
                let wasFirstKey = firstKeyProbe()
                if writeOnValid { writeKeyTrackingAdd(candidate) }
                state = .verified
                if writeOnValid { onKeyVerified?(wasFirstKey) }
            case .invalidKey:
                state = .invalid
            case .inconclusive:
                if writeOnInconclusive { writeKeyTrackingAdd(candidate) }
                // No separate "unverified-saved" pill — inconclusive lands
                // on .unverified so the user knows re-checking is worthwhile.
                state = .unverified
            }
        }
    }
}

// MARK: - Provider key row

private struct APIKeyRow: View {
    @Bindable var model: APIKeyFieldModel
    let description: String
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsRow(
            label: "\(model.provider.displayName) API Key",
            description: description,
            verticalPadding: RowMetrics.verticalPaddingTall
        ) {
            HStack(spacing: VFSpacing.sm) {
                fieldCapsule
                statusPill
            }
        }
    }

    private var placeholder: String {
        switch model.provider {
        case .openai: return "sk-\u{2026}"
        case .gemini: return "AIza\u{2026}"
        case .anthropic: return "sk-ant-\u{2026}"
        }
    }

    private var fieldCapsule: some View {
        HStack(spacing: VFSpacing.sm) {
            Group {
                if model.isRevealed {
                    TextField(placeholder, text: $model.rawKey)
                } else {
                    SecureField(placeholder, text: $model.rawKey)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.vfTextPrimary)
            .focused($isFocused)
            .onSubmit(model.saveAndValidate)
            .onChange(of: model.rawKey) { _, _ in model.handleEdit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.saveAndValidate() }
            }
            .frame(width: 220)

            Button {
                model.isRevealed.toggle()
            } label: {
                Image(systemName: model.isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
            }
            .buttonStyle(.plain)
            .help(model.isRevealed ? "Hide API key" : "Show API key")
        }
        .padding(.horizontal, VFSpacing.md)
        .padding(.vertical, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.vfControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.vfHairline, lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.state {
        case .verified:   SettingsStatusPill(kind: .verified)
        case .invalid:    SettingsStatusPill(kind: .invalid)
        case .checking:   SettingsStatusPill(kind: .checking)
        case .unverified: SettingsStatusPill(kind: .unverified)
        }
    }
}

// MARK: - Revalidate row

private struct RevalidateRow: View {
    let models: [APIKeyFieldModel]

    var body: some View {
        SettingsRow(
            label: "Revalidate Keys",
            description: "Re-check your stored keys if requests start failing or you rotated one with a provider."
        ) {
            Button("Revalidate") {
                for model in models { model.revalidate() }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .disabled(models.contains { $0.state == .checking })
        }
    }
}

#Preview {
    let prefs = PreferencesStore()
    return APIAuthSection()
        .environment(prefs)
        .environment(LocalModelManager(preferences: prefs))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
