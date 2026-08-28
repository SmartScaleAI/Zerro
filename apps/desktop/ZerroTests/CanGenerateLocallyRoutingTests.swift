//
//  CanGenerateLocallyRoutingTests.swift
//  ZerroTests
//
//  Phase 4 (Local Whisper) — the highest-risk change: decoupling the trial/
//  preflight ROUTING decision from "has an OpenAI key" and generalizing it to
//  "can generate locally" (at least one chat key AND a usable transcription
//  path). The test matrix IS the deliverable, so it's exhaustive:
//
//    • `AppState.canGenerateLocally(...)` — the pure capability predicate over
//      hasAnyChatKey × engine × modelInstalled × openAIKeyPresent (Keychain/
//      disk-free; the "fakes" are the explicit signals).
//    • `EntitlementStore.preflightBlock` across
//      state {licensed, trial, expired} × keysets × modelInstalled ×
//      sttEngine, driving `canGenerateLocally` as the COMPUTED predicate.
//    • The non-breaking guarantees + the single new (model-installed) behavior,
//      called out as named tests so the evidence is legible.
//    • The AppState resolver seam (the injectable closure) is honored.
//
//  All dependencies are in-memory; no Keychain, disk, or network. Every
//  generation runs the local pipeline, so the only routing decision left is
//  the pre-flight: whether the user can self-fund.
//

import XCTest
@testable import Zerro

@MainActor
final class CanGenerateLocallyRoutingTests: XCTestCase {

    // MARK: - Keysets (the chat-key + OpenAI-key signals the predicate sees)

    /// The production keyholder shapes. `hasAnyChatKey` gates self-funding at
    /// all; `openAIKeyPresent` decides the cloud-Whisper STT path. Claude-only
    /// and Gemini-only present IDENTICAL signals (a non-OpenAI chat key, no
    /// OpenAI key) — both enumerated to document that the predicate treats them
    /// the same (the difference is which chat provider, which routing handles
    /// elsewhere).
    private struct Keyset {
        let label: String
        let hasAnyChatKey: Bool
        let openAIKeyPresent: Bool
    }
    private let keysets: [Keyset] = [
        Keyset(label: "none",          hasAnyChatKey: false, openAIKeyPresent: false),
        Keyset(label: "openai-only",   hasAnyChatKey: true,  openAIKeyPresent: true),
        Keyset(label: "claude-only",   hasAnyChatKey: true,  openAIKeyPresent: false),
        Keyset(label: "gemini-only",   hasAnyChatKey: true,  openAIKeyPresent: false),
        Keyset(label: "openai+claude", hasAnyChatKey: true,  openAIKeyPresent: true),
    ]

    private let engines: [STTEngine] = [.auto, .local, .cloud]

    // MARK: - The pure capability predicate (no Keychain/disk)

    /// Full truth table for `AppState.canGenerateLocally`. The no-chat-key
    /// sub-space is swept programmatically (always false — the chat-key gate
    /// dominates); the chat-key rows carry HAND-WRITTEN expectations so the test
    /// can't pass tautologically by re-deriving the function under test.
    func testCanGenerateLocallyPredicate() {
        // No chat key → false for every STT path.
        for engine in engines {
            for model in [true, false] {
                for key in [true, false] {
                    XCTAssertFalse(
                        AppState.canGenerateLocally(
                            hasAnyChatKey: false, engine: engine,
                            modelInstalled: model, openAIKeyPresent: key
                        ),
                        "no chat key must be false (engine=\(engine) model=\(model) key=\(key))"
                    )
                }
            }
        }
        // With a chat key, the STT path decides.
        // (engine, modelInstalled, openAIKeyPresent) → expected
        let chatKeyCases: [(STTEngine, Bool, Bool, Bool)] = [
            (.auto,  true,  true,  true),
            (.auto,  true,  false, true),   // model alone — the Claude-only headline
            (.auto,  false, true,  true),   // OpenAI key alone — today's path
            (.auto,  false, false, false),  // chat key but NO transcription path
            (.local, true,  true,  true),
            (.local, true,  false, true),
            (.local, false, true,  false),  // .local needs the model, key irrelevant
            (.local, false, false, false),
            (.cloud, true,  true,  true),
            (.cloud, true,  false, false),  // .cloud needs the OpenAI key, model irrelevant
            (.cloud, false, true,  true),
            (.cloud, false, false, false),
        ]
        for (engine, model, key, expected) in chatKeyCases {
            XCTAssertEqual(
                AppState.canGenerateLocally(
                    hasAnyChatKey: true, engine: engine,
                    modelInstalled: model, openAIKeyPresent: key
                ),
                expected,
                "chatKey + engine=\(engine) model=\(model) key=\(key)"
            )
        }
    }

    // MARK: - preflightBlock matrix

    /// The pre-flight gate across state × keysets × modelInstalled × sttEngine,
    /// with `canGenerateLocally` computed by the predicate. The stores are pure
    /// reads, so one of each is reused.
    func testPreflightBlockMatrix() {
        let licensed = byokStore()
        let trial = trialStore()
        let expired = expiredStore()

        for ks in keysets {
            for model in [true, false] {
                for engine in engines {
                    let cgl = AppState.canGenerateLocally(
                        hasAnyChatKey: ks.hasAnyChatKey, engine: engine,
                        modelInstalled: model, openAIKeyPresent: ks.openAIKeyPresent
                    )
                    let ctx = "keys=\(ks.label) model=\(model) engine=\(engine) cgl=\(cgl)"

                    // Granting states block .apiKeyMissing iff they can't self-fund.
                    let expected: EntitlementStore.PreflightBlock? = cgl ? nil : .apiKeyMissing
                    XCTAssertEqual(licensed.preflightBlock(canGenerateLocally: cgl), expected, "licensed \(ctx)")
                    XCTAssertEqual(trial.preflightBlock(canGenerateLocally: cgl), expected, "trial \(ctx)")
                    // Expired: pre-flight is never the gate (canGenerate is).
                    XCTAssertNil(expired.preflightBlock(canGenerateLocally: cgl), "expired \(ctx)")
                }
            }
        }
    }

    // MARK: - Non-breaking guarantees + the one new behavior (explicit)

    /// An OpenAI-key user self-funds on `.auto` whether or not a model is
    /// installed — byte-identical routing to before Phase 4 (the only STT path
    /// pre-Local-Whisper was OpenAI Whisper).
    func testNonBreaking_OpenAIKeyUserSelfFunds() {
        for model in [true, false] {
            XCTAssertTrue(
                AppState.canGenerateLocally(hasAnyChatKey: true, engine: .auto, modelInstalled: model, openAIKeyPresent: true),
                "an OpenAI key is a usable transcription path (model=\(model))"
            )
        }
        XCTAssertNil(trialStore().preflightBlock(canGenerateLocally: true))
        XCTAssertNil(byokStore().preflightBlock(canGenerateLocally: true))
    }

    /// Claude-only / Gemini-only with NO model installed: `.auto` can't
    /// resolve, so `canGenerateLocally` is false and the pre-flight blocks
    /// exactly as an OpenAI-less user did before — for the trial and the
    /// license alike.
    func testNonOpenAIKeyNoModelBlocksPreflight() {
        for ks in [keysets[2], keysets[3]] { // claude-only, gemini-only
            let cgl = AppState.canGenerateLocally(
                hasAnyChatKey: ks.hasAnyChatKey, engine: .auto,
                modelInstalled: false, openAIKeyPresent: ks.openAIKeyPresent
            )
            XCTAssertFalse(cgl, "\(ks.label): chat key but no transcription path")
            XCTAssertEqual(trialStore().preflightBlock(canGenerateLocally: cgl), .apiKeyMissing, ks.label)
            XCTAssertEqual(byokStore().preflightBlock(canGenerateLocally: cgl), .apiKeyMissing, ks.label)
        }
    }

    /// A Claude-only (no OpenAI key) user with the on-device model + `.auto`
    /// has a fully local path: no false `.apiKeyMissing` for the trial or the
    /// license.
    func testNonOpenAIKeyWithModelPassesPreflight() {
        let cgl = AppState.canGenerateLocally(
            hasAnyChatKey: true, engine: .auto, modelInstalled: true, openAIKeyPresent: false
        )
        XCTAssertTrue(cgl, "a chat key + an installed model is a usable local path")
        XCTAssertNil(trialStore().preflightBlock(canGenerateLocally: cgl))
        XCTAssertNil(byokStore().preflightBlock(canGenerateLocally: cgl))
    }

    // MARK: - AppState resolver seam (the injectable closure)

    /// `canGenerateLocally()` honors an injected `canGenerateLocallyProvider`
    /// (the Phase-3 pattern), so both entitlement readers can be driven without a
    /// Keychain/disk. (The default closure's cheap reads are exercised by the
    /// pure-predicate test above; here we prove the override path.)
    func testResolverHonorsInjectedProvider() {
        let app = AppState()
        app.canGenerateLocallyProvider = { true }
        XCTAssertTrue(app.canGenerateLocally())
        app.canGenerateLocallyProvider = { false }
        XCTAssertFalse(app.canGenerateLocally())
    }

    // MARK: - Store builders (in-memory; mirror PreflightGateTests)

    private func makeLicense(present: Bool) -> LicenseService {
        LicenseService(
            licenseKeySlot: InMemoryKeychainSlot(present ? "KEY" : nil),
            instanceIDSlot: InMemoryKeychainSlot(present ? "instance" : nil),
            lastValidatedSlot: InMemoryKeychainSlot(nil),
            licensedProductIDSlot: InMemoryKeychainSlot(present ? "7" : nil),
            licensedMajorSlot: InMemoryKeychainSlot(present ? "1" : nil),
            policy: LicenseEditionPolicy(requiredMajor: 1, approvedProductIDs: [7]),
            transport: OfflineLicenseTransport()
        )
    }

    private func byokStore() -> EntitlementStore {
        EntitlementStore(enforcementMode: .official, licenseService: makeLicense(present: true))
    }

    /// A trial clock over in-memory slots, either freshly started or elapsed,
    /// against a fixed `now`.
    private func makeClock(expired: Bool) -> TrialManager {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = expired ? now.addingTimeInterval(-Double(TrialManager.trialLengthDays + 1) * 86_400) : now
        return TrialManager(
            startDateSlot: InMemoryKeychainSlot(String(Int(start.timeIntervalSince1970))),
            maxDateSeenSlot: InMemoryKeychainSlot(),
            clock: { now }
        )
    }

    /// An ACTIVE local trial (no license).
    private func trialStore() -> EntitlementStore {
        EntitlementStore(
            enforcementMode: .official,
            licenseService: makeLicense(present: false),
            trialManager: makeClock(expired: false)
        )
    }

    /// An ELAPSED local trial (no license) → the gated state.
    private func expiredStore() -> EntitlementStore {
        EntitlementStore(
            enforcementMode: .official,
            licenseService: makeLicense(present: false),
            trialManager: makeClock(expired: true)
        )
    }
}
