//
//  Colors.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

extension Color {
    // Brand (monochrome)
    static let vfBrandAccent = Color.white
    // Text/icons sitting on top of a `vfBrandAccent` fill.
    static let vfOnBrand = Color(red: 0.07, green: 0.07, blue: 0.09)

    // Status — Apple HIG palette per the Phase 2.5 design decision
    // (#FF453A / #FF9F0A / #30D158). Values had drifted slightly before
    // Phase 11 R2; re-pinned here so the Settings destructive buttons +
    // Verified pill + Launch-at-Login toggle land on the exact HIG hex.
    static let vfRecordingRed = Color(red: 1.00, green: 0.271, blue: 0.227) // #FF453A
    static let vfWarningAmber = Color(red: 1.00, green: 0.624, blue: 0.039) // #FF9F0A
    static let vfSuccessGreen = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158

    /// Semantic alias for destructive UI (Clear History, Reset to
    /// Defaults, the Delete button in Recent Prompts). Same hex as
    /// `vfRecordingRed`; the named alias keeps the button styles from
    /// reading as if they're coupled to "the recording-pill red" when
    /// the meaning is "destructive action."
    static let vfDestructive = vfRecordingRed

    // Surfaces (dark theme)
    static let vfPanelBackground = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let vfCardBackground = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let vfPillBackground = Color(red: 0.12, green: 0.12, blue: 0.14)

    // Text
    static let vfTextPrimary = Color.white.opacity(0.95)
    static let vfTextSecondary = Color.white.opacity(0.55)
    static let vfTextTertiary = Color.white.opacity(0.35)

    // Borders/separators
    static let vfHairline = Color.white.opacity(0.08)

    // Selection / hover fill used by the menu-bar dropdown rows. Fixed
    // #1868BF — a muted blue that holds up over the panel's dark
    // background without the saturation of full `systemBlue`.
    static let vfMenuRowHover = Color(red: 0x18 / 255.0, green: 0x68 / 255.0, blue: 0xBF / 255.0)

    /// Hover fill for quiet pill controls (secondary buttons, the dismiss "x"
    /// circle). Replaces the literal Color(red: 0.28, green: 0.28, blue: 0.30)
    /// that was copy-pasted across the pill content views.
    static let vfPillControlHover = Color(red: 0.28, green: 0.28, blue: 0.30)

    /// Locked accent for the Phase 17 mode-switch confirmation pill —
    /// the "arrow.left.arrow.right" glyph and the primary "Switch" fill.
    /// Fixed #0A84FF (macOS systemBlue) per the approved Claude Design
    /// mockup. Deliberately NOT `vfBrandAccent` (which is the app's
    /// monochrome white); this is the one place the design calls for a
    /// saturated blue, signalling a reversible per-recording choice
    /// rather than the brand identity.
    static let vfAccentBlue = Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
}
