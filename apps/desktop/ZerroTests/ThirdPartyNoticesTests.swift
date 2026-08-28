//
//  ThirdPartyNoticesTests.swift
//  ZerroTests
//
//  The Third-Party Notices loader contract: the app bundle (tests run
//  hosted in Zerro.app, so Bundle.main IS the app) must carry the
//  THIRD_PARTY_NOTICES.md resource naming every embedded dependency, and
//  a bundle without the resource must degrade to nil rather than crash.
//

import XCTest
@testable import Zerro

final class ThirdPartyNoticesTests: XCTestCase {

    func testBundledNoticesLoadFromAppBundle() throws {
        let text = try XCTUnwrap(
            ThirdPartyNotices.load(from: .main),
            "Zerro.app must bundle THIRD_PARTY_NOTICES.md (Copy Bundle Resources)"
        )
        // Every component embedded in or downloaded by the app must be
        // covered. Keep in sync with the root THIRD_PARTY_NOTICES.md.
        for component in ["Sparkle", "KeyboardShortcuts", "PostHog", "whisper.cpp", "OpenAI"] {
            XCTAssertTrue(
                text.contains(component),
                "Bundled notices are missing the \(component) section"
            )
        }
        XCTAssertTrue(
            text.contains("Copyright (c) 2022 OpenAI"),
            "The OpenAI Whisper model license must keep its own copyright line"
        )
    }

    func testMissingResourceReturnsNilInsteadOfCrashing() {
        // The test bundle carries no THIRD_PARTY_NOTICES.md.
        let testBundle = Bundle(for: ThirdPartyNoticesTests.self)
        XCTAssertNil(ThirdPartyNotices.load(from: testBundle))
    }
}
