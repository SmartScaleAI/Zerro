//
//  WhatsNewPolicy.swift
//  Zerro
//
//  Pure launch-time decision for the "What's New" window — should this
//  launch auto-pop the changelog? Split from the view/scene the same way
//  `UpdateWindowPolicy` is split from `UpdaterView`: all inputs injected,
//  no Bundle/UserDefaults reads, so the rule is unit-testable without
//  SwiftUI or AppKit (see WhatsNewPolicyTests' decision matrix).
//
//  The caller (ZerroApp) owns the side effects: BOTH `.present` and
//  `.seedOnly` write `lastSeen = current`, and `.none` also moves the
//  marker forward when the version changed but the pop was suppressed
//  (checkbox off / missing entry), so a suppressed version is never
//  re-evaluated forever. Keeping the bump out of here keeps `decide`
//  side-effect-free.
//

import Foundation

enum WhatsNewPolicy {

    /// The outcome of a launch-time evaluation.
    enum Decision: Equatable {
        /// Auto-pop the window for this version.
        case present(version: String)
        /// First-ever launch: record the marker, show nothing (onboarding
        /// owns the first-run experience — a fresh install has no "news").
        case seedOnly(version: String)
        /// Nothing changed, or the pop was suppressed.
        case none
    }

    /// The launch decision. Auto-present only when ALL hold:
    ///   1. `lastSeen != nil` — not a first-ever install (else `.seedOnly`).
    ///   2. `current != lastSeen` — the version actually changed. Plain
    ///      string inequality: the rule is "every change", so no semantic
    ///      version parsing; a downgrade simply doesn't re-trigger because
    ///      the caller only ever moves `lastSeen` to `current`.
    ///   3. `autoShowEnabled` — the footer "Show changelog after each
    ///      update" checkbox.
    ///   4. `onboardingComplete` — never stack on top of onboarding.
    ///   5. `hasEntry` — there are notes for `current` (defensive: a release
    ///      that forgot to update `Changelog` must not pop an empty window).
    static func decide(
        current: String,
        lastSeen: String?,
        autoShowEnabled: Bool,
        onboardingComplete: Bool,
        hasEntry: Bool
    ) -> Decision {
        guard let lastSeen else { return .seedOnly(version: current) }
        guard current != lastSeen else { return .none }
        guard autoShowEnabled, onboardingComplete, hasEntry else { return .none }
        return .present(version: current)
    }
}
