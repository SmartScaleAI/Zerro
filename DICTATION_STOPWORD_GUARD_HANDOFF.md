# Handoff: Stop the domain dictionary from clobbering common English words ("here" → "Hero")

## Goal

In Dev Mode, when the user dictates a common English word, the transcription must keep that word as spoken. Today the domain-dictionary correction step silently rewrites short common words into similarly-spelled project terms — most visibly **"here" → "Hero"** (matching the `hero.tsx` component). Fix this by adding a **stopword guard**: a token that is itself a common English word must never be snapped to a canonical term, no matter how close the edit distance.

Legitimate corrections (e.g. "Versel" → "Vercel", "Superbase" → "Supabase") must keep working — only real English words are protected.

## Root cause (confirmed)

The recording and Whisper transcription are correct; they capture "here" faithfully. The corruption happens **after**, in the Dev-Mode-only post-processing step.

- **File:** `apps/desktop/Zerro/Services/Dev/DevDomainDictionary.swift`
- **Call sites:** `apps/desktop/Zerro/AppState.swift` lines ~2394–2395 and ~2589–2590 (`DevDomainDictionary.seed(projectURL:)` then `dictionary.corrected(transcript)`), on both the managed and BYOK Dev paths.

The chain that produces the bug:

1. `seed(projectURL:)` walks the project and adds component basenames as canonical terms. The repo contains `apps/web/components/templates/axis/hero.tsx`, so **"hero"** (4 chars) is seeded as a canonical term — it passes the existing `count >= 4` length gate.
2. The user says **"here"**. Whisper transcribes "here" (4 chars, passes the `token.count >= 4` gate in `correctedToken`).
3. `correctedToken("here")` finds no exact match, then computes `levenshtein("here", "hero") == 1`.
4. The conservative gates are `best.dist <= 2` **AND** `Double(best.dist) / Double(maxLen) <= 0.34`. Here that is `1 <= 2` ✓ and `1/4 = 0.25 <= 0.34` ✓ → it snaps "here" → "Hero".

The file's header comment already anticipates this class of bug ("short names like 'ts', 'vue', 'zod' collide with ordinary words") but only guards by dropping terms under 4 chars. The gap is that **4–5 char component names** (hero, list, item, card, grid, menu, hero, modal, table…) still collide with everyday English words ("here", "hear", "her", "herd", "home", "list", "item"…) at edit distance 1.

## The fix (Option 1 — stopword guard)

Add a set of common English words to `DevDomainDictionary`. In `correctedToken`, **before** running the edit-distance search, check whether the token (lowercased) is a common word. If it is, return the token unchanged.

Key point about why this is safe and does NOT break dictating actual component names:

- The **exact-match short-circuit stays first and untouched.** `correctedToken` already returns the token unchanged when it is itself a known canonical term (`if lowerToCanonical[lower] != nil { return token }`). So when the user genuinely says **"hero"**, it matches the `hero.tsx` canonical term exactly and is returned as-is **before** the stoplist or any distance math runs. "hero" stays "Hero". ✓
- The stopword guard runs **after** the exact-match check and **before** the fuzzy search. So "here" (a stopword, not an exact canonical term) is protected and stays "here". ✓
- The guard only ever **prevents a change**. It never forces a word into anything. The comparison is always *from the word the user actually said*, never *toward* a guess — so "here" and "hero" can never be confused with each other.

### Suggested implementation

In `DevDomainDictionary.swift`, add a static stopword set and one guard line.

```swift
// MARK: - Stopwords

/// Common English words that must NEVER be snapped to a project term, even at
/// edit distance 1. Short component/library names (hero, list, item, card,
/// menu, grid, modal, table, …) collide with everyday words ("here", "hear",
/// "list", "item") at distance 1, and the conservative distance gates can't
/// tell the difference. A real word the user spoke must win over a near-miss
/// project term — the agent can still grep around an un-snapped common word,
/// but a clobbered "here"→"Hero" is silently wrong. This guards the whole
/// class of collisions, not just the "here"/"Hero" case that surfaced it.
///
/// Lowercased. Keep focused on short, high-frequency words (≤6 chars is where
/// the collisions live); this is not meant to be an exhaustive dictionary.
static let stopwords: Set<String> = [
    // pronouns / determiners / common function words
    "here", "hear", "heard", "her", "hers", "here's", "herd",
    "there", "their", "they", "them", "this", "that", "these", "those",
    "what", "when", "where", "which", "while", "with", "your", "yours",
    "home", "hold", "have", "from", "into", "over", "than", "then",
    "will", "would", "could", "should", "make", "made", "more", "most",
    "some", "same", "such", "very", "just", "like", "want", "need",
    // words that collide with common UI/component names
    "list", "item", "card", "cards", "menu", "grid", "table", "modal",
    "page", "pages", "link", "links", "form", "forms", "text", "title",
    "input", "label", "panel", "header", "footer", "button", "icon",
    "image", "images", "field", "fields", "row", "rows", "tab", "tabs",
    "view", "views", "name", "names", "value", "color", "style", "left",
    "right", "center", "top", "bottom", "size", "show", "hide", "open",
    "close", "click", "type", "edit", "save", "load", "send", "code"
]
// NOTE to implementer: refine this list as you see fit — the only hard
// requirement (locked by tests) is that "here", "hear", and "herd" are
// protected. Do NOT include legitimate-only-as-typo strings like "versel"
// or "superbase"; those must still snap.
```

Then add the guard at the top of `correctedToken`, immediately after the existing exact-match short-circuit:

```swift
func correctedToken(_ token: String) -> String {
    let lower = token.lowercased()
    // Already a known term (any casing) → leave exactly as written.
    // (Keeps a genuinely-spoken "hero" as "Hero" — exact match wins first.)
    if lowerToCanonical[lower] != nil { return token }

    // NEW: a common English word the user actually said must never be snapped
    // to a near-miss project term ("here" must not become "Hero").
    if Self.stopwords.contains(lower) { return token }

    guard token.count >= 4 else { return token }
    // … unchanged fuzzy-match logic below …
}
```

Place the guard **after** the `lowerToCanonical` check (so exact canonical terms still win) and **before** the `count >= 4` / fuzzy search. Do not change the seeding, the Levenshtein function, the distance gates, or the `corrected(_:)` traversal — the guard is the only behavioral change.

## Decisions already made (confirmed with the product owner)

- **Approach is the stopword guard (Option 1)** — not gate-tightening and not a bundled word-frequency table. Targeted, no new dependency, easy to test.
- **A genuinely-spoken component name still snaps/keeps correctly.** "hero" stays "Hero" via the existing exact-match short-circuit; only real common words are protected. This was explicitly checked and is the expected behavior.
- **Accepted trade-off:** if the user says "here" but actually means the Hero component (e.g. "center the here button"), it will now stay "here" and the dictionary won't fix it. That is correct — the dictionary must not silently overrule a real spoken word, and downstream resolution/agent can handle "here button" from context. The old behavior (every "here" → "Hero") is the worse failure.

## Tests

There is no dedicated dictionary test file yet; the relevant tests currently live in `apps/desktop/ZerroTests/DevWordTimingTests.swift` (see `testDictionarySnapsNearMissTermsToCanonical`, `testDictionaryLeavesCorrectAndUnrelatedTokens`, `testDictionarySeedsFromPackageJSONAndComponents`). Add new cases there (or create `DevDomainDictionaryStopwordTests.swift` following the same `@testable import Zerro` / `XCTestCase` pattern). Required cases:

1. **The reported bug:** dictionary seeded with `["Hero"]`; `correctedToken("here")` returns `"here"` (NOT "Hero"). Also assert via `corrected("center it here")` that the full-text path leaves "here" intact.
2. **Sibling collisions:** with `["Hero"]`, `correctedToken("hear")` → `"hear"` and `correctedToken("herd")` → `"herd"`.
3. **Genuine component name still kept:** with `["Hero"]`, `correctedToken("hero")` → `"hero"` (exact match) and `correctedToken("Hero")` → `"Hero"`.
4. **Legitimate corrections still work (regression):** with `["Vercel", "Supabase"]`, `correctedToken("Versel")` → `"Vercel"` and `correctedToken("Superbase")` → `"Supabase"`. These strings are not stopwords, so they must still snap.
5. **Casing/punctuation preserved in full text:** `corrected("Deploy to Versel here.")` → `"Deploy to Vercel here."` (Versel snapped, "here" protected, trailing period kept).

Run the desktop test target after the change and confirm all existing dictionary tests still pass alongside the new ones.

## Acceptance criteria

1. Dictating "here" in Dev Mode produces "here" in the prompt, never "Hero". *(the reported bug)*
2. Dictating "hear" / "herd" / "her" produces those words unchanged.
3. Dictating "hero" (the actual component) still produces "Hero".
4. "Versel" → "Vercel" and "Superbase" → "Supabase" style corrections still work.
5. All existing `DevDomainDictionary` tests pass; new stopword tests pass.
6. No change to recording, Whisper transcription, seeding, the distance gates, or the BYOK/managed call flow — the only diff is the stopword set + one guard line in `correctedToken`.

## Files likely to change

- `apps/desktop/Zerro/Services/Dev/DevDomainDictionary.swift` — add `static let stopwords` + one guard line in `correctedToken`. Primary change.
- `apps/desktop/ZerroTests/DevWordTimingTests.swift` (or a new `DevDomainDictionaryStopwordTests.swift`) — add the test cases above.

No changes needed in `AppState.swift` — the call sites are unaffected.
