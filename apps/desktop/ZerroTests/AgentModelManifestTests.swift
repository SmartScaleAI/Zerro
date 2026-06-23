//
//  AgentModelManifestTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2) — the model-manifest layer: fallback chain (live → cache
//  → bundled), provider mapping, the `--model` argv threading, the per-agent
//  remembered-model resolution, and the Cursor CLI parser. The store's network
//  goes through `StubManagedTransport`; UserDefaults is an ephemeral suite, so
//  nothing here touches the real backend or the user's prefs.
//

import XCTest
@testable import Zerro

@MainActor
final class AgentModelManifestTests: XCTestCase {

    private func makeStore(transport: ManagedTransport) -> AgentModelManifestStore {
        AgentModelManifestStore(transport: transport, defaults: .ephemeralPreview())
    }

    private let manifestJSON = """
    {"providers":{
      "anthropic":[
        {"model_id":"claude-opus-4-8","display_name":"Claude Opus 4.8"},
        {"model_id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"}
      ]
    }}
    """

    // MARK: - Fallback chain

    func testBundledFallbackBeforeAnyFetch() {
        let store = makeStore(transport: StubManagedTransport())
        // No cache, no fetch yet → the bundled defaults (never empty).
        XCTAssertFalse(store.models(forProvider: "anthropic").isEmpty)
        XCTAssertEqual(store.models(forProvider: "anthropic"), AgentModelManifestStore.bundled["anthropic"])
        // OpenAI is retired — no bundled list, so an openai lookup is empty.
        XCTAssertTrue(store.models(forProvider: "openai").isEmpty)
    }

    func testWarmAdoptsLiveManifestNewestFirst() async {
        let transport = StubManagedTransport()
        transport.enqueue(manifestJSON, status: 200)
        let store = makeStore(transport: transport)
        await store.warm()
        XCTAssertEqual(store.models(forProvider: "anthropic").map(\.modelID),
                       ["claude-opus-4-8", "claude-sonnet-4-6"])
        XCTAssertEqual(store.models(forProvider: "anthropic").first?.displayName, "Claude Opus 4.8")
    }

    func testWarmIgnoresAnyOpenAIInBody() async {
        // A stray openai array in the body (e.g. a not-yet-cleaned backend) is
        // ignored — OpenAI is retired, so it never surfaces.
        let transport = StubManagedTransport()
        transport.enqueue(#"{"providers":{"anthropic":[{"model_id":"claude-opus-4-8","display_name":"Claude Opus 4.8"}],"openai":[{"model_id":"gpt-5-codex","display_name":"GPT-5 Codex"}]}}"#, status: 200)
        let store = makeStore(transport: transport)
        await store.warm()
        XCTAssertEqual(store.models(forProvider: "anthropic").map(\.modelID), ["claude-opus-4-8"])
        XCTAssertTrue(store.models(forProvider: "openai").isEmpty)
    }

    func testWarmTransportFailureKeepsBundled() async {
        let transport = StubManagedTransport()
        transport.error = URLError(.notConnectedToInternet)
        let store = makeStore(transport: transport)
        await store.warm()
        // Offline → fail open, keep the bundled list (picker never empties).
        XCTAssertEqual(store.models(forProvider: "anthropic"), AgentModelManifestStore.bundled["anthropic"])
    }

    func testWarmNon200KeepsBundled() async {
        let transport = StubManagedTransport()
        transport.enqueue("{}", status: 500)
        let store = makeStore(transport: transport)
        await store.warm()
        XCTAssertEqual(store.models(forProvider: "anthropic"), AgentModelManifestStore.bundled["anthropic"])
    }

    func testWarmEmptyManifestKeepsBundled() async {
        let transport = StubManagedTransport()
        transport.enqueue(#"{"providers":{"anthropic":[]}}"#, status: 200)
        let store = makeStore(transport: transport)
        await store.warm()
        // A transient empty body must not blank a working list.
        XCTAssertEqual(store.models(forProvider: "anthropic"), AgentModelManifestStore.bundled["anthropic"])
    }

    func testWarmPersistsCacheReadBackByNewStore() async {
        let defaults = UserDefaults.ephemeralPreview()
        let transport = StubManagedTransport()
        transport.enqueue(manifestJSON, status: 200)
        let store = AgentModelManifestStore(transport: transport, defaults: defaults)
        await store.warm()
        // A fresh store over the SAME defaults reads the cached manifest at init,
        // before any fetch — the live→cache step of the fallback chain.
        let reopened = AgentModelManifestStore(transport: StubManagedTransport(), defaults: defaults)
        XCTAssertEqual(reopened.models(forProvider: "anthropic").map(\.modelID),
                       ["claude-opus-4-8", "claude-sonnet-4-6"])
    }

    // MARK: - Provider mapping

    func testAgentProviderMapping() {
        XCTAssertEqual(AgentModelMapping.source(forAgent: DevAgentRegistry.claudeCodeID), .manifest(provider: "anthropic"))
        // Codex is sourced from its OWN list now, not the OpenAI manifest.
        XCTAssertEqual(AgentModelMapping.source(forAgent: DevAgentRegistry.codexID), .codexCLI)
        XCTAssertEqual(AgentModelMapping.source(forAgent: "cursor"), .cursorCLI)
        XCTAssertEqual(AgentModelMapping.source(forAgent: "unknown-agent"), .none)
    }

    func testModelsForAgentResolvesManifestProvider() async {
        let transport = StubManagedTransport()
        transport.enqueue(manifestJSON, status: 200)
        let store = makeStore(transport: transport)
        await store.warm()
        XCTAssertEqual(store.models(forAgent: DevAgentRegistry.claudeCodeID).map(\.modelID),
                       ["claude-opus-4-8", "claude-sonnet-4-6"])
        XCTAssertTrue(store.models(forAgent: "unknown-agent").isEmpty)
        // Codex resolves to its own CLI list (DevAgentDetection), NOT the manifest.
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
        // other model survives. (DevAgentDetection.devModelExclusions — the
        // app-side mirror of the models.ts / ModelRegistry.swift `enabled:false`.)
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
