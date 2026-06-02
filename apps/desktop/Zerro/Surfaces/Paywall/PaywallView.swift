//
//  PaywallView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Phase A of the billing system — the paywall window's content. Opened
//  ONLY by the recording-start gate when `EntitlementStore.canGenerate`
//  is false (state `.expired`); it never auto-presents at launch (the
//  Window scene uses `.defaultLaunchBehavior(.suppressed)`).
//
//  Reuses the onboarding window's visual chrome wholesale — the same
//  `OnboardingStepLayout`, logo tile, primary/secondary button styles,
//  `vfCardBackground`, and spacing tokens — so the two surfaces read as
//  one app. The copy is non-punitive (the trial ended, here's how to keep
//  going) and presents the three purchase paths.
//
//  Phase A behavior: every button is INERT beyond a log line. Real
//  checkout / license activation lands in Phases C (BYOK) and E (managed
//  subscriptions) — each click site carries a `// DEFERRED Phase X:`
//  marker. Prices are `$X` placeholders (see `Price`) so a real price can
//  be dropped in by find-and-replace without inventing one here.
//

import os
import SwiftUI

struct PaywallView: View {
    var body: some View {
        VStack(spacing: 0) {
            mainPanel

            #if DEBUG
            // Mirrors OnboardingDevPanel's placement: a DEBUG-only panel
            // pinned below the main card so every entitlement state — and
            // thus every gate branch — can be forced without a real
            // billing backend. See PaywallDevPanel.
            PaywallDevPanel()
                .padding(.horizontal, VFSpacing.xxl)
                .padding(.bottom, VFSpacing.lg)
            #endif
        }
        .frame(width: 580)
        .background(Color.vfCardBackground)
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        OnboardingStepLayout {
            OnboardingLogoTile()
        } content: {
            VStack(spacing: VFSpacing.md) {
                Text("Your free trial has ended")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Keep turning a quick screen recording and a sentence of narration into a ready-to-paste prompt. Pick the option that fits how you work.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vfTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            optionStack
        }
        .frame(minHeight: 520)
    }

    // MARK: - Options

    private var optionStack: some View {
        VStack(spacing: VFSpacing.md) {
            // BYOK — one-time license, the user funds generation with their
            // own OpenAI key. Two affordances: buy a new license, or
            // activate one they already hold.
            PaywallOptionCard(
                title: "Bring your own key",
                subtitle: "Pay once. Use your own OpenAI API key — no monthly fee.",
                price: Price.byok,
                primaryLabel: "Get a license",
                primaryAction: {
                    // DEFERRED Phase C: LemonSqueezy checkout + license activation
                    Log.ui.notice("paywall: BYOK 'Get a license' tapped (Phase A no-op)")
                },
                secondaryLabel: "Enter existing license",
                secondaryAction: {
                    // DEFERRED Phase C: LemonSqueezy checkout + license activation
                    Log.ui.notice("paywall: BYOK 'Enter existing license' tapped (Phase A no-op)")
                }
            )

            // Managed Starter — Zerro-hosted credits, smaller monthly allotment.
            PaywallOptionCard(
                title: "Starter",
                subtitle: "We handle the AI. A monthly pool of credits, no API key to manage.",
                price: Price.starter,
                primaryLabel: "Subscribe to Starter",
                primaryAction: {
                    // DEFERRED Phase E: LemonSqueezy subscription checkout
                    Log.ui.notice("paywall: 'Subscribe to Starter' tapped (Phase A no-op)")
                }
            )

            // Managed Pro — Zerro-hosted credits, larger monthly allotment.
            PaywallOptionCard(
                title: "Pro",
                subtitle: "Everything in Starter with a larger monthly credit pool for heavy use.",
                price: Price.pro,
                primaryLabel: "Subscribe to Pro",
                primaryAction: {
                    // DEFERRED Phase E: LemonSqueezy subscription checkout
                    Log.ui.notice("paywall: 'Subscribe to Pro' tapped (Phase A no-op)")
                }
            )
        }
    }
}

// MARK: - Price placeholders

/// Placeholder price strings. Real numbers aren't decided in Phase A, so
/// these stay as `$X` / `$X/mo` literals — grep `TODO: set prices` to find
/// the one place to update once pricing is locked (Phases C/E).
private enum Price {
    // TODO: set prices
    static let byok = "$X"
    // TODO: set prices
    static let starter = "$X/mo"
    // TODO: set prices
    static let pro = "$X/mo"
}

// MARK: - Option card

/// One purchase option: title, one-line value, a price chip, a primary
/// action, and an optional secondary action (used by BYOK for "Enter
/// existing license"). Built from the shared onboarding button styles so
/// it matches the rest of the app's chrome.
private struct PaywallOptionCard: View {
    let title: String
    let subtitle: String
    let price: String
    let primaryLabel: String
    let primaryAction: () -> Void
    var secondaryLabel: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.sm)
                Text(price)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vfTextPrimary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPrimaryButton(primaryLabel, action: primaryAction)
                .padding(.top, VFSpacing.xs)

            if let secondaryLabel, let secondaryAction {
                OnboardingSecondaryButton(secondaryLabel, action: secondaryAction)
            }
        }
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.lg, style: .continuous)
                .strokeBorder(Color.vfHairline, lineWidth: 1)
        )
    }
}

// MARK: - Previews

#Preview("Paywall") {
    PaywallView()
        .environment(EntitlementStore())
}

#Preview("Paywall · option card") {
    VStack(spacing: VFSpacing.md) {
        PaywallOptionCard(
            title: "Bring your own key",
            subtitle: "Pay once. Use your own OpenAI API key — no monthly fee.",
            price: "$X",
            primaryLabel: "Get a license",
            primaryAction: {},
            secondaryLabel: "Enter existing license",
            secondaryAction: {}
        )
        PaywallOptionCard(
            title: "Starter",
            subtitle: "We handle the AI. A monthly pool of credits.",
            price: "$X/mo",
            primaryLabel: "Subscribe to Starter",
            primaryAction: {}
        )
    }
    .padding(VFSpacing.xxl)
    .frame(width: 580)
    .background(Color.vfCardBackground)
}
