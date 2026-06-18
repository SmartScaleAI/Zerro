//
//  PillControls.swift
//  Zerro
//
//  The shared control vocabulary for the pill family. Every pill state
//  (recording, processing, error, recovery, paid-block, result, dev-result,
//  anchors…) used to hand-roll its own buttons and status icons, which drifted:
//  four different primary fills, three secondary treatments, badged vs. bare
//  leading icons, and the hover-gray copy-pasted as a literal in ~5 places.
//
//  These four components are the canonical replacements, applied with a
//  semantic-by-intent color rule (see the per-view call sites in PillView.swift
//  and ArtifactCardView.swift):
//
//    - PillPrimaryButton    — the one filled button; .role picks the fill.
//    - PillSecondaryButton  — the quiet text button (Cancel / Discard / Revert).
//    - PillDismissButton    — the corner "x".
//    - PillLeadingIconBadge — the badged status icon (every leading icon).
//
//  Pure renderers: geometry comes from `PillMetrics`, color from the semantic
//  tokens in `Colors.swift`. No state logic lives here.
//

import SwiftUI

// MARK: - PillPrimaryButton

/// The one filled button in the pill family. `role` is the semantic intent and
/// drives the capsule fill + label color; everything else (13pt semibold label,
/// optional 11pt leading symbol, padding, capsule, no border) is fixed.
struct PillPrimaryButton: View {
    enum Role {
        case positive     // forward "go" action   → vfBrandAccent (white) fill, vfOnBrand text
        case warning      // error / upgrade        → vfWarningAmber fill, vfOnBrand text
        case destructive  // stop / delete          → vfDestructive fill, white text
        case reversible   // recovery / mode-switch → vfAccentBlue fill, white text
    }

    let title: String
    /// Leading SF symbol, 11pt semibold, 6pt gap before the label.
    var systemImage: String? = nil
    let role: Role
    let action: () -> Void

    /// Capsule fill — the semantic intent color.
    private var fill: Color {
        switch role {
        case .positive:    return .vfBrandAccent
        case .warning:     return .vfWarningAmber
        case .destructive: return .vfDestructive
        case .reversible:  return .vfAccentBlue
        }
    }

    /// Label/icon color. The light fills (.positive white, .warning amber) take
    /// the near-black `vfOnBrand`; the saturated fills (.destructive red,
    /// .reversible blue) take pure white.
    private var foreground: Color {
        switch role {
        case .positive, .warning:     return .vfOnBrand
        case .destructive, .reversible: return .white
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, PillMetrics.primaryHPad)
            .padding(.vertical, PillMetrics.primaryVPad)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - PillSecondaryButton

/// The quiet text button — Cancel / Discard / Revert. 13pt regular, secondary
/// text that bumps to primary on hover, and a gray hover capsule
/// (`vfPillControlHover`) that fades in only under the cursor. No leading icon
/// (drops the xmark the recording/processing Cancel used to carry).
struct PillSecondaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isHovering ? Color.vfTextPrimary : Color.vfTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(height: PillMetrics.controlHeight)
                .background(
                    Capsule()
                        .fill(Color.vfPillControlHover)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .fixedSize()
    }
}

// MARK: - PillDismissButton

/// The corner "x" — the canonical dismiss affordance for every pill state. The
/// glyph is always visible (secondary at rest, primary on hover); only the
/// circular gray background (`vfPillControlHover`) fades in under the cursor.
struct PillDismissButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? Color.vfTextPrimary : Color.vfTextSecondary)
                .frame(width: PillMetrics.dismissBadge, height: PillMetrics.dismissBadge)
                .background(
                    Circle()
                        .fill(Color.vfPillControlHover)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - PillLeadingIconBadge

/// The badged leading status icon — used by every pill state's status glyph so
/// the success/warning/recovery indicators all read at the same weight. A
/// `tint`-colored SF symbol in a soft `tint.opacity(0.20)` circle.
struct PillLeadingIconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: PillMetrics.iconBadge, height: PillMetrics.iconBadge)
            .background(Circle().fill(tint.opacity(0.20)))
    }
}

// MARK: - Previews

#Preview("PillControls") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
            PillPrimaryButton(title: "Confirm", role: .positive) {}
            PillPrimaryButton(title: "Retry", systemImage: "arrow.clockwise", role: .warning) {}
            PillPrimaryButton(title: "Stop", systemImage: "stop.fill", role: .destructive) {}
            PillPrimaryButton(title: "Generate", role: .reversible) {}
        }
        HStack(spacing: 12) {
            PillSecondaryButton(title: "Cancel") {}
            PillSecondaryButton(title: "Discard") {}
            PillDismissButton {}
        }
        HStack(spacing: 12) {
            PillLeadingIconBadge(systemImage: "checkmark", tint: .vfSuccessGreen)
            PillLeadingIconBadge(systemImage: "exclamationmark.triangle.fill", tint: .vfWarningAmber)
            PillLeadingIconBadge(systemImage: "arrow.clockwise", tint: .vfAccentBlue)
        }
    }
    .padding(40)
    .background(Color.vfPanelBackground)
}
