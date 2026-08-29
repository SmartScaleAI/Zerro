//
//  AgentModelManifestTests.swift
//  ZerroTests
//
//  Dev Mode — the model-manifest layer: the BUNDLED AgentModels.json
//  resource (loading, parsing, fail-safe behavior on missing/malformed
//  data), provider mapping, the `--model` argv threading, the per-agent
//  remembered-model resolution, and the Codex/Cursor CLI parsers. The store
//  needs NO transport and NO persistent cache — its init takes only a
//  Bundle — so nothing here touches any backend or the user's prefs.
//

import XCTest
@testable import Zerro

@MainActor
final class AgentModelManifestTests: XCTestCase {

    private let manifestJSON = """
    {"providers":{
      "anthropic":[
        {"model_id":"claude-opus-4-8","display_name":"Claude Opus 4.8"},
        {"model_id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"}
      ]
    }}
    """

    // MARK: - Bundled resource

    func testBundledResourceIsPresentInTheAppBundle() {
        // Tests are hosted in Zerro.app, so Bundle.main IS the built app —
        // this asserts the JSON actually ships inside the bundle.
        XCTAssertNotNil(
            Bundle.main.url(forResource: AgentModelManifestStore.resourceName, withExtension: "json"),
            "AgentModels.json must be bundled into Zerro.app"
        )
    }

    func testBundledManifestLoadsAndAnthropicListIsNonEmpty() {
        let store = AgentModelManifestStore()
        let models = store.models(forProvider: "anthropic")
        XCTAssertFalse(models.isEmpty, "the bundled manifest must carry Anthropic models")
        // Newest-first: rank 0 is the default pick.
        XCTAssertEqual(models.first?.modelID, "claude-opus-4-8")
        // Every entry has a real id + label.
        for model in models {
            XCTAssertFalse(model.modelID.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
        }
        // No manifest list for retired/unknown providers.
        XCTAssertTrue(store.models(forProvider: "openai").isEmpty)
    }

    func testMissingResourceFailsSafelyToEmpty() {
        // The TEST bundle carries no AgentModels.json — the store must come up
        // empty (never crash), which downstream renders as "no picker" and the
        // agent's own default model.
        let store = AgentModelManifestStore(bundle: Bundle(for: AgentModelManifestTests.self))
        XCTAssertTrue(store.providers.isEmpty)
        XCTAssertTrue(store.models(forProvider: "anthropic").isEmpty)
        XCTAssertTrue(store.models(forAgent: DevAgentRegistry.claudeCodeID).isEmpty)
    }

    func testDecodeParsesTheWireShapeNewestFirst() throws {
        let resolved = try XCTUnwrap(AgentModelManifestStore.decode(Data(manifestJSON.utf8)))
        XCTAssertEqual(resolved["anthropic"]?.map(\.modelID),
                       ["claude-opus-4-8", "claude-sonnet-4-6"])
        XCTAssertEqual(resolved["anthropic"]?.first?.displayName, "Claude Opus 4.8")
    }

    func testMalformedAndEmptyManifestsDecodeToNil() {
        XCTAssertNil(AgentModelManifestStore.decode(Data("not json".utf8)))
        XCTAssertNil(AgentModelManifestStore.decode(Data()))
        XCTAssertNil(AgentModelManifestStore.decode(Data(#"{"providers":{}}"#.utf8)),
                     "no providers must not look loaded")
        XCTAssertNil(AgentModelManifestStore.decode(Data(#"{"providers":{"anthropic":[]}}"#.utf8)),
                     "an empty model list must not look loaded")
    }

    // MARK: - Agent mapping

    func testAgentProviderMapping() {
        XCTAssertEqual(AgentModelMapping.source(forAgent: DevAgentRegistry.claudeCodeID),
                       .manifest(provider: "anthropic"))
        XCTAssertEqual(AgentModelMapping.source(forAgent: DevAgentRegistry.codexID), .codexCLI)
        XCTAssertEqual(AgentModelMapping.source(forAgent: DevAgentRegistry.cursorID), .cursorCLI)
        XCTAssertEqual(AgentModelMapping.source(forAgent: "someday-agent"), AgentModelSource.none)
    }

    func testModelsForAgentResolvesTheBundledManifest() {
        let store = AgentModelManifestStore()
        XCTAssertEqual(
            store.models(forAgent: DevAgentRegistry.claudeCodeID),
            store.models(forProvider: "anthropic"),
            "Claude Code resolves through the bundled anthropic manifest"
        )
        XCTAssertFalse(store.models(forAgent: DevAgentRegistry.claudeCodeID).isEmpty)
    }

    // MARK: - Codex models cache parser

    func testParseCodexModelsCache() {
        // Mirrors ~/.codex/models_cache.json: visibility "list" kept (priority
        // asc), "hide" dropped (e.g. codex-auto-review). GPT-5.4 mini is also
        // dropped by the Dev Mode exclusion (see testParseCodexModelsCacheExcludesGPT54Mini).
        let json = #"""
        {"fetched_at":"x","models":[
          {"slug":"gpt-5.5-codex","display_name":"GPT-5.5 Codex","visibility":"list","priority":23},
          {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":9},
          {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":43}
        ]}
        """#
        let out = DevAgentDetection.parseCodexModelsCache(Data(json.utf8))
        XCTAssertEqual(out.map(\.modelID), ["gpt-5.5", "gpt-5.5-codex"])   // priority-sorted
        XCTAssertEqual(out.first?.displayName, "GPT-5.5")
    }

    func testParseCodexModelsCacheExcludesGPT54Mini() {
        // Dev Mode product exclusion: GPT-5.4 mini AND its effort/latency variants
        // are filtered out even though the user's Codex account lists them; every
        // other model survives. (DevAgentDetection.devModelExclusions — the Dev
        // Mode counterpart of ModelRegistry.swift's `enabled: false` kill switch.)
        let json = #"""
        {"fetched_at":"x","models":[
          {"slug":"gpt-5.4-mini","display_name":"GPT-5.4-Mini","visibility":"list","priority":23},
          {"slug":"gpt-5.4-mini-high","display_name":"GPT-5.4-Mini High","visibility":"list","priority":24},
          {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":9},
          {"slug":"gpt-5.5-codex","display_name":"GPT-5.5 Codex","visibility":"list","priority":5}
        ]}
        """#
        let out = DevAgentDetection.parseCodexModelsCache(Data(json.utf8))
        XCTAssertEqual(out.map(\.modelID), ["gpt-5.5-codex", "gpt-5.5"])   // priority-sorted, mini family gone
        XCTAssertFalse(out.contains { $0.modelID.contains("gpt-5.4-mini") })
    }

    func testParseCodexModelsCacheGarbageIsEmpty() {
        XCTAssertTrue(DevAgentDetection.parseCodexModelsCache(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(DevAgentDetection.parseCodexModelsCache(Data("{}".utf8)).isEmpty)
    }

    // MARK: - Cursor CLI parser

    func testParseCursorModelsCuratesRealOutput() {
        // A representative slice of the live `cursor-agent models` output
        // (verified 2026-06-18): "<id> - <Display Name>" rows, an "Available
        // models" header, a trailing "Tip:" line, and the effort×latency
        // permutation explosion we collapse.
        let out = DevAgentDetection.parseCursorModels("""
        Available models

        auto - Auto
        composer-2.5 - Composer 2.5 (current)
        composer-2.5-fast - Composer 2.5 Fast (default)
        claude-opus-4-8-low - Opus 4.8 1M Low
        claude-opus-4-8-high - Opus 4.8 1M
        claude-opus-4-8-high-fast - Opus 4.8 1M Fast
        claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking
        gpt-5.5-medium - GPT-5.5 1M
        gpt-5.5-high - GPT-5.5 1M High
        gemini-3.1-pro - Gemini 3.1 Pro

        Tip: use --model <id> (or /model <id> in interactive mode) to switch.
        """)
        let ids = out.map(\.modelID)
        // One canonical row per family; auto pinned first; header + Tip dropped;
        // -fast / effort permutations collapsed.
        XCTAssertEqual(ids, ["auto", "composer-2.5-fast", "claude-opus-4-8-high", "gpt-5.5-high", "gemini-3.1-pro"])
        XCTAssertEqual(out.first?.modelID, "auto")
        // Composer collapses to its account default ("(default)") representative.
        XCTAssertEqual(out.first { $0.modelID == "composer-2.5-fast" }?.displayName, "Composer 2.5 Fast (default)")
        // Opus collapses to the -high tier with its clean label (NOT "id - id").
        XCTAssertEqual(out.first { $0.modelID == "claude-opus-4-8-high" }?.displayName, "Opus 4.8 1M")
        // No header/Tip leaked in as a bogus model; no parameterized brackets.
        XCTAssertFalse(ids.contains { $0.lowercased().hasPrefix("tip") || $0.lowercased().hasPrefix("available") })
        XCTAssertFalse(ids.contains { $0.contains("[") })
    }

    func testParseCursorModelsDropsBracketedAndKeepsAutoFirst() {
        // Parameterized "[context=…]" forms are dropped (canonical id is enough);
        // `auto` is pinned first even when listed later.
        let out = DevAgentDetection.parseCursorModels("""
        claude-opus-4-8-high - Opus 4.8 1M
        claude-opus-4-8[context=1m,effort=high] - Opus 4.8 1M (1M ctx)
        auto - Auto
        """)
        XCTAssertEqual(out.map(\.modelID), ["auto", "claude-opus-4-8-high"])
    }

    func testParseCursorModelsExcludesGPT54MiniFamily() {
        // Defensive Dev Mode exclusion: even if Cursor advertises a gpt-5.4-mini
        // family, every permutation collapses to one rep and is then dropped;
        // other families survive and `auto` stays pinned first.
        let out = DevAgentDetection.parseCursorModels("""
        auto - Auto
        gpt-5.4-mini-high - GPT-5.4 mini High
        gpt-5.4-mini-medium - GPT-5.4 mini Medium
        gpt-5.5-high - GPT-5.5 High
        """)
        XCTAssertEqual(out.map(\.modelID), ["auto", "gpt-5.5-high"])
        XCTAssertFalse(out.contains { $0.modelID.contains("gpt-5.4-mini") })
    }

    func testParseCursorModelsEmpty() {
        XCTAssertTrue(DevAgentDetection.parseCursorModels("").isEmpty)
        XCTAssertTrue(DevAgentDetection.parseCursorModels("\n\n").isEmpty)
        // A header + Tip with no real rows → empty (no bogus models).
        XCTAssertTrue(DevAgentDetection.parseCursorModels("Available models\n\nTip: use --model <id>").isEmpty)
    }
}

// MARK: - Per-agent remembered model (PreferencesStore)

@MainActor
final class PreferencesSelectedModelTests: XCTestCase {

    private func makePrefs() -> PreferencesStore {
        PreferencesStore(defaults: .ephemeralPreview())
    }

    private let models = [
        AgentModel(modelID: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        AgentModel(modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
    ]

    func testDefaultsToNewestWhenNoneRemembered() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.selectedModel(forAgent: "claude-code", available: models), "claude-opus-4-8")
    }

    func testHonorsRememberedPickWhenStillAvailable() {
        let prefs = makePrefs()
        prefs.selectedModelByAgent["claude-code"] = "claude-sonnet-4-6"
        XCTAssertEqual(prefs.selectedModel(forAgent: "claude-code", available: models), "claude-sonnet-4-6")
    }

    func testRetiredRememberedPickFallsBackToNewest() {
        let prefs = makePrefs()
        prefs.selectedModelByAgent["claude-code"] = "claude-opus-4-5"   // no longer in the list
        XCTAssertEqual(prefs.selectedModel(forAgent: "claude-code", available: models), "claude-opus-4-8")
    }

    func testNoModelsYieldsNil() {
        let prefs = makePrefs()
        XCTAssertNil(prefs.selectedModel(forAgent: "claude-code", available: []))
    }

    func testRememberedModelIsPersisted() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        prefs.selectedModelByAgent["claude-code"] = "claude-sonnet-4-6"
        // A fresh store over the same defaults reads the remembered pick back.
        let reopened = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.selectedModelByAgent["claude-code"], "claude-sonnet-4-6")
    }
}

// MARK: - --model argv threading (DevAgentRegistry)

final class DevAgentModelArgsTests: XCTestCase {

    private func entry(modelFlagName: String?) -> DevAgentEntry {
        DevAgentEntry(
            id: "x", displayName: "X", executableName: "x",
            promptDelivery: .stdin, outputFormat: .streamJSON,
            baseArgs: ["-p"], editsOnlyArgs: ["--edits"], allowCommandsArgs: ["--all"],
            installed: true, absolutePath: URL(fileURLWithPath: "/bin/x"),
            modelFlagName: modelFlagName
        )
    }

    func testModelAppendedWhenSelected() {
        let e = entry(modelFlagName: "--model")
        XCTAssertEqual(e.arguments(permission: .editsOnly, model: "claude-opus-4-8"),
                       ["-p", "--edits", "--model", "claude-opus-4-8"])
    }

    func testNoModelFlagWhenModelNil() {
        let e = entry(modelFlagName: "--model")
        XCTAssertEqual(e.arguments(permission: .editsOnly, model: nil), ["-p", "--edits"])
        XCTAssertEqual(e.arguments(permission: .allowCommands, model: ""), ["-p", "--all"])
    }

    func testNoModelFlagWhenAgentHasNoFlagName() {
        let e = entry(modelFlagName: nil)
        XCTAssertEqual(e.arguments(permission: .editsOnly, model: "anything"), ["-p", "--edits"])
    }

    func testClaudeCodeDeclaresModelFlag() {
        XCTAssertEqual(DevAgentRegistry.entry(id: DevAgentRegistry.claudeCodeID)?.modelFlagName, "--model")
    }
}
