//
//  OnboardingStep.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  The discrete steps of the first-launch onboarding flow. Ordered
//  via `Int` raw value so advance/back/jump are trivial arithmetic, and
//  `CaseIterable` so the step-dots indicator and the dev panel both
//  iterate the same source-of-truth ordering.
//
//  Phase F (revised): `email` is a REQUIRED step right after `welcome` —
//  every new user verifies their email there, which grants the server-funded
//  trial credits up front so the trial works with no mid-task interruption.
//  The old API-key step was removed (it's only relevant to the post-trial BYOK
//  path, which the paywall + Settings already cover): trial users use
//  server-funded credits and Managed subscribers never need a key, so onboarding
//  no longer asks for one.
//

import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case consent
    case email
    case screenRecording
    case microphone
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
        case .welcome:         return "welcome"
        case .consent:         return "consent"
        case .email:           return "email"
        case .screenRecording: return "screen_recording"
        case .microphone:      return "microphone"
        case .devMode:         return "dev_mode"
        case .allSet:          return "all_set"
        }
    }

    /// Compact label used by the dev panel's step-jump buttons. Production
    /// titles live in the step views themselves.
    var devLabel: String {
        switch self {
        case .welcome:         return "1 \u{00B7} Welcome"
        case .consent:         return "2 \u{00B7} Consent"
        case .email:           return "3 \u{00B7} Email"
        case .screenRecording: return "4 \u{00B7} Screen"
        case .microphone:      return "5 \u{00B7} Mic"
        case .devMode:         return "6 \u{00B7} Dev"
        case .allSet:          return "7 \u{00B7} Ready"
        }
    }
}
