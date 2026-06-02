//
//  PaywallScene.swift
//  Zerro
//
//  Created by Colin Breeding on 6/1/26.
//
//  Namespace for the paywall window-scene constants. Mirrors
//  `OnboardingScene` so callers that open or dismiss the window
//  programmatically (the hotkey gate via `AppDelegate.openPaywall`, the
//  Window scene in `ZerroApp.body`, the opener registrar) share one
//  identifier instead of hard-coding the string.
//

import Foundation

enum PaywallScene {
    static let windowID = "paywall"
}
