//
//  Changelog.swift
//  Zerro
//
//  The bundled "What's New" changelog: a static, versioned list of curated
//  release notes shipped inside the app (no network fetch, no dependency on
//  the deferred Sparkle appcast pipeline). Edited as part of each release —
//  add a new entry at the TOP of `entries` in the same PR that bumps
//  VERSION / CFBundleShortVersionString (see
//  apps/desktop/Scripts/RELEASE-AUTOMATION.md).
//
//  Read by two surfaces: the launch-time auto-pop (via `WhatsNewPolicy` —
//  `entry(for:)` is its "does the current version have notes" guard) and the
//  Settings → About "What's New" row, which always shows the full list.
//

import Foundation

/// One released version's curated notes. `version` matches
/// `CFBundleShortVersionString` exactly (e.g. "1.4.22"). Order in
/// `Changelog.entries` is authoritative: newest first. `date` is display-only.
struct ChangelogEntry: Identifiable, Equatable {
    var id: String { version }
    let version: String
    /// Optional release stamp rendered next to the version ("Jul 2, 2026").
    let date: Date?
    let highlights: [ChangelogHighlight]
}

/// A single bullet under a version. `kind` reserves room for New/Improved/
/// Fixed glyphs later without a data migration; the view currently renders
/// every kind as the same em-dash bullet, so the `.note` default is fine.
struct ChangelogHighlight: Identifiable, Equatable {
    enum Kind { case new, improved, fixed, note }

    let id = UUID()
    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind = .note) {
        self.text = text
        self.kind = kind
    }
}

enum Changelog {

    /// The bundled, curated changelog — newest first. This is the single
    /// source of truth for both the auto-pop and the About → What's New
    /// window. Keep bullets short, human, and user-facing (what changed for
    /// them, not which internals moved). Scripts/check_changelog_entry.py
    /// fails the release when the version in apps/desktop/VERSION has no
    /// entry here, so this list can't silently fall behind.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.0.2",
            date: nil,
            highlights: [
                ChangelogHighlight(
                    "This staging release verifies updates through Zerro's public GitHub Releases channel.",
                    kind: .note
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.0.1",
            date: nil,
            highlights: [
                ChangelogHighlight(
                    "Staging builds now receive updates through Zerro’s public GitHub Releases channel.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.0.0",
            date: nil,
            highlights: [
                ChangelogHighlight(
                    "Zerro runs on your own API keys from supported AI providers, so your requests go straight to the provider accounts you control.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "The official app includes a 14-day trial with no card required.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "A single one-time license covers two Macs and every Zerro 1.x update.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Dev Mode runs with the local and provider setup you configure in Settings.",
                    kind: .new
                ),
            ]
        ),
    ]

    /// Entry whose `version` matches exactly, if any. The auto-pop's
    /// defensive guard: no entry for the current version → no window.
    static func entry(for version: String) -> ChangelogEntry? {
        entries.first { $0.version == version }
    }
}
