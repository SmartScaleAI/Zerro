//
//  ConvertPromptMirrorTests.swift
//  ZerroTests
//
//  Phase 6 of the typed-artifact refactor: byte-identity enforcement for the
//  BYOK copy of the locked conversion prompt v1 — the Swift twin of the
//  server's convert/prompt_test.ts. The in-repo source of truth is the first
//  fenced block of Scripts/artifact-eval/convert-prompt-v1.md; this test
//  reads it via #filePath and compares character-for-character, so a
//  drifting copy fails the suite instead of relying on the KEEP IN SYNC
//  comment. Same pattern as PromptV2MirrorTests.
//

import XCTest
@testable import Zerro

final class ConvertPromptMirrorTests: XCTestCase {

    /// `ZerroTests/ConvertPromptMirrorTests.swift` → `apps/desktop/` →
    /// `Scripts/artifact-eval/convert-prompt-v1.md`.
    private static let mirrorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/artifact-eval/convert-prompt-v1.md")

    func testComposedIsByteIdenticalToTheLockedMirror() throws {
        let md = try String(contentsOf: Self.mirrorURL, encoding: .utf8)
        let parts = md.components(separatedBy: "\n```\n")
        XCTAssertGreaterThanOrEqual(parts.count, 3, "convert-prompt-v1.md has no fenced block — mirror format changed?")
        let mirror = parts[1]

        let composed = ConversionSystemPrompt.composed()
        if composed != mirror {
            let c = Array(composed), m = Array(mirror)
            var i = 0
            while i < min(c.count, m.count) && c[i] == m[i] { i += 1 }
            let context = { (a: [Character]) -> String in
                String(a[max(0, i - 40)..<min(a.count, i + 40)])
            }
            XCTFail(
                "Swift conversion prompt drifted from convert-prompt-v1.md at char \(i): "
                    + "composed …\(context(c))… vs mirror …\(context(m))… "
                    + "(lengths \(composed.count) vs \(mirror.count))"
            )
        }
        XCTAssertEqual(composed.count, 3_413, "locked v1 length — update alongside an intentional prompt change")
    }

    func testComposedCarriesTheBlockOnlyAgentPromptContract() {
        let p = ConversionSystemPrompt.composed()
        XCTAssertTrue(p.contains("<<<ZERRO_ARTIFACT type=\"agent_prompt\""))
        XCTAssertTrue(p.contains("<<<END_ZERRO_ARTIFACT>>>"))
        XCTAssertTrue(p.contains("The phrase \"the user\" must not appear"), "voice ban carried over from v2")
        XCTAssertTrue(p.contains("output ONLY the artifact block"), "block-only output contract present")
    }
}
