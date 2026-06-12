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
//  • v2 (typed-artifact refactor Phase 2): entries gain optional
//    chatText / artifactType / artifactBody / artifactTitle alongside the
//    raw `prompt` (kept as the verbatim-fallback payload). Versioning is
//    the FILE NAME — v2 reads/writes `recent_prompts_v2.json` and never
//    opens the v1 file, so an old install simply starts with empty history
//    (pre-launch, no migration by design; plan Phase 2 step 5). Title now
//    prefers the model's artifact title, falling back to `deriveTitle`.
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
/// RAW generated body — kept verbatim as the fallback copy payload even in
/// v2, where the parsed pieces ride alongside it.
///
/// v2 fields (typed-artifact refactor, all optional so a chat-only response
/// simply carries nil): `chatText` is the parsed conversational text,
/// `artifactType` the §2 wire string (`agent_prompt`, `message`, …, stored
/// as a String so history survives enum changes), `artifactBody` the
/// artifact's body, and `artifactTitle` the model-written card title.
struct RecentPrompt: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var prompt: String
    var timestamp: Date
    var chatText: String?
    var artifactType: String?
    var artifactBody: String?
    var artifactTitle: String?

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        timestamp: Date = Date(),
        chatText: String? = nil,
        artifactType: String? = nil,
        artifactBody: String? = nil,
        artifactTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.timestamp = timestamp
        self.chatText = chatText
        self.artifactType = artifactType
        self.artifactBody = artifactBody
        self.artifactTitle = artifactTitle
    }
}

// MARK: - Display + copy semantics (Phase 5)

extension RecentPrompt {

    /// The §2 type this entry carries, when its stored wire string still
    /// maps to a known case. nil for chat-only entries AND for a stored
    /// string the current enum no longer knows (history outlives enum
    /// changes by design — `artifactType` is persisted as a String).
    var resolvedArtifactType: ArtifactType? {
        artifactType.flatMap(ArtifactType.init(rawValue:))
    }

    /// Row glyph for the history surfaces: the artifact type's icon, the
    /// generic doc for an unrecognized stored type, and a chat bubble for
    /// chat-only entries.
    var displayIconName: String {
        guard artifactType != nil else { return "text.bubble" }
        return (resolvedArtifactType ?? .generic).iconName
    }

    /// What copying this entry puts on the clipboard — the same per-type
    /// semantics as the live pill (§2 table): artifact body when one was
    /// attached, chat text for chat-only, the raw `prompt` for pre-v2 /
    /// fail-safe entries. History persists no frames/clicks, so an
    /// `agent_prompt` copy here carries NO Attached Context block — a
    /// known, accepted gap (plan Phase 5 step 4).
    var copyPayload: String {
        if let artifactBody, !artifactBody.isEmpty { return artifactBody }
        if let chatText, !chatText.isEmpty { return chatText }
        return prompt
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

    /// Inserts a new prompt at the top of the list. Title prefers the
    /// model's artifact title (v2) and falls back to deriving one from the
    /// first non-empty line of `prompt`. Older entries beyond `maxEntries`
    /// fall off the end. Idempotent on duplicate `prompt` bodies —
    /// re-recording the same exact prompt bumps the existing entry's
    /// timestamp rather than creating two near-identical rows.
    ///
    /// The v2 parameters default to nil so every pre-refactor call site
    /// (and any raw/unparseable result in Phase 4+) keeps working unchanged.
    func add(
        prompt: String,
        chatText: String? = nil,
        artifactType: String? = nil,
        artifactBody: String? = nil,
        artifactTitle: String? = nil
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let modelTitle = artifactTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let modelTitle, !modelTitle.isEmpty {
            // The contract caps titles at 80 chars; deriveTitle's capping
            // also covers an over-long one that slipped past a warning.
            title = modelTitle.count > Self.maxTitleLength
                ? Self.deriveTitle(from: modelTitle)
                : modelTitle
        } else {
            title = Self.deriveTitle(from: trimmed)
        }
        let entry = RecentPrompt(
            title: title,
            prompt: trimmed,
            chatText: chatText,
            artifactType: artifactType,
            artifactBody: artifactBody,
            artifactTitle: modelTitle.flatMap { $0.isEmpty ? nil : $0 }
        )

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

    /// Phase 6 (conversion fallback): grafts a converted artifact onto the
    /// EXISTING entry for `originalPrompt` — a conversion must never create a
    /// second history row. Matches the most recent entry whose raw `prompt`
    /// equals the original (the same trimmed text `add` stored); updates its
    /// artifact fields, re-titles from the model's artifact title (same rule
    /// as `add`), and persists. No-op when nothing matches (e.g. the history
    /// was cleared between generation and conversion).
    func attachConvertedArtifact(
        originalPrompt: String,
        type: String,
        body: String,
        title: String?
    ) {
        let trimmed = originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = prompts.firstIndex(where: { $0.prompt == trimmed }) else { return }
        prompts[idx].artifactType = type
        prompts[idx].artifactBody = body
        let modelTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelTitle, !modelTitle.isEmpty {
            prompts[idx].artifactTitle = modelTitle
            prompts[idx].title = modelTitle.count > Self.maxTitleLength
                ? Self.deriveTitle(from: modelTitle)
                : modelTitle
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
                .appendingPathComponent("recent_prompts_v2.json")
        }
        return base
            .appendingPathComponent("Zerro", isDirectory: true)
            .appendingPathComponent("recent_prompts_v2.json")
    }
}
