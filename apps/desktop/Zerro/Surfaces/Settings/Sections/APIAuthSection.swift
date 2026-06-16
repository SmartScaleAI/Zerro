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
//  The OpenAI key is special: transcription (Whisper) stays OpenAI no matter
//  which chat model is selected, so every BYOK recording needs it — the row
//  copy says so.
//
//  Per-provider Keychain entries are the single source of truth; each field
//  loads from its slot on appear and writes on `.valid` results only — a
//  typo'd key never overwrites a working one. Inconclusive (network) results
//  still write through because the user's *intent* is to rotate. A blanked
//  field deletes the entry (independent remove).
//

import SwiftUI

struct APIAuthSection: View {
    @State private var openAIModel = APIKeyFieldModel(provider: .openai)
    @State private var geminiModel = APIKeyFieldModel(provider: .gemini)
    @State private var anthropicModel = APIKeyFieldModel(provider: .anthropic)

    var body: some View {
        SettingsSection("API Keys") {
            APIKeyRow(
                model: openAIModel,
                description: "Required \u{2014} transcription (Whisper) always runs on OpenAI, whichever chat model you pick. Stored in macOS Keychain."
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

    init(provider: ModelProvider) {
        self.provider = provider
        let slot = ProviderKeys.slot(for: provider)
        self.keychain = slot
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
            // Tier 3 analytics: a present→empty transition is a key removal.
            // Presence only — the key value is never included.
            let hadKey = !(keychain.read()?.isEmpty ?? true)
            keychain.delete()
            state = .unverified
            if hadKey {
                Analytics.capture("byok_key_removed", ["provider": provider.rawValue])
            }
            return
        }
        // Skip the round-trip if nothing actually changed.
        if state == .verified, trimmed == (keychain.read() ?? "") {
            return
        }
        run(validating: trimmed, writeOnValid: true, writeOnInconclusive: true)
    }

    /// Triggered by the Revalidate button — runs validation against the
    /// stored key without re-typing. If the user has typed something
    /// new without blurring yet, we still validate THAT (it matches
    /// their stated intent), but we don't write through on
    /// inconclusive: the field hasn't been committed yet.
    func revalidate() {
        let candidate = trimmedKey.isEmpty
            ? (keychain.read() ?? "")
            : trimmedKey
        guard !candidate.isEmpty else {
            state = .unverified
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
    }

    private func run(validating candidate: String, writeOnValid: Bool, writeOnInconclusive: Bool) {
        state = .checking
        Task { @MainActor in
            let result = await validator(candidate)
            guard state == .checking else { return }
            switch result {
            case .valid:
                if writeOnValid { writeKeyTrackingAdd(candidate) }
                state = .verified
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
                .fill(Color.vfPillBackground)
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
    APIAuthSection()
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
