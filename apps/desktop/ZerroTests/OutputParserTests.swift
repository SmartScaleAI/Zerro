//
//  OutputParserTests.swift
//  ZerroTests
//
//  Phase 2 of the modes → typed-artifact refactor. Two layers:
//
//  1. The shared contract suite: `Scripts/artifact-eval/parser-tests.json`
//     is the §2 contract's executable spec — 41 cases (strict + recovery
//     tier, including the 10 real model outputs that motivated the tier),
//     shared verbatim with the JS reference parser in
//     `Scripts/eval-models.mjs` (run there via `--parser-tests`). This test
//     loads the SAME file from the repo (no hand-copied cases), so the two
//     implementations cannot drift without one of them failing.
//  2. Swift-specific cases on top: unicode handling, CRLF×recovery combos,
//     and boundary conditions around the title cap — things that exercise
//     Swift string semantics (grapheme clusters) rather than contract rules.
//

import XCTest
@testable import Zerro

final class OutputParserTests: XCTestCase {

    // MARK: - Shared contract suite (parser-tests.json)

    /// One case of the shared spec. `expect` fields are all optional —
    /// absent means "not asserted", matching the JS runner's semantics.
    private struct SpecCase: Decodable {
        let name: String
        let tier: String
        let input: String
        let expect: Expect

        struct Expect: Decodable {
            let valid: Bool?
            let recovered: Bool?
            let hasArtifact: Bool?
            let type: String?
            let rawType: String?
            let title: String?
            let bodyStartsWith: String?
            let bodyEndsWith: String?
            let bodyContains: String?
            let chatTextContains: String?
            let chatTextNotContains: String?
            let warningsContain: String?
            let requestPresent: Bool?
        }
    }

    /// `ZerroTests/OutputParserTests.swift` → `apps/desktop/` →
    /// `Scripts/artifact-eval/parser-tests.json`. Loading the repo file via
    /// `#filePath` (the project's pattern for repo-relative test inputs)
    /// keeps the JSON the single executable spec for both implementations.
    private static let specURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ZerroTests/
        .deletingLastPathComponent() // apps/desktop/
        .appendingPathComponent("Scripts/artifact-eval/parser-tests.json")

    func testSharedContractSuite() throws {
        let data = try Data(contentsOf: Self.specURL)
        let cases = try JSONDecoder().decode([SpecCase].self, from: data)
        XCTAssertGreaterThanOrEqual(cases.count, 41, "shared spec shrank — was a case deleted?")

        for c in cases {
            let label = "[\(c.tier)] \(c.name)"
            let got = OutputParser.parse(c.input)
            let e = c.expect

            if let valid = e.valid {
                XCTAssertEqual(got.isValid, valid, "\(label): valid")
            }
            if let recovered = e.recovered {
                XCTAssertEqual(got.wasRecovered, recovered, "\(label): recovered")
            }
            if let hasArtifact = e.hasArtifact {
                XCTAssertEqual(got.artifact != nil, hasArtifact, "\(label): hasArtifact")
            }
            if let type = e.type {
                XCTAssertEqual(got.artifact?.type.rawValue, type, "\(label): type")
            }
            if let rawType = e.rawType {
                XCTAssertEqual(got.artifact?.rawType, rawType, "\(label): rawType")
            }
            if let title = e.title {
                XCTAssertEqual(got.artifact?.title, title, "\(label): title")
            }
            if let prefix = e.bodyStartsWith {
                XCTAssertTrue(got.artifact?.body.hasPrefix(prefix) ?? false, "\(label): body should start with \(prefix)")
            }
            if let suffix = e.bodyEndsWith {
                XCTAssertTrue(got.artifact?.body.hasSuffix(suffix) ?? false, "\(label): body should end with \(suffix)")
            }
            if let contains = e.bodyContains {
                XCTAssertTrue(got.artifact?.body.contains(contains) ?? false, "\(label): body should contain \(contains)")
            }
            if let chat = e.chatTextContains {
                XCTAssertTrue(got.chatText.contains(chat), "\(label): chatText should contain \(chat)")
            }
            if let absent = e.chatTextNotContains {
                XCTAssertFalse(got.chatText.contains(absent), "\(label): chatText must not contain \(absent)")
            }
            if let warning = e.warningsContain {
                XCTAssertTrue(got.warnings.contains { $0.contains(warning) }, "\(label): warnings should mention \(warning) — got \(got.warnings)")
            }
            if let requestPresent = e.requestPresent {
                XCTAssertEqual(got.requestPresent, requestPresent, "\(label): requestPresent")
            }
        }
    }

    // MARK: - Swift-specific: no-request sentinel

    /// The empty-case sentinel flips `requestPresent` off, is stripped from the
    /// rendered chat text, and never invalidates the response (the chat line is
    /// still shown). The shared suite asserts the flag; this Swift-only case
    /// proves the literal marker does not leak into the UI text (no shared
    /// "chatText omits" assertion exists, so it lives here).
    func testNoRequestSentinelStrippedFromChatText() {
        let raw = """
        I didn't catch a request in this recording — record again and say what you need.
        <<<ZERRO_NO_REQUEST>>>
        """
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.isValid)
        XCTAssertNil(got.artifact)
        XCTAssertFalse(got.requestPresent)
        XCTAssertFalse(got.chatText.contains("ZERRO_NO_REQUEST"), "sentinel must be stripped from chat text")
        XCTAssertTrue(got.chatText.contains("didn't catch a request"))
    }

    /// Hardening: the marker still gates and is stripped even when the model
    /// emits it inline (not alone on its line). Detection and stripping are
    /// substring-based, so the raw token never leaks into the visible text and
    /// the surrounding sentence survives intact.
    func testNoRequestSentinelInlineIsStrippedAndGates() {
        let raw = "I didn't catch a request in this recording — record again and say what you need. <<<ZERRO_NO_REQUEST>>>"
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.isValid)
        XCTAssertNil(got.artifact)
        XCTAssertFalse(got.requestPresent)
        XCTAssertFalse(got.chatText.contains("ZERRO_NO_REQUEST"), "inline sentinel must be stripped from chat text")
        XCTAssertTrue(got.chatText.contains("record again and say what you need."))
    }

    /// requestPresent stays true for an ordinary artifact-less reply (the
    /// category-2 explain/advice case).
    func testRequestPresentDefaultsTrueWithoutSentinel() {
        let got = OutputParser.parse("Here's why that build fails — the cache key is stale.")
        XCTAssertTrue(got.isValid)
        XCTAssertNil(got.artifact)
        XCTAssertTrue(got.requestPresent)
    }

    // MARK: - Swift-specific: unicode

    func testUnicodeTitleBodyAndChatParse() {
        let raw = """
        Très bien — the café page renders 日本語 correctly, you can ship it. 🚀

        <<<ZERRO_ARTIFACT type="message" title="Déploiement — 出荷 ✅">>>
        Salut l'équipe — le café ☕️ est prêt. 出荷します。
        <<<END_ZERRO_ARTIFACT>>>
        """
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.isValid)
        XCTAssertFalse(got.wasRecovered)
        XCTAssertEqual(got.artifact?.type, .message)
        XCTAssertEqual(got.artifact?.title, "Déploiement — 出荷 ✅")
        XCTAssertTrue(got.chatText.contains("🚀"))
        XCTAssertEqual(got.artifact?.body, "Salut l'équipe — le café ☕️ est prêt. 出荷します。")
    }

    /// Title length is counted in Characters (grapheme clusters): 80 emoji
    /// are 80 characters — at the cap, not over it — even though they are
    /// far more than 80 UTF-8 bytes or UTF-16 code units.
    ///
    /// Known, immaterial divergence from the JS reference: JS `.length`
    /// counts UTF-16 units, so it would warn on 80 non-BMP emoji. The
    /// shared spec only exercises ASCII titles (where both agree), and the
    /// warning is advisory — it never affects validity or parsing.
    func testTitleCapCountsGraphemes() {
        let exactly80 = String(repeating: "🦊", count: 80)
        let atCap = OutputParser.parse(
            "chat\n<<<ZERRO_ARTIFACT type=\"generic\" title=\"\(exactly80)\">>>\nbody\n<<<END_ZERRO_ARTIFACT>>>"
        )
        XCTAssertTrue(atCap.isValid)
        XCTAssertFalse(atCap.warnings.contains { $0.contains("80") }, "80 graphemes is AT the cap, not over")

        let over = OutputParser.parse(
            "chat\n<<<ZERRO_ARTIFACT type=\"generic\" title=\"\(exactly80)🦊\">>>\nbody\n<<<END_ZERRO_ARTIFACT>>>"
        )
        XCTAssertTrue(over.isValid, "over-long title warns but stays valid")
        XCTAssertTrue(over.warnings.contains { $0.contains("80") })
    }

    // MARK: - Swift-specific: CRLF × recovery tier

    /// CRLF line endings combined with an R1 chevron slip — both quirks at
    /// once must still recover (the JSON spec covers each separately).
    func testCRLFWithRecoveryTier() {
        let raw = "chat line\r\n<<<ZERRO_ARTIFACT type=\"snippet\" title=\"T\">\r\nls -la\r\n<<<END_ZERRO_ARTIFACT>>>\r\n"
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.isValid)
        XCTAssertTrue(got.wasRecovered)
        XCTAssertEqual(got.artifact?.type, .snippet)
        XCTAssertEqual(got.artifact?.body, "ls -la")
        XCTAssertEqual(got.chatText, "chat line")
    }

    // MARK: - Swift-specific: boundary conditions

    /// A fenced ``` code block in the chat text whose CONTENT carries no
    /// ZERRO tokens is plain chat — the parser keys on its own delimiters,
    /// not markdown structure. (The JSON spec covers the hostile variant
    /// where a ZERRO token hides inside a code block.)
    func testMarkdownCodeBlockInChatTextIsHarmless() {
        let raw = """
        Use this pattern:

        ```swift
        let x = foo(<<<not_a_fence>>>)
        ```

        <<<ZERRO_ARTIFACT type="snippet" title="The fix">>>
        let x = foo(bar)
        <<<END_ZERRO_ARTIFACT>>>
        """
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.isValid)
        XCTAssertEqual(got.artifact?.type, .snippet)
        XCTAssertTrue(got.chatText.contains("```swift"))
    }

    /// Whitespace-only input is valid chat-only with empty chat text — the
    /// degenerate floor of the fail-safe guarantee (never crash).
    func testWhitespaceOnlyInput() {
        let got = OutputParser.parse("  \n\t\n  ")
        XCTAssertTrue(got.isValid)
        XCTAssertNil(got.artifact)
        XCTAssertEqual(got.chatText, "")
    }

    /// The R3 prefix keeps interior indentation when it carries content —
    /// a glued close fence after an indented last line preserves the indent
    /// relative to the body's interior (leading trim applies to the whole
    /// body, not per-line).
    func testR3PreservesInteriorIndentation() {
        let raw = "chat\n<<<ZERRO_ARTIFACT type=\"snippet\" title=\"T\">>>\nfunc f() {\n    return 1\n}<<<END_ZERRO_ARTIFACT>>>"
        let got = OutputParser.parse(raw)
        XCTAssertTrue(got.wasRecovered)
        XCTAssertEqual(got.artifact?.body, "func f() {\n    return 1\n}")
    }
}
