//
//  AccountBillingPane.swift
//  Zerro
//
//  The API Keys & License detail pane. One way to use Zerro: your own
//  provider API keys, with a one-time Zerro license after the 14-day trial.
//  The pane stacks the API-key section, the transcription controls, and the
//  license section — nothing else.
//

import SwiftUI

struct AccountBillingPane: View {
    var body: some View {
        // Matches the pane's 28pt inter-section rhythm (SettingsView.pane).
        VStack(alignment: .leading, spacing: 28) {
            APIAuthSection()
            TranscriptionSection()
            BYOKLicenseSection()
        }
    }
}

// MARK: - Previews
//
// `EntitlementStore.preview` pins the state via the dev override (DEBUG-only),
// so these previews are `#if DEBUG`-guarded — `#Preview` bodies otherwise
// compile in Release too and would fail on the missing symbol.

#if DEBUG
#Preview("Licensed") {
    AccountBillingPane()
        .environment(EntitlementStore.preview(.byok))
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}

#Preview("Free trial") {
    AccountBillingPane()
        .environment(EntitlementStore.preview(.localTrial(daysRemaining: 9)))
        .environment(PreferencesStore())
        .environment(LocalModelManager(preferences: PreferencesStore()))
        .environment(ProviderKeyPresence())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
#endif
