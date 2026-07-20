//
//  RecentPromptStoreTests.swift
//  ZerroTests
//
//  Phase 2 of the modes → typed-output refactor: RecentPromptStore v2 —
//  optional chatText/outputType/outputBody/outputTitle fields, the
//  output-title-first titling rule, and the persistence behaviors that
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

    func testAddPrefersModelOutputTitle() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(
            prompt: "Long raw model output…",
            chatText: "The promo code fails silently — prompt below.",
            outputType: "agent_prompt",
            outputBody: "Fix the silent failure of Apply.",
            outputTitle: "Fix silent promo code failure"
        )
        let entry = store.prompts.first
        XCTAssertEqual(entry?.title, "Fix silent promo code failure")
        XCTAssertEqual(entry?.outputTitle, "Fix silent promo code failure")
    }

    func testBlankOutputTitleFallsBackToDerivation() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "Align the submit button.", outputTitle: "   ")
        let entry = store.prompts.first
        XCTAssertEqual(entry?.title, "Align the submit button.")
        XCTAssertNil(entry?.outputTitle, "whitespace-only title is not persisted")
    }

    func testOverlongOutputTitleIsCapped() {
        let store = RecentPromptStore(fileURL: fileURL)
        let long = String(repeating: "word ", count: 40) // 200 chars
        store.add(prompt: "body", outputTitle: long)
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
            outputType: "snippet",
            outputBody: "SELECT 1;",
            outputTitle: "Top customers query"
        )
        let reloaded = RecentPromptStore(fileURL: fileURL)
        let entry = reloaded.prompts.first
        XCTAssertEqual(entry?.prompt, "raw output")
        XCTAssertEqual(entry?.chatText, "chat")
        XCTAssertEqual(entry?.outputType, "snippet")
        XCTAssertEqual(entry?.outputBody, "SELECT 1;")
        XCTAssertEqual(entry?.outputTitle, "Top customers query")
    }

    func testChatOnlyEntryCarriesNilOutputFields() {
        let store = RecentPromptStore(fileURL: fileURL)
        store.add(prompt: "Just an explanation, no output.")
        let reloaded = RecentPromptStore(fileURL: fileURL)
        let entry = reloaded.prompts.first
        XCTAssertNil(entry?.chatText)
        XCTAssertNil(entry?.outputType)
        XCTAssertNil(entry?.outputBody)
        XCTAssertNil(entry?.outputTitle)
    }

    /// The v2 file shipped with `artifact*` JSON keys before the output
    /// rename. Pins the on-disk contract in BOTH directions: a legacy file
    /// still decodes into the renamed properties, and a fresh save still
    /// writes the legacy keys (never `outputType` etc.).
    func testOnDiskKeysStayArtifactNamedAfterRename() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        [{"id":"6F1E9C1A-2B3C-4D5E-8F90-1A2B3C4D5E6F",
          "title":"Fix silent promo code failure",
          "prompt":"raw body",
          "timestamp":"2026-06-12T10:00:00Z",
          "chatText":"chat",
          "artifactType":"agent_prompt",
          "artifactBody":"Fix the silent failure of Apply.",
          "artifactTitle":"Fix silent promo code failure"}]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let store = RecentPromptStore(fileURL: fileURL)
        let entry = store.prompts.first
        XCTAssertEqual(entry?.outputType, "agent_prompt")
        XCTAssertEqual(entry?.outputBody, "Fix the silent failure of Apply.")
        XCTAssertEqual(entry?.outputTitle, "Fix silent promo code failure")

        store.add(prompt: "new body", outputType: "snippet", outputBody: "SELECT 1;")
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\"artifactType\""), "disk keys are a compat contract")
        XCTAssertTrue(written.contains("\"artifactBody\""))
        XCTAssertFalse(written.contains("\"outputType\""), "renamed properties must not leak to disk")
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
        outputType: String? = nil,
        outputBody: String? = nil
    ) -> RecentPrompt {
        RecentPrompt(
            title: "t",
            prompt: prompt,
            chatText: chatText,
            outputType: outputType,
            outputBody: outputBody
        )
    }

    func testCopyPayloadPrefersOutputBody() {
        let e = entry(prompt: "raw with fences", chatText: "intro", outputType: "snippet", outputBody: "SELECT 1;")
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
        XCTAssertEqual(entry(outputType: "agent_prompt").displayIconName, "curlybraces")
        XCTAssertEqual(entry(outputType: "message").displayIconName, "envelope")
        XCTAssertEqual(entry(outputType: "snippet").displayIconName, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(entry(outputType: "document").displayIconName, "doc.text")
    }

    func testDisplayIconChatOnlyAndUnknownType() {
        XCTAssertEqual(entry().displayIconName, "text.bubble", "chat-only rows get the chat bubble")
        XCTAssertEqual(
            entry(outputType: "future_type").displayIconName,
            OutputType.generic.iconName,
            "a stored type the enum no longer knows degrades to the generic glyph"
        )
        XCTAssertNil(entry(outputType: "future_type").resolvedOutputType)
    }
}
