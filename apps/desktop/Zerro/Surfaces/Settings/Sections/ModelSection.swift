//
//  ModelSection.swift
//  Zerro
//
//  Multi-model — the "Default model" control in Settings (General pane).
//  Writes `PreferencesStore.selectedModelID`: the model every recording
//  starts with. The capture toolbar's model chip seeds from this value
//  and can override it for a single recording WITHOUT changing it (the
//  menu-bar Model submenu, by contrast, writes this same default).
//
//  Mode rules mirror ModelPickerSubmenu (one rendering contract for
//  every model list):
//  • Managed / Trial — each row shows its credit price
//    ("Claude Opus 4.7 · 10 credits", §1.5: credits are the unit).
//  • BYOK — names only (credits are meaningless) + per-provider
//    key-gating: a model whose provider has no key on file renders
//    disabled with an "add key" hint.
//
//  A Menu (not Picker(.menu)) because Picker rows can't be individually
//  disabled, and BYOK gating needs exactly that.
//

import SwiftUI

struct ModelSection: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementStore.self) private var entitlements

    /// BYOK key-gating: providers with a key on file, refreshed on each
    /// appearance so a key added in the API Keys section applies
    /// immediately. Not read outside `.byok`.
    @State private var availableProviders: Set<ModelProvider> = []

    private var isBYOK: Bool { entitlements.state == .byok }

    var body: some View {
        SettingsSection("Model") {
            SettingsStackedRow(
                label: "Default model",
                trailing: { modelMenu },
                below: { caption }
            )
        }
        .onAppear {
            if isBYOK { availableProviders = ProviderKeys.availableProviders() }
        }
    }

    // MARK: - Menu

    private var modelMenu: some View {
        Menu {
            ForEach(ModelRegistry.enabled) { model in
                let gated = isGated(model)
                Button {
                    // Tier 4 analytics: prior id BEFORE the write; only on a
                    // real change. Model ids only — no content.
                    let fromModel = preferences.selectedModelID
                    if model.id != fromModel {
                        Analytics.capture("model_changed", [
                            "from_model": fromModel,
                            "to_model": model.id,
                            "surface": "settings",
                        ])
                    }
                    preferences.selectedModelID = model.id
                } label: {
                    // The selected row carries the checkmark (menus on
                    // macOS render the systemImage leading, mirroring
                    // native pull-downs).
                    if preferences.selectedModelID == model.id {
                        Label(rowTitle(model), systemImage: "checkmark")
                    } else {
                        Text(rowTitle(model))
                    }
                }
                .disabled(gated)
            }
        } label: {
            Text(selectedTitle)
                .lineLimit(1)
        }
        // Fixed slot width (240pt accommodates "Gemini 3.5 Flash ·
        // 4 credits"); .trailing pins the menu button's right edge to
        // the row's 20pt padding so it lines up with the mic picker
        // and the segmented mode control.
        .frame(width: 240, alignment: .trailing)
    }

    /// The closed-state label: the current default, with its price in
    /// Managed/Trial ("Gemini 3.5 Flash · 4 credits").
    private var selectedTitle: String {
        guard let entry = ModelRegistry.entry(id: preferences.selectedModelID) else {
            return preferences.selectedModelID
        }
        return title(for: entry, withBadge: false)
    }

    /// Row label: name, price (Managed/Trial), Recommended marker, or
    /// the BYOK "add key" hint on gated rows.
    private func rowTitle(_ model: ModelEntry) -> String {
        if isGated(model) {
            return "\(model.displayName) \u{2014} add \(model.provider.displayName) key"
        }
        return title(for: model, withBadge: true)
    }

    private func title(for model: ModelEntry, withBadge: Bool) -> String {
        var text = model.displayName
        if showsCredits {
            let credits = model.creditPrice == 1 ? "1 credit" : "\(model.creditPrice) credits"
            text += " \u{00B7} \(credits)"
        }
        if withBadge && model.recommended {
            text += " \u{00B7} Recommended"
        }
        return text
    }

    /// Credits render in Managed/Trial only — never BYOK/expired (§1.5;
    /// same rule as ModelPickerSubmenu and the toolbar dropdown).
    private var showsCredits: Bool {
        switch entitlements.state {
        case .managed, .trial: return true
        case .byok, .expired: return false
        }
    }

    private func isGated(_ model: ModelEntry) -> Bool {
        isBYOK && !availableProviders.contains(model.provider)
    }

    // MARK: - Caption

    private var caption: some View {
        Text("New recordings start with this model. The capture toolbar can switch the model for a single recording without changing this default.")
            .font(.system(size: 12))
            .foregroundStyle(Color.vfTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews
//
// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too and would fail on the missing symbol.

#if DEBUG
#Preview("Managed") {
    ModelSection()
        .environment(PreferencesStore())
        .environment(EntitlementStore.preview(
            .managed(tier: .pro, creditsRemaining: 248, resetDate: .now)
        ))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("BYOK") {
    ModelSection()
        .environment(PreferencesStore())
        .environment(EntitlementStore.preview(.byok))
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
#endif
