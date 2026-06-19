//
//  DevWordTimingTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 2) — word-level transcript timing (§7) and the
//  domain dictionary (§11). The Whisper word-array decode is exercised against a
//  `verbose_json` fixture (no network); the dictionary's near-miss correction is
//  pinned with seeded terms.
//

import XCTest
@testable import Zerro

final class DevWordTimingTests: XCTestCase {

    // MARK: - Word decode

    func testParsesWordLevelTimingFromVerboseJSON() throws {
        // A `verbose_json` body with BOTH segment and word granularity (what
        // `timestamp_granularities[]=word` adds for a Dev Mode recording).
        let json = """
        {
          "text": "Make the Get started button teal.",
          "segments": [
            { "id": 0, "start": 0.0, "end": 1.8, "text": " Make the Get started button teal." }
          ],
          "words": [
            { "word": "Make",    "start": 0.00, "end": 0.20 },
            { "word": "the",     "start": 0.20, "end": 0.32 },
            { "word": "Get",     "start": 0.32, "end": 0.55 },
            { "word": "started", "start": 0.55, "end": 0.90 },
            { "word": "button",  "start": 0.90, "end": 1.25 },
            { "word": "teal",    "start": 1.25, "end": 1.70 }
          ]
        }
        """.data(using: .utf8)!

        let transcript = try OpenAITranscriptionService.parseTranscript(from: json)
        XCTAssertEqual(transcript.words.count, 6)
        XCTAssertEqual(transcript.words.first, WordTiming(word: "Make", start: 0.0, end: 0.20))
        XCTAssertEqual(transcript.words.last, WordTiming(word: "teal", start: 1.25, end: 1.70))
        // Per-word start/end are monotonic and within the segment.
        for k in 1..<transcript.words.count {
            XCTAssertGreaterThanOrEqual(transcript.words[k].start, transcript.words[k - 1].start)
        }
        // Segment-level parse unchanged (normal-mode shape still holds).
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments.first?.text, "Make the Get started button teal.")
    }

    func testNoWordsArrayYieldsEmptyWords() throws {
        // A normal-mode body (segment granularity only) → empty words, unchanged.
        let json = """
        { "text": "hello", "segments": [ { "id": 0, "start": 0, "end": 1, "text": " hello" } ] }
        """.data(using: .utf8)!
        let transcript = try OpenAITranscriptionService.parseTranscript(from: json)
        XCTAssertTrue(transcript.words.isEmpty)
        XCTAssertEqual(transcript.fullText, "hello")
    }

    // MARK: - Domain dictionary

    func testDictionarySnapsNearMissTermsToCanonical() {
        let dict = DevDomainDictionary(terms: ["Vercel", "Supabase", "Tailwind", "Zustand"])
        // Mangled library names snap back; ordinary words + punctuation survive.
        XCTAssertEqual(
            dict.corrected("I deployed to Versel using Superbase, Tailwynd, and Zustund."),
            "I deployed to Vercel using Supabase, Tailwind, and Zustand."
        )
    }

    func testDictionaryLeavesCorrectAndUnrelatedTokens() {
        let dict = DevDomainDictionary(terms: ["Supabase", "Vercel"])
        // Exact (any-casing) matches and unrelated words are untouched — no
        // false positives on ordinary prose.
        XCTAssertEqual(
            dict.corrected("the build was based on supabase and shipped"),
            "the build was based on supabase and shipped"
        )
    }

    func testDictionaryCorrectsWordTimingsInTranscript() {
        let dict = DevDomainDictionary(terms: ["Vercel"])
        let t = Transcript(
            segments: [TranscriptSegment(start: 0, end: 1, text: "deploy to Versel")],
            fullText: "deploy to Versel",
            words: [
                WordTiming(word: "deploy", start: 0.0, end: 0.3),
                WordTiming(word: "to", start: 0.3, end: 0.4),
                WordTiming(word: "Versel", start: 0.4, end: 0.8),
            ]
        )
        let c = dict.corrected(t)
        XCTAssertEqual(c.fullText, "deploy to Vercel")
        XCTAssertEqual(c.segments.first?.text, "deploy to Vercel")
        // The spelling is snapped; the timing is preserved exactly.
        XCTAssertEqual(c.words.last, WordTiming(word: "Vercel", start: 0.4, end: 0.8))
    }

    func testDictionarySeedsFromPackageJSONAndComponents() {
        let pkg = """
        {
          "dependencies": { "vercel": "^1", "@supabase/supabase-js": "^2" },
          "devDependencies": { "tailwindcss": "^3" }
        }
        """.data(using: .utf8)!
        let dict = DevDomainDictionary.build(packageJSON: pkg, componentFilenames: ["Navbar.tsx", "PricingCard.tsx"])
        // Scope-stripped dep names + component basenames are all canonical terms.
        XCTAssertTrue(dict.terms.contains("vercel"))
        XCTAssertTrue(dict.terms.contains("supabase-js"))
        XCTAssertTrue(dict.terms.contains("tailwindcss"))
        XCTAssertTrue(dict.terms.contains("Navbar"))
        // And it actually corrects against the seeded set.
        XCTAssertEqual(dict.corrected("deployed to Versel"), "deployed to vercel")
    }

    func testEmptyDictionaryIsNoOp() {
        let dict = DevDomainDictionary(terms: ["ts", "go"]) // both < 4 chars → dropped
        XCTAssertTrue(dict.isEmpty)
        XCTAssertEqual(dict.corrected("ts and go and Versel"), "ts and go and Versel")
    }
}
