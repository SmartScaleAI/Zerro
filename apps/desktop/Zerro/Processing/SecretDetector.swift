//
//  SecretDetector.swift
//  Zerro
//
//  Created by Colin Breeding on 6/6/26.
//
//  Phase 3 — the pure, testable core of secret/PII detection.
//
//  `Redactor` runs one Apple Vision OCR pass per keyframe (Part A) and uses the
//  recognized text twice: it (a) paints opaque boxes over any line that contains
//  a secret and (b) masks that secret in the text it attaches to the payload.
//  THIS file is the single decision point for "is there a secret in this string,
//  and what exactly is it" — kept free of Vision/AVFoundation so it can be
//  unit-tested exhaustively (SecretDetectorTests) with no image, no model.
//
//  Design stance: HIGH PRECISION over recall. A false positive paints a black
//  box over innocent on-screen text and drops it from the OCR the model sees —
//  visibly destructive. A false negative leaks a secret the user probably didn't
//  mean to show, but the frames are already going to a model the user opted into.
//  So every pattern below is anchored on a structurally-distinctive secret
//  format (vendor prefixes, key headers, Luhn-valid card runs) — NOT on loose
//  heuristics like "long random-looking string". The label rule and the card
//  rule are the only value-shaped matches, and both require strong surrounding
//  structure (an explicit `secret:`/`api_key=` label; a digit run that passes
//  Luhn).
//
//  Returned spans are the SECRETS THEMSELVES (the token, the value after a
//  label, the card number) — never the whole line — so the caller's
//  `replacingOccurrences` masks exactly the sensitive substring and leaves the
//  surrounding context ("API key:", "email me at") intact and useful to the model.
//
//  Phase 2b: a future audio-onset anchor is unrelated here; the natural Phase-3
//  extension is OCR-confidence-gated detection (skip low-confidence lines) once
//  we see false-positive rates on real recordings.
//

import Foundation

enum SecretDetector {

    /// Returns every distinct sensitive substring found in `text`, in no
    /// particular order. Empty when nothing matches. The caller (Redactor) uses
    /// each returned span both to locate the OCR observation to box in pixels
    /// and to mask the substring in the attached text — so the two stay in lock
    /// step (we never leak via text what we hid in pixels, or vice-versa).
    nonisolated static func sensitiveSubstrings(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var hits: [String] = []
        var seen = Set<String>()
        func add(_ span: String) {
            // Trim incidental trailing punctuation a regex value-grab can pull in
            // (e.g. a quote or comma after `key="…"`); never trim the secret's own
            // structural chars. Empty/whitespace spans are ignored.
            let trimmed = span.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;)]}> \t"))
            guard trimmed.count >= 4 else { return }
            if seen.insert(trimmed).inserted { hits.append(trimmed) }
        }

        // 1. Structural patterns — match a whole secret by its distinctive shape.
        //    `group` selects which capture is the secret (0 = the whole match;
        //    >0 = a sub-group, used when the match includes a label/keyword we
        //    must NOT redact, only the value after it).
        for rule in Self.patterns {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in rule.regex.matches(in: text, options: [], range: range) {
                let captureIndex = rule.group
                guard captureIndex < match.numberOfRanges else { continue }
                let r = match.range(at: captureIndex)
                guard r.location != NSNotFound else { continue }
                add(ns.substring(with: r))
            }
        }

        // 2. Credit-card numbers: a 13–19 digit run that PASSES Luhn. The Luhn
        //    check is what keeps this high-precision — a long but invalid digit
        //    run (an order id, a phone-number blob, a nonce) is NOT a card and is
        //    left alone. Matched on contiguous digits only; spaced/hyphenated
        //    groupings are deliberately out of scope (low frequency on screen,
        //    and widening the match risks eating innocent numeric tables).
        let ns = text as NSString
        let digitRange = NSRange(location: 0, length: ns.length)
        for match in Self.digitRun.matches(in: text, options: [], range: digitRange) {
            let digits = ns.substring(with: match.range)
            if passesLuhn(digits) { add(digits) }
        }

        return hits
    }

    // MARK: - Luhn

    /// Standard Luhn (mod-10) checksum — PURE (no length opinion). The 13–19
    /// digit card-length bound is applied by the `digitRun` regex at the call
    /// site; this confirms a candidate run actually checksums as a card so
    /// arbitrary long numbers (order ids, nonces) aren't boxed out. Returns
    /// false for any non-digit input or a run too short to checksum.
    nonisolated static func passesLuhn(_ digits: String) -> Bool {
        let nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count == digits.count, nums.count >= 2 else { return false }
        var sum = 0
        var double = false
        for d in nums.reversed() {
            var v = d
            if double {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
            double.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - Patterns

    private struct Pattern {
        let regex: NSRegularExpression
        /// Capture group that holds the secret (0 = whole match).
        let group: Int
    }

    /// Build a case-insensitive-where-noted regex, trapping only on a
    /// programming error (a malformed literal here, never runtime input).
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: options) }
        catch { preconditionFailure("invalid SecretDetector regex: \(pattern) — \(error)") }
    }

    /// The structural secret patterns. Order doesn't matter (results are
    /// de-duped). Each is anchored on a format that effectively never occurs by
    /// accident in normal prose or code.
    private static let patterns: [Pattern] = [
        // OpenAI keys: project keys (`sk-proj-…`) and classic (`sk-…`). The
        // token bodies are long; 20+ chars keeps us off short `sk-` literals.
        Pattern(regex: re(#"sk-proj-[A-Za-z0-9_-]{20,}"#), group: 0),
        Pattern(regex: re(#"sk-[A-Za-z0-9]{20,}"#), group: 0),
        // GitHub: fine-grained PAT (`github_pat_…`) and classic (`ghp_…`, 36 body).
        Pattern(regex: re(#"github_pat_[A-Za-z0-9_]{20,}"#), group: 0),
        Pattern(regex: re(#"gh[pousr]_[A-Za-z0-9]{36,}"#), group: 0),
        // AWS access key id.
        Pattern(regex: re(#"AKIA[0-9A-Z]{16}"#), group: 0),
        // Slack tokens (`xoxb-`, `xoxp-`, `xoxa-`, `xoxr-`, `xoxs-`).
        Pattern(regex: re(#"xox[baprs]-[A-Za-z0-9-]{10,}"#), group: 0),
        // Google API keys.
        Pattern(regex: re(#"AIza[A-Za-z0-9_-]{35}"#), group: 0),
        // A bearer token: redact the TOKEN (group 1), not the word "Bearer".
        Pattern(regex: re(#"Bearer\s+([A-Za-z0-9._~+/=-]{8,})"#), group: 1),
        // JWT (header.payload.signature, all base64url) — starts `eyJ`.
        Pattern(regex: re(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#), group: 0),
        // PEM private-key header line (any key type). The header alone is a
        // strong tell; the body is multi-line and Vision yields it per-line, so
        // boxing the header line is the high-value redaction.
        Pattern(regex: re(#"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#), group: 0),
        // A value following a secret-ish label: `password:`, `api_key=`, etc.
        // Group 2 (the value) is the secret — the label is left intact. Requires
        // a `:`/`=` AND a non-space value, so the BARE word "password" never
        // matches (a key negative case).
        Pattern(
            regex: re(#"(?i)\b(password|passwd|pwd|secret|api[_-]?key)\b\s*[:=]\s*("?[^\s"']{4,}"?)"#),
            group: 2
        ),
        // Email addresses (PII).
        Pattern(regex: re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), group: 0),
    ]

    /// A contiguous 13–19 digit run, word-boundaried so it isn't a slice of a
    /// longer number. Luhn-filtered by the caller.
    private static let digitRun: NSRegularExpression = re(#"\b\d{13,19}\b"#)
}
