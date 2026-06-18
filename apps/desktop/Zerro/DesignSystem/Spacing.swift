//
//  Spacing.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

enum VFSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum VFRadius {
    static let sm: CGFloat = 6     // KeyCap chips
    static let md: CGFloat = 10    // inner cards
    static let lg: CGFloat = 14    // outer panels, action buttons
    static let pill: CGFloat = 999 // capsule
}

/// Shared metrics for the pill family's controls (see `PillControls.swift`).
/// These replace the bare numbers that were inlined across the pill content
/// views so every primary/secondary button, dismiss "x", and status-icon
/// badge lands on one set of values.
enum PillMetrics {
    static let contentHPad: CGFloat = VFSpacing.lg   // 16 — horizontal inset of pill content
    static let contentVPad: CGFloat = 10             // vertical inset of pill content
    static let controlHeight: CGFloat = 30           // primary + secondary button height
    static let primaryHPad: CGFloat = 16             // filled-button horizontal padding
    static let primaryVPad: CGFloat = 7              // filled-button vertical padding
    static let iconBadge: CGFloat = 30               // leading status-icon badge diameter
    static let dismissBadge: CGFloat = 26            // corner "x" badge diameter
}
