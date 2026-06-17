//
//  ModelPickerSubmenu.swift
//  Zerro
//
//  Phase 6 (multi-model 6A) — the model picker, presented as the menu-bar
//  "Model" row's trailing popover (the same hover-driven submenu shape as
//  Recent Prompts / Microphone). ONE component, mode-aware:
//
//  • Managed / Trial: a balance header (credits remaining, §1.5) above the
//    model rows. NO per-model cost (metered-credits Phase 4): rows are model
//    names only; the only per-recording number the user sees is the actual
//    `credits_charged` post-generation.
//  • BYOK / other: model names only — no balance header (credits are
//    meaningless when the user pays their provider directly). Per-provider
//    key-gating lands with multi-provider BYOK (6C/6D).
//
//  Rows render in registry order; Gemini 3.5 Flash carries the
//  "Recommended" badge. Selecting writes
//  `PreferencesStore.selectedModelID` — the generation path reads it fresh at
//  request time — and dismisses the panel.
//
//  THREE SURFACES, ONE KEY: this submenu and Settings → General → "Default
//  model" (ModelSection) both WRITE `selectedModelID` (the persisted
//  default); the capture toolbar's model chip (AreaSelectorView) SEEDS from
//  it but overrides per-recording without writing back. Keep all three on
//  that contract — a fourth writer or a divergent read re-introduces the
//  "which model am I on?" confusion this split exists to prevent.
//

import SwiftUI

struct ModelPickerSubmenu: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.submenuDismiss) private var dismiss

    /// BYOK key-gating (6C.3): providers with a key on file, loaded fresh on
    /// each open so a Settings change applies immediately. Irrelevant (and
    /// not read) outside `.byok`.
    @State private var availableProviders: Set<ModelProvider> = []

    private var isBYOK: Bool { entitlements.state == .byok }

    var body: some View {
        VStack(spacing: 0) {
            if let balance = creditBalance {
                balanceHeader(balance)
                Rectangle()
                    .fill(Color.vfHairline)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            ForEach(ModelRegistry.enabled) { model in
                // Key-gating: in BYOK a model is selectable only when its
                // provider's key is present; the rest stay VISIBLE but greyed
                // with a hint (the user should see the tool supports them).
                let gated = isBYOK && !availableProviders.contains(model.provider)
                ModelPickerRow(
                    model: model,
                    isSelected: preferences.selectedModelID == model.id,
                    gatedHint: gated ? "Add \(model.provider.displayName) key" : nil
                ) {
                    // Tier 4 analytics: capture the prior id BEFORE the write;
                    // fire only on a real change. Model ids only — no content.
                    let fromModel = preferences.selectedModelID
                    if model.id != fromModel {
                        Analytics.capture("model_changed", [
                            "from_model": fromModel,
                            "to_model": model.id,
                            "surface": "menu_bar",
                        ])
                    }
                    preferences.selectedModelID = model.id
                    dismiss()
                }
            }
        }
        .frame(width: 280)
        .onAppear {
            if isBYOK { availableProviders = ProviderKeys.availableProviders() }
        }
    }

    /// The spendable balance to render against, or `nil` when credits don't
    /// apply (BYOK funds via the user's own provider keys; `.expired` has no
    /// balance to show). Managed reads the snapshot's `creditsRemaining`,
    /// which the backend defines as the COMBINED plan + top-up balance (F4) —
    /// exactly what the server's spend gate checks, so "~N left" can't
    /// promise generations the proxy would refuse.
    private var creditBalance: Int? {
        switch entitlements.state {
        case .managed:
            return entitlements.managedSnapshot?.creditsRemaining
        case .trial(let creditsRemaining):
            return creditsRemaining
        case .byok, .expired:
            return nil
        }
    }

    /// Balance header: credits remaining as the §1.5 PRIMARY number. No
    /// per-model translation line (metered-credits Phase 4) — the balance is
    /// the only credit figure shown here.
    private func balanceHeader(_ balance: Int) -> some View {
        Text("\(CreditDisplay.creditsHeadline(balance)) left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.vfTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - ModelPickerRow

private struct ModelPickerRow: View {
    let model: ModelEntry
    let isSelected: Bool
    /// Non-nil = BYOK key-gated: the row renders dimmed + unselectable with
    /// this trailing hint ("Add Gemini key") as the only trailing element.
    var gatedHint: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    private var isGated: Bool { gatedHint != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                Text(model.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if model.recommended {
                    Text("Recommended")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.vfBrandAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Color.vfBrandAccent.opacity(0.15))
                        )
                        .fixedSize()
                }

                Spacer(minLength: VFSpacing.sm)

                if let hint = gatedHint {
                    // BYOK key-gating hint — the only trailing element now that
                    // the per-model credit column is gone (metered-credits P4).
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vfTextTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, MenuMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered && !isGated ? Color.vfMenuRowHover : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, MenuMetrics.rowHorizontalInset)
        }
        .buttonStyle(.plain)
        .disabled(isGated)
        .opacity(isGated ? 0.45 : 1)
        .help(isGated ? "Add a \(model.provider.displayName) API key in Settings to use this model" : "")
        .onHover { isHovered = $0 }
    }
}

// MARK: - Previews
//
// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too and would fail on the missing symbol.

#if DEBUG
#Preview("Managed — 248 credits") {
    ModelPickerSubmenu()
        .environment(PreferencesStore())
        .environment(EntitlementStore.preview(
            .managed(creditsRemaining: 248, resetDate: .now)
        ))
        .background(.regularMaterial)
}

#Preview("Trial — 40 credits") {
    ModelPickerSubmenu()
        .environment(PreferencesStore())
        .environment(EntitlementStore.preview(.trial(creditsRemaining: 40)))
        .background(.regularMaterial)
}

#Preview("BYOK — no credit UI") {
    ModelPickerSubmenu()
        .environment(PreferencesStore())
        .environment(EntitlementStore.preview(.byok))
        .background(.regularMaterial)
}
#endif
