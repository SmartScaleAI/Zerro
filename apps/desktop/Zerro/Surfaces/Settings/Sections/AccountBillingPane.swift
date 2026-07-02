//
//  AccountBillingPane.swift
//  Zerro
//
//  Phase 6 (multi-model 6E) — the Account & Billing detail pane, restructured
//  as a clean EITHER/OR: the user is in exactly ONE mode at a time —
//
//    • Managed — Zerro's plan + credits (BillingSection: usage meter, plan,
//      subscription key, subscribe/manage). No API-key fields.
//    • BYOK — bring your own API keys (APIAuthSection + BYOKLicenseSection).
//      No plan/credit/meter UI; plan-state strings ("Expired" etc.) never
//      render here.
//
//  This replaces the old screen that stacked the API-key section AND the
//  license section simultaneously (it read as a checklist, not a choice, and
//  showed contradictory states like "Plan: Expired" next to a working key).
//
//  MODE SOURCE OF TRUTH (6D/F6): `EntitlementState` — `.byok` shows the BYOK
//  pane; `.managed`/`.trial`/`.expired` are all server-credit-side states and
//  show the Managed pane. The "switch" link is a VIEW override only: it
//  reveals the other mode's setup so the user can complete it (add keys /
//  activate a license / subscribe); the entitlement actually flips when that
//  setup succeeds, at which point the override resets and the pane follows
//  the real state again.
//

import SwiftUI

struct AccountBillingPane: View {
    @Environment(EntitlementStore.self) private var entitlements

    /// Which mode the pane is showing. Derived from the entitlement unless
    /// the user clicked the switch link to set up the other mode.
    enum BillingMode: Equatable {
        case managed
        case byok
    }

    /// The view-level switch override (6E.3). `nil` = follow the entitlement.
    @State private var overrideMode: BillingMode?

    private var entitlementMode: BillingMode {
        entitlements.state == .byok ? .byok : .managed
    }

    private var mode: BillingMode { overrideMode ?? entitlementMode }

    /// True while the user is previewing/setting up the NON-active mode.
    private var isPreviewingOtherMode: Bool {
        overrideMode != nil && overrideMode != entitlementMode
    }

    var body: some View {
        // Matches the pane's 28pt inter-section rhythm (SettingsView.pane).
        VStack(alignment: .leading, spacing: 28) {
            modeSection

            switch mode {
            case .managed:
                BillingSection()
            case .byok:
                APIAuthSection()
                TranscriptionSection()
                BYOKLicenseSection()
            }
        }
        // The entitlement flipped (activation/subscription landed, license
        // deactivated, …) — drop any preview override and follow reality.
        .onChange(of: entitlements.state) { _, _ in overrideMode = nil }
    }

    // MARK: - Mode selector (6E.1 + 6E.3)

    private var modeSection: some View {
        SettingsSection("How You\u{2019}re Using Zerro") {
            SettingsRow(
                label: modeTitle,
                description: modeDescription,
                verticalPadding: RowMetrics.verticalPaddingTall
            ) {
                Button(switchLabel) {
                    overrideMode = (mode == .managed) ? .byok : .managed
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
            }
        }
    }

    private var modeTitle: String {
        switch mode {
        case .managed: return "Managed \u{2014} Zerro\u{2019}s plan + credits"
        case .byok: return "Bring your own API keys (BYOK)"
        }
    }

    private var modeDescription: String {
        if isPreviewingOtherMode {
            switch mode {
            case .managed:
                return "Finish setup below to switch: subscribe, then activate the key from your purchase email."
            case .byok:
                return "Finish setup below to switch: activate a BYOK license and add your API keys."
            }
        }
        switch mode {
        case .managed:
            return "Generation runs on Zerro-hosted credits \u{2014} the simplest way to use Zerro."
        case .byok:
            return "You pay your providers directly for usage \u{2014} no credits involved."
        }
    }

    /// The ONE low-key switch affordance (6E.3) — flips the pane to the other
    /// mode's setup, or back, without touching the entitlement itself.
    private var switchLabel: String {
        if isPreviewingOtherMode {
            return entitlementMode == .managed ? "Back to Managed" : "Back to BYOK"
        }
        switch mode {
        case .managed: return "Switch to BYOK"
        case .byok: return "Switch to Managed"
        }
    }
}

// MARK: - Previews
//
// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too and would fail on the missing symbol.

#if DEBUG
#Preview("Managed") {
    AccountBillingPane()
        .environment(EntitlementStore.preview(
            .managed(creditsRemaining: 248, resetDate: .now.addingTimeInterval(86_400 * 12))
        ))
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("BYOK") {
    AccountBillingPane()
        .environment(EntitlementStore.preview(.byok))
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("Trial") {
    AccountBillingPane()
        .environment(EntitlementStore.preview(.trial(creditsRemaining: 34)))
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
#endif
