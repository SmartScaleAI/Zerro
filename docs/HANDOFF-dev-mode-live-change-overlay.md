# Handoff: Dev-Mode Live-Change Overlay + Before/After Swipe

## Goal

Make a Dev Mode agent run feel **alive on the page**, not buried in the pill.
Two coordinated pieces, both sourced from data Zerro **already has**:

1. **Live-change overlay** — while the coding agent is editing, paint a
   translucent **Dev Mode green** (`#34E27A`, `Color.vfDevAccent`) wash with a
   small floating label (`editing the CTA…`) over the on-screen region the user
   *pointed at* for each change. The wash is anchored to the resolved deixis
   anchors, so the change is visually tied to the thing they gestured at while
   narrating.
2. **Before/after swipe** — capture a screenshot of the recorded region **before**
   the agent runs; when the run finishes, the result card offers **Compare**,
   which raises a swipe divider over the captured region: left of the divider =
   the frozen *before* screenshot, right = the live, hot-reloaded *after* page.

This is the page-side analogue of the existing pulsing edge ring
(`DevRingWindowController`) and green recording cursor
(`DevCursorWindowController`) — same "Dev Mode is happening right now" language,
same overlay-window pattern, same opt-out discipline. **It adds zero new
permissions and zero new detection** — it re-presents data the deixis pipeline
and the selection already produced.

---

## Why this is cheap (read before coding)

Everything the overlay needs is **already on `AppState` at dispatch time**:

- `AppState.devResolvedAnchors: [ResolvedDeixisAnchor]`
  (`@ObservationIgnored`, AppState ~line 614) — each carries
  `candidate.point` (a `DeixisPoint`, normalized **[0,1], top-left, frame
  space**) and `clientConfidence`. See `DevAnchorPipeline.swift` /
  `DeixisResolver.swift`.
- `AppState.devModelAnchors: [DevAnchor]` (AppState ~line 618) — each carries
  `label` (verbatim visible text, e.g. `"Get started"`), `kind`, `region`
  (`header|nav|hero|sidebar|main|footer`), `currentState`, `modelConfidence`,
  paired to a resolved anchor by `refIndex`.
- `AppState.activeSelection: SelectionRect?` (AppState ~line 532) — the recorded
  region. `SelectionRect.rect` is a `CGRect` in **global AppKit screen space
  (points, bottom-left origin)**; `SelectionRect.screenLocalizedName` resolves
  the `NSScreen`. See `SelectionRect.swift`.

So a labeled wash is: **map each anchor's normalized point → a global screen
point** (invert the exact crop/flip the selector used — the math is already
written in `RecordingFocusWindowController.windowLocalRect`, just inverted) →
draw a fixed-size rounded-rect wash centered there, sized by `region`, labeled
from `DevAnchor.label`.

**Key honest constraint:** an anchor is a **point, not a bounding box.** v1 does
NOT attempt pixel-perfect element outlines. A region-sized wash centered on the
point reads correctly as "this area is changing" and degrades gracefully. Do not
add live OCR / DOM reading to tighten this — that is a deliberate non-goal for
v1 (noted at the end).

---

## Scope decisions (settled — do not re-litigate)

- **Targeting = reuse deixis anchors.** Point-centered, region-sized washes from
  `devResolvedAnchors` + `devModelAnchors`. NO new detection, NO live OCR.
- **Confidence gate.** Only draw a wash for an anchor whose **combined**
  confidence is at least medium. Reuse the existing combiner —
  `AppState.combinedConfidence(_:)` (AppState ~line 3048) — with the same
  threshold family the dispatch path uses. A low-confidence anchor draws
  **nothing** (never point the wash at a guess).
- **Generic fallback.** If **no** anchor is drawable (none, or all below
  threshold), show a single soft full-region green edge-glow plus one rotating
  label driven by the agent substatus, so the page never looks dead during a
  run. (This is the only state that does not depend on anchors.)
- **Label source.** `DevAnchor.label` → `editing the {label}…`; when `label` is
  nil (bare icon/image), fall back to the `region` → `editing the {region}…`.
- **Sequencing v1 = order-based.** Light washes in anchor order as the agent
  streams `editing(file:)` events. Filename↔anchor fuzzy-matching is a later
  refinement (noted at the end), NOT v1.
- **Compare = swipe slider** over the captured region (before screenshot vs live
  after), draggable divider. Press-to-toggle and side-by-side thumbnails were
  considered and rejected for v1.
- **One Appearance toggle**, default **ON**, gating BOTH pieces — mirror
  `pulsingRingEnabled` / `devCursorEnabled` exactly.

---

## Architecture — mirror the existing overlay controllers

Study and closely mirror these; the new controller is intentionally parallel:

- **`apps/desktop/Zerro/Surfaces/RecordingFocus/RecordingFocusWindowController.swift`**
  — THE template. Borderless, transparent, click-through, self-observing
  `AppState` loop, the `windowLocalRect` global↔window-local conversion (the
  exact Y-flip you need, inverted), the `onOrderIn`-zoom-suppressing fade-in
  (`CATransaction` + `display()` + deferred alpha ramp). Copy this structure.
- **`apps/desktop/Zerro/Surfaces/DevRing/DevRingWindowController.swift`** — the
  Dev-Mode lifecycle observation (`devRingActive` derived flag), multi-display
  (one window per `NSScreen`, rebuild on `didChangeScreenParametersNotification`),
  and the **performance discipline** (render the wash/glow once, animate only
  layer opacity via `repeatForever`; never animate blur/shadow radius — the web
  version of this effect pinned a helper at ~50% CPU). The overlay can be up for
  minutes; idle cost must stay near-zero.
- **`apps/desktop/Zerro/AppState.swift`** — `devRingActive` (~line 970) and
  `devCursorActive` (~line 988) are the exact pattern for the new derived flag.
  `recordingIsDevMode` resets to false on teardown (~line 1326). Dispatch is
  driven from ~line 2898; the dev pill substatus arrives at the `.running(let
  substatus)` case (~line 3013); the run resolves in `applyDevOutcome(_:)`
  (~line 3211).
- **`apps/desktop/Zerro/Services/Dev/DevAgentRunner.swift`** —
  `DevRunSubstatus` (`readingFiles`, `editing(file:)`, `running`) and
  `DevAgentEvent` are what the overlay sequences against.
- **`apps/desktop/Zerro/Preferences/PreferencesStore.swift`** —
  `pulsingRingEnabled` / `devCursorEnabled` are the exact pattern for the new
  pref (Keys enum, stored property, UserDefaults backing, default ON).
- **`apps/desktop/Zerro/Surfaces/Settings/Sections/AppearanceSection.swift`** —
  add the toggle directly below "Recording Cursor Highlight".
- **`apps/desktop/Zerro/Surfaces/Pill/ArtifactCardView.swift`** — the Dev Mode
  result card where the **Compare** affordance is added.
- **`apps/desktop/Zerro/DesignSystem/Colors.swift`** — use `Color.vfDevAccent`
  (`#34E27A`) for everything green. Introduce NO new color.
- **`apps/desktop/Zerro/ZerroApp.swift`** — where `DevRingWindowController` /
  `DevCursorWindowController` are instantiated and held; instantiate the new
  controller the same way (same lifetime, passed `appState` + `preferences`).

---

## Part 1 — Live-change overlay

### 1.1 New AppState derived flag

Mirror `devRingActive` exactly — the overlay should be on for the SAME window
the ring is (the agent-run window), so it rides every dispatch/complete/cancel/
revert path for free:

```swift
/// True while the live-change overlay should be shown: a Dev Mode coding-agent
/// run is actively in progress (the `.devAgentDispatching`/`.devAgentRunning`
/// window). Single source of truth for `DevChangeOverlayWindowController`.
/// Deriving it from the run state means every dispatch/complete/cancel/revert
/// path drives it for free — same as `devRingActive`.
var devChangeOverlayActive: Bool {
    devRingActive   // identical condition to the ring; reuse it
}
```

If `devRingActive` is private/internal-only, expose the same underlying
condition. Do **not** invent a new lifecycle source — the ring already nailed
"true exactly during the run."

### 1.2 New preference

In `PreferencesStore`, copy the `devCursorEnabled` shape:
- `Keys.liveChangeOverlayEnabled = "liveChangeOverlayEnabled"`.
- `var liveChangeOverlayEnabled: Bool`, UserDefaults-backed, **default ON**.

### 1.3 The wash model — anchors → screen rects

New small pure type + builder (fully unit-testable, no AppKit), e.g.
`apps/desktop/Zerro/Services/Dev/DevChangeWash.swift`:

```swift
/// One green wash to draw during a run: where (global screen rect), what label,
/// and the anchor order it should light up in.
struct DevChangeWash: Equatable, Sendable {
    let rect: CGRect        // global AppKit screen space, points (bottom-left)
    let label: String       // "the CTA", "the hero" — the "editing {label}…" infix
    let order: Int          // anchor index → reveal order
}
```

Builder responsibilities:

1. **Pair** `devResolvedAnchors` with `devModelAnchors` by `refIndex` (positional
   fallback when the model didn't echo `ref`, same as the dispatch path).
2. **Gate** by `combinedConfidence(_:)` ≥ the medium threshold; drop the rest.
   Note its real semantics (AppState ~line 3048): it returns
   `min(client, modelConfidence)` **only when** a model anchor paired this
   reference; when the model returned no anchor for it, it returns the **client
   signal alone** (it does NOT `min` against a missing model value). So a
   high-client dwell with no model echo still passes — that is intended.
3. For each surviving anchor, **map the normalized point → global screen point**:

   ```
   // point: normalized [0,1], TOP-LEFT, in frame (= selection) space.
   // rect:  selection.rect, global AppKit, BOTTOM-LEFT origin.
   screenX = rect.minX + point.x * rect.width
   screenY = rect.minY + (1 - point.y) * rect.height   // single Y-flip
   ```

   This is the inverse of `RecordingFocusWindowController.windowLocalRect`'s
   flip. **Verify against that function** — getting the flip wrong points every
   wash at the vertically-mirrored spot.

4. **Size** the wash by `DevAnchor.region` / `kind` (centered on the screen
   point), clamped to stay within `selection.rect`. Suggested starting sizes
   (fractions of the selection, tune in review):
   - `header` / `nav` / `footer`: ~50% w × ~16% h
   - `hero`: ~55% w × ~26% h
   - `sidebar`: ~22% w × full h
   - `button` / `link` / `icon` / `input` (and `kind`-led small elements):
     ~26% w × ~12% h
   - `main` / `container` / unknown: ~40% w × ~18% h
5. **Label** = `DevAnchor.label ?? region.rawValue`. The view renders
   `editing \(label)…`.

If the result is empty → the controller shows the **generic fallback** (full-
region edge-glow + rotating substatus label) instead of washes.

### 1.4 New overlay controller

New file:
`apps/desktop/Zerro/Surfaces/DevChangeOverlay/DevChangeOverlayWindowController.swift`.

Responsibilities, copied structurally from `RecordingFocusWindowController` +
`DevRingWindowController`:

- `shouldShow` = `appState.devChangeOverlayActive &&
  preferences.liveChangeOverlayEnabled`.
- Observation `Task` loop tracking `devChangeOverlayActive`,
  `liveChangeOverlayEnabled`, `activeSelection`, AND the current run substatus
  (so the lit wash advances as `editing(file:)` events arrive). Flipping the
  pref off mid-run hides immediately; back on re-shows.
- **One overlay window**, sized to the selection's `NSScreen.frame` (resolve via
  `screenLocalizedName` → intersecting screen → main, exactly like
  `RecordingFocusWindowController.resolveScreen`). The washes live in that
  window's top-left view space (convert each `DevChangeWash.rect` with the same
  `windowLocalRect` helper). Rebuild on `didChangeScreenParametersNotification`
  while active.
- Window config identical to RecordingFocus/DevRing: borderless,
  `isOpaque = false`, clear bg, no shadow, `animationBehavior = .none`,
  `ignoresMouseEvents = true` (purely decorative — must NEVER eat clicks meant
  for the app being edited), `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]`, excluded from windows menu, not released
  when closed. **Level: `.floating`** — above the edited app content, but the
  pill stays above this (pill sits one above `.floating`); coexists with the
  `.screenSaver` ring (the ring hugs the screen edge, this sits on content, no
  overlap). Confirm the pill still renders above; if not, keep the overlay below
  the pill's level.
- Fade the whole window alpha in/out (~0.18–0.25s) using the
  `CATransaction`/`display()`/deferred-ramp trick from
  `RecordingFocusWindowController.show` to avoid the Core Animation `onOrderIn`
  zoom.

### 1.5 The view

`DevChangeOverlayView` (SwiftUI, hosted like `RecordingFocusView`):

- Renders each wash as a rounded rect (`RoundedRectangle(cornerRadius: ~7)`)
  filled `Color.vfDevAccent.opacity(~0.16)` with a `~1.5pt`
  `Color.vfDevAccent.opacity(~0.85)` stroke; a small label chip above-left
  (`Color.vfDevAccent` bg, dark text, `editing {label}…`).
- The **currently-active** wash (per the substatus order) gets a subtle pulsing
  **opacity** overlay (a second stroke whose **opacity** animates — NEVER blur/
  shadow radius; flatten with `.drawingGroup()`, per the DevRing perf note).
  Already-done washes can dim or drop; not-yet-started washes render faint or
  hidden. Keep it cheap.
- **Generic fallback** state: a single full-bounds inset green glow (rendered
  once, opacity-pulsed) + one centered label chip showing the live substatus
  (`reading files…` / `editing…` / `working…`).
- Crucially: this is the same green family as the ring/cursor; do not introduce a
  second accent.

### 1.6 Sequencing (v1)

Drive `order` from substatus: maintain a "current step" index that advances each
time a new `editing(file:)` event arrives (cap at the last wash), so washes light
roughly in step with the agent's progress. When the agent reports `readingFiles`
or `running` (not editing), keep the current wash. This is intentionally
order-based, not filename-matched. (Filename↔label matching = later.)

### 1.7 Wire it up in ZerroApp

Instantiate and retain `DevChangeOverlayWindowController` wherever
`DevRingWindowController` is created, same lifetime, passing `appState` +
`preferences`.

---

## Part 2 — Before/after swipe

### 2.1 Capture the "before" frame

The compare needs a still of the region as it looked **before** the agent
touched anything. Capture it at **checkpoint time** (right before dispatch), of
`activeSelection.rect`, using the Screen-Recording permission that is **already
granted** (no new permission):

- Prefer **`SCScreenshotManager`** (ScreenCaptureKit, already a dependency via
  `RecordingSession`) cropped to the region; fall back to
  `CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, .bestResolution)`
  for the same rect. Capture at native Retina scale.
- Do this on the dispatch path, just **before** `devDispatchCoordinator.dispatch`
  is called (AppState ~line 2898), guarded by `recordingIsDevMode`. Keep it
  best-effort: a failed capture simply disables Compare for that run (the rest of
  the result card is unchanged).
- Store the resulting `CGImage`/`NSImage` (+ the `rect` and `screenLocalizedName`
  it was taken in) on the dev-run result so `applyDevOutcome` can hand it to the
  result card. Add a field to the success payload (e.g. extend
  `DevDispatchCoordinator.Success`, or carry it alongside in AppState — pick the
  smaller change; AppState-side is fine since the capture happens in AppState,
  not the coordinator).

**Privacy note:** this still is **in-memory only**, lives for the lifetime of the
result card, and is dropped when the card is dismissed/replaced. Never written to
disk; never sent anywhere. (Consistent with §14.5 / the local-first posture.)
State this in the file header.

### 2.2 Result-card "Compare" affordance

In `ArtifactCardView.swift` (Dev Mode result state — the `N files changed (+x −y)
· [Revert] [Done]` card):

- When a before-frame exists, add a **Compare** control (button/icon —
  `arrows-horizontal` language) next to Revert/Done.
- Tapping it raises the swipe overlay (§2.3). Tapping again (or a close affordance
  on the overlay) dismisses it. Revert/Done remain available.
- When no before-frame exists, omit Compare entirely (no disabled state).

### 2.3 The swipe overlay

New file:
`apps/desktop/Zerro/Surfaces/DevChangeOverlay/DevCompareWindowController.swift`
(can live beside the live overlay; they're siblings, never on screen at the same
time — live overlay is during the run, compare is after).

- Borderless window pinned to **`activeSelection.rect`** on its `NSScreen`
  (same `resolveScreen` + `windowLocalRect` math). NOT full-screen — it covers
  exactly the captured region, like a content patch.
- Renders the **before screenshot** scaled to fill the region. A draggable
  vertical **divider** clips the before image: left of the divider shows the
  frozen before; right of the divider is **transparent**, so the live,
  hot-reloaded page underneath shows through as the "after". (No need to capture
  "after" — it's the real page.)
- The window is **click-through everywhere EXCEPT the divider handle**
  (`ignoresMouseEvents = true` on the window, with the divider handle as a small
  interactive subview/tracking area — or invert: a mostly-passthrough content
  view that only hit-tests the handle). The user drags the handle left/right to
  reveal. Label the two sides faintly (`before` / `after`) in
  `Color.vfDevAccent`.
- Divider + handle use `Color.vfDevAccent`. Fade in/out like the other overlays.
- Dismiss on: tapping Compare again, a close button on the overlay, Revert, Done,
  or the result card being dismissed/replaced. Must never outlive the card.

---

## Lifecycle safety (the #1 risk — make it bulletproof)

Mirror the discipline the `DevCursor` handoff demanded for hiding the system
cursor. Neither overlay may ever be orphaned on screen.

- **Live overlay** must disappear on EVERY run-end path: `done`, `failed`,
  `cancelled`, app quit, and Revert. Deriving `devChangeOverlayActive` from
  `devRingActive` gives this for free (the ring already proved it). Add
  belt-and-suspenders teardown in `deinit` and on
  `applicationWillTerminate`/app termination, exactly like the other overlay
  controllers.
- **Compare overlay** is tied to the result card's lifetime: it must close when
  the card is dismissed, when Revert runs (the "after" page is about to change
  back — keeping a stale before/after split would be misleading), and on quit.
- **Coexistence:** the pulsing ring, the green cursor (recording only — never
  during the run, so no conflict with the live overlay), and these two overlays
  must not fight. All green = `Color.vfDevAccent`. The live overlay sits on
  content (`.floating`), the ring hugs the screen edge (`.screenSaver`); confirm
  the pill renders above the live overlay. Compare and the live overlay are never
  simultaneous.

---

## Tests

Follow the existing `apps/desktop/ZerroTests/` style (`DevRingActiveTests`,
`DevCursorActivationTests`, `DevModeTeardownSafetyTests`, the `Dev…` guard
tests). Add:

- **`DevChangeWashTests.swift`** (pure, the highest-value tests):
  - normalized point → global screen rect: a known `selection.rect` + a known
    `[0,1]` point yields the expected centered global rect, **with the Y-flip
    correct** (assert a top-left-ish point maps high on screen, i.e. large
    `maxY`, not mirrored). Include a non-origin, multi-display-style rect.
  - confidence gating: anchors below the medium threshold are dropped; at/above
    are kept; an empty/all-dropped input yields `[]` (→ fallback).
  - label fallback: `label` nil → uses `region`; both present → uses `label`.
  - region/kind → wash size mapping, and clamping so a wash never exceeds
    `selection.rect`.
  - refIndex pairing + positional fallback (mirror the dispatch-path pairing
    tests).
- **`DevChangeOverlayActivationTests.swift`**:
  - `devChangeOverlayActive` true only during the run window (false for idle, a
    non-dev recording, a normal recording, and after `done`/`failed`/`cancelled`).
  - `shouldShow` respects `liveChangeOverlayEnabled` (true only when both on).
  - sequencing: feeding a stream of `editing(file:)` substatuses advances the
    active-wash index and caps at the last wash.
- **Compare teardown** (extend `DevModeTeardownSafetyTests` or a new
  `DevCompareTeardownTests.swift`): the compare overlay closes on card-dismiss,
  Revert, and termination; the before-frame reference is released (no retain
  leak). Make the screenshot capture injectable (a closure returning an optional
  image, defaulting to the real `SCScreenshotManager`/`CGWindowListCreateImage`
  call) so the dispatch-path wiring is testable without touching the real
  display — mirror how `CursorTracker` injects `now`/`location`.

---

## Acceptance criteria

1. During a Dev Mode agent run (pref ON), each **medium-or-higher** anchor draws
   a green wash centered on the pointed-at region, labeled `editing {label}…`,
   lighting up roughly in step with the agent's `editing(file:)` events; the
   washes are correctly positioned (no vertical mirroring) and clipped to the
   captured region.
2. A run with **no** drawable anchor shows the generic full-region green glow +
   a rotating substatus label instead — the page never looks dead.
3. The live overlay is **click-through** (never intercepts clicks/keys for the
   app being edited) and disappears immediately and completely on every run-end
   path (done / failed / cancelled / quit / Revert), and on toggling the pref off
   mid-run; toggling back on re-shows it. Default ON.
4. When a run finishes and a before-frame was captured, the result card shows
   **Compare**; activating it raises a swipe divider over the captured region —
   dragging reveals the frozen *before* on one side and the live hot-reloaded
   *after* on the other — and dismisses cleanly (and on Revert/Done/quit). When
   no before-frame exists, Compare is absent (not disabled).
5. The before-frame is in-memory only, never written to disk or transmitted, and
   released when the card goes away.
6. No measurable idle CPU during a multi-minute run: the wash/glow is rendered
   once and only layer **opacity** animates (follow the DevRing perf note — never
   animate blur/shadow radius, no per-tick re-render).
7. The pulsing edge ring, the green recording cursor, the live overlay, and the
   compare overlay coexist without visual conflict, all sourced from
   `Color.vfDevAccent`.

---

## Watch out for

- **The Y-flip.** `point` is top-left frame space; `selection.rect` is bottom-left
  global. Get the single flip wrong and every wash targets the mirrored spot.
  Cross-check against `RecordingFocusWindowController.windowLocalRect`.
- **Point, not box.** Don't over-promise pixel-perfect outlines. Region-sized
  washes are the v1 contract; clamp them inside the selection.
- **Never eat clicks.** Both overlays are decorative; only the compare divider
  handle is interactive. `ignoresMouseEvents = true` on the windows; hit-test
  only the handle.
- **Never orphan an overlay.** Belt-and-suspenders teardown (deinit +
  app-termination), same bar as the DevCursor cursor-restore.
- **Don't capture "after."** The after side is the live page showing through a
  transparent cutout — capturing a second screenshot would go stale on hot-reload.
- **Multi-display + screen-config changes.** Resolve the selection's screen and
  rebuild on `didChangeScreenParametersNotification`, like the other overlays.
- **All green from `Color.vfDevAccent`.** No new hardcoded hex.
- **Keep the screenshot capture best-effort.** A capture failure disables Compare
  for that run; it must never fail the run or the result card.

---

## Files to create
- `apps/desktop/Zerro/Surfaces/DevChangeOverlay/DevChangeOverlayWindowController.swift`
- `apps/desktop/Zerro/Surfaces/DevChangeOverlay/DevCompareWindowController.swift`
- `apps/desktop/Zerro/Services/Dev/DevChangeWash.swift`
- `apps/desktop/ZerroTests/DevChangeWashTests.swift`
- `apps/desktop/ZerroTests/DevChangeOverlayActivationTests.swift`
- `apps/desktop/ZerroTests/DevCompareTeardownTests.swift` (or extend
  `DevModeTeardownSafetyTests.swift`)

## Files to edit
- `apps/desktop/Zerro/AppState.swift` — add `devChangeOverlayActive`; capture the
  before-frame on the dispatch path (~line 2898) guarded by `recordingIsDevMode`;
  carry it to `applyDevOutcome` (~line 3211) / the result card.
- `apps/desktop/Zerro/Preferences/PreferencesStore.swift` — add
  `liveChangeOverlayEnabled` key + property (default ON).
- `apps/desktop/Zerro/Surfaces/Settings/Sections/AppearanceSection.swift` — add
  the toggle below "Recording Cursor Highlight".
- `apps/desktop/Zerro/Surfaces/Pill/ArtifactCardView.swift` — add the Compare
  affordance to the Dev Mode result card.
- `apps/desktop/Zerro/ZerroApp.swift` — instantiate + retain the two new
  controllers alongside `DevRingWindowController` / `DevCursorWindowController`.
- (Optional) `apps/desktop/Zerro/Services/Dev/DevDispatchCoordinator.swift` — only
  if you choose to carry the before-frame through `Success` rather than alongside
  it in AppState.

---

## Out of scope (note for later, do NOT build now)

- **Filename↔anchor sync.** Fuzzy-match the streamed `editing(file:)` path to the
  anchor whose label/region it most likely corresponds to, for true per-edit
  highlighting instead of order-based.
- **Pixel-perfect element outlines** via live OCR or a browser-DOM read under the
  cursor. The deterministic "browser-assist" idea from `DEV-MODE-DESIGN.md` §11
  could later replace point-centered washes with real element rects.
- **Animated diff on the page** (e.g. morphing the before→after region) — the
  swipe is the v1 compare.
- **Non-git / window-target recordings** — same constraints as the rest of Dev
  Mode; the overlay follows `activeSelection`, so window-target follow-on-move has
  the same v1 limitation noted in `RecordingFocusWindowController`.
