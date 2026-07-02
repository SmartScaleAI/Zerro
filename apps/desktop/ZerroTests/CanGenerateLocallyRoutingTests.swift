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
//    • `EntitlementStore.generationRoute` / `preflightBlock` across
//      plan {byok, trial, managed, expired} × keysets × modelInstalled ×
//      sttEngine, driving `canGenerateLocally` as the COMPUTED predicate.
//    • The non-breaking guarantees + the single new (model-installed) behavior,
//      called out as named tests so the evidence is legible.
//    • The AppState resolver seam (the injectable closure) is honored.
//
//  All dependencies are in-memory; no Keychain, disk, or network. Trial token/
//  email sub-branches stay covered by TrialCreditsTests — here every trial store
//  is a FRESH unverified trial so the trial route is purely
//  `canGenerateLocally ? .local : .trialNeedsEmail`, isolating the Phase-4 lever.
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

    // MARK: - generationRoute matrix

    /// plan {byok, trial, managed, expired} × keysets × modelInstalled ×
    /// sttEngine → expected route, with `canGenerateLocally` computed by the
    /// predicate. The plan stores are pure reads, so one of each is reused.
    func testGenerationRouteMatrix() {
        let byok = byokStore()
        let managed = managedStore()
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

                    // BYOK: always .local — funds locally; fails gracefully at
                    // record time if STT can't resolve (unchanged from today).
                    XCTAssertEqual(byok.generationRoute(canGenerateLocally: cgl), .local, "byok \(ctx)")
                    // Managed: always the proxy — the server is the spend
                    // authority, independent of any local capability.
                    XCTAssertEqual(managed.generationRoute(canGenerateLocally: cgl), .managedProxy, "managed \(ctx)")
                    // Expired: defensive .local (the canGenerate gate blocks it
                    // first); independent of capability.
                    XCTAssertEqual(expired.generationRoute(canGenerateLocally: cgl), .local, "expired \(ctx)")
                    // Trial (fresh, unverified): .local iff the user can self-fund,
                    // else the email-capture flow. THIS is the Phase-4 lever.
                    XCTAssertEqual(
                        trial.generationRoute(canGenerateLocally: cgl),
                        cgl ? .local : .trialNeedsEmail,
                        "trial \(ctx)"
                    )
                }
            }
        }
    }

    // MARK: - preflightBlock matrix

    /// The pre-flight gate mirrored across the same matrix. Managed credit/status
    /// blocking is independent of `canGenerateLocally` (covered exhaustively in
    /// PreflightGateTests); here the managed store is active-with-credits, so it
    /// must never block on capability.
    func testPreflightBlockMatrix() {
        let byok = byokStore()
        let managed = managedStore()
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

                    // BYOK: blocks .apiKeyMissing iff it can't self-fund.
                    let expectedByok: EntitlementStore.PreflightBlock? = cgl ? nil : .apiKeyMissing
                    XCTAssertEqual(byok.preflightBlock(canGenerateLocally: cgl), expectedByok, "byok \(ctx)")
                    // Managed (active, credits > 0): capability never blocks.
                    XCTAssertNil(managed.preflightBlock(canGenerateLocally: cgl), "managed \(ctx)")
                    // Trial / expired: pre-flight is never the gate (canGenerate is).
                    XCTAssertNil(trial.preflightBlock(canGenerateLocally: cgl), "trial \(ctx)")
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
        XCTAssertEqual(trialStore().generationRoute(canGenerateLocally: true), .local)
        XCTAssertNil(byokStore().preflightBlock(canGenerateLocally: true))
    }

    /// Claude-only / Gemini-only with NO model installed (production reality
    /// until Phase 5): `.auto` can't resolve, so `canGenerateLocally` is false and
    /// the trial routes EXACTLY as today (email capture), and BYOK pre-flight
    /// blocks exactly as an OpenAI-less user did before. The phase is inert in
    /// production until a model exists.
    func testNonBreaking_NonOpenAIKeyNoModelUnchanged() {
        for ks in [keysets[2], keysets[3]] { // claude-only, gemini-only
            let cgl = AppState.canGenerateLocally(
                hasAnyChatKey: ks.hasAnyChatKey, engine: .auto,
                modelInstalled: false, openAIKeyPresent: ks.openAIKeyPresent
            )
            XCTAssertFalse(cgl, "\(ks.label): chat key but no transcription path")
            XCTAssertEqual(trialStore().generationRoute(canGenerateLocally: cgl), .trialNeedsEmail, ks.label)
            XCTAssertEqual(byokStore().preflightBlock(canGenerateLocally: cgl), .apiKeyMissing, ks.label)
        }
    }

    /// THE new behavior (only once a model is installed): a Claude-only (no
    /// OpenAI key) TRIAL user with the on-device model + `.auto` now self-funds
    /// LOCALLY instead of consuming trial server credits.
    func testNewBehavior_NonOpenAIKeyWithModelRoutesLocalOnTrial() {
        let cgl = AppState.canGenerateLocally(
            hasAnyChatKey: true, engine: .auto, modelInstalled: true, openAIKeyPresent: false
        )
        XCTAssertTrue(cgl, "a chat key + an installed model is a usable local path")
        XCTAssertEqual(
            trialStore().generationRoute(canGenerateLocally: cgl), .local,
            "Claude/Gemini-only trial + model → their dime, not trial credits"
        )
        // And the same setup lets a BYOK user past pre-flight (no false
        // .apiKeyMissing now that a non-OpenAI local path exists).
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
            transport: OfflineLicenseTransport()
        )
    }

    private func byokStore() -> EntitlementStore {
        EntitlementStore(
            licenseService: makeLicense(present: true),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.byok.rawValue),
            defaults: .ephemeralPreview()
        )
    }

    /// A `.managed` store, active with credits — so its pre-flight is gated only
    /// by the (here-healthy) snapshot, never by `canGenerateLocally`.
    private func managedStore() -> EntitlementStore {
        let defaults = UserDefaults.ephemeralPreview()
        let snapshot = ManagedEntitlementSnapshot(
            status: .active, creditsRemaining: 100, creditsLimit: 100, resetDate: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        defaults.set(try! encoder.encode(snapshot), forKey: "managed_entitlement_snapshot_v1")
        return EntitlementStore(
            licenseService: makeLicense(present: true),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(LicenseProductKind.managed.rawValue),
            defaults: defaults
        )
    }

    /// A FRESH, unverified trial (no token, no remembered email) so the trial
    /// route reduces to `canGenerateLocally ? .local : .trialNeedsEmail`.
    private func trialStore() -> EntitlementStore {
        EntitlementStore(
            licenseService: makeLicense(present: false),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            trialCredits: .inMemory(),
            defaults: .ephemeralPreview()
        )
    }

    private func expiredStore() -> EntitlementStore {
        let trial = TrialCreditsManager.inMemory()
        trial.applyCreditsRemaining(0) // confirmed-zero → .expired
        return EntitlementStore(
            licenseService: makeLicense(present: false),
            sessionTokens: .inMemory(),
            productKindSlot: InMemoryKeychainSlot(nil),
            trialCredits: trial,
            defaults: .ephemeralPreview()
        )
    }
}
