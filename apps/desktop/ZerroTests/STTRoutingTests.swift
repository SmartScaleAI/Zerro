//
//  STTRoutingTests.swift
//  ZerroTests
//
//  Phase 3 (Local Whisper) — the STT router truth table + the $0-local cost rule.
//  `STTRouting.resolve` is pure: availability is passed in and the service
//  factories are injected, so every branch is exercised without a model file, a
//  Keychain key, or the network.
//

import XCTest
@testable import Zerro

@MainActor
final class STTRoutingTests: XCTestCase {

    // MARK: - Fakes

    private struct FakeLocalService: TranscriptionService {
        func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript {
            Transcript(segments: [], fullText: "")
        }
    }
    private struct FakeCloudService: TranscriptionService {
        func transcribe(audioFileURL: URL, wordTimestamps: Bool) async throws -> Transcript {
            Transcript(segments: [], fullText: "")
        }
    }

    private enum Expected { case local, cloud, needsLocalModel, needsOpenAIKey }

    private func resolve(_ engine: STTEngine, installed: Bool, key: Bool) -> STTResolution {
        STTRouting.resolve(
            engine: engine,
            modelInstalled: installed,
            openAIKeyPresent: key,
            localModelURL: installed ? URL(fileURLWithPath: "/tmp/model.bin") : nil,
            makeLocalService: { _ in FakeLocalService() },
            makeCloudService: { FakeCloudService() }
        )
    }

    private func assert(_ resolution: STTResolution, is expected: Expected,
                        _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (resolution, expected) {
        case (.service(let s), .local):
            XCTAssertTrue(s is FakeLocalService, "\(message): expected LOCAL service", file: file, line: line)
        case (.service(let s), .cloud):
            XCTAssertTrue(s is FakeCloudService, "\(message): expected CLOUD service", file: file, line: line)
        case (.needsLocalModel, .needsLocalModel), (.needsOpenAIKey, .needsOpenAIKey):
            break
        default:
            XCTFail("\(message): unexpected resolution \(resolution) (wanted \(expected))", file: file, line: line)
        }
    }

    // MARK: - Truth table

    /// {auto, local, cloud} × {modelInstalled} × {openAIKey} → expected resolution.
    func testTruthTable() {
        let cases: [(STTEngine, Bool, Bool, Expected)] = [
            // .auto — local when installed, else cloud when keyed, else needs key.
            (.auto,  true,  true,  .local),
            (.auto,  true,  false, .local),
            (.auto,  false, true,  .cloud),
            (.auto,  false, false, .needsOpenAIKey),
            // .local — local when installed, else needs model (key irrelevant).
            (.local, true,  true,  .local),
            (.local, true,  false, .local),
            (.local, false, true,  .needsLocalModel),
            (.local, false, false, .needsLocalModel),
            // .cloud — cloud when keyed, else needs key (model irrelevant).
            (.cloud, true,  true,  .cloud),
            (.cloud, true,  false, .needsOpenAIKey),
            (.cloud, false, true,  .cloud),
            (.cloud, false, false, .needsOpenAIKey),
        ]
        for (engine, installed, key, expected) in cases {
            assert(resolve(engine, installed: installed, key: key), is: expected,
                   "engine=\(engine) installed=\(installed) key=\(key)")
        }
    }

    /// THE non-breaking guarantee (production reality until Phase 5): no local
    /// model installed + an OpenAI key + `.auto` resolves to CLOUD Whisper.
    func testNonBreaking_NoModel_OpenAIKey_Auto_ResolvesCloud() {
        assert(resolve(.auto, installed: false, key: true), is: .cloud,
               "no model + OpenAI key + auto must stay on cloud Whisper")
    }

    // MARK: - canResolve predicate (the shared STT source of truth)

    /// `canResolve` is the boolean predicate that pre-flight and entitlement
    /// routing (Phase 4 `canGenerateLocally`) share with `resolve`. Explicit
    /// truth table (hand-written expectations): {auto,local,cloud} ×
    /// {modelInstalled} × {openAIKeyPresent}.
    func testCanResolveTruthTable() {
        let cases: [(STTEngine, Bool, Bool, Bool)] = [
            // engine, modelInstalled, openAIKeyPresent, expected
            (.auto,  true,  true,  true),
            (.auto,  true,  false, true),
            (.auto,  false, true,  true),
            (.auto,  false, false, false),
            (.local, true,  true,  true),
            (.local, true,  false, true),
            (.local, false, true,  false),
            (.local, false, false, false),
            (.cloud, true,  true,  true),
            (.cloud, true,  false, false),
            (.cloud, false, true,  true),
            (.cloud, false, false, false),
        ]
        for (engine, model, key, expected) in cases {
            XCTAssertEqual(
                STTRouting.canResolve(engine: engine, modelInstalled: model, openAIKeyPresent: key),
                expected,
                "canResolve(engine=\(engine) model=\(model) key=\(key))"
            )
        }
    }

    /// The "can never disagree" guarantee. Over the full boolean matrix — with
    /// `localModelURL` consistent with `modelInstalled`, the only inputs the app
    /// actually produces — `canResolve` is true EXACTLY when `resolve` returns a
    /// service. This is what lets pre-flight, routing, and recording-time
    /// resolution share one rule without drifting apart.
    func testCanResolveAgreesWithResolve() {
        for engine in [STTEngine.auto, .local, .cloud] {
            for model in [true, false] {
                for key in [true, false] {
                    let producesService: Bool
                    if case .service = resolve(engine, installed: model, key: key) {
                        producesService = true
                    } else {
                        producesService = false
                    }
                    XCTAssertEqual(
                        STTRouting.canResolve(engine: engine, modelInstalled: model, openAIKeyPresent: key),
                        producesService,
                        "canResolve must agree with resolve (engine=\(engine) model=\(model) key=\(key))"
                    )
                }
            }
        }
    }

    // MARK: - Default (real) factories

    /// With no injected factories, `.cloud` + a key builds the REAL cloud service.
    func testDefaultCloudFactoryBuildsOpenAIService() {
        let resolution = STTRouting.resolve(
            engine: .cloud, modelInstalled: false, openAIKeyPresent: true, localModelURL: nil
        )
        guard case .service(let s) = resolution else { return XCTFail("expected a service") }
        XCTAssertTrue(s is OpenAITranscriptionService)
    }

    /// With no injected factory, `.local` + a path to a NON-existent file → the
    /// real `WhisperCppTranscriptionService(modelURL:)` throws `.modelUnavailable`,
    /// the factory returns nil, and routing degrades to `.needsLocalModel`.
    func testDefaultLocalFactoryFallsBackWhenFileMissing() {
        let resolution = STTRouting.resolve(
            engine: .local,
            modelInstalled: true,
            openAIKeyPresent: false,
            localModelURL: URL(fileURLWithPath: "/nonexistent/model.bin")
        )
        guard case .needsLocalModel = resolution else {
            return XCTFail("expected .needsLocalModel, got \(resolution)")
        }
    }

    // MARK: - $0 local STT cost

    func testLocalSTTCostIsZero() {
        XCTAssertEqual(AppState.sttCostUSD(audioDurationSeconds: 123, isLocal: true), 0)
    }

    func testCloudSTTCostMatchesWhisperEstimate() {
        let duration = 90.0
        XCTAssertEqual(
            AppState.sttCostUSD(audioDurationSeconds: duration, isLocal: false),
            OpenAITranscriptionService.estimatedCost(audioDurationSeconds: duration),
            accuracy: 1e-12
        )
        XCTAssertGreaterThan(AppState.sttCostUSD(audioDurationSeconds: duration, isLocal: false), 0)
    }
}
