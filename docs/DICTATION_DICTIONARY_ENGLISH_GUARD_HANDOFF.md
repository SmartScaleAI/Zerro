# Handoff: Dictation dictionary must ignore common English words ("here" must never become "Hero")

## Goal

The Dev Mode transcription dictionary (`DevDomainDictionary`) should keep doing its ONE useful job — snapping Whisper-mangled **unusual** project names back to canonical spelling ("Versel" → "Vercel", "Superbase" → "Supabase", "Zoo stand" → "Zustand") — but it must **never involve a common English word**, on either side of the correction:

1. **Never seed a common-English term.** Component filenames are frequently plain words (Hero, Card, Page, Team, Button, Footer, Header, Input, Label). Today these become canonical "correct spellings," and ordinary speech gets snapped toward them. Drop any seed term that is a real English word.
2. **Never snap *from* a common English word.** Even against a legitimately-unusual term, a token the user actually said that is itself a real English word ("here", "note", "text", "reach") must be left exactly as spoken.

Net effect: real words the user dictates always survive verbatim; only genuinely non-English names (libraries, unusual components, package names) are ever corrected.

## Background — why this dictionary exists (do not remove it)

Whisper transcribes normal English well but mangles project-specific names it has never heard (library/component/variable names aren't real words, so it guesses phonetically). Those names are the exact anchors the dev agent must match against the codebase, so the dictionary seeds canonical spellings from the project (`package.json` deps + component filenames) and snaps near-miss transcript tokens back before prompt generation. The mechanism is sound; the **fuel is poisoned** — component filenames drag common English words into the canonical set.

## Root cause (confirmed empirically against this repo)

- **File:** `apps/desktop/Zerro/Services/Dev/DevDomainDictionary.swift` (unchanged from its original Phase 2 form — note: the previously-drafted stopword fix was never landed).
- **Call sites:** `apps/desktop/Zerro/AppState.swift` ~lines 2394–2395 and ~2589–2590 (`DevDomainDictionary.seed(projectURL:)` → `dictionary.corrected(transcript)`), on both managed and BYOK Dev paths, inside a `Task.detached` (off-main).

This project seeds these short, common-English-colliding terms (component basenames + deps, ≥4 chars):
`hero, card, page, team, node, next, motion, tools, button, footer, header, input, label`.

At Levenshtein distance 1 (within the existing `dist ≤ 2` and `dist/maxLen ≤ 0.34` gates) they swallow everyday speech. Verified collisions on THIS repo:

| user says | snaps to (component) |
|---|---|
| here / herd | hero |
| cards / cart | card |
| pages | page |
| teams / tear | team |
| note | node |
| text | next |
| reach | react |
| tool | tools |
| lotion | motion |

The screenshot ("this Hero … the hero Hero … this Hero") is three independent `here → hero` snaps in one sentence — not a regression, the same bug on a sentence that says "here" repeatedly.

## The fix (confirmed approach: real-dictionary check via `NSSpellChecker`)

Decision made with the product owner: classify "is this a common English word?" using the **OS spell-checker** (`NSSpellChecker`, already on every Mac — no new dependency, not currently used elsewhere in the app), rather than a hand-maintained stoplist. It catches the whole class (hero, card, tear, lotion, …), not just words someone remembered to list.

Two guards, both keyed on the same `isCommonEnglishWord(_:)` check:

### Guard 1 — drop common-word SEED terms (in `init(terms:)` / `build`)
When building the term list, skip any raw term that is a real English word. So "Hero", "Card", "Page", "Team", "Button", "Footer", "Header", "Input", "Label" never become canonical targets. Unusual names ("supabase", "zustand", "navbar", "shadcn", "clsx", "lucide", "framer", "tailwindcss", "vercel") are kept.

### Guard 2 — never snap FROM a common word (in `correctedToken`)
After the existing exact-match short-circuit and before the fuzzy search, return the token unchanged if it is a real English word:

```swift
func correctedToken(_ token: String) -> String {
    let lower = token.lowercased()
    // Already a known term (any casing) → leave exactly as written.
    if lowerToCanonical[lower] != nil { return token }
    // NEW (Guard 2): a real English word the user actually said is never snapped.
    if Self.isCommonEnglishWord(lower) { return token }
    guard token.count >= 4 else { return token }
    // … unchanged fuzzy match …
}
```

Guard 1 keeps Guard 2 from being load-bearing alone (no common-word targets exist to snap toward), and Guard 2 protects words even if a term slips through Guard 1. Both are needed.

### The English-word check

Add a static helper. `NSSpellChecker` is AppKit and main-thread-affined by convention, but `seed()` runs off-main in a `Task.detached`. Use the thread-safe pattern:

```swift
import AppKit

extension DevDomainDictionary {
    /// True when `word` is an ordinary English word (so the dictionary must not
    /// touch it). Backed by the OS spell-checker. Words ≤3 chars are treated as
    /// common (already excluded by the ≥4 seed/snap gate, but cheap to short-
    /// circuit). Case-insensitive; callers pass a lowercased token.
    static func isCommonEnglishWord(_ lowercased: String) -> Bool {
        guard lowercased.count >= 4 else { return true }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: lowercased,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        // location == NSNotFound ⇒ no misspelling found ⇒ it IS a real word.
        return range.location == NSNotFound
    }
}
```

Implementer notes / things to get right:
- **Threading:** `NSSpellChecker.shared` is documented as main-thread-preferred. It is widely used off-main for `checkSpelling`, but confirm no main-thread assertion fires under the `Task.detached` seed path. If it does, two safe options: (a) build the dictionary's dropped-term filtering by collecting candidate terms off-main and doing the spell pass on a hop to `MainActor`, then handing the finished `DevDomainDictionary` (a `Sendable` value type) back; or (b) compute an English-word `Set` once on `MainActor` at app launch and inject it. Prefer (a) — it keeps the whole thing inside `seed`. Keep the public surface (`corrected`, `correctedToken`) pure and synchronous; only the *construction* needs the speller.
- **Determinism for tests:** the spell-check call makes `correctedToken` depend on the OS dictionary, which is awkward to unit-test. Inject the word-check so tests can supply a deterministic predicate. E.g. store `let isCommon: @Sendable (String) -> Bool` on the struct, defaulting to `Self.isCommonEnglishWord`, and let tests pass a fake (`{ ["here","hear","herd","note","text","reach"].contains($0) }`). This keeps the existing pure/testable design intact.
- **Don't over-correct casing:** preserve existing behavior — untouched tokens keep their original casing; only snapped tokens take the canonical spelling.
- **Leave everything else alone:** seeding scan, Levenshtein, the `dist ≤ 2` / `≤0.34` gates, `corrected(_:)` traversal, word-timing correction, and the BYOK/managed call flow are unchanged.

## Expected results (verified in a faithful simulation against this repo's real seed set)

User's actual sentence (Whisper raw): `"this here, I want the hero here to be different, and I want it to be blue. The part above the hero."`
→ After guarded correction: **identical** — every "here" stays "here".

Legitimate corrections still fire:
- `Versel` → `vercel`
- `Superbase` → `supabase`
- `Zoostand` → `zustand`

Terms DROPPED from the seed set as common English (this repo): `button, card, footer, header, input, label, motion, next, node, page, team, tools`.
Terms KEPT: `avatar, badge, clsx, eslint, hero?, layout, navbar, react?, shadcn, toggle, supabase, tailwindcss, lucide, framer, typescript, zustand, vercel`.

> Note: `hero` and `react` are themselves real English-ish words — `hero` IS a dictionary word, so Guard 1 will (correctly) drop it too, which is fine: we don't need "hero" as a snap target, and Guard 2 already protects "here". Confirm the speller classifies `hero` and `react` as words on the target OS; if `react` is treated as a non-word it stays a (harmless) seed term. Either way the user-facing behavior is correct.

## Tests

Add to `apps/desktop/ZerroTests/DevWordTimingTests.swift` (or a new `DevDomainDictionaryEnglishGuardTests.swift`, same `@testable import Zerro` / `XCTestCase` pattern). Use the injected predicate so tests are deterministic and don't depend on the OS dictionary:

1. **The reported bug:** dictionary seeded with `["Hero"]`, `isCommon = {"here","hear","herd"}`; `correctedToken("here")` → `"here"`, `"hear"` → `"hear"`, `"herd"` → `"herd"`. Full-text: `corrected("the part above the here")` leaves "here" intact.
2. **Multi-collision sentence:** seeded with `["Hero","Card","Page","Team","Node","Next"]`; the sentence in "Expected results" round-trips unchanged.
3. **Guard 1 drops common seed terms:** building from `["Hero","Card","Supabase","Vercel"]` with the English predicate yields a term set containing `supabase`/`vercel` but NOT `hero`/`card`.
4. **Genuine unusual name still corrected:** seeded with `["Vercel","Supabase","Zustand"]`; `"Versel"` → `"Vercel"`, `"Superbase"` → `"Supabase"`, `"Zoostand"` → `"Zustand"`.
5. **Exact component name still kept (when it survives Guard 1):** an unusual component like `["Navbar"]` → `correctedToken("Navbar")` → `"Navbar"`.
6. **Empty dictionary is still a no-op** (regression of existing test).
7. **Optional integration smoke test (not deterministic, mark accordingly):** with the real `NSSpellChecker` predicate, assert `isCommonEnglishWord("here") == true` and `isCommonEnglishWord("supabase") == false`.

Run the four affected suites on macOS (no Swift/Xcode toolchain in the handoff environment — the simulation above validated the git/logic mechanics, but XCTest must be run on the machine).

## Acceptance criteria

1. Dictating "here / hear / herd / note / text / reach / cards / pages / teams / tool" in Dev Mode produces those words verbatim — never a component name.
2. "Versel" → "Vercel", "Superbase" → "Supabase", "Zoostand" → "Zustand" still work.
3. Common-word component names (Hero, Card, Page, Team, Button, Footer, Header, Input, Label) are no longer seeded as snap targets.
4. No new third-party dependency (uses `NSSpellChecker`); no main-thread assertion under the off-main `seed` path.
5. `corrected`/`correctedToken` remain pure & synchronous; the English check is injectable for deterministic tests.
6. All existing `DevDomainDictionary` tests pass alongside the new ones.

## Files likely to change

- `apps/desktop/Zerro/Services/Dev/DevDomainDictionary.swift` — add `isCommonEnglishWord` (+ injectable predicate), apply Guard 1 in build/init and Guard 2 in `correctedToken`. Primary change.
- `apps/desktop/ZerroTests/DevWordTimingTests.swift` (or new test file) — the cases above.

No change needed in `AppState.swift` (call sites unaffected) or `DevRecovery.swift`.

## Fallback if `NSSpellChecker` proves problematic off-main

If the spell-checker can't be made to behave under the detached seed path within reasonable effort, ship a hardcoded common-word `Set` (a few hundred high-frequency words + the observed UI-noun collisions) as `isCommonEnglishWord`'s default instead — same two guards, same tests (which already inject the predicate, so they don't change). This is strictly a fallback; the dictionary check is preferred for coverage.
