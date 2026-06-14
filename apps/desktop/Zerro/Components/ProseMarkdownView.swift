//
//  ProseMarkdownView.swift
//  Zerro
//
//  Block-level markdown renderer for PROSE surfaces (the result summary /
//  chat text). `AttributedString(markdown:)` collapses block structure into
//  a single inline run, so `### heading`, `| table |`, and `- bullet` lines
//  arrive as literal syntax. This view parses those blocks and lays them out
//  as distinct stacked views — headings, bullet/numbered lists, and tables —
//  while inline markdown (**bold**, *italic*, `code`) still resolves within
//  each block.
//
//  Scope: SUMMARY ONLY. The artifact body well stays raw/monospace; this
//  renderer is not used there.
//

import SwiftUI

struct ProseMarkdownView: View {
    let markdown: String

    /// Base prose size — matches the previous ChatProseText look.
    var baseSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(Color.vfTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VFSpacing.xs)

        case let .paragraph(text):
            inline(text)
                .font(.system(size: baseSize))
                .foregroundStyle(Color.vfTextPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", markerColor: .vfTextSecondary, text: item)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: item.marker, markerColor: .vfBrandAccent, text: item.text)
                }
            }

        case let .table(header, rows):
            tableView(header: header, rows: rows)
        }
    }

    private func listRow(marker: String, markerColor: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
            Text(marker)
                .font(.system(size: baseSize, weight: .semibold))
                .foregroundStyle(markerColor)
            inline(text)
                .font(.system(size: baseSize))
                .foregroundStyle(Color.vfTextPrimary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .leading, horizontalSpacing: VFSpacing.lg, verticalSpacing: VFSpacing.xs) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    inline(col < header.count ? header[col] : "")
                        .font(.system(size: baseSize, weight: .semibold))
                        .foregroundStyle(Color.vfTextSecondary)
                }
            }
            Rectangle()
                .fill(Color.vfHairline)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
                .gridCellColumns(columnCount)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        inline(col < row.count ? row[col] : "")
                            .font(.system(size: baseSize))
                            .foregroundStyle(Color.vfTextPrimary)
                    }
                }
            }
        }
        .padding(.vertical, VFSpacing.xs)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 4
        case 2: return baseSize + 2
        default: return baseSize + 1
        }
    }

    /// Inline-only markdown so **bold**, *italic*, and `code` resolve within
    /// a block; falls back to the raw string if parsing balks (never drop
    /// the text — it's the fail-safe surface).
    private func inline(_ s: String) -> Text {
        let attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        return Text(attr)
    }
}

// MARK: - MarkdownBlock parsing

/// A coarse block model — only the structures that appear in result
/// summaries (headings, lists, tables, paragraphs). Deliberately small: it
/// is not a full CommonMark parser, just enough to stop block syntax from
/// leaking through as literal text.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([(marker: String, text: String)])
    case table(header: [String], rows: [[String]])

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Blank line — block separator.
            if line.isEmpty {
                i += 1
                continue
            }

            // Heading: 1–6 leading '#' followed by a space.
            if let heading = parseHeading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Table: this line has pipes and the next is a separator row.
            if line.contains("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                let header = splitTableRow(line)
                var rows: [[String]] = []
                i += 2 // consume header + separator
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                    rows.append(splitTableRow(rowLine))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Bullet list: consecutive '-', '*', or '+' items.
            if isBullet(line) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBullet(t) else { break }
                    items.append(stripBullet(t))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list: consecutive 'N.' items.
            if numberedMarker(line) != nil {
                var items: [(marker: String, text: String)] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let marker = numberedMarker(t) else { break }
                    items.append((marker: marker, text: stripNumber(t, marker: marker)))
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Paragraph: gather consecutive plain lines until a blank line or
            // a line that starts another block.
            var paragraph: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || parseHeading(t) != nil || isBullet(t)
                    || numberedMarker(t) != nil
                    || (t.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                paragraph.append(t)
                i += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: Line classifiers

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else {
            return false
        }
        let rest = line.dropFirst()
        return rest.first == " "
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Returns the numeric marker (e.g. "1.") when the line opens a numbered
    /// list item, else nil.
    private static func numberedMarker(_ line: String) -> String? {
        var digits = ""
        for ch in line {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == "." else { return nil }
        let afterDot = afterDigits.dropFirst()
        guard afterDot.first == " " else { return nil }
        return digits + "."
    }

    private static func stripNumber(_ line: String, marker: String) -> String {
        String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    /// A table separator row: pipes plus only dashes, colons, and spaces in
    /// each cell (e.g. `|---|---:|`).
    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("|"), line.contains("-") else { return false }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "-: ")
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Split a `| a | b |` row into trimmed cells, dropping the empty edges
    /// produced by leading/trailing pipes.
    private static func splitTableRow(_ raw: String) -> [String] {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        return line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

#Preview {
    ProseMarkdownView(markdown: """
    The usage tiers differ mainly by **rate-limit throughput**, not by the \
    model's actual context window/input-size capability.

    From your OpenAI Limits page:

    ### Usage tier thresholds
    Your org upgrades automatically as total credit purchases reach:

    | Tier | Credit purchase threshold |
    |---|---:|
    | Free tier | $0 |
    | Tier 1 | $5 |
    | Tier 2 | $50 |
    | Tier 5 | $1,000 |

    ### What changes between tiers
    Higher tiers generally raise limits like:

    - **TPM** — tokens per minute, how many input + output tokens per minute.
    - **RPM** — requests per minute.
    - **RPD** — requests per day, where applicable.
    """)
    .padding()
    .frame(width: 520)
    .background(Color.vfCardBackground)
}
