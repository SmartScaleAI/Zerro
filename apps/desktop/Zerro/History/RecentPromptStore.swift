//
//  RecentPromptStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — persistence layer for the result history surfaced by the
//  menu-bar "Recent Prompts" submenu, the Paste-last row, and the
//  Settings "History" tab. Storage is a flat JSON file under
//  `Application Support/Zerro/recent_prompts.json` (sandboxed, so inside
//  the app container). Capped at `RecentPromptStore.maxEntries` so the
//  file can't grow without bound.
//
//  Design notes:
//  • JSON-on-disk was picked over SwiftData (schema-migration overhead
//    we don't need yet) and UserDefaults (not sized for prompt bodies,
//    plus it's a plist on disk anyway).
//  • Writes are debounce-free — `add`/`delete`/`clear` write synchronously
//    so a crash a millisecond after a successful recording doesn't lose
//    the result. The on-disk file is small (≤50 entries) so the cost is
//    irrelevant.
//  • The model carries both `title` (one-line summary for list display)
//    and `prompt` (full body for clipboard paste). Title is derived from
//    the first non-empty line of the prompt at insert time.
//

import Foundation
import os

// MARK: - RecentPrompt

/// One persisted entry in the history. `title` is the user-facing summary
/// in the submenu / Paste-last row / History list; `prompt` is the full
/// generated body copied to the clipboard when the user clicks an entry.
struct RecentPrompt: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var prompt: String
    var timestamp: Date

    init(id: UUID = UUID(), title: String, prompt: String, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.timestamp = timestamp
    }
}

// MARK: - RecentPromptStore

@MainActor
@Observable
final class RecentPromptStore {

    // MARK: Constants

    /// Cap on how many prompts we keep on disk. Picked at the size where
    /// the History list is still scannable without virtualization but
    /// users with a busy week can still trust their last few sessions to
    /// be there. Older entries fall off as new ones land.
    static let maxEntries = 50

    /// Cap on derived-title length for the submenu / Paste-last row.
    /// Long enough to read at a glance, short enough not to wrap inside
    /// the 280pt-wide submenu row.
    private static let maxTitleLength = 80

    // MARK: State

    /// Most-recent-first. Views read this directly via @Observable.
    private(set) var prompts: [RecentPrompt] = []

    // MARK: Internals

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Init

    /// Default init resolves `Application Support/Zerro/recent_prompts.json`
    /// and loads any existing entries. Tests can pass a custom URL.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // MARK: API

    /// Inserts a new prompt at the top of the list. Title is derived from
    /// the first non-empty line of `prompt`, trimmed to a sensible length.
    /// Older entries beyond `maxEntries` fall off the end. Idempotent on
    /// duplicate `prompt` bodies — re-recording the same exact prompt
    /// bumps the existing entry's timestamp rather than creating two
    /// near-identical rows.
    func add(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = Self.deriveTitle(from: trimmed)
        let entry = RecentPrompt(title: title, prompt: trimmed)

        // Dedup against the most recent entry only — re-runs of the same
        // recording are common (Retry path), surprise duplicates further
        // back in the list are not.
        if let first = prompts.first, first.prompt == trimmed {
            prompts[0].timestamp = entry.timestamp
        } else {
            prompts.insert(entry, at: 0)
            if prompts.count > Self.maxEntries {
                prompts.removeLast(prompts.count - Self.maxEntries)
            }
        }
        save()
    }

    func delete(id: UUID) {
        prompts.removeAll { $0.id == id }
        save()
    }

    func clear() {
        prompts.removeAll()
        save()
    }

    /// Most-recent entry, or nil if the history is empty. Used by the
    /// menu-bar Paste-last row.
    var mostRecent: RecentPrompt? { prompts.first }

    // MARK: Title derivation

    /// First non-empty line of the prompt, with markdown heading markers
    /// stripped (`### Context` → `Context`) and trailing whitespace
    /// trimmed. Falls back to a leading slice of the prompt if every line
    /// is blank. Capped at `maxTitleLength` with an ellipsis.
    static func deriveTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading markdown heading hashes ("## Context" → "Context")
        // and the equivalent bold-marker wrapping that the prompt-system
        // template sometimes lays down.
        var cleaned = firstLine
        while cleaned.hasPrefix("#") || cleaned.hasPrefix("*") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.count > maxTitleLength {
            let cut = cleaned.index(cleaned.startIndex, offsetBy: maxTitleLength)
            cleaned = cleaned[..<cut].trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return cleaned
    }

    // MARK: Persistence

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            prompts = try decoder.decode([RecentPrompt].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            prompts = []
        } catch {
            // Corrupt JSON shouldn't break the app — log and start fresh.
            // We DON'T delete the corrupt file: if a future migration can
            // recover it, throwing it away would be worse.
            // Error description marked .private — file errors typically
            // embed the full path to the history file.
            Log.history.error("load failed: \(error.localizedDescription, privacy: .private)")
            prompts = []
        }
    }

    private func save() {
        do {
            try ensureParentDirectoryExists()
            let data = try encoder.encode(prompts)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.history.error("save failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func ensureParentDirectoryExists() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }

    private static func defaultFileURL() -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            // Application Support not reachable is exceptional; fall
            // back to the container tmp so the app still functions
            // (history just won't survive a relaunch).
            Log.history.error("applicationSupport unreachable: \(error.localizedDescription, privacy: .private)")
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("recent_prompts.json")
        }
        return base
            .appendingPathComponent("Zerro", isDirectory: true)
            .appendingPathComponent("recent_prompts.json")
    }
}
