//
//  Changelog.swift
//  Zerro
//
//  The bundled "What's New" changelog: a static, versioned list of curated
//  release notes shipped inside the app (no network fetch, no dependency on
//  the deferred Sparkle appcast pipeline). Edited as part of each release —
//  add a new entry at the TOP of `entries` in the same PR that bumps
//  VERSION / CFBundleShortVersionString (see docs/DEPLOY-RUNBOOK.md).
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
    /// them, not which internals moved). Entries below 1.4.23, plus the
    /// 1.4.24…1.4.28 backfill, were distilled from each release tag's app-only
    /// commit range (`git log --no-merges app-vP..app-vN -- apps/desktop/`).
    /// Scripts/check_changelog_entry.py fails the release when the version in
    /// apps/desktop/VERSION has no entry here, so this list can't silently
    /// fall behind again.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.4.33",
            date: releaseDate(2026, 7, 31),
            highlights: [
                ChangelogHighlight(
                    "A deeper black theme now runs consistently across Zerro\u{2019}s windows and app surfaces.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Trial onboarding is more reliable when you return to the app, with clearer outcomes and credit handling.",
                    kind: .fixed
                ),
                ChangelogHighlight(
                    "Low-credit warnings now appear at the correct time.",
                    kind: .fixed
                ),
                ChangelogHighlight(
                    "Plan and upgrade screens now accurately show the five AI models currently available.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.29",
            date: releaseDate(2026, 7, 21),
            highlights: [
                ChangelogHighlight(
                    "\u{201C}Prompt\u{201D} is now \u{201C}Result\u{201D}: the menu bar, your history, and Settings all use the clearer name.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "The area selector\u{2019}s instruction pill is bigger and centered, so the next step is easier to spot.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "The capture-toolbar tour now marks the agent step with a \u{201C}Dev Mode only\u{201D} badge.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "The menu bar icon is sharper on Retina displays.",
                    kind: .fixed
                ),
                ChangelogHighlight(
                    "The What\u{2019}s New history in Settings \u{2192} About & Support is caught up: releases 1.4.24 through 1.4.28 have their notes again.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.28",
            date: releaseDate(2026, 7, 21),
            highlights: [
                ChangelogHighlight(
                    "Renamed \u{201C}Prompt\u{201D} to \u{201C}Result\u{201D} across the menu bar, history, and Settings.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "A bigger, centered instruction pill while the area selector waits for you to drag.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "The capture-toolbar tour\u{2019}s agent step is labeled \u{201C}Dev Mode only\u{201D}.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Fixed a blurry menu bar icon on Retina displays.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.27",
            date: releaseDate(2026, 7, 20),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.26",
            date: releaseDate(2026, 7, 20),
            highlights: [
                ChangelogHighlight(
                    "Artifact mode is now called Ask, across the toolbar and Settings.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Dev Mode shows a Cancel button when the agent stalls, and canceling now reliably stops the agent and all of its helper processes.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "The status pill appears on the display you\u{2019}re recording, and the microphone picker updates when devices are plugged in or unplugged.",
                    kind: .fixed
                ),
                ChangelogHighlight(
                    "A recording that finishes just as macOS revokes Screen Recording permission is no longer lost.",
                    kind: .fixed
                ),
                ChangelogHighlight(
                    "Privacy hardening: analytics wait for your consent, and home-folder paths are stripped from diagnostics.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.25",
            date: releaseDate(2026, 7, 3),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.24",
            date: releaseDate(2026, 7, 3),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.23",
            date: releaseDate(2026, 7, 2),
            highlights: [
                ChangelogHighlight(
                    "Zerro now shows this What\u{2019}s New window after each update, so you can see what changed at a glance.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Reopen it any time from Settings \u{2192} About & Support, or turn off the auto-show with the toggle below.",
                    kind: .note
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.22",
            date: releaseDate(2026, 7, 2),
            highlights: [
                ChangelogHighlight(
                    "On-device transcription: recordings can now be transcribed locally with Whisper, no API key or network required.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Resize and move a selection before recording: grab an edge handle or drag from inside the area.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "A quick first-run tour of the capture toolbar after onboarding.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Redesigned the Recent Prompts detail view with a cleaner header and toolbar, plus a confirmation before deleting.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Selections that are too small to record now show clear feedback while you drag instead of silently failing.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.21",
            date: releaseDate(2026, 6, 30),
            highlights: [
                ChangelogHighlight(
                    "Top up with one-time Credit Packs from the Upgrade window, no subscription change needed.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Chat-style answers now include a plain Copy action.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "More reliable Screen Recording permission handling, with a safety net if macOS revokes it mid-session.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.20",
            date: releaseDate(2026, 6, 29),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode status is now descriptive: see what the agent is doing, with a live step-by-step plan line as it works.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Onboarding is shorter: Screen Recording and Microphone are now a single permissions step.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Recordings with no voice input are caught locally and skipped before they spend a credit.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.19",
            date: releaseDate(2026, 6, 27),
            highlights: [
                ChangelogHighlight(
                    "Claude Code now signs in reliably in Dev Mode\u{2019}s fenced tiers: it runs in its own built-in sandbox instead of an external wrapper.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.18",
            date: releaseDate(2026, 6, 26),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.17",
            date: releaseDate(2026, 6, 26),
            highlights: [
                ChangelogHighlight(
                    "Snappier capture processing: heavy frame extraction now runs off the main thread.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "More reliable automatic updates: older versions can always reach the newest release.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.16",
            date: releaseDate(2026, 6, 25),
            highlights: [
                ChangelogHighlight(
                    "Coding agents keep access to their sign-in credentials while sandboxed in Dev Mode.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.15",
            date: releaseDate(2026, 6, 25),
            highlights: [
                ChangelogHighlight(
                    "After checkout, a dedicated \u{201C}Activate your key\u{201D} window opens with your license prefilled, one click to activate.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.14",
            date: releaseDate(2026, 6, 25),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode permission tiers: one trust dial from Ask Permission to Auto-Approve to Unrestricted.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Fenced Dev Mode runs are sandboxed: agents can only write inside your project, and network access is allowlisted.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Unrestricted runs warn before recording, with a \u{201C}don\u{2019}t show again\u{201D} option.",
                    kind: .new
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.13",
            date: releaseDate(2026, 6, 24),
            highlights: [
                ChangelogHighlight(
                    "Clearer privacy disclosures across onboarding and Settings, including exactly what secret redaction covers.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "A smoother license-activation flow in the paywall.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.12",
            date: releaseDate(2026, 6, 23),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.11",
            date: releaseDate(2026, 6, 23),
            highlights: [
                ChangelogHighlight(
                    "Onboarding now introduces Dev Mode.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Secret redaction now also covers Dev Mode\u{2019}s anchor screenshots and text hints.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "A failed Dev Mode undo can no longer lose work: the checkpoint is kept until your files are verified restored.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.10",
            date: releaseDate(2026, 6, 22),
            highlights: [
                ChangelogHighlight("Performance and stability improvements.", kind: .note),
            ]
        ),
        ChangelogEntry(
            version: "1.4.8",
            date: releaseDate(2026, 6, 22),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode can start a brand-new project from scratch: pick a location and Zerro creates the folder and repository.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Dev Mode can auto-detect the project folder from the localhost tab you\u{2019}re viewing (opt-in).",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "New Appearance section in Settings, including the Dev Mode ring and cursor-glow toggles.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "A more consistent dark theme and cleaner capture-toolbar layout.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.7",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "More dictation fixes: common words can no longer be swapped for project-specific terms.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.6",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "Dictation no longer replaces common English words with code terms from your project.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.5",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "Starting a new recording can no longer dismiss an unresolved result: the hotkey flashes the pill instead.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.4",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode\u{2019}s Undo now verifies that files the agent created are fully restored.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.3",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode change counts now include brand-new files in projects without any commits.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.2",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode checkpoints handle locked git indexes and empty repositories gracefully.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.1",
            date: releaseDate(2026, 6, 19),
            highlights: [
                ChangelogHighlight(
                    "The default recording shortcut is now \u{2325}\u{2009}Space.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "A soft pulsing ring around the screen shows while a Dev Mode agent is working.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "The Dev Mode pill shows elapsed time while the agent runs.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Smoother loading animations.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.4.0",
            date: releaseDate(2026, 6, 18),
            highlights: [
                ChangelogHighlight(
                    "Dev Mode: record what you want changed and Zerro dispatches it to your coding agent (Claude Code, Codex, or Cursor), with automatic checkpoints so everything can be undone.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Point and say \u{201C}this button\u{201D}: Dev Mode tracks your cursor and reads the screen to resolve what you mean.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Approve the plan before the agent touches your files, and get a summary with a full diff when it finishes.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Redesigned capture toolbar: compact icons with a Prompt/Dev mode switch.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "If you quit mid-run, Zerro offers to restore your files on the next launch.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.3.0",
            date: releaseDate(2026, 6, 16),
            highlights: [
                ChangelogHighlight(
                    "Subscribe in-app: Zerro Pro with metered credits, no API key required.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Full-screen capture: record the entire display with one click from the selector.",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Send feedback right from the app (Settings \u{2192} Send Feedback).",
                    kind: .new
                ),
                ChangelogHighlight(
                    "Recordings shorter than 3 seconds are stopped before they spend a credit.",
                    kind: .improved
                ),
                ChangelogHighlight(
                    "Warnings and errors in the pill now show their full text.",
                    kind: .improved
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.2.2",
            date: releaseDate(2026, 6, 14),
            highlights: [
                ChangelogHighlight(
                    "Very long model responses are now detected as truncated instead of producing broken output.",
                    kind: .fixed
                ),
            ]
        ),
        ChangelogEntry(
            version: "1.2.1",
            date: releaseDate(2026, 6, 14),
            highlights: [
                ChangelogHighlight(
                    "Failed generations that can be retried now show an expanded failure card with details and a Retry button.",
                    kind: .improved
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

/// Display-only release stamp (local calendar midnight — the changelog shows
/// a day, not an instant, so timezone precision doesn't matter here).
private func releaseDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
    DateComponents(calendar: .current, year: year, month: month, day: day).date
}
