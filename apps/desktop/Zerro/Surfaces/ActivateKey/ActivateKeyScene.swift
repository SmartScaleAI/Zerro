//
//  ActivateKeyScene.swift
//  Zerro
//
//  Namespace for the post-purchase "Activate your key" window-scene constants.
//  Mirrors `PaywallScene` / `TrialEmailScene` so the callers that open it
//  programmatically (the checkout-return deep link via
//  `AppDelegate.openActivateKey`, the Window scene in `ZerroApp.body`, the opener
//  registrar, and `DockIconController.qualifyingWindowIDs`) share one identifier
//  instead of hard-coding the string.
//
//  This window is the dedicated landing spot for a checkout return that carries
//  an issued license/subscription key: the key is routed here PREFILLED so the
//  user explicitly taps Activate (E-01 — a deep link never auto-activates), in
//  place of opening the full paywall.
//

import Foundation

enum ActivateKeyScene {
    static let windowID = "activate-key"
}
