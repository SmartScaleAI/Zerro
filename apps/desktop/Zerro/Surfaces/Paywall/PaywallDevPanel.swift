//
//  PaywallDevPanel.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  DEBUG-only dev panel that sits below the paywall card, mirroring
//  `OnboardingDevPanel`'s placement and pill styling. Forces the shared
//  `EntitlementStore` into any `EntitlementState` so every gate branch
//  can be exercised without a real billing backend:
//    • `.trial` / `.byok` / `.managed` → the gate grants access, so the
//      hotkey reaches the area selector.
//    • `.expired` → the gate refuses and opens this paywall.
//
//  Because the default dev state is `.trial`, the paywall won't open on
//  its own — use the matching entitlement rows in the menu-bar DEBUG
//  section (MenuBarPanelView) to force `.expired` and open it the first
//  time; from here you can flip between every state.
//

#if DEBUG

import SwiftUI

struct PaywallDevPanel: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                Text("DEV")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.vfTextTertiary)
                Spacer()
                Text("force entitlement state")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfTextTertiary)
            }

            // Wraps so all five state pills fit the 580-wide card without
            // forcing a single overflowing row.
            FlowingPills(
                items: EntitlementStore.devStates,
                isSelected: { entitlements.devMatches($0.state) },
                label: { $0.label },
                action: { entitlements.devSetState($0.state) }
            )
        }
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - FlowingPills

/// A simple two-row pill layout for the five entitlement states. Kept
/// local to the dev panel — it doesn't need to be a general-purpose flow
/// layout, just enough to keep the pills from overflowing the card.
private struct FlowingPills<Item>: View {
    let items: [Item]
    let isSelected: (Item) -> Bool
    let label: (Item) -> String
    let action: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(rows[rowIndex].indices, id: \.self) { itemIndex in
                        let item = rows[rowIndex][itemIndex]
                        DevPill(
                            label: label(item),
                            isSelected: isSelected(item)
                        ) {
                            action(item)
                        }
                    }
                }
            }
        }
    }

    /// Splits the items into rows of at most three pills.
    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0 ..< min($0 + 3, items.count)])
        }
    }
}

// MARK: - DevPill

/// Local copy of the onboarding dev panel's pill — the original is
/// `private` to OnboardingDevPanel, so we mirror it here rather than
/// widening that file's access surface for a DEBUG-only control.
private struct DevPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.vfOnBrand : Color.vfTextSecondary)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.vfBrandAccent : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

#endif
