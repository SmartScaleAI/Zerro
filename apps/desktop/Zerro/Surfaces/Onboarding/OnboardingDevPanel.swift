//
//  OnboardingDevPanel.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  DEBUG-only dev panel that sits below the main onboarding card.
//  Provides:
//    • Step jump pills — leap to any step without walking through the
//      flow.
//    • Sub-state pin pills — on the merged Permissions step, override
//      each permission's live PermissionsManager value with a forced
//      .notDetermined / .granted / .denied (SCREEN + MIC pinned
//      independently) so each sub-state can be rendered without
//      toggling system permissions.
//
//  This is the canonical Phase 5 debug surface — the temporary
//  PermissionsDebugSection in the menu bar dropdown will get folded
//  into this panel and removed from MenuBarPanel by Checkpoint 5.
//

#if DEBUG

import SwiftUI

struct OnboardingDevPanel: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                Text("DEV")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.vfTextTertiary)
                Spacer()
                Text("jump / pin sub-state")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.vfTextTertiary)
            }

            stepJumpRow

            subStatePinRow
        }
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Step jump

    private var stepJumpRow: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                DevPill(
                    label: step.devLabel,
                    isSelected: onboarding.currentStep == step
                ) {
                    onboarding.jump(to: step)
                }
            }
        }
    }

    // MARK: - Sub-state pin

    /// Renders the pin-state row for whichever permission step is
    /// currently active. Other steps render a muted "no sub-states"
    /// label so the panel's height doesn't jump around.
    @ViewBuilder
    private var subStatePinRow: some View {
        switch onboarding.currentStep {
        case .permissions:
            VStack(spacing: VFSpacing.sm) {
                permissionPinRow(label: "SCREEN", binding: bindScreen)
                permissionPinRow(label: "MIC", binding: bindMic)
            }
        case .welcome, .consent, .email, .devMode, .allSet:
            HStack {
                Text("\u{2014}").font(.system(size: 11)).foregroundStyle(Color.vfTextTertiary)
                Text("No sub-states for this step")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
            }
        }
    }

    private func permissionPinRow(label: String, binding: Binding<PermissionStatus?>) -> some View {
        HStack(spacing: VFSpacing.sm) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.vfTextSecondary)
                .frame(width: 58, alignment: .leading)

            DevPill(
                label: "Live",
                isSelected: binding.wrappedValue == nil
            ) { binding.wrappedValue = nil }

            DevPill(
                label: "Before",
                isSelected: binding.wrappedValue == .notDetermined
            ) { binding.wrappedValue = .notDetermined }

            DevPill(
                label: "Granted",
                isSelected: binding.wrappedValue == .granted
            ) { binding.wrappedValue = .granted }

            DevPill(
                label: "Denied",
                isSelected: binding.wrappedValue == .denied
            ) { binding.wrappedValue = .denied }
        }
    }

    // Bindings cross the @Bindable boundary by hand because the dev
    // panel only mutates these fields when DEBUG is compiled in, and
    // @Bindable wrappers add ceremony for production code that never
    // reads them. Direct closures keep the prod surface clean.

    private var bindScreen: Binding<PermissionStatus?> {
        Binding(
            get: { onboarding.pinnedScreenSubState },
            set: { onboarding.pinnedScreenSubState = $0 }
        )
    }

    private var bindMic: Binding<PermissionStatus?> {
        Binding(
            get: { onboarding.pinnedMicSubState },
            set: { onboarding.pinnedMicSubState = $0 }
        )
    }
}

// MARK: - DevPill

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
