//
//  AttachedContextBuilder.swift
//  Zerro
//
//  Created by Colin Breeding on 6/11/26.
//
//  Phase 2 of the modes → typed-output refactor: assembles the §2
//  "Attached Context" block CLIENT-side from what the recording already
//  produced — per-frame OCR text and resolved clicks. No transcript, no
//  server involvement (locked decision).
//
//  The §2 markdown template below survives ONLY as model input — the
//  convert endpoint receives the block verbatim. Revision 2026-06-12: the
//  output card's context drawer was removed, so the block is never
//  rendered, and no copy payload includes it for any type — it is
//  internal-only.
//
//      ## Attached Context
//      **Screen text (OCR excerpts):** <deduped, length-capped OCR>
//      **Clicks:** clicked "Sign in", clicked "Apply", …
//
//  Rules (§2): dedupe repeated OCR lines across frames, cap the assembled
//  block at ~4,000 chars trimming at WHOLE lines (never a dangling
//  markdown fragment), omit either section when it is empty, and return
//  nil when both are.
//

import Foundation

/// Pure assembly of the Attached Context block. Stateless string work only.
enum AttachedContextBuilder {

    /// §2: "Cap the assembled context at ~4,000 chars." The cap is applied
    /// to the OCR excerpt first (it is the unbounded input); the header and
    /// click line stay intact unless they alone exceed the cap.
    nonisolated static let maxLength = 4_000

    private nonisolated static let header = "## Attached Context"
    private nonisolated static let ocrLabel = "**Screen text (OCR excerpts):**"
    private nonisolated static let clicksLabel = "**Clicks:**"

    /// Builds the context block, or nil when there is nothing to attach.
    nonisolated static func build(frames: [ExtractedFrame], clicks: [ResolvedClick]) -> String? {
        let allOCR = dedupedOCRLines(from: frames)
        let clickLabels = clicks
            .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let clickPhrases = clickLabels.map { "clicked \"\($0)\"" }

        guard !allOCR.isEmpty || !clickLabels.isEmpty else { return nil }

        let clicksSection = clickPhrases.isEmpty ? nil : "\(clicksLabel) \(clickPhrases.joined(separator: ", "))"

        // Give the OCR excerpt whatever budget remains after the fixed
        // parts, so the assembled block lands under the cap.
        var ocrSection: String?
        if !allOCR.isEmpty {
            var fixedLength = header.count + 1 + ocrLabel.count + 1 // header + \n + label + space
            if let clicksSection {
                fixedLength += 1 + clicksSection.count // \n + clicks line
            }
            let budget = max(0, maxLength - fixedLength)
            let capped = cappedLines(allOCR, budget: budget)
            if !capped.kept.isEmpty {
                let excerpt = capped.kept.joined(separator: "\n") + (capped.truncated ? "\u{2026}" : "")
                ocrSection = "\(ocrLabel) \(excerpt)"
            }
        }

        var block = [header, ocrSection, clicksSection]
            .compactMap { $0 }
            .joined(separator: "\n")

        // Defensive final cap — only reachable when the click line alone is
        // enormous (hundreds of long labels). Trim at the last whole LINE
        // inside the cap so no dangling markdown fragment is ever emitted.
        if block.count > maxLength {
            let prefix = String(block.prefix(maxLength - 1))
            if let lastBreak = prefix.lastIndex(of: "\n") {
                block = String(prefix[..<lastBreak]) + "\n\u{2026}"
            } else {
                block = prefix + "\u{2026}"
            }
        }

        return block
    }

    // MARK: OCR assembly

    /// Splits every frame's OCR text into lines and keeps the FIRST
    /// occurrence of each (§2: "dedupe repeated OCR lines across frames" —
    /// consecutive frames of the same screen repeat most of their text).
    /// Order is frame order, then line order within the frame.
    private nonisolated static func dedupedOCRLines(from frames: [ExtractedFrame]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for frame in frames {
            guard let text = frame.ocrText else { continue }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, seen.insert(line).inserted else { continue }
                result.append(line)
            }
        }
        return result
    }

    /// Keeps whole lines up to `budget` characters — never a mid-line cut,
    /// so a truncation can't leave a dangling markdown fragment. Trailing
    /// kept lines with no alphanumeric content (stray "*", "-", "—" OCR
    /// noise at the cut point) are dropped from the truncated tail.
    private nonisolated static func cappedLines(_ lines: [String], budget: Int) -> (kept: [String], truncated: Bool) {
        var kept: [String] = []
        var length = 0
        for line in lines {
            let cost = line.count + (kept.isEmpty ? 0 : 1) // + "\n" separator
            if length + cost > budget { break }
            kept.append(line)
            length += cost
        }
        var truncated = kept.count < lines.count
        if truncated {
            while let last = kept.last, last.rangeOfCharacter(from: .alphanumerics) == nil {
                kept.removeLast()
                truncated = true
            }
        }
        return (kept, truncated)
    }
}
