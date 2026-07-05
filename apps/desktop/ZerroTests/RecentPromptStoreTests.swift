//
//  RecentPromptStoreTests.swift
//  ZerroTests
//
//  Phase 2 of the modes → typed-artifact refactor: RecentPromptStore v2 —
//  optional chatText/artifactType/artifactBody/artifactTitle fields, the
//  artifact-title-first titling rule, and the persistence behaviors that
//  predate v2 but were previously untested (dedup bump, cap, round-trip).
//  Storage versioning is the file NAME (recent_prompts_v2.json); tests pass
//  explicit URLs so they exercise the store, not the default path.
//

import XCTest
@testable import Zerro

final class RecentPromptStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentPromptStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("recent_prompts_v2.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: Titling

    func testAddDerivesTitleFromFirstNonEmptyLine() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "## Context\nLogin form misaligned.")
        XCTAssertEqual(store.prompts.first?.title, "Context")
    }

    func testAddPrefersModelArtifactTitle() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(
            prompt: "Long raw model output…",
            chatText: "The promo code fails silently — prompt below.",
            artifactType: "agent_prompt",
            artifactBody: "Fix the silent failure of Apply.",
            artifactTitle: "Fix silent promo code failure"
        )
        let entry = store.prompts.first
        XCTAssertEqual(entry?.title, "Fix silent promo code failure")
        XCTAssertEqual(entry?.artifactTitle, "Fix silent promo code failure")
    }

    func testBlankArtifactTitleFallsBackToDerivation() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "Align the submit button.", artifactTitle: "   ")
        let entry = store.prompts.first
        XCTAssertEqual(entry?.title, "Align the submit button.")
        XCTAssertNil(entry?.artifactTitle, "whitespace-only title is not persisted")
    }

    func testOverlongArtifactTitleIsCapped() {
        let store = RecentPromptStore(fileURL: fileURL)
        let long = String(repeating: "word ", count: 40) // 200 chars
        store.add(prompt: "body", artifactTitle: long)
        let title = store.prompts.first?.title ?? ""
        XCTAssertLessThanOrEqual(title.count, 81, "80 + ellipsis")
        XCTAssertTrue(title.hasSuffix("\u{2026}"))
    }

    // MARK: v2 round-trip

    func testV2FieldsPersistAcrossReload() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(
            prompt: "raw output",
            chatText: "chat",
            artifactType: "snippet",
            artifactBody: "SELECT 1;",
            artifactTitle: "Top customers query"
        )
        let reloaded = RecentPromptStore(fileURL: fileURL)
        let entry = reloaded.prompts.first
        XCTAssertEqual(entry?.prompt, "raw output")
        XCTAssertEqual(entry?.chatText, "chat")
        XCTAssertEqual(entry?.artifactType, "snippet")
        XCTAssertEqual(entry?.artifactBody, "SELECT 1;")
        XCTAssertEqual(entry?.artifactTitle, "Top customers query")
    }

    func testChatOnlyEntryCarriesNilArtifactFields() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "Just an explanation, no artifact.")
        let reloaded = RecentPromptStore(fileURL: fileURL)
        let entry = reloaded.prompts.first
        XCTAssertNil(entry?.chatText)
        XCTAssertNil(entry?.artifactType)
        XCTAssertNil(entry?.artifactBody)
        XCTAssertNil(entry?.artifactTitle)
    }

    // MARK: Pre-v2 behaviors (previously untested)

    func testDuplicatePromptBumpsTimestampInsteadOfInserting() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "same body")
        let firstTimestamp = store.prompts[0].timestamp
        store.add(prompt: "same body")
        XCTAssertEqual(store.prompts.count, 1)
        XCTAssertGreaterThanOrEqual(store.prompts[0].timestamp, firstTimestamp)
    }

    func testMaxEntriesCapDropsOldest() {
        let store = RecentPromptStore(fileURL: fileURL)
        for i in 0..<(RecentPromptStore.maxEntries + 5) {
            store.add(prompt: "prompt \(i)")
        }
        XCTAssertEqual(store.prompts.count, RecentPromptStore.maxEntries)
        XCTAssertEqual(store.prompts.first?.prompt, "prompt \(RecentPromptStore.maxEntries + 4)")
        XCTAssertEqual(store.prompts.last?.prompt, "prompt 5")
    }

    func testDeleteAndClearPersist() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "one")
        store.add(prompt: "two")
        let id = store.prompts[0].id
        store.delete(id: id)
        XCTAssertEqual(RecentPromptStore(fileURL: fileURL).prompts.map(\.prompt), ["one"])
        store.clear()
        XCTAssertTrue(RecentPromptStore(fileURL: fileURL).prompts.isEmpty)
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json{{".utf8).write(to: fileURL)
        let store = RecentPromptStore(fileURL: fileURL)
        XCTAssertTrue(store.prompts.isEmpty)
    }

    // MARK: I-01 hardening — owner-only perms + backup exclusion

    private func posixPermissions(atPath path: String) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).uint16Value
    }

    func testSaveSetsOwnerOnlyFilePermissions() throws {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "plaintext prompt body")
        XCTAssertEqual(try posixPermissions(atPath: fileURL.path), 0o600)
    }

    func testPermissionsRestoredOnEverySave() throws {
        // The .atomic write replaces the file wholesale, resetting perms
        // to the umask default — hardening must reapply on each save.
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "one")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )
        store.add(prompt: "two")
        XCTAssertEqual(try posixPermissions(atPath: fileURL.path), 0o600)
    }

    func testSaveSetsParentDirectoryOwnerOnly() throws {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "p")
        XCTAssertEqual(
            try posixPermissions(atPath: fileURL.deletingLastPathComponent().path),
            0o700
        )
    }

    func testSaveTightensPreExistingParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "p")
        XCTAssertEqual(
            try posixPermissions(atPath: fileURL.deletingLastPathComponent().path),
            0o700
        )
    }

    func testSaveExcludesFileFromBackup() throws {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "p")
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: Phase 5 — per-type display + copy semantics

    private func entry(
        prompt: String = "raw",
        chatText: String? = nil,
        artifactType: String? = nil,
        artifactBody: String? = nil
    ) -> RecentPrompt {
        RecentPrompt(
            title: "t",
            prompt: prompt,
            chatText: chatText,
            artifactType: artifactType,
            artifactBody: artifactBody
        )
    }

    func testCopyPayloadPrefersArtifactBody() {
        let e = entry(prompt: "raw with fences", chatText: "intro", artifactType: "snippet", artifactBody: "SELECT 1;")
        XCTAssertEqual(e.copyPayload, "SELECT 1;")
    }

    func testCopyPayloadChatOnlyCopiesChatText() {
        let e = entry(prompt: "raw", chatText: "just an explanation")
        XCTAssertEqual(e.copyPayload, "just an explanation")
    }

    func testCopyPayloadFallsBackToRawPrompt() {
        // Pre-v2 / fail-safe entries carry only the raw prompt.
        XCTAssertEqual(entry(prompt: "raw output").copyPayload, "raw output")
    }

    func testDisplayIconPerType() {
        XCTAssertEqual(entry(artifactType: "agent_prompt").displayIconName, "curlybraces")
        XCTAssertEqual(entry(artifactType: "message").displayIconName, "envelope")
        XCTAssertEqual(entry(artifactType: "snippet").displayIconName, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(entry(artifactType: "document").displayIconName, "doc.text")
    }

    func testDisplayIconChatOnlyAndUnknownType() {
        XCTAssertEqual(entry().displayIconName, "text.bubble", "chat-only rows get the chat bubble")
        XCTAssertEqual(
            entry(artifactType: "future_type").displayIconName,
            ArtifactType.generic.iconName,
            "a stored type the enum no longer knows degrades to the generic glyph"
        )
        XCTAssertNil(entry(artifactType: "future_type").resolvedArtifactType)
    }
}
