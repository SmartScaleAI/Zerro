//
//  DevDomainDictionaryEnglishGuardTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 2) — the domain dictionary's English-word guards
//  (§11). The dictionary's ONE job is snapping Whisper-mangled *unusual* names
//  back to canonical spelling ("Versel"→"Vercel"). It must never involve a common
//  English word on either side: it must not seed plain-word component names
//  (Hero/Card/Page) as snap targets (Guard 1), and it must never snap a real word
//  the user actually said ("here"/"note"/"text") toward any term (Guard 2).
//
//  The English-word check is injected so these tests are deterministic and do not
//  depend on the OS spell-checker (the real `NSSpellChecker` predicate is only
//  smoke-tested at the bottom).
//

import XCTest
@testable import Zerro

final class DevDomainDictionaryEnglishGuardTests: XCTestCase {

    // MARK: - Guard 2 — never snap FROM a common word

    func testReportedBug_HereNeverBecomesHero() {
        // The screenshot bug: with "Hero" seeded, "here"/"hear"/"herd" were each
        // snapped to "Hero" at edit distance 1. Guard 2 leaves them verbatim.
        let isCommon: @Sendable (String) -> Bool = { ["here", "hear", "herd"].contains($0) }
        let dict = DevDomainDictionary(terms: ["Hero"], isCommon: isCommon)

        XCTAssertEqual(dict.correctedToken("here"), "here")
        XCTAssertEqual(dict.correctedToken("hear"), "hear")
        XCTAssertEqual(dict.correctedToken("herd"), "herd")
        // And in full text: "here" survives next to ordinary words.
        XCTAssertEqual(dict.corrected("the part above the here"), "the part above the here")
    }

    func testMultiCollisionSentenceRoundTripsUnchanged() {
        // The user's actual sentence, repeated "here" included. Every real word is
        // flagged common, so none is snapped toward any seeded component name.
        let sentence = "this here, I want the hero here to be different, " +
            "and I want it to be blue. The part above the hero."
        let words: Set<String> = [
            "this", "here", "want", "the", "hero", "different",
            "and", "blue", "part", "above",
        ]
        let isCommon: @Sendable (String) -> Bool = { words.contains($0) }
        let dict = DevDomainDictionary(
            terms: ["Hero", "Card", "Page", "Team", "Node", "Next"],
            isCommon: isCommon
        )
        XCTAssertEqual(dict.corrected(sentence), sentence)
    }

    // MARK: - Guard 1 — drop common-word SEED terms

    func testGuard1DropsCommonSeedTerms() {
        let isCommon: @Sendable (String) -> Bool = { ["hero", "card"].contains($0) }
        let dict = DevDomainDictionary(
            terms: ["Hero", "Card", "Supabase", "Vercel"],
            isCommon: isCommon
        )
        let lowered = Set(dict.terms.map { $0.lowercased() })
        XCTAssertTrue(lowered.contains("supabase"))
        XCTAssertTrue(lowered.contains("vercel"))
        XCTAssertFalse(lowered.contains("hero"))
        XCTAssertFalse(lowered.contains("card"))
    }

    func testGuard1AppliesThroughBuild() {
        // The seeding entry point (package.json deps + component basenames) drops
        // common-word component names too.
        let isCommon: @Sendable (String) -> Bool = { ["hero", "card", "page"].contains($0) }
        let dict = DevDomainDictionary.build(
            packageJSON: nil,
            componentFilenames: ["Hero.tsx", "Card.tsx", "Page.tsx", "Navbar.tsx"],
            isCommon: isCommon
        )
        let lowered = Set(dict.terms.map { $0.lowercased() })
        XCTAssertEqual(lowered, ["navbar"])
    }

    // MARK: - Legitimate corrections still fire

    func testGenuineUnusualNamesStillCorrected() {
        // No common words in play → the dictionary does its real job.
        let dict = DevDomainDictionary(
            terms: ["Vercel", "Supabase", "Zustand"],
            isCommon: { _ in false }
        )
        XCTAssertEqual(dict.correctedToken("Versel"), "Vercel")
        XCTAssertEqual(dict.correctedToken("Superbase"), "Supabase")
        XCTAssertEqual(dict.correctedToken("Zoostand"), "Zustand")
    }

    func testExactUnusualComponentNameKept() {
        // An unusual component that survives Guard 1 is matched exactly (any
        // casing), unchanged.
        let dict = DevDomainDictionary(terms: ["Navbar"], isCommon: { _ in false })
        XCTAssertEqual(dict.correctedToken("Navbar"), "Navbar")
        XCTAssertEqual(dict.correctedToken("navbar"), "navbar")
    }

    func testEmptyDictionaryIsNoOpWithGuards() {
        let dict = DevDomainDictionary(terms: [], isCommon: { _ in false })
        XCTAssertTrue(dict.isEmpty)
        XCTAssertEqual(dict.corrected("here note text reach"), "here note text reach")
    }

    // MARK: - Integration smoke (real OS speller — may vary by OS dictionary)

    func testRealSpellCheckerClassifiesCommonVsUnusual() {
        // Not strictly deterministic across OS versions, but the core distinction
        // the feature relies on should hold: everyday words are "common",
        // project names are not.
        XCTAssertTrue(DevDomainDictionary.isCommonEnglishWord("here"))
        XCTAssertTrue(DevDomainDictionary.isCommonEnglishWord("note"))
        XCTAssertFalse(DevDomainDictionary.isCommonEnglishWord("supabase"))
        XCTAssertFalse(DevDomainDictionary.isCommonEnglishWord("zustand"))
    }
}
