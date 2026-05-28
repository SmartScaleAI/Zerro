//
//  OnboardingStep.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//
//  The six discrete steps of the first-launch onboarding flow. Ordered
//  via `Int` raw value so advance/back/jump are trivial arithmetic, and
//  `CaseIterable` so the step-dots indicator and the dev panel both
//  iterate the same source-of-truth ordering.
//

import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case screenRecording
    case microphone
    case accessibility
    case apiKey
    case allSet

    var id: Int { rawValue }

    /// Compact label used by the dev panel's step-jump buttons. Production
    /// titles live in the step views themselves.
    var devLabel: String {
        switch self {
        case .welcome:         return "1 \u{00B7} Welcome"
        case .screenRecording: return "2 \u{00B7} Screen"
        case .microphone:      return "3 \u{00B7} Mic"
        case .accessibility:   return "4 \u{00B7} Access"
        case .apiKey:          return "5 \u{00B7} Key"
        case .allSet:          return "6 \u{00B7} Ready"
        }
    }
}
