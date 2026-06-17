//
//  DevDomainDictionary.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 2) — the transcription domain dictionary (§11).
//  Whisper mangles library / component / variable names it has no context for
//  ("Vercel"→"Versel", "Supabase"→"Superbase", "Zustand"→"Zoo stand"). Those
//  names are exactly the anchors the dev prompt and the agent need to be exact,
//  so we seed a dictionary from the project itself — `package.json` dependency
//  names + component filenames — and snap near-miss transcript tokens back to the
//  canonical spelling BEFORE prompt generation.
//
//  Conservative by construction (a wrong "correction" is worse than a mangled
//  word the agent can still grep around): only a token that is a CLOSE but
//  non-exact match to a seeded term is snapped, gated on a small absolute AND
//  relative edit distance, and only for terms ≥4 chars (short names like "ts",
//  "vue", "zod" collide with ordinary words). An already-correct token (any
//  casing) is left exactly as the user said it.
//
//  Dev-Mode-only; never runs for a normal recording.
//

import Foundation

struct DevDomainDictionary: Sendable {

    /// Canonical terms (correct spelling/casing) to snap near-misses to.
    let terms: [String]
    /// Lowercased term → canonical, for the exact-match short-circuit.
    private let lowerToCanonical: [String: String]

    /// Build from raw terms (de-duped; short terms dropped as collision-prone).
    init(terms rawTerms: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in rawTerms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 4 else { continue }
            let key = t.lowercased()
            if seen.insert(key).inserted { kept.append(t) }
        }
        self.terms = kept
        self.lowerToCanonical = Dictionary(kept.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    var isEmpty: Bool { terms.isEmpty }

    // MARK: - Seeding

    /// Seed from a project's `package.json` bytes + a list of component
    /// filenames. Dependency names contribute their scope-stripped name and last
    /// path segment (e.g. `@tanstack/react-query` → `react-query`); component
    /// filenames contribute their basename (extension stripped). Pure + testable;
    /// the filesystem scan lives in `seed(projectURL:)`.
    static func build(packageJSON: Data?, componentFilenames: [String]) -> DevDomainDictionary {
        var terms: [String] = []

        for name in componentFilenames {
            let base = (name as NSString).deletingPathExtension
            if !base.isEmpty { terms.append(base) }
        }

        if let data = packageJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["dependencies", "devDependencies", "peerDependencies"] {
                guard let deps = obj[key] as? [String: Any] else { continue }
                for dep in deps.keys {
                    // "@scope/pkg" → "pkg" (and "scope"); "pkg" → "pkg".
                    if dep.hasPrefix("@") {
                        let parts = dep.dropFirst().split(separator: "/")
                        terms.append(contentsOf: parts.map(String.init))
                    } else {
                        terms.append(dep)
                    }
                }
            }
        }
        return DevDomainDictionary(terms: terms)
    }

    /// Best-effort filesystem seed for a Dev Mode project folder: reads
    /// `package.json` at the root and collects component-style filenames a few
    /// levels deep. Off-main-safe (pure file reads). Returns an empty dictionary
    /// on any failure — correction then becomes a no-op.
    static func seed(projectURL: URL) -> DevDomainDictionary {
        let fm = FileManager.default
        let packageJSON = try? Data(contentsOf: projectURL.appendingPathComponent("package.json"))

        let componentExtensions: Set<String> = ["tsx", "jsx", "vue", "svelte"]
        let skipDirs: Set<String> = ["node_modules", ".git", ".next", "dist", "build", ".turbo", "out"]
        var filenames: [String] = []
        if let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var visited = 0
            for case let url as URL in enumerator {
                if skipDirs.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                visited += 1
                if visited > 5000 { break } // bound the walk on a huge repo
                if componentExtensions.contains(url.pathExtension.lowercased()) {
                    filenames.append(url.lastPathComponent)
                }
            }
        }
        return build(packageJSON: packageJSON, componentFilenames: filenames)
    }

    // MARK: - Correction

    /// Correct a transcript in place: snaps near-miss tokens in `fullText`, every
    /// segment's text, AND each word timing back to the canonical term. Word
    /// start/end are untouched (only the spelling changes). A no-op for an empty
    /// dictionary.
    func corrected(_ transcript: Transcript) -> Transcript {
        guard !isEmpty else { return transcript }
        return Transcript(
            segments: transcript.segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: corrected($0.text))
            },
            fullText: corrected(transcript.fullText),
            words: transcript.words.map {
                WordTiming(word: correctedToken($0.word), start: $0.start, end: $0.end)
            }
        )
    }

    /// Correct a free-text string token-by-token, preserving all non-alphanumeric
    /// characters (spaces, punctuation, casing of untouched tokens).
    func corrected(_ text: String) -> String {
        guard !isEmpty else { return text }
        var result = ""
        var token = ""
        func flush() {
            if !token.isEmpty { result += correctedToken(token); token = "" }
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                token.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    /// Snap a single alphanumeric token to a canonical term when it's a close
    /// non-exact match; otherwise return it unchanged.
    func correctedToken(_ token: String) -> String {
        let lower = token.lowercased()
        // Already a known term (any casing) → leave exactly as written.
        if lowerToCanonical[lower] != nil { return token }
        guard token.count >= 4 else { return token }

        var best: (term: String, dist: Int)?
        for term in terms {
            let d = Self.levenshtein(lower, term.lowercased())
            if best == nil || d < best!.dist { best = (term, d) }
            if d == 1 { break } // can't beat 1 for a non-exact match
        }
        guard let best else { return token }
        let maxLen = max(token.count, best.term.count)
        // Conservative gates: ≤2 edits AND ≤~⅓ of the token changed.
        if best.dist <= 2, Double(best.dist) / Double(maxLen) <= 0.34 {
            return best.term
        }
        return token
    }

    // MARK: - Levenshtein

    /// Classic DP edit distance (two-row). Inputs are pre-lowercased by callers.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
