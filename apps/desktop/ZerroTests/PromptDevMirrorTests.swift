//
//  PromptDevMirrorTests.swift
//  ZerroTests
//
//  J-01 — byte-identity enforcement for the BYOK copy of the Dev Mode system
//  prompt: the dev twin of PromptV2MirrorTests. The in-repo source of truth is
//  the first fenced block of Scripts/artifact-eval/prompt-dev.md; this test
//  reads it via #filePath and compares character-for-character, so a drifting
//  copy fails the suite instead of relying on "sync by review". The
//  mirror's fence is FOUR backticks — the dev prompt itself contains a
//  three-backtick zerro_anchors block, so extraction splits on ```` lines.
//

import XCTest
@testable import Zerro

final class PromptDevMirrorTests: XCTestCase {

    /// `ZerroTests/PromptDevMirrorTests.swift` → `apps/desktop/` →
    /// `Scripts/artifact-eval/prompt-dev.md` (same repo-relative pattern as
    /// PromptV2MirrorTests).
    private static let mirrorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/artifact-eval/prompt-dev.md")

    func testDevPromptIsByteIdenticalToTheLockedMirror() throws {
        let md = try String(contentsOf: Self.mirrorURL, encoding: .utf8)
        let parts = md.components(separatedBy: "\n````\n")
        XCTAssertGreaterThanOrEqual(
            parts.count, 3,
            "prompt-dev.md has no four-backtick fenced block — mirror format changed?"
        )
        let mirror = parts[1]

        let composed = PromptGenerationSystemPrompt.composed(mode: .dev)
        XCTAssertEqual(composed, PromptGenerationSystemPrompt.devText)
        if composed != mirror {
            // An 8.7k-char assertEquals diff is unreadable — locate the first
            // divergence precisely (same diagnostic as PromptV2MirrorTests).
            let c = Array(composed), m = Array(mirror)
            var i = 0
            while i < min(c.count, m.count) && c[i] == m[i] { i += 1 }
            let context = { (a: [Character]) -> String in
                String(a[max(0, i - 40)..<min(a.count, i + 40)])
            }
            XCTFail(
                "Swift dev prompt drifted from prompt-dev.md at char \(i): "
                    + "composed …\(context(c))… vs mirror …\(context(m))… "
                    + "(lengths \(composed.count) vs \(mirror.count))"
            )
        }
        XCTAssertEqual(composed.count, 8_721, "locked dev prompt length — update alongside an intentional prompt change")
    }
}
