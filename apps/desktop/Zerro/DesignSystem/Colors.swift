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

    /// Dev Mode accent — the one place the otherwise-monochrome selection +
    /// toolbar chrome turns chromatic, to signal "this recording dispatches to
    /// a coding agent." Fixed #34E27A. `vfOnBrand` (the near-black above) is the
    /// text/knob color to sit ON this green for contrast. Gated entirely on
    /// `state.isDevMode`; nothing renders green when Dev Mode is off.
    static let vfDevAccent = Color(red: 0.204, green: 0.886, blue: 0.478) // #34E27A

    // Status — Apple HIG palette per the Phase 2.5 design decision
    // (#FF453A / #FF9F0A / #30D158). Values had drifted slightly before
    // Phase 11 R2; re-pinned here so the Settings destructive buttons +
    // Verified pill + Launch-at-Login toggle land on the exact HIG hex.
    static let vfRecordingRed = Color(red: 1.00, green: 0.271, blue: 0.227) // #FF453A
    static let vfWarningAmber = Color(red: 1.00, green: 0.624, blue: 0.039) // #FF9F0A
    static let vfSuccessGreen = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158

    /// Staging build-distinction accent — the single amber/orange used by every
    /// "this is the Staging build" marker (recording-overlay border + badge,
    /// menu-bar icon tint, app-icon ribbon) so they read as one family and can
    /// never be confused with production. Fixed #FF9500 (vivid orange-amber),
    /// deliberately distinct from `vfRecordingRed` and `vfWarningAmber`. Only
    /// referenced from `#if STAGING` paths, so it never paints in production.
    static let vfStagingAccent = Color(red: 1.00, green: 0.584, blue: 0.0) // #FF9500

    /// Semantic alias for destructive UI (Clear History, Reset to
    /// Defaults, the Delete button in Recent Prompts). Same hex as
    /// `vfRecordingRed`; the named alias keeps the button styles from
    /// reading as if they're coupled to "the recording-pill red" when
    /// the meaning is "destructive action."
    static let vfDestructive = vfRecordingRed

    // Surfaces (fixed black theme)
    // Base / main background for every first-party Zerro window and panel.
    static let vfPanelBackground = Color.black // #000000
    // Pill shells share the pure-black base across every compact/expanded state.
    static let vfPillBackground = Color.black // #000000

    // The single raised accent gray used over the black base throughout the
    // app. Fixed #1C1C1E: light enough to establish card/control boundaries,
    // still dark enough that the application reads as a black theme.
    static let vfAccentGray = Color(
        red: 28.0 / 255.0,
        green: 28.0 / 255.0,
        blue: 30.0 / 255.0
    ) // #1C1C1E

    // Semantic aliases keep intent readable while guaranteeing that cards,
    // overlays, artifacts, fields, selects, and selected segments share the
    // same accent gray. Future palette tuning happens at `vfAccentGray`.
    static let vfCardBackground = vfAccentGray
    static let vfOverlayBackground = vfAccentGray
    static let vfArtifactBackground = vfAccentGray
    // Hover/pressed overlays remain local interaction feedback.
    static let vfControlBackground = vfAccentGray
    // Overlay dropdown panels use the same default gray as their toolbar
    // triggers. Keep this semantic alias tied to `vfControlBackground` so the
    // two surfaces cannot drift during future palette adjustments.
    static let vfDropdownBackground = vfControlBackground

    // Custom dropdown interaction states. These deliberately step up from the
    // #1C1C1E panel instead of reusing it: a quiet hover, a persistent
    // selection, then a slightly brighter selected-hover state. Other menus,
    // including the intentionally blue menu-bar panel, retain their own styling.
    static let vfDropdownRowHover = Color(
        red: 36.0 / 255.0,
        green: 36.0 / 255.0,
        blue: 38.0 / 255.0
    ) // #242426
    static let vfDropdownRowSelected = Color(
        red: 44.0 / 255.0,
        green: 44.0 / 255.0,
        blue: 46.0 / 255.0
    ) // #2C2C2E
    static let vfDropdownRowSelectedHover = Color(
        red: 52.0 / 255.0,
        green: 52.0 / 255.0,
        blue: 55.0 / 255.0
    ) // #343437

    // Text
    static let vfTextPrimary = Color.white.opacity(0.95)
    static let vfTextSecondary = Color.white.opacity(0.55)
    static let vfTextTertiary = Color.white.opacity(0.35)

    // Borders/separators
    static let vfHairline = Color.white.opacity(0.08)
    // Outer edge for floating overlays and pills. Fixed #303030 so pure-black
    // Zerro chrome stays distinguishable over black captured content; internal
    // separators continue using the quieter `vfHairline`.
    static let vfOverlayBorder = Color(
        red: 48.0 / 255.0,
        green: 48.0 / 255.0,
        blue: 48.0 / 255.0
    ) // #303030

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
