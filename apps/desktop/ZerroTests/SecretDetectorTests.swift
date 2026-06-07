//
//  SecretDetectorTests.swift
//  ZerroTests
//
//  Phase 3 — the safety net for the pure secret/PII detector.
//
//  SecretDetector decides what Redactor boxes out of a frame's pixels and masks
//  in the OCR text. It's the precision/recall surface of redaction, so it's
//  tested exhaustively here with synthetic strings (no Vision, no image): every
//  format we claim to catch, and — just as important — the look-alikes we must
//  NOT catch (a black box over innocent text is destructive). It also asserts
//  the returned spans are the SECRETS themselves, not the whole line.
//

import XCTest
@testable import Zerro

final class SecretDetectorTests: XCTestCase {

    private func hits(_ s: String) -> [String] {
        SecretDetector.sensitiveSubstrings(in: s)
    }

    /// Asserts at least one returned span CONTAINS the expected secret. When the
    /// line carries surrounding context (it's longer than the secret), also
    /// asserts no span is the whole line — that's the precision guarantee (we
    /// mask the secret, not the surrounding prose). A line that IS exactly a
    /// secret (e.g. a PEM header on its own line) legitimately returns itself.
    private func assertCatches(_ line: String, _ secret: String,
                               file: StaticString = #filePath, line ln: UInt = #line) {
        let result = hits(line)
        XCTAssertTrue(
            result.contains(where: { $0.contains(secret) }),
            "expected to catch \(secret) in \(line); got \(result)", file: file, line: ln)
        if line.count > secret.count {
            XCTAssertFalse(
                result.contains(line),
                "span should be the secret, not the whole line: \(result)", file: file, line: ln)
        }
    }

    private func assertIgnores(_ line: String, file: StaticString = #filePath, line ln: UInt = #line) {
        XCTAssertEqual(hits(line), [], "expected no secrets in: \(line)", file: file, line: ln)
    }

    // MARK: - Positives

    func testOpenAIKeys() {
        assertCatches("export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123", "sk-abcdefghijklmnopqrstuvwxyz0123")
        assertCatches("key: sk-proj-AbCd1234EfGh5678IjKl90MnOpQrSt", "sk-proj-AbCd1234EfGh5678IjKl90MnOpQrSt")
    }

    func testGitHubTokens() {
        assertCatches("token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        assertCatches("github_pat_11ABCDE0000aBcDeFgHiJ_KLMNOPqrstuvwx", "github_pat_11ABCDE0000aBcDeFgHiJ_KLMNOPqrstuvwx")
    }

    func testAWSAccessKey() {
        assertCatches("AWS_ACCESS_KEY_ID AKIAABCDEFGHIJKLMNOP", "AKIAABCDEFGHIJKLMNOP")
    }

    func testSlackToken() {
        assertCatches("slack xoxb-123456789012-abcdEFGHijklMNOP", "xoxb-123456789012-abcdEFGHijklMNOP")
    }

    func testGoogleAPIKey() {
        assertCatches("AIzaSyA1234567890abcdefghijklmnopqrstuv", "AIzaSyA1234567890abcdefghijklmnopqrstuv")
    }

    func testBearerToken() {
        // The TOKEN is the secret — not the word "Bearer".
        let result = hits("Authorization: Bearer abcDEF1234567890xyz")
        XCTAssertTrue(result.contains("abcDEF1234567890xyz"), "got \(result)")
        XCTAssertFalse(result.contains(where: { $0 == "Bearer" }))
    }

    func testJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        assertCatches("token=\(jwt)", jwt)
    }

    func testPrivateKeyHeader() {
        assertCatches("-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----")
        assertCatches("-----BEGIN PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----")
    }

    func testLabeledSecretValue() {
        // The VALUE is the secret; the label ("password:") is left intact.
        let result = hits("password: hunter2supersecret")
        XCTAssertTrue(result.contains("hunter2supersecret"), "got \(result)")
        XCTAssertFalse(result.contains(where: { $0.lowercased().contains("password") }), "label leaked: \(result)")

        assertCatches("api_key = topSecretValue123", "topSecretValue123")
        assertCatches("API-KEY: anotherSecretValue", "anotherSecretValue")
    }

    func testEmail() {
        assertCatches("contact alice.smith@example.com for access", "alice.smith@example.com")
    }

    func testTruncatedEmail() {
        // A UI-elided address whose TLD is cut off (the real-world leak) — the
        // full-email rule can't fire, the truncated-email rule must.
        assertCatches("Owner colin@smartaiscaling.c... edit", "colin@smartaiscaling.c...")
        // Ellipsis directly after the domain (no dot), `...` and `…` forms.
        assertCatches("from name@domain... here", "name@domain...")
        assertCatches("from name@domain… here", "name@domain…")
        // The FULL address still matches even when a truncated one is also nearby.
        assertCatches("name@domain.com and name@domain.c...", "name@domain.com")
    }

    func testLuhnValidCard() {
        // 4242 4242 4242 4242 is the canonical Luhn-valid test card.
        assertCatches("card 4242424242424242 on file", "4242424242424242")
    }

    // MARK: - Negatives (must NOT match — false positives are destructive)

    func testIgnoresPlainProse() {
        assertIgnores("The quick brown fox jumps over the lazy dog, then rests.")
    }

    func testIgnoresNormalCode() {
        assertIgnores("let total = items.reduce(0) { $0 + $1.count } // sum")
    }

    func testIgnoresBareWordPassword() {
        // No `:`/`=` + value → the LABEL rule must not fire on the word alone.
        assertIgnores("I forgot my password again and had to reset it")
    }

    func testIgnoresNonLuhnDigitRun() {
        // 16 digits but fails the Luhn checksum → not a card.
        XCTAssertFalse(SecretDetector.passesLuhn("4242424242424241"))
        assertIgnores("order number 4242424242424241 shipped today")
    }

    func testIgnoresShortSkPrefix() {
        // `sk-` with a short tail isn't an OpenAI key.
        assertIgnores("the sk-12 abbreviation means something else")
    }

    func testIgnoresEmailLookAlikes() {
        // A bare `@handle` mention (no local part) is not an email — even elided.
        assertIgnores("mention @handle in the thread")
        assertIgnores("ping @handle... later")
        // Too-short `local@domain` with no real TLD is not an email.
        assertIgnores("see a@b for details")
        // An ellipsis with a 1-char domain head must not trip the truncated rule.
        assertIgnores("wait a@b... really")
        // Ordinary prose with an ellipsis stays untouched.
        assertIgnores("and so it goes on... and on")
    }

    // MARK: - Luhn helper

    func testLuhn() {
        XCTAssertTrue(SecretDetector.passesLuhn("4242424242424242"))
        XCTAssertTrue(SecretDetector.passesLuhn("79927398713")) // classic Luhn example
        XCTAssertFalse(SecretDetector.passesLuhn("4242424242424241"))
        XCTAssertFalse(SecretDetector.passesLuhn("123")) // too short to be a card
        XCTAssertFalse(SecretDetector.passesLuhn("abcd")) // non-digits
    }

    // MARK: - Aggregate shape

    func testMultipleSecretsOneLineAndDedup() {
        let result = hits("user alice@example.com key sk-abcdefghijklmnopqrstuvwxyz0123 and alice@example.com again")
        XCTAssertTrue(result.contains("alice@example.com"))
        XCTAssertTrue(result.contains("sk-abcdefghijklmnopqrstuvwxyz0123"))
        // de-duped: the repeated email appears once.
        XCTAssertEqual(result.filter { $0 == "alice@example.com" }.count, 1)
    }

    func testEmptyStringIsEmpty() {
        XCTAssertEqual(hits(""), [])
    }
}
