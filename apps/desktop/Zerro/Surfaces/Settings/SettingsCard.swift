//
//  SettingsCard.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Reusable primitives for the single-pane Settings layout introduced in
//  Phase 11. Composes into uppercase-tracked section headers + rounded
//  card containers + label/description rows with consistent padding and
//  hairline dividers. The card visuals lean on the existing
//  `vfCardBackground` / `vfHairline` design tokens so this surface stays
//  in lockstep with the rest of the app.
//
//  Composition pattern callers use:
//
//      SettingsSection("API & Authentication") {
//          SettingsRow(
//              label: "API Key",
//              description: "Stored in macOS Keychain — never sent…"
//          ) { keyField }
//          SettingsRowDivider()
//          SettingsRow(
//              label: "Revalidate Key",
//              description: "Re-check your key if requests fail…"
//          ) { revalidateButton }
//      }
//

import SwiftUI

// MARK: - Section

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        // Round 3: header → card spacing locked at 12pt. Section
        // header tracking bumped to 0.88pt which is exactly 0.08em at
        // the 11pt label size.
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(Color.vfTextSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            SettingsCard { content() }
        }
    }
}

// MARK: - Card

/// Round 3: card corner radius locked at 12pt. Lives at file scope
/// because Swift doesn't permit static stored properties inside
/// generic types, and SettingsCard is generic over its content. Don't
/// reuse VFRadius.lg (14pt) — that token is used elsewhere in the app
/// (action buttons, area selector) and changing it would affect
/// surfaces that aren't part of this redesign.
private let settingsCardCornerRadius: CGFloat = 12

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: settingsCardCornerRadius, style: .continuous)
                .fill(Color.vfCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: settingsCardCornerRadius, style: .continuous)
                .strokeBorder(Color.vfHairline, lineWidth: 0.5)
        )
    }
}

// MARK: - Row metrics
//
// Single source of truth for the dimensions shared across all row
// variants and the inter-row divider. Keeps the card-internal rhythm
// consistent: change one constant, every row + divider moves together.

enum RowMetrics {
    /// Row horizontal padding from the card edge. 20pt per the Phase
    /// 11 R3 spec.
    static let horizontalPadding: CGFloat = 20
    /// Row vertical padding (top + bottom).
    static let verticalPadding: CGFloat = 14
    /// Slightly taller variant for content-heavy rows (the API Key
    /// row's trailing field carries the masked key + eye toggle + pill
    /// on the same horizontal line, which reads better with a touch
    /// more breathing room).
    static let verticalPaddingTall: CGFloat = 18
}

// MARK: - Row

/// Standard row: bold label + (optional) gray description on the left,
/// arbitrary trailing control on the right. Caller-supplied trailing
/// view is right-aligned and gets its own intrinsic width.
///
/// `verticalPadding` defaults to the shared `RowMetrics.verticalPadding`
/// (14pt). Callers can override per-row for content-heavy rows like
/// the API Key row, whose trailing field is taller than the standard
/// row and benefits from a touch more breathing room.
struct SettingsRow<Trailing: View>: View {
    let label: String
    let description: String?
    let verticalPadding: CGFloat
    @ViewBuilder let trailing: () -> Trailing

    init(
        label: String,
        description: String? = nil,
        verticalPadding: CGFloat = RowMetrics.verticalPadding,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.label = label
        self.description = description
        self.verticalPadding = verticalPadding
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: VFSpacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: VFSpacing.md)
            trailing()
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stacked row

/// Variant of SettingsRow that lets the caller place secondary content
/// (e.g. an Output Mode caption) BELOW the label/control pair without
/// reaching into another card. Trailing aligned to the label row.
struct SettingsStackedRow<Trailing: View, Below: View>: View {
    let label: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(alignment: .center, spacing: VFSpacing.lg) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer(minLength: VFSpacing.md)
                trailing()
            }
            below()
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, RowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Navigation row

/// Full-width clickable row with a trailing chevron. Used for the
/// Recent Prompts and Send Feedback rows that lead somewhere on click.
struct SettingsNavigationRow: View {
    let label: String
    let description: String?
    let action: () -> Void

    @State private var isHovered = false

    init(label: String, description: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.description = description
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: VFSpacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                    if let description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vfTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: VFSpacing.md)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.vfTextTertiary)
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, RowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.white.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Divider

/// Hairline divider used between rows inside a SettingsCard. Inset by
/// the row's horizontal padding so the line doesn't run all the way
/// from edge to edge.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.vfHairline)
            .frame(height: 0.5)
            .padding(.horizontal, RowMetrics.horizontalPadding)
    }
}

// MARK: - Button styles
//
// SwiftUI's stock button styles either match the system tint (blue) or
// look out of place against the dark card surface. These two styles
// give the spec's "secondary" and "destructive" affordances a single
// home so every section uses the same chrome.

struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

struct SettingsDestructiveButtonStyle: ButtonStyle {
    // Round 3: tuned to spec — 1pt border at 60% red opacity, 8% red
    // background, label at full red. Pressed state bumps the fill to
    // 16% for the typical "pressed" affordance without rebounding to
    // a different color.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfDestructive)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.vfDestructive.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.vfDestructive.opacity(0.60), lineWidth: 1)
            )
    }
}

// MARK: - Switch toggle style
//
// Drop-in replacement for the native `.toggleStyle(.switch)` (an AppKit
// NSSwitch) on the Settings toggles. The native switch intermittently drew
// its green track but NOT its white knob when the Settings window first
// appeared mid-animation, before it was key/main — "green background, no
// knob, resolves on interaction." Root cause is native-layer draw timing:
// the knob layer lagged a frame. Drawing the knob as a SwiftUI `Circle`
// removes that timing entirely — the shape is part of the SwiftUI layout,
// so it renders deterministically on first paint, every open. It also
// unifies the toggle look with the app's green-on / neutral-off / white-
// knob design family. Lives here so every Settings section shares one
// switch chrome (same "single home" rationale as the button styles above).

struct VFSwitchToggleStyle: ToggleStyle {
    // The Settings rows render their own visible label + description and
    // call `.labelsHidden()` on the Toggle, so honor that here the way the
    // native style does — otherwise the Toggle's own label would draw a
    // second time next to the switch.
    @Environment(\.labelsVisibility) private var labelsVisibility

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: VFSpacing.md) {
            if labelsVisibility != .hidden {
                configuration.label
                Spacer(minLength: 0)
            }
            VFSwitch(isOn: configuration.isOn)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
        }
        // We've left the native control, so re-expose a switch to
        // assistive tech: VoiceOver announces it as a toggle with its
        // on/off value and the same label the row provides.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The switch visual: a Capsule track + a SwiftUI `Circle` knob. The knob
/// is a plain shape (not a native layer), so it always renders. Dimensions
/// match the native NSSwitch footprint (38×22) so swapping the style in
/// doesn't shift the surrounding row layout.
private struct VFSwitch: View {
    let isOn: Bool

    private let trackWidth: CGFloat = 38
    private let trackHeight: CGFloat = 22
    private let knobInset: CGFloat = 2

    private var knobDiameter: CGFloat { trackHeight - knobInset * 2 }
    /// Distance the knob center travels from track center to either edge.
    private var knobOffset: CGFloat { (trackWidth - trackHeight) / 2 }

    var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? Color.vfSuccessGreen : Color.white.opacity(0.18))
            .frame(width: trackWidth, height: trackHeight)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: isOn ? knobOffset : -knobOffset)
            )
            .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

// MARK: - Verification pill
//
// Small green/red/neutral pill on the right of the API key field showing
// the validation disposition. Lives here (vs. the section file) so its
// shape can be reused if other fields ever surface a verified state.

struct SettingsStatusPill: View {
    enum Kind {
        case verified
        case invalid
        case checking
        case unverified
    }

    let kind: Kind

    // Round 4 fix for the stretched-pill regression: `.fixedSize()`
    // pins both axes to the content's intrinsic dimensions, so even
    // when the surrounding HStack squeezes horizontal space the pill
    // can't collapse and force its "Verified" text to wrap character-
    // by-character (which is what stretched the capsule vertically
    // into a tall green tablet). Border overlay removed per spec —
    // the design wants a clean filled capsule.
    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 36)
        .background(
            Capsule(style: .continuous)
                .fill(background)
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .verified:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
        case .invalid:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
                .scaleEffect(0.85)
                .frame(width: 12, height: 12)
        case .unverified:
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
        }
    }

    private var label: String {
        switch kind {
        case .verified:   return "Verified"
        case .invalid:    return "Invalid"
        case .checking:   return "Checking\u{2026}"
        case .unverified: return "Unverified"
        }
    }

    private var foreground: Color {
        switch kind {
        case .verified:   return Color.vfSuccessGreen
        case .invalid:    return Color.vfRecordingRed
        case .checking:   return Color.vfTextSecondary
        case .unverified: return Color.vfWarningAmber
        }
    }

    private var background: Color {
        switch kind {
        case .verified:   return Color.vfSuccessGreen.opacity(0.18)
        case .invalid:    return Color.vfRecordingRed.opacity(0.18)
        case .checking:   return Color.white.opacity(0.06)
        case .unverified: return Color.vfWarningAmber.opacity(0.18)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: VFSpacing.xl) {
            SettingsSection("API & Authentication") {
                SettingsRow(label: "API Key", description: "Stored in macOS Keychain.") {
                    SettingsStatusPill(kind: .verified)
                }
                SettingsRowDivider()
                SettingsRow(label: "Revalidate Key", description: "Re-check your key.") {
                    Button("Revalidate") {}
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }
            SettingsSection("History") {
                SettingsNavigationRow(
                    label: "Recent Results",
                    description: "Browse and re-copy your last results."
                ) {}
                SettingsRowDivider()
                SettingsRow(label: "Clear History", description: "Permanently deletes every saved result.") {
                    Button("Clear History\u{2026}") {}
                        .buttonStyle(SettingsDestructiveButtonStyle())
                }
            }
        }
        .padding()
    }
    .frame(width: 640, height: 400)
    .background(Color.vfPanelBackground)
}
