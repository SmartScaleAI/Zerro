//
//  HotkeySymbols.swift
//  Zerro
//
//  Shared symbol formatting for a `KeyboardShortcuts.Shortcut`, used by
//  both the Settings keycap recorder (HotkeyDisplay) and the menu-bar
//  panel's trailing hotkey hints so the two surfaces always agree on
//  glyphs and modifier ordering.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Shortcut {
    /// Returns one label per keycap in the design's canonical order:
    /// Command → Shift → Control → Option → key. This intentionally
    /// diverges from the shortcut.description string (which follows
    /// Apple's text-readout order ⌃⌥⇧⌘key with Command rightmost) —
    /// the Phase 11 design mockups put Command first, so we build the
    /// array directly from `modifiers` instead of parsing the
    /// description. The key glyph at the end is extracted by
    /// stripping the four modifier glyphs from `description`, which
    /// preserves multi-character keys like "F1", "Space", "⏎".
    var keycapLabels: [String] {
        var out: [String] = []

        if modifiers.contains(.command) { out.append("\u{2318}") } // ⌘
        if modifiers.contains(.shift)   { out.append("\u{21E7}") } // ⇧
        if modifiers.contains(.control) { out.append("\u{2303}") } // ⌃
        if modifiers.contains(.option)  { out.append("\u{2325}") } // ⌥

        if let keyLabel, !keyLabel.isEmpty {
            out.append(keyLabel)
        }
        return out
    }

    /// The keycap labels joined into a single hint string (e.g. "⌘⌃R")
    /// for compact contexts like the menu-bar panel's trailing text.
    var symbolsDisplay: String {
        keycapLabels.joined()
    }

    /// Extracts the non-modifier portion of `description`. Modifier
    /// glyphs may appear anywhere in the description string (depends
    /// on macOS / locale conventions), so we filter them out rather
    /// than positionally trim.
    private var keyLabel: String? {
        let modifierGlyphs: Set<Character> = ["\u{2303}", "\u{2325}", "\u{21E7}", "\u{2318}"]
        let key = description.filter { !modifierGlyphs.contains($0) }
        return key.isEmpty ? nil : key
    }
}
