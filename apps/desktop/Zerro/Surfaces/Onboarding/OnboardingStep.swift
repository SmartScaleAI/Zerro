//
//  OnboardingStep.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The discrete steps of the first-launch onboarding flow. Ordered
//  via `Int` raw value so advance/jump are trivial arithmetic, and
//  `CaseIterable` so the step-dots indicator and the dev panel both
//  iterate the same source-of-truth ordering.
//
//  This legacy step list is the persistence bridge for the redesigned route
//  (`OnboardingRoute`): the `email` value is kept so an install that saved it
//  still resumes, but no screen renders an email step anymore — the setup
//  screen advances straight to provider keys.
//

import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case consent
    case email
    case permissions   // merged Screen Recording + Microphone
    case devMode      // NEW — educational, shown to all users
    case allSet

    var id: Int { rawValue }

    /// Stable, snake_case identifier for analytics — decoupled from `devLabel`
    /// (debug-only, may change) and `rawValue` (an index that shifts if steps
    /// are reordered/inserted). Used as the `onboarding_step_viewed.step`
    /// property and the per-step `captureOnce` dedupe key, so it must stay
    /// constant across releases.
    var analyticsName: String {
        switch self {
        case .welcome:     return "welcome"
        case .consent:     return "consent"
        case .email:       return "email"
        case .permissions: return "permissions"
        case .devMode:     return "dev_mode"
        case .allSet:      return "all_set"
        }
    }

    /// Compact label used by the dev panel's step-jump buttons. Production
    /// titles live in the step views themselves.
    var devLabel: String {
        switch self {
        case .welcome:     return "1 \u{00B7} Welcome"
        case .consent:     return "2 \u{00B7} Consent"
        case .email:       return "3 \u{00B7} Email"
        case .permissions: return "4 \u{00B7} Permissions"
        case .devMode:     return "5 \u{00B7} Dev"
        case .allSet:      return "6 \u{00B7} Ready"
        }
    }
}
