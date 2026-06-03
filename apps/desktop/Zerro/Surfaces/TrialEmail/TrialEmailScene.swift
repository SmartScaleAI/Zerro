//
//  TrialEmailScene.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Namespace for the Phase F trial email-capture window-scene constants. Mirrors
//  `PaywallScene` / `OnboardingScene` so the callers that open it
//  programmatically (AppState via `AppDelegate.openTrialEmailCapture`, the Window
//  scene in `ZerroApp.body`, the opener registrar) share one identifier.
//

import Foundation

enum TrialEmailScene {
    static let windowID = "trial-email"
}
