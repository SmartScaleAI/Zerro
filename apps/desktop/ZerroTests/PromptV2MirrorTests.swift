//
//  PromptV2MirrorTests.swift
//  ZerroTests
//
//  Phase 4 of the typed-output refactor: byte-identity enforcement for the
//  BYOK copy of the locked prompt v2 — the Swift twin of the server's
//  prompt_test.ts. The in-repo source of truth is the first fenced block of
//  Scripts/artifact-eval/prompt-v2.md; this test reads it via #filePath and
//  compares character-for-character, so a drifting copy fails the suite
//  instead of relying on the KEEP IN SYNC comment.
//

import XCTest
@testable import Zerro

final class PromptV2MirrorTests: XCTestCase {

    /// `ZerroTests/PromptV2MirrorTests.swift` → `apps/desktop/` →
    /// `Scripts/artifact-eval/prompt-v2.md` (same repo-relative pattern as
    /// OutputParserTests).
    private static let mirrorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/artifact-eval/prompt-v2.md")

    func testComposedIsByteIdenticalToTheLockedMirror() throws {
        let md = try String(contentsOf: Self.mirrorURL, encoding: .utf8)
        let parts = md.components(separatedBy: "\n```\n")
        XCTAssertGreaterThanOrEqual(parts.count, 3, "prompt-v2.md has no fenced block — mirror format changed?")
        let mirror = parts[1]

        let composed = PromptGenerationSystemPrompt.composed()
        if composed != mirror {
            // A 14k-char assertEquals diff is unreadable — locate the first
            // divergence precisely (same diagnostic as the server test).
            let c = Array(composed), m = Array(mirror)
            var i = 0
            while i < min(c.count, m.count) && c[i] == m[i] { i += 1 }
            let context = { (a: [Character]) -> String in
                String(a[max(0, i - 40)..<min(a.count, i + 40)])
            }
            XCTFail(
                "Swift prompt drifted from prompt-v2.md at char \(i): "
                    + "composed …\(context(c))… vs mirror …\(context(m))… "
                    + "(lengths \(composed.count) vs \(mirror.count))"
            )
        }
        XCTAssertEqual(composed.count, 14_228, "locked v2 length — update alongside an intentional prompt change")
    }

    func testComposedCarriesTheOutputContractNotModes() {
        let p = PromptGenerationSystemPrompt.composed()
        XCTAssertTrue(p.contains("<<<ZERRO_ARTIFACT"))
        XCTAssertTrue(p.contains("<<<END_ZERRO_ARTIFACT>>>"))
        XCTAssertFalse(p.contains("OUTPUT MODE:"), "v1 mode paragraph must be gone")
        XCTAssertFalse(p.contains("goes straight to the clipboard"), "v1 clipboard paragraph must be gone")
    }
}
