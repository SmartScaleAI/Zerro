//
//  ActivationAnchorScene.swift
//  Zerro
//
//  Window-scene id for the invisible "activation anchor" — the FIRST-declared
//  `Window` scene in `ZerroApp.body`.
//
//  Why it exists: AppKit auto-materializes the first-declared `Window` scene when
//  this accessory (LSUIElement) app is activated/brought to the foreground (e.g.
//  a `zerro://` deep link reactivating it from the browser).
//  `.defaultLaunchBehavior(.suppressed)` doesn't cover that activation path, so
//  the first Window pops on screen. Previously that was the Settings window, which
//  is how a post-purchase deep link ended up showing three windows. This anchor
//  takes the first slot and renders nothing visible, so the framework's
//  materialization is harmless. See the scene declaration in `ZerroApp.body`.
//

import Foundation

enum ActivationAnchorScene {
    static let windowID = "activation-anchor"
}
