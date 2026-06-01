//
//  ModeSwitchPatterns.swift
//  Zerro
//
//  Created by Colin Breeding on 5/31/26.
//
//  Phase 18 — the tuning data for ModeSwitchDetector, decoded once from
//  the bundled `ModeSwitchPatterns.json`. The split is deliberate: the
//  WORD LISTS here are product/tuning data (edit the JSON, no rebuild of
//  the detection rules), while the MATCHING RULES (cue + target
//  proximity, opposite-mode-only scan, time-based edge weighting) live in
//  ModeSwitchDetector. Treat this type as a dumb bag of strings.
//
//  Fail-closed: if the resource is missing or won't decode, `bundled`
//  resolves to `.empty` and the detector — which guards on non-empty cue
//  and target lists — returns `.noMatch` for everything. A broken pattern
//  file silently disables the feature rather than crashing or guessing.
//

import Foundation
import os

// `nonisolated` so the synthesized Decodable conformance + memberwise init
// stay usable from `load`/`bundled`, which run off the main actor (the
// project's `-default-isolation=MainActor` would otherwise pin this pure
// value type). It's `Sendable`, so opting the whole type out is safe.
nonisolated struct ModeSwitchPatterns: Decodable, Equatable, Sendable {
    /// Words/phrases that signal an intent to change something — the
    /// REQUIRED half of every match (a bare format-noun never matches
    /// alone). E.g. "instead", "actually", "switch to", "just".
    let switchCues: [String]

    /// Phrases that name an Instruct-style output. Scanned only when the
    /// user is in Explain mode (we look for the OPPOSITE request).
    let instructTargets: [String]

    /// Phrases that name an Explain-style output. Scanned only when the
    /// user is in Instruct mode.
    let explainTargets: [String]

    /// Spoken-noise tokens stripped during normalization so they don't
    /// inflate the cue↔target word distance ("um, you know, explain this"
    /// should read as tightly as "explain this").
    let fillerTokens: [String]

    /// Canonical app name → spoken/spelled variants, normalized so a
    /// target like "for cursor" matches regardless of how Whisper
    /// rendered it ("Cursor AI", "cursor"). Variants are matched
    /// longest-first; see ModeSwitchDetector.normalize.
    let appNameVariants: [String: [String]]

    /// The targets to scan for the given mode. Note: callers pass the
    /// OPPOSITE of the selected mode — we only ever suggest switching TO
    /// the other mode, never reinforce the current one.
    func targets(for mode: OutputMode) -> [String] {
        switch mode {
        case .instruct: return instructTargets
        case .explain:  return explainTargets
        }
    }
}

extension ModeSwitchPatterns {

    /// The all-empty set. Resolved by `bundled` on any load failure;
    /// the detector treats it as "feature off" (fail-closed).
    nonisolated static let empty = ModeSwitchPatterns(
        switchCues: [],
        instructTargets: [],
        explainTargets: [],
        fillerTokens: [],
        appNameVariants: [:]
    )

    /// The pattern set shipped in the app bundle, decoded once. Read from
    /// `Bundle.main`; under the XCTest host this is still the app bundle,
    /// so the resource resolves there too.
    ///
    /// `nonisolated` for the same reason as the Loggers in `Log` — the
    /// detector runs from whatever context AppState's processing Task is
    /// on, and the project's `-default-isolation=MainActor` would
    /// otherwise pin this static. `ModeSwitchPatterns` is `Sendable`, so
    /// this is safe to share.
    nonisolated static let bundled: ModeSwitchPatterns = load(from: .main)

    /// Decode the pattern resource from `bundle`, falling back to
    /// `.empty` (and logging — never the file contents) on any failure.
    /// Exposed (rather than inlined into `bundled`) so a test can verify
    /// the shipped JSON decodes against an explicit bundle.
    nonisolated static func load(from bundle: Bundle) -> ModeSwitchPatterns {
        guard let url = bundle.url(forResource: "ModeSwitchPatterns", withExtension: "json") else {
            // Resource name only (a constant we control) — no user content.
            Log.modeSwitch.error("ModeSwitchPatterns.json missing from bundle — detector disabled")
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ModeSwitchPatterns.self, from: data)
        } catch {
            // .private: a decode error can echo back fragments of the file.
            Log.modeSwitch.error("ModeSwitchPatterns.json decode failed: \(error.localizedDescription, privacy: .private) — detector disabled")
            return .empty
        }
    }
}
