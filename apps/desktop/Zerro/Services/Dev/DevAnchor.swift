//
//  DevAnchor.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 5) — the structured anchor the generation model
//  returns per referring expression (§7), and its DEFENSIVE parser. The model is
//  fed the marked crop + nearby OCR + the phrase, and emits a fenced
//  ```zerro_anchors``` JSON array describing the element it resolved:
//
//    { ref, label, type, region, current_state, confidence, alt_candidates }
//
//  Parsing mirrors the Phase-1 stream-json discipline: unknown shapes DEGRADE —
//  a missing field defaults, a bad enum → `.unknown`, a non-array / malformed
//  block → `[]` — and NEVER crash. A model that ignores the contract simply
//  yields no anchors (the run proceeds on the dwell/OCR client signal alone).
//

import Foundation

struct DevAnchor: Equatable, Sendable {

    enum Kind: String, Sendable, CaseIterable {
        case button, link, text, image, icon, input, container, unknown
        static func from(_ s: String?) -> Kind { Kind(rawValue: (s ?? "").lowercased()) ?? .unknown }
    }

    enum Region: String, Sendable, CaseIterable {
        case header, nav, hero, sidebar, main, footer, unknown
        static func from(_ s: String?) -> Region { Region(rawValue: (s ?? "").lowercased()) ?? .unknown }
    }

    /// 0-based index of the referring expression this anchor resolves, when the
    /// model echoed it back. nil → positional fallback (the caller pairs by order).
    let refIndex: Int?
    /// Verbatim visible text the agent can grep ("Get started"). nil when the
    /// element has no text (a bare icon/image).
    let label: String?
    let kind: Kind
    let region: Region
    /// The element's current visual state ("blue bg, 14px"), for the change spec.
    let currentState: String?
    /// The MODEL's agreement that the marked element matches a visible label,
    /// `0...1`. Combined with the client dwell/OCR signal (M6, `min`).
    let modelConfidence: Double
    let altCandidates: [String]
}

enum DevAnchorParser {

    /// Extract + parse the `zerro_anchors` block from a model response. Returns
    /// `[]` for any absence/malformation (never throws). The agent_prompt artifact
    /// is parsed separately by `ArtifactParser`; this only reads the anchors block.
    static func parse(_ raw: String) -> [DevAnchor] {
        guard let jsonText = extractBlock(raw) else { return [] }
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return parseJSON(obj)
    }

    /// Testable core: turn a decoded JSON value into anchors, leniently.
    static func parseJSON(_ json: Any) -> [DevAnchor] {
        guard let array = json as? [Any] else { return [] }
        var out: [DevAnchor] = []
        for entry in array {
            guard let o = entry as? [String: Any] else { continue } // skip non-objects
            out.append(DevAnchor(
                refIndex: intField(o["ref"]) ?? intField(o["ref_index"]),
                label: nonEmptyString(o["label"]),
                kind: .from(o["type"] as? String),
                region: .from(o["region"] as? String),
                currentState: nonEmptyString(o["current_state"]),
                modelConfidence: clampConfidence(o["confidence"]),
                altCandidates: stringArray(o["alt_candidates"])
            ))
        }
        return out
    }

    // MARK: - Block extraction

    /// Pull the inner text of a ```zerro_anchors … ``` fence. Falls back to a bare
    /// top-level JSON array if the model emitted one without the fence. nil when
    /// neither is present.
    private static func extractBlock(_ raw: String) -> String? {
        if let fenced = between(raw, open: "```zerro_anchors", close: "```") { return fenced }
        if let fenced = between(raw, open: "```ZERRO_ANCHORS", close: "```") { return fenced }
        // Bare-array fallback: a `[ … ]` that looks like our anchor list.
        if let l = raw.firstIndex(of: "["), let r = raw.lastIndex(of: "]"), l < r {
            let slice = String(raw[l...r])
            if slice.contains("label") || slice.contains("confidence") { return slice }
        }
        return nil
    }

    private static func between(_ s: String, open: String, close: String) -> String? {
        guard let openRange = s.range(of: open) else { return nil }
        let afterOpen = openRange.upperBound
        guard let closeRange = s.range(of: close, range: afterOpen..<s.endIndex) else { return nil }
        return String(s[afterOpen..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lenient field coercion

    private static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func intField(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func clampConfidence(_ v: Any?) -> Double {
        let d: Double
        if let n = v as? Double { d = n }
        else if let n = v as? Int { d = Double(n) }
        else if let s = v as? String, let n = Double(s) { d = n }
        else { return 0.5 } // absent/garbage → neutral
        return Swift.min(1, Swift.max(0, d))
    }

    private static func stringArray(_ v: Any?) -> [String] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap { nonEmptyString($0) }
    }
}
