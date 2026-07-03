# Handoff — What's New: review fixes + changelog backfill

Branch: `feature/whats-new-changelog` (already has the feature; do NOT re-implement it).
This is a follow-up pass from a code review. Three code fixes + a changelog content
backfill. Keep the build green and all existing tests passing; nothing is committed yet,
so commit at the end and open the PR against `staging` when done.

---

## Task 1 — Gate the launch auto-pop OFF in Staging builds

Right now the "What's New" window auto-pops in Staging too. It should NOT: Staging is an
internal test channel and the pop is noise for testers. The manual **Settings → About →
What's New** row must keep working in every build.

Use the existing `Build.isStaging` (`apps/desktop/Zerro/BuildEnvironment.swift`) — true
only under the `STAGING` compilation condition, false in Debug/Release.

Edit the `.present` case of the launch decision in `apps/desktop/Zerro/ZerroApp.swift`
(inside the one-shot init block, ~line 358). Keep the `lastSeenWhatsNewVersion` bump and
the breadcrumb unconditional so the marker still advances normally in Staging; only skip
the three flags that actually surface the window:

```swift
case .present:
    // Auto-pop everywhere EXCEPT Staging (internal test channel — the pop is
    // noise there). The marker still advances below, and the About → What's
    // New row still opens the window manually in every build.
    if !Build.isStaging {
        Self.shouldPresentWhatsNewOnLaunch = true
        AppDelegate.shouldPresentWhatsNewOnLaunch = true
        WhatsNewScene.autoPresentedThisLaunch = true
    }
    prefs.lastSeenWhatsNewVersion = currentVersion
    Log.breadcrumb(category: .appLifecycle, message: "whats-new auto-pop")
```

Do NOT thread `Build.isStaging` into `WhatsNewPolicy.decide` — the policy stays a pure
function of its current inputs; build-channel gating belongs at the call site. (If you
prefer, the breadcrumb message can note the suppressed case, but don't over-engineer it.)

Acceptance: Production/Debug behavior unchanged; a Staging build never auto-pops but the
About row still opens the window; `lastSeenWhatsNewVersion` advances in all builds.

---

## Task 2 — Remove the redundant `@Bindable` in WhatsNewView

In `apps/desktop/Zerro/Surfaces/WhatsNew/WhatsNewView.swift`, `body` declares
`@Bindable var preferences = preferences` (~line 21) but only ever reads
`preferences.showWhatsNewOnUpdate` (in the `.onChange`). The binding (`$preferences`) is
only used in `footer`, which already has its own local `@Bindable`. Remove the
body-level one; leave the `footer`'s intact. Confirm it still compiles (the `.onChange`
reads the plain environment value, which is fine).

Acceptance: no `$preferences` usage in `body` breaks; the footer toggle still two-way
binds; build is clean with no new warnings.

---

## Task 3 — Add the 1.4.23 changelog entry

`1.4.23` is staged (`staging-v1.4.23`) but has no entry, so its auto-pop would be
silently suppressed by the `hasEntry` guard. Add a `1.4.23` entry at the TOP of
`Changelog.entries` in `apps/desktop/Zerro/WhatsNew/Changelog.swift`.

Derive its notes from the commit range since the last app release. This is a monorepo —
scope to the desktop app and skip merge commits (see the scoping note in Task 4):

```
git log --oneline --no-merges app-v1.4.22..staging-v1.4.23 -- apps/desktop/
```

Use the tag date for the stamp: `git log -1 --format=%as staging-v1.4.23`.

Write 2–5 short, user-facing bullets (see the style rules in Task 4). If `VERSION` is
still `1.4.22`, DO NOT bump it here — that happens in the release PR; this task only adds
the changelog entry so it's ready when 1.4.23 ships.

---

## Task 4 — Backfill historical versions

Populate `Changelog.entries` with the earlier shipped releases so the window shows real
history (it renders newest-first and scrolls). There is NO pre-written notes source — the
`apps/web/public/appcast.xml` carries only version/download metadata, no notes — so
synthesize each entry from that version's git commit range.

### Scope: DESKTOP APP ONLY (critical)

This is a monorepo (`apps/desktop`, `apps/web`, `supabase`, `docs`). The app's What's New
must show ONLY macOS-app changes. Website (`apps/web`), backend (`supabase`), and
repo/docs/tooling commits must NOT appear. Enforce this at the query level with a path
filter, and drop merge-PR commits (they duplicate the underlying feature commits as
noise):

```
git log --oneline --no-merges <range> -- apps/desktop/
```

This is not optional — a plain `git log <range>` pulls in website features (e.g. "Add
comparison section", landing-page/credit-meter/email-setup work) that would be wrong to
show a desktop-app user. If a single commit touches both the app and the website, it's
fine to keep it (it's an app change too) — the path filter already includes it. Backend-
only changes are excluded by scope; only mention a backend change if it visibly changed
app behavior AND had a matching `apps/desktop` commit (which the filter would then catch).

### Which versions

The app releases are the `app-v*` tags. Cover this line (newest first), matching each
entry's `version` string to the release's `CFBundleShortVersionString`:

```
1.4.23 (Task 3), 1.4.22 (already present), 1.4.21, 1.4.20, 1.4.19, 1.4.18, 1.4.17,
1.4.16, 1.4.15, 1.4.14, 1.4.13, 1.4.12, 1.4.11, 1.4.10, 1.4.9, 1.4.8, 1.4.7, 1.4.6,
1.4.5, 1.4.4, 1.4.3, 1.4.2, 1.4.1, 1.4.0, 1.3.0, 1.2.2, 1.2.1
```

Notes on the tag data (handle defensively, don't guess):
- There are duplicate/oddly-named tags (`app-v-1.4.6`, `app-v-1.4.7`) and one appcast
  title/version mismatch (title `1.4.17` with `shortVersionString` `1.4.18`). Treat the
  version number itself as the source of truth, dedupe, and skip any tag you can't map to
  a clean version.
- If a tag has no earlier `app-v` predecessor (the floor, `app-v1.2.1`), don't diff —
  just write a short "initial / early release" highlight or 1–2 representative bullets
  from its history.

### Per-version method

For each version `N` with predecessor `P`:

```
git log --oneline --no-merges P..N -- apps/desktop/   # app-only changes in this release
git log -1 --format=%as N                             # entry date (YYYY-MM-DD → releaseDate(y,m,d))
```

Then distill 2–5 bullets. Curation rules (this is the important part — a changelog is not
a commit dump):
- **Keep** user-visible changes: new features, UX improvements, notable bug fixes.
- **Drop** internal-only commits: `chore:`, `ci:`, version bumps, refactors, test-only
  changes, docs, dependency bumps, build/tooling, anything a user would never notice.
- **Merge** related commits into one bullet; don't list five commits that are one feature.
- **Rewrite** in user language — "what changed for them," not which files moved. Present
  tense, concise, no trailing period is fine (match the existing 1.4.22 entry's voice).
- Use `ChangelogHighlight("…", kind: .new / .improved / .fixed)` — pick the honest kind.
  (The view renders all kinds as the same em-dash bullet today; `kind` is for future
  tagging, so it's fine if most are `.improved`.)
- If a release genuinely has nothing user-facing (a pure internal/patch release), it's
  acceptable to give it a single honest bullet like "Performance and stability
  improvements." Use this sparingly — only when the range truly has no user-facing change.

### Format

Match the existing entry exactly:

```swift
ChangelogEntry(
    version: "1.4.21",
    date: releaseDate(2026, 6, /* day */),
    highlights: [
        ChangelogHighlight("…", kind: .improved),
        ChangelogHighlight("…", kind: .fixed),
    ]
),
```

Keep `entries` strictly newest-first. Don't touch the `ChangelogEntry` /
`ChangelogHighlight` types or `entry(for:)`.

### Review gate

These notes are user-facing, so surface a summary of the drafted entries (version → date
→ bullets) in your final message for Colin to skim, and flag any version where the commit
range was ambiguous or thin so he can sanity-check or rewrite. Don't silently invent
features that aren't in the history.

---

## Verification (all tasks)

- Debug build succeeds.
- Existing suites pass, especially `WhatsNewPolicyTests`, `WhatsNewPreferencesTests`,
  `PulsingRingPreferenceTests`, `STTPreferencesTests`.
- `WhatsNewPolicyTests.testEntriesAreUniquePerVersion` still passes (no duplicate
  versions introduced during backfill) — this is the guard against a copy-paste slip.
- Manual sanity (if you can run it): a Debug build with
  `defaults write <bundleID> vf.whatsNew.lastSeenVersion 1.0.0` then relaunch → the window
  pops and scrolls through the full backfilled history; the footer toggle flips; Close
  dismisses; the About → What's New row opens it on demand.

## Commit / PR

Commit on `feature/whats-new-changelog` with a message summarizing: staging gate,
`@Bindable` cleanup, and the changelog backfill (1.4.0–1.4.23 + earlier). Open the PR
against `staging`. Leave `VERSION` untouched.
