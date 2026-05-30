//
//  APIAuthSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — API & Authentication section of the redesigned single-pane
//  Settings layout. Two rows:
//    1. API Key   — masked monospace field (with eye toggle) + pill
//                   showing the live verification disposition. The pill
//                   states drive off `OpenAIClient.validateKey`, the
//                   same validator the onboarding API-key step uses.
//    2. Revalidate Key — secondary button that re-runs validation
//                   against the currently-stored key without requiring
//                   the user to re-type it.
//
//  The Keychain entry itself is the single source of truth; the field
//  loads from it on appear and writes on `.valid` results only — a typo'd
//  key never overwrites a working one. Inconclusive (network) results
//  still write through because the user's *intent* is to rotate.
//

import SwiftUI

struct APIAuthSection: View {
    @State private var model = APIKeyFieldModel()

    var body: some View {
        SettingsSection("API & Authentication") {
            APIKeyRow(model: model)
            SettingsRowDivider()
            RevalidateRow(model: model)
        }
    }
}

// MARK: - Shared model

/// One instance shared by both rows so the Revalidate button can act on
/// whatever the user has currently typed (or whatever's in Keychain),
/// and so the pill state updates in lockstep on either path.
@MainActor
@Observable
final class APIKeyFieldModel {
    enum State: Equatable {
        case unverified
        case checking
        case verified
        case invalid
    }

    var rawKey: String = ""
    var isRevealed: Bool = false
    var state: State = .unverified

    @ObservationIgnored private let keychain = KeychainStore.openAIAPIKey

    init() {
        let stored = keychain.read() ?? ""
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
    /// Empty input deletes the Keychain entry; non-empty triggers
    /// validation against the provider.
    func saveAndValidate() {
        let trimmed = trimmedKey
        if trimmed.isEmpty {
            keychain.delete()
            state = .unverified
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

    private func run(validating candidate: String, writeOnValid: Bool, writeOnInconclusive: Bool) {
        state = .checking
        Task { @MainActor in
            let result = await OpenAIClient.validateKey(candidate)
            guard state == .checking else { return }
            switch result {
            case .valid:
                if writeOnValid { keychain.write(candidate) }
                state = .verified
            case .invalidKey:
                state = .invalid
            case .inconclusive:
                if writeOnInconclusive { keychain.write(candidate) }
                // We don't have a separate "unverified-saved" pill in
                // the redesigned single-pane layout; the spec specifies
                // only Verified / Invalid / Checking / Unverified.
                // Inconclusive lands on .unverified so the user knows
                // re-checking is worthwhile.
                state = .unverified
            }
        }
    }
}

// MARK: - API Key row

private struct APIKeyRow: View {
    @Bindable var model: APIKeyFieldModel
    @FocusState private var isFocused: Bool

    var body: some View {
        // Round 4: 18pt vertical padding (vs. the standard 14pt) lets
        // the field + pill + 2-line description breathe without the
        // pill feeling squeezed against the row's hairline divider.
        SettingsRow(
            label: "API Key",
            description: "Stored in macOS Keychain \u{2014} never sent to our servers.",
            verticalPadding: RowMetrics.verticalPaddingTall
        ) {
            HStack(spacing: VFSpacing.sm) {
                fieldCapsule
                statusPill
            }
        }
    }

    private var fieldCapsule: some View {
        // Round 4: SF Mono 13pt, 10pt corner radius. Fixed height
        // (36pt) keeps the capsule from inheriting the row's
        // alignment-driven height and matches the pill's height for
        // clean horizontal alignment.
        HStack(spacing: VFSpacing.sm) {
            Group {
                if model.isRevealed {
                    TextField("sk-\u{2026}", text: $model.rawKey)
                } else {
                    SecureField("sk-\u{2026}", text: $model.rawKey)
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
    @Bindable var model: APIKeyFieldModel

    var body: some View {
        SettingsRow(
            label: "Revalidate Key",
            description: "Re-check your key if requests start failing or you rotated it with your provider."
        ) {
            Button("Revalidate") { model.revalidate() }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(model.state == .checking)
        }
    }
}

#Preview {
    APIAuthSection()
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
