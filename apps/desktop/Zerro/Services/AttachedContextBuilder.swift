//
//  AttachedContextBuilder.swift
//  Zerro
//
//  Created by Colin Breeding on 6/11/26.
//
//  Phase 2 of the modes → typed-artifact refactor: assembles the §2
//  "Attached Context" block CLIENT-side from what the recording already
//  produced — per-frame OCR text and resolved clicks. No transcript, no
//  server involvement (locked decision). ADDITIVE in this phase; Phase 4/5
//  wire it into the copy payload (appended on `agent_prompt` copy) and the
//  artifact card's context drawer.
//
//  §2 template:
//
//      ## Attached Context
//      **Screen text (OCR excerpts):** <deduped, length-capped OCR>
//      **Clicks:** clicked "Sign in", clicked "Apply", …
//
//  Rules (§2): dedupe repeated OCR lines across frames, cap the assembled
//  block at ~4,000 chars, omit either section when it is empty, and return
//  nil when both are — the drawer simply doesn't render.
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
        let ocrLines = dedupedOCRLines(from: frames)
        let clickPhrases = clicks
            .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "clicked \"\($0)\"" }

        guard !ocrLines.isEmpty || !clickPhrases.isEmpty else { return nil }

        let clicksSection = clickPhrases.isEmpty ? nil : "\(clicksLabel) \(clickPhrases.joined(separator: ", "))"

        // Give the OCR excerpt whatever budget remains after the fixed
        // parts, so the assembled block lands under the cap.
        var ocrSection: String?
        if !ocrLines.isEmpty {
            var fixedLength = header.count + 1 + ocrLabel.count + 1 // header + \n + label + space
            if let clicksSection {
                fixedLength += 1 + clicksSection.count // \n + clicks line
            }
            let budget = max(0, maxLength - fixedLength)
            ocrSection = "\(ocrLabel) \(cappedExcerpt(ocrLines, budget: budget))"
        }

        let block = [header, ocrSection, clicksSection]
            .compactMap { $0 }
            .joined(separator: "\n")

        // Defensive final cap — only reachable when the click line alone is
        // enormous (hundreds of long labels). Grapheme-safe via prefix.
        guard block.count > maxLength else { return block }
        return String(block.prefix(maxLength - 1)) + "\u{2026}"
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

    /// Joins lines up to `budget` characters, truncating at a line boundary
    /// where possible. A budget too small for even the first line degrades
    /// to a grapheme-safe character cut with an ellipsis.
    private nonisolated static func cappedExcerpt(_ lines: [String], budget: Int) -> String {
        var kept: [String] = []
        var length = 0
        for line in lines {
            let cost = line.count + (kept.isEmpty ? 0 : 1) // + "\n" separator
            if length + cost > budget { break }
            kept.append(line)
            length += cost
        }
        if kept.isEmpty, let first = lines.first {
            // Not even one whole line fits — cut within the line.
            guard budget > 1 else { return "" }
            return String(first.prefix(budget - 1)) + "\u{2026}"
        }
        if kept.count < lines.count {
            return kept.joined(separator: "\n") + "\u{2026}"
        }
        return kept.joined(separator: "\n")
    }
}
