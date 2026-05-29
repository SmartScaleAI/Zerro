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

    // Status
    static let vfRecordingRed = Color(red: 1.00, green: 0.27, blue: 0.27)
    static let vfWarningAmber = Color(red: 1.00, green: 0.624, blue: 0.039) // #FF9F0A
    static let vfSuccessGreen = Color(red: 0.30, green: 0.78, blue: 0.40)

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
}
