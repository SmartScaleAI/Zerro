//
//  OutputParser.swift
//  Zerro
//
//  Created by Colin Breeding on 6/11/26.
//
//  Phase 2 of the modes → typed-artifact refactor: the client-side parser
//  for the §2 output contract, INCLUDING the three-rule recovery tier
//  (§2 amendment, 2026-06-11).
//  ADDITIVE in this phase — nothing calls it yet; Phase 4 runs it on every
//  generation result.
//
//  KEEP IN SYNC: the JS reference implementation is `parseArtifactResponse`
//  in `apps/desktop/Scripts/eval-models.mjs`. Both implementations must pass
//  every case in `apps/desktop/Scripts/artifact-eval/parser-tests.json` —
//  that file is the contract's executable spec (OutputParserTests loads it
//  directly). A behavior change here requires changing the JSON, the JS
//  reference, and plan §2 together, or not at all.
//
//  Fail-safe philosophy (§2): a malformed response must always degrade to
//  plain chat text. This parser never throws, never returns an unrenderable
//  result, and never invents an artifact — the recovery tier is a CLOSED
//  list of three rules, each still requiring the literal ZERRO tokens and
//  parseable attributes.
//

import Foundation

/// Pure, stateless parser for the §2 typed-artifact response contract.
/// `nonisolated` string work only — safe to call from any context.
enum OutputParser {

    // MARK: Contract tokens

    /// Known wire types; anything else coerces to `.generic` with a warning.
    private nonisolated static let openPrefix = "<<<ZERRO_ARTIFACT"
    private nonisolated static let closeFence = "<<<END_ZERRO_ARTIFACT>>>"
    /// The close token without its chevron tail — a line containing this but
    /// not ending with the full close fence is an unrecoverable malformation.
    private nonisolated static let closeToken = "<<<END_ZERRO_ARTIFACT"

    /// Empty-case sentinel the generation step emits (on its own line) when
    /// the recording held no request of any kind. It is NOT a fence: it never
    /// produces or invalidates an artifact — it only flips `requestPresent`
    /// off (the chat line is still shown). Stripped from chat text so it never
    /// reaches the UI.
    private nonisolated static let noRequestSentinel = "<<<ZERRO_NO_REQUEST>>>"

    /// Strict open fence: `<<<ZERRO_ARTIFACT type="…" title="…">>>`, alone
    /// on its line (trailing whitespace tolerated), exactly three chevrons.
    private nonisolated static let strictOpen =
        /^<<<ZERRO_ARTIFACT\s+type="([^"]*)"\s+title="([^"]*)"\s*>>>$/

    /// Recovery open fence (R1/R2): same anchor and attributes, but ≥ 1
    /// trailing chevron (R1), optionally followed by spilled body text (R2).
    private nonisolated static let recoveryOpen =
        /^<<<ZERRO_ARTIFACT\s+type="([^"]*)"\s+title="([^"]*)"\s*(>+)(.*)$/

    /// Defense-in-depth scrubber tokens (handoff-artifact-fence-leak). When a
    /// response degrades to the chat-only fallback (e.g. a generation truncated
    /// by the output-token limit leaves one open fence and no close), the raw
    /// wire delimiter must NEVER be shown verbatim in the pill. These match the
    /// open fence (with its attrs + any chevron run, R1/R2 tolerant) and the
    /// close fence so they can be stripped from the fallback text while keeping
    /// any real spillover content on the same line. The straggler regex catches
    /// a malformed open token whose attrs didn't parse. KEEP IN SYNC with the
    /// `scrubFenceTokens` mirror in `eval-models.mjs`.
    private nonisolated static let openFenceToken =
        /<<<ZERRO_ARTIFACT\s+type="[^"]*"\s+title="[^"]*"\s*>+/
    /// J-05: `[^>\n]*` stops at the first chevron and `(?:>+|$)` then consumes
    /// the closing chevron run — a malformed-but-chevron'd token is removed
    /// WITHOUT eating the real content after its `>>>`; a chevron-less
    /// truncated token still matches to end of line via the `$` alternative.
    private nonisolated static let openFenceStraggler = /<<<ZERRO_ARTIFACT[^>\n]*(?:>+|$)/
    private nonisolated static let closeFenceToken = /<<<END_ZERRO_ARTIFACT>*/

    /// Contract cap on the model-written title; over-length warns only.
    private nonisolated static let maxTitleLength = 80

    // MARK: Parse

    /// Parses a raw model response per §2. Never throws; on any malformation
    /// outside the recovery tier the ENTIRE raw output becomes `chatText`
    /// with no artifact and `isValid == false`.
    nonisolated static func parse(_ raw: String) -> Output {
        var warnings: [String] = []
        // CRLF-normalize then split — equivalent to the JS reference's
        // split(/\r?\n/): \r\n and \n both break lines, a lone \r does not.
        let rawLines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Empty-case sentinel: the generation step emits `<<<ZERRO_NO_REQUEST>>>`
        // (contractually alone on its own line) when there was no request.
        // Record its presence, then strip it BEFORE classification/assembly so
        // it never leaks into chat text. (It is not a fence, so it would
        // otherwise pass through untouched into the chat-only fallback.)
        // Detection and stripping are substring-based, not own-line equality:
        // a model that emits the marker inline ("…say what you need.
        // <<<ZERRO_NO_REQUEST>>>") still gates AND has the raw token removed
        // from the visible text. A line that is ONLY the sentinel disappears
        // entirely (the contract shape); an inline one keeps its surrounding
        // text.
        let requestPresent = !rawLines.contains { $0.contains(noRequestSentinel) }
        let lines: [String] = rawLines.compactMap { line in
            guard line.contains(noRequestSentinel) else { return line }
            let stripped = line.replacingOccurrences(of: noRequestSentinel, with: "")
            return stripped.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stripped
        }

        // One pass to classify fence candidates. Opens must sit at column 0;
        // an open token anywhere else is unrecoverable. Closes are strict
        // (alone on the line) or R3 (line ENDS with the exact close fence);
        // a close token not at end of line is unrecoverable.
        var opens: [Int] = []
        var closes: [(index: Int, strict: Bool, prefix: String)] = []
        var sawMidlineFence = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix(openPrefix) {
                opens.append(i)
            } else if line.contains(openPrefix) {
                sawMidlineFence = true
            }
            let trimmed = line.trimmingTrailingWhitespace()
            if trimmed == closeFence && line.hasPrefix(closeFence) {
                closes.append((i, true, ""))
            } else if trimmed.hasSuffix(closeFence) {
                closes.append((i, false, String(trimmed.dropLast(closeFence.count))))
            } else if line.contains(closeToken) {
                sawMidlineFence = true
            }
        }

        func chatOnly(valid: Bool) -> Output {
            // Built from the sentinel-stripped lines (not `raw`) so the empty-
            // case marker never reaches the UI. Equivalent to the old
            // `raw.trimmed` for every sentinel-free input. Fence tokens are
            // scrubbed as a safety net so a malformed/truncated response (one
            // open fence, no close) can never show the raw `<<<ZERRO_ARTIFACT`
            // wire syntax — a no-op on a genuinely fence-free chat reply.
            Output(
                chatText: Self.scrubFenceTokens(from: lines.joined(separator: "\n"))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                artifact: nil,
                isValid: valid,
                wasRecovered: false,
                warnings: warnings,
                requestPresent: requestPresent
            )
        }

        if opens.isEmpty && closes.isEmpty && !sawMidlineFence {
            return chatOnly(valid: true)
        }
        if sawMidlineFence {
            warnings.append("fence delimiter not alone at line start")
            return chatOnly(valid: false)
        }
        guard opens.count == 1, closes.count == 1 else {
            warnings.append("expected exactly one artifact block: \(opens.count) open / \(closes.count) close fences")
            return chatOnly(valid: false)
        }
        let open = opens[0]
        let close = closes[0]
        guard close.index > open else {
            warnings.append("close fence does not follow the open fence")
            return chatOnly(valid: false)
        }

        // Open fence: strict first, then the R1/R2 recovery shape.
        let openLine = lines[open].trimmingTrailingWhitespace()
        let rawType: String
        let title: String
        var spill = ""
        var openStrict = true
        if let m = openLine.wholeMatch(of: strictOpen) {
            rawType = String(m.1)
            title = String(m.2)
        } else if let m = openLine.wholeMatch(of: recoveryOpen) {
            openStrict = false
            rawType = String(m.1)
            title = String(m.2)
            spill = String(m.4).trimmingCharacters(in: .whitespaces)
            warnings.append(spill.isEmpty
                ? "recovered (R1): open fence ended \"\(m.3)\" instead of \">>>\""
                : "recovered (R2): open fence with body spillover (\"\(m.3)\" + text)")
        } else {
            warnings.append("unparseable open fence: \(lines[open].trimmingCharacters(in: .whitespaces).prefix(120))")
            return chatOnly(valid: false)
        }
        if !close.strict {
            warnings.append("recovered (R3): close fence at end of last body line")
        }
        let recovered = !openStrict || !close.strict

        let type: ArtifactType
        if let known = ArtifactType(rawValue: rawType) {
            type = known
        } else {
            warnings.append("unknown type \"\(rawType)\" coerced to generic")
            type = .generic
        }
        if title.count > maxTitleLength {
            warnings.append("title is \(title.count) chars (contract caps at \(maxTitleLength))")
        }

        let chatText = lines[..<open].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyLines = Array(lines[(open + 1)..<close.index])
        if !close.prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.append(close.prefix)
        }
        if !spill.isEmpty {
            bodyLines.insert(spill, at: 0)
        }
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = lines[(close.index + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if chatText.isEmpty { warnings.append("no chat text before the artifact block") }
        if body.isEmpty { warnings.append("empty artifact body") }
        if !trailing.isEmpty { warnings.append("text after the close fence (contract: chat first, artifact last)") }

        return Output(
            chatText: chatText,
            artifact: Artifact(type: type, rawType: rawType, title: title, body: body),
            isValid: true,
            wasRecovered: recovered,
            warnings: warnings,
            requestPresent: requestPresent
        )
    }

    // MARK: Fence-token scrub (defense in depth)

    /// Removes any raw artifact wire delimiter from chat-only fallback text so
    /// a malformed or truncated response never surfaces `<<<ZERRO_ARTIFACT …>>>`
    /// / `<<<END_ZERRO_ARTIFACT>>>` verbatim in the pill. Operates per line: a
    /// line that is purely a fence token is dropped; a line where a fence token
    /// was glued to real content keeps the content (e.g. a truncated open fence
    /// with body spillover on the same line). A line with no fence material is
    /// returned untouched, so this is a no-op on an ordinary chat reply. KEEP IN
    /// SYNC with `scrubFenceTokens` in `eval-models.mjs`.
    private nonisolated static func scrubFenceTokens(from text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let scrubbed = line
                .replacing(openFenceToken, with: "")
                .replacing(openFenceStraggler, with: "")
                .replacing(closeFenceToken, with: "")
            if scrubbed == line {
                out.append(line) // no fence material — keep verbatim (incl. blanks)
            } else if !scrubbed.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(scrubbed) // token glued to real content — keep the content
            }
            // else: the line was a pure fence token — drop it entirely.
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Trailing-whitespace trim

private extension String {
    /// JS `String.trimEnd()` equivalent — strips trailing whitespace only,
    /// leaving indentation intact (the R3 prefix keeps its leading spaces).
    nonisolated func trimmingTrailingWhitespace() -> String {
        var view = Substring(self)
        while let last = view.last, last.isWhitespace {
            view.removeLast()
        }
        return String(view)
    }
}
