# What's New (Changelog) Window — Implementation Plan

Status: PLAN (no code written yet)
Owner: Colin
Target: `apps/desktop` (native SwiftUI macOS app)

## 1. Goal

Ship a "What's New" window that:

1. Auto-pops the first time the app runs on a newer version than the user last saw
   (every version change, including patches — CleanShot X behavior).
2. Can be reopened on demand from **Settings → About & Support**.
3. Renders as a versioned changelog list (newest first, scrollable), styled in
   Zerro's dark/monochrome branding instead of CleanShot's.
4. Carries a footer checkbox — **"Show changelog after each update"** — that lets the
   user disable the auto-pop. Reopening from About still works when it's off.

## 2. Decision: content source — **bundled in-app (recommended)**

The changelog ships as a static, versioned list inside the app bundle (a Swift array,
or a bundled `changelog.json` decoded at launch), edited as part of each release.

Why this over the alternatives:

- **No new backend surface.** Remote-fetch (Supabase/JSON) would add network fetch,
  caching, and an offline-fallback path for a feature that is inherently offline-safe.
  A changelog only ever describes versions that already shipped, so there is no value
  in editing it after release — the one real benefit of remote content doesn't apply.
- **No dependency on the deferred Sparkle appcast pipeline.** `UpdaterView.swift` and
  `AboutSupportSection.swift` both note the appcast/release pipeline (C4) is deferred
  and not live. Sourcing notes from appcast release-notes would block this feature on
  that pipeline. Bundled content ships today.
- **Editorial control + curated tone**, matching the CleanShot feel: short,
  human-written bullets per version rather than raw commit logs.
- **Clean upgrade path.** The view/model read from a `ChangelogProvider` protocol, so a
  future remote source can be swapped in behind the same UI with no view changes.

Trade-off accepted: notes are updated by editing a file in the same PR that bumps
`VERSION` / `CFBundleShortVersionString`. That's a one-line-per-release chore and keeps
the changelog honest (it can't drift ahead of what actually shipped).

Process note: add "update `Changelog.swift`" to the release checklist in
`docs/DEPLOY-RUNBOOK.md` so it isn't forgotten on a release.

## 3. Trigger rule (confirmed: every version change)

At launch, compare the current short version to the last version the user has seen:

- `current = CFBundleShortVersionString` (same source as
  `DiagnosticsCollector.displayVersionString()`).
- `lastSeen = PreferencesStore.lastSeenWhatsNewVersion` (new key, nil when never set).

Auto-present when **all** of:

1. `lastSeen != nil` — i.e. NOT a first-ever install. (Fresh installs get Onboarding,
   not a changelog; we silently seed `lastSeen = current` instead — see §7.)
2. `current != lastSeen` — the version actually changed. String inequality is enough for
   "every change"; no semantic parsing needed for the auto-pop decision.
3. `preferences.showWhatsNewOnUpdate == true` — the footer checkbox.
4. `onboarding.hasCompletedOnboarding == true` — never stack on top of onboarding.
5. There is a changelog entry for `current` (defensive: if a release forgets to add
   notes, don't pop an empty window — just reconcile `lastSeen`).

After the decision is made (whether or not we present), set `lastSeen = current` so the
window fires **at most once per version**. Downgrades (current < lastSeen) simply don't
match rule 2 and are ignored; `lastSeen` is only ever moved forward to `current` when we
handle a launch, so a downgrade won't re-trigger.

Note on the checkbox-off case: we still bump `lastSeen` on every launch. Consequence —
turning the checkbox back on later will not retroactively show notes for versions that
shipped while it was off. That matches user intent ("stop showing me this") and keeps the
rule to a single stored value.

## 4. Architecture overview

Five small pieces, each mirroring an existing pattern in the codebase:

| Piece | New file(s) | Mirrors |
|---|---|---|
| Changelog data + provider | `Zerro/WhatsNew/Changelog.swift` | `ModelRegistry` (static registry) |
| Pure decision logic | `Zerro/WhatsNew/WhatsNewPolicy.swift` | `UpdateWindowPolicy.swift` (pure, testable) |
| Preferences | edits to `Preferences/PreferencesStore.swift` | existing keys/props |
| Window scene + chrome | `Zerro/Surfaces/WhatsNew/WhatsNewScene.swift` | `FeedbackScene.swift` |
| Window view | `Zerro/Surfaces/WhatsNew/WhatsNewView.swift` | `FeedbackView.swift` |
| App wiring | edits to `ZerroApp.swift` | Onboarding / Feedback scenes |
| About entry point | edits to `AboutSupportSection.swift` | `SendFeedbackRow` |

The pure `WhatsNewPolicy` is deliberately split from the view (same split as
`UpdateWindowPolicy` vs `UpdaterView`) so the "should we show it" rule is unit-testable
without SwiftUI or AppKit.

## 5. Data model

```swift
// Zerro/WhatsNew/Changelog.swift

/// One released version's notes. `version` matches CFBundleShortVersionString
/// exactly (e.g. "1.4.22"). Order in `Changelog.entries` is authoritative:
/// newest first. `date` is display-only.
struct ChangelogEntry: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let date: Date?          // optional "Jul 2, 2026" stamp under the version
    let highlights: [Highlight]
}

struct Highlight: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: Kind           // drives an optional leading glyph/tint

    enum Kind { case new, improved, fixed, note }
}

/// The bundled, curated changelog. Edited each release (add a new entry at
/// the TOP). This is the single source of truth for both the auto-pop and the
/// About → What's New window.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.4.22",
            date: /* 2026-07-02 */ nil,
            highlights: [
                Highlight(text: "…", kind: .new),
                Highlight(text: "…", kind: .fixed),
            ]
        ),
        // older entries below…
    ]

    /// Entry whose `version` matches, if any.
    static func entry(for version: String) -> ChangelogEntry? {
        entries.first { $0.version == version }
    }
}
```

`Kind` is optional polish — if you want to match CleanShot's plain em-dash bullets
exactly, every highlight can just be `.note` and the view renders a uniform bullet. The
enum leaves room for New/Improved/Fixed tags later without a data migration.

If you prefer editing JSON over Swift, ship `changelog.json` in the bundle and decode it
in `Changelog`'s initializer; the rest of the plan is unchanged. Swift-array is simplest
and gives compile-time safety, so it's the default recommendation.

## 6. Pure decision logic

```swift
// Zerro/WhatsNew/WhatsNewPolicy.swift

enum WhatsNewPolicy {
    /// The outcome of a launch-time evaluation.
    enum Decision: Equatable {
        case present(version: String)   // auto-pop for this version
        case seedOnly(version: String)  // first-ever launch: record, don't show
        case none                        // nothing changed / suppressed
    }

    /// Pure decision — all inputs injected, no Bundle/Defaults reads here.
    static func decide(
        current: String,
        lastSeen: String?,
        autoShowEnabled: Bool,
        onboardingComplete: Bool,
        hasEntry: Bool
    ) -> Decision {
        guard let lastSeen else { return .seedOnly(version: current) }   // fresh install
        guard current != lastSeen else { return .none }                  // unchanged
        guard autoShowEnabled, onboardingComplete, hasEntry else { return .none }
        return .present(version: current)
    }
}
```

Both `.present` and `.seedOnly` cause the caller to write `lastSeen = current`. `.none`
also bumps `lastSeen` to `current` when `current != lastSeen` but auto-show was
suppressed (checkbox off / no entry), so a suppressed version isn't re-evaluated forever
— the caller handles that bump; keeping it out of the pure function keeps `decide`
side-effect-free and easy to test. (Alternatively fold it in as a 4th case; either is
fine — the doc's test matrix in §11 assumes the caller does the bump.)

## 7. Preferences additions

In `Preferences/PreferencesStore.swift`, add two things following the exact existing
pattern (stringly-typed key in `Keys`, stored property with `didSet` persistence,
initialized in `init`):

```swift
// Keys
static let showWhatsNewOnUpdate     = "vf.whatsNew.showOnUpdate"
static let lastSeenWhatsNewVersion  = "vf.whatsNew.lastSeenVersion"
```

```swift
/// Footer checkbox — "Show changelog after each update". Default ON (opt-out),
/// so users see the first post-adoption changelog. Use object(forKey:) so an
/// unset key falls back to true rather than UserDefaults' false-for-missing.
var showWhatsNewOnUpdate: Bool {
    didSet { defaults.set(showWhatsNewOnUpdate, forKey: Keys.showWhatsNewOnUpdate) }
}

/// The newest version whose What's New the user has already seen (or that was
/// silently seeded on first launch). nil = never recorded. NOT resettable —
/// wiping it on "Reset to Defaults" would re-pop the changelog on next launch.
var lastSeenWhatsNewVersion: String? {
    didSet {
        if let lastSeenWhatsNewVersion {
            defaults.set(lastSeenWhatsNewVersion, forKey: Keys.lastSeenWhatsNewVersion)
        } else {
            defaults.removeObject(forKey: Keys.lastSeenWhatsNewVersion)
        }
    }
}
```

Init:

```swift
self.showWhatsNewOnUpdate =
    defaults.object(forKey: Keys.showWhatsNewOnUpdate) as? Bool ?? true
self.lastSeenWhatsNewVersion =
    defaults.string(forKey: Keys.lastSeenWhatsNewVersion)
```

Resettable set: add **only** `showWhatsNewOnUpdate` to `Keys.resettable` (so "Reset to
Defaults" turns the checkbox back on). Deliberately **exclude**
`lastSeenWhatsNewVersion` — like `localModelVersion`, it tracks real history and a reset
shouldn't cause a spurious re-pop. Mirror this in `resetToDefaults()` by setting
`showWhatsNewOnUpdate = true` and leaving `lastSeenWhatsNewVersion` untouched.

## 8. The window scene + chrome

New `Zerro/Surfaces/WhatsNew/WhatsNewScene.swift`, a near-copy of `FeedbackScene.swift`:

```swift
enum WhatsNewScene {
    static let windowID = "whats-new"
    static let preferredWidth: CGFloat  = 520
    static let preferredHeight: CGFloat = 560
}

extension View {
    /// Chromeless, fixed-size, dark surface bleeding under the traffic lights —
    /// same treatment as applyFeedbackWindowChrome(), reusing WindowConfigurator.
    func applyWhatsNewWindowChrome() -> some View { /* copy of feedback chrome */ }
}
```

Reuse the shared `WindowConfigurator` (defined alongside the Settings chrome, already
used by Feedback). Keep the height fixed and let the entry list scroll inside — the
window is a fixed panel, not a resizable document (matches the screenshot).

## 9. The window view

New `Zerro/Surfaces/WhatsNew/WhatsNewView.swift`. Layout maps 1:1 to the CleanShot
screenshot, retinted with Zerro tokens (`Color.vfPanelBackground`, `Color.vfCardBackground`,
`Color.vfTextPrimary/Secondary`, `Color.vfBrandAccent`, `VFSpacing`, `VFRadius`):

```
┌───────────────────────────────────────────────┐
│  ● ● ●   New in Zerro                          │  ← title, under traffic lights
│                                                 │
│  ┌── ScrollView ──────────────────────────┐    │
│  │  1.4.22                    Jul 2, 2026  │    │  ← version (bold) + date (tertiary)
│  │    —  <highlight>                        │    │
│  │    —  <highlight>                        │    │
│  │                                          │    │
│  │  1.4.21                                  │    │
│  │    —  <highlight>                        │    │
│  │    …                                     │    │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  ☑ Show changelog after each update    [Close] │  ← footer: checkbox + primary button
└───────────────────────────────────────────────┘
```

Key details:

- **Title row**: `Text("New in Zerro")` at ~15–16pt semibold, `vfTextPrimary`,
  inset so it clears the floating traffic lights (top padding, matching Feedback's
  `.padding(VFSpacing.xl)`).
- **Scroll body**: `ScrollView { LazyVStack(alignment: .leading, spacing: VFSpacing.xl) }`
  iterating `Changelog.entries`. Each entry = a version header row
  (`Text(entry.version)` bold ~20pt + right-aligned `Text(date)` in `vfTextTertiary`),
  then each `Highlight` as an em-dash bullet: an em-dash / small glyph in
  `vfTextTertiary` + wrapping `Text` in `vfTextSecondary`, `.fixedSize(horizontal:
  false, vertical: true)` so long lines wrap like the screenshot.
- **Auto-scroll to top**: default scroll position shows the newest entry first (entries
  are already newest-first), so nothing extra needed for the auto-pop case.
- **Footer**: an `HStack` with a `Toggle("Show changelog after each update",
  isOn: $preferences.showWhatsNewOnUpdate)` on the left (bound straight to the store, so
  it's live everywhere) and a primary "Close" button on the right using the same filled
  `vfBrandAccent` treatment as Feedback's send button. Use the existing checkbox/toggle
  style from `SettingsCard.swift` (see the custom `Toggle` style used across settings
  sections) so the check matches app styling rather than the raw macOS checkbox.
- **Environment**: inject `PreferencesStore` (for the toggle) via the scene, exactly as
  Settings/Feedback inject their environments.
- **Dismiss**: Close calls `dismissWindow(id: WhatsNewScene.windowID)`.
- Empty-state guard: if `Changelog.entries` is ever empty (shouldn't happen in prod),
  render a single "You're up to date" line rather than a blank scroll area.

## 10. App wiring (`ZerroApp.swift`)

**(a) Declare the scene** next to the Feedback/Onboarding windows. Follow the Onboarding
pattern so it can auto-present at launch:

```swift
Window("Zerro — What's New", id: WhatsNewScene.windowID) {
    WhatsNewView()
        .dockIconVisibility(windowID: WhatsNewScene.windowID)
        .disablesWindowRestoration()
        .environment(preferences)
}
.windowStyle(.hiddenTitleBar)
.windowResizability(.contentSize)
.restorationBehavior(.disabled)
.defaultLaunchBehavior(Self.shouldPresentWhatsNewOnLaunch ? .presented : .suppressed)
.defaultSize(width: WhatsNewScene.preferredWidth, height: WhatsNewScene.preferredHeight)
```

`Self.shouldPresentWhatsNewOnLaunch` is computed once at `App.init` (like
`shouldPresentOnboardingOnLaunch`) from `WhatsNewPolicy.decide(...)` returning
`.present`. It reads `CFBundleShortVersionString`, the two prefs, and
`onboarding.hasCompletedOnboarding` — all available at init.

**(b) In `applicationDidFinishLaunching`**, mirror the onboarding activation + reconcile
`lastSeen`:

```swift
let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
let decision = WhatsNewPolicy.decide(
    current: current,
    lastSeen: preferences.lastSeenWhatsNewVersion,
    autoShowEnabled: preferences.showWhatsNewOnUpdate,
    onboardingComplete: onboarding.hasCompletedOnboarding,
    hasEntry: Changelog.entry(for: current) != nil
)
switch decision {
case .present:
    NSApp.activate(ignoringOtherApps: true)   // scene already auto-mounted
    preferences.lastSeenWhatsNewVersion = current
case .seedOnly:
    preferences.lastSeenWhatsNewVersion = current
case .none:
    // still move the marker forward if the version changed but was suppressed,
    // so a suppressed version isn't re-checked forever.
    if preferences.lastSeenWhatsNewVersion != current {
        preferences.lastSeenWhatsNewVersion = current
    }
}
```

The `shouldPresentWhatsNewOnLaunch` flag (init-time) and the runtime decision use the
same pure function with the same inputs, so they agree.

**(c) Manual-open plumbing.** The About row needs to open this window even after launch.
Add an `openWindow` capture registrar mirroring the existing
`OnboardingOpenerRegistrar` / `SettingsOpenerRegistrar` (mounted in the `MenuBarExtra`
label, the one always-present view) → stores a `requestOpenWhatsNew` closure on
`AppDelegate`. Or, simpler: the About row already lives inside the Settings window, which
has an `@Environment(\.openWindow)` in scope, so `SendFeedbackRow`'s exact approach works
without a registrar:

```swift
NSApp.activate(ignoringOtherApps: true)
openWindow(id: WhatsNewScene.windowID)
```

Use the in-Settings `openWindow` approach (no registrar needed) since the only manual
entry point is the About page.

## 11. About page integration (`AboutSupportSection.swift`)

Add a `WhatsNewRow` between `VersionRow` and `CheckForUpdatesRow`, modeled on
`SendFeedbackRow` (a `SettingsNavigationRow`):

```swift
SettingsSection("About & Support") {
    VersionRow()
    SettingsRowDivider()
    WhatsNewRow()          // ← new
    SettingsRowDivider()
    CheckForUpdatesRow()
    SettingsRowDivider()
    CopyDiagnosticInfoRow()
    SettingsRowDivider()
    SendFeedbackRow()
}
```

```swift
private struct WhatsNewRow: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SettingsNavigationRow(
            label: "What's New",
            description: "See the latest changes and improvements."
        ) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WhatsNewScene.windowID)
        }
    }
}
```

Manual open ignores the version check and the checkbox — it always shows the full list.

## 12. Edge cases

- **First-ever install**: `lastSeen == nil` → `.seedOnly` → record `current`, show
  nothing. Onboarding owns the first-run experience.
- **Checkbox off**: no auto-pop; `lastSeen` still advances; About → What's New still
  works.
- **Missing notes for current version**: `hasEntry == false` → no pop (defensive), marker
  still advances. Catch this in review via the release checklist.
- **Downgrade** (e.g. QA installs an older build): `current != lastSeen` but we only ever
  move `lastSeen` forward to `current` on handling, and the auto-pop shows the current
  (older) version's notes only if it changed — acceptable for QA; not a real user path.
- **Staging build** (`#if STAGING`): decide whether staging should pop. Recommend gating
  the auto-pop with the same staging awareness other surfaces use, or simply letting it
  run (it reads the staging bundle version). Low stakes — call it out in review.
- **Xcode preview**: guard any launch-time work with `ZerroApp.isRunningInXcodePreview`
  (already used by `UpdaterViewModel`) so previews don't try to auto-present.
- **Window retained across close/reopen**: like Feedback, the scene retains `@State`.
  No per-open reset needed here since the view is read-only (no form state), but keep the
  scroll starting at top.

## 13. Analytics

Optional but cheap, matching existing `Analytics.capture(...)` usage:

- `whats_new_shown` with `{ version, trigger: "auto" | "manual" }` on window appear.
- `whats_new_autoshow_toggled` with `{ enabled }` when the checkbox flips.

Respect the existing analytics opt-out; route through the same `Analytics` layer as
elsewhere (no new PII — version string only).

## 14. Testing

Unit tests (in `ZerroTests`, alongside the existing `UpdateWindowPolicy` tests) for the
pure `WhatsNewPolicy.decide` matrix:

| current | lastSeen | autoShow | onboardingDone | hasEntry | expected |
|---|---|---|---|---|---|
| 1.4.22 | nil | true | true | true | `.seedOnly` |
| 1.4.22 | 1.4.22 | true | true | true | `.none` |
| 1.4.22 | 1.4.21 | true | true | true | `.present` |
| 1.4.22 | 1.4.21 | false | true | true | `.none` |
| 1.4.22 | 1.4.21 | true | false | true | `.none` |
| 1.4.22 | 1.4.21 | true | true | false | `.none` |
| 1.4.21 | 1.4.22 | true | true | true | `.none` (downgrade) |

Plus a `PreferencesStore` test (in-memory `UserDefaults`) asserting the default of
`showWhatsNewOnUpdate == true`, round-trip of `lastSeenWhatsNewVersion`, and that
`resetToDefaults()` re-enables the checkbox but leaves `lastSeenWhatsNewVersion`
untouched.

Manual QA:

1. Set `lastSeenWhatsNewVersion` to an older value in defaults, relaunch → window pops.
2. Uncheck the box, relaunch on a new version → no pop; About → What's New still opens.
3. Fresh defaults (delete both keys) → no pop on first launch; second launch (no version
   change) → no pop.
4. Visual: window matches the screenshot layout in Zerro branding; long bullets wrap;
   list scrolls; Close dismisses.

`reset-for-testing.sh` already exists at the desktop root — extend it to clear the two
new keys so QA can re-trigger cleanly.

## 15. File-by-file change list

New:

- `apps/desktop/Zerro/WhatsNew/Changelog.swift` — data model + bundled entries + provider.
- `apps/desktop/Zerro/WhatsNew/WhatsNewPolicy.swift` — pure launch-decision logic.
- `apps/desktop/Zerro/Surfaces/WhatsNew/WhatsNewScene.swift` — window id, size, chrome.
- `apps/desktop/Zerro/Surfaces/WhatsNew/WhatsNewView.swift` — the window UI.
- `apps/desktop/ZerroTests/WhatsNewPolicyTests.swift` — decision matrix.

Edited:

- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` — 2 keys, 2 props, init,
  resettable set, `resetToDefaults()`.
- `apps/desktop/Zerro/ZerroApp.swift` — new `Window` scene, `shouldPresentWhatsNewOnLaunch`,
  launch-time reconcile in `applicationDidFinishLaunching`.
- `apps/desktop/Zerro/Surfaces/Settings/Sections/AboutSupportSection.swift` — `WhatsNewRow`.
- `apps/desktop/reset-for-testing.sh` — clear the two new defaults keys.
- `docs/DEPLOY-RUNBOOK.md` — add "update Changelog.swift" to the release checklist.
- Add the new files to the Xcode project (`Zerro.xcodeproj`) target membership.

## 16. Suggested build order

1. `Changelog.swift` + `WhatsNewPolicy.swift` + tests (pure, no UI) — lock the logic.
2. `PreferencesStore` additions + tests.
3. `WhatsNewScene` + `WhatsNewView` with a `#Preview` (build the visuals in isolation,
   like Feedback's preview).
4. Wire the About row (easiest way to manually open + iterate on the view).
5. Wire the launch auto-present + reconcile in `ZerroApp`.
6. QA pass with `reset-for-testing.sh`, then seed the first real `Changelog` entries.

## 17. Future / not in scope

- Remote-fetched changelog behind the same `WhatsNewView` (swap the provider only).
- Per-highlight New/Improved/Fixed tags (the `Highlight.Kind` enum already reserves this).
- Deep-linking a specific version, or a "full history" web page link in the footer.
