# Area Selector Toolbar Walkthrough — Design + Build Plan

**Status:** Proposal / planning
**Feature:** First-run interactive walkthrough of the capture overlay's toolbar
**Owner:** Colin
**Last updated:** 2026-07-01

---

## 1. Goal

The first time a user opens the capture overlay, walk them through the five
controls on the floating toolbar, one at a time, so they understand what each
does before they record. Cover **only** these five controls, in this order:

1. **Mode switch** (Artifact | Dev)
2. **Model selector**
3. **Microphone**
4. **Coding agent settings** (Dev Mode only)
5. **Record button**

Nothing else (recording pill, result card, errors, credits, recovery) is in
scope for this walkthrough.

---

## 2. Grounding: what "the overlay" and "the toolbar" actually are

"The overlay" is the **Area Selector** — the dim-the-screen, drag-a-region
surface that appears before recording. Code lives in
`apps/desktop/Zerro/Surfaces/AreaSelector/`:

| File | Role |
|------|------|
| `AreaSelectorView.swift` (~2,436 lines) | All SwiftUI rendering, incl. the toolbar and its per-control geometry |
| `AreaSelectorState.swift` (~930 lines) | Observable state: mode, selection rect, hover flags, menu-open flags, selected model/mic |
| `AreaSelectorWindowController.swift` (~1,524 lines) | AppKit window, the mouse monitor that owns hover + hit-testing, and `present(...)` — the entry point |
| `SelectionRect.swift` | Small geometry helper |

The toolbar is rendered by `floatingToolbar(in:)`
(`AreaSelectorView.swift:1617`) and only appears once
`state.confirmableSelectionRect` is non-nil (i.e. there is a region to record).

> **React analogy.** Think of `AreaSelectorState` as a single store (like a
> `useReducer`/Zustand store), `AreaSelectorView` as the render layer that reads
> it, and `AreaSelectorWindowController` as an imperative event layer that
> handles the mouse and writes back to the store. The unusual part vs. web: the
> SwiftUI view tree is **hit-test-disabled**, so the view itself never receives
> clicks/hovers — the controller's global mouse monitor computes which control
> the cursor is over and sets flags on the store. This matters a lot below.

---

## 3. The five controls (exact code references)

All five are laid out left→right by `compactLayout(devMode:)`
(`AreaSelectorView.swift:423`). Each has a **static frame helper** that returns
the control's rect — these are the anchors the walkthrough will reuse.

| # | Control | Renderer | Frame helper (anchor) | Opens | Hover flag |
|---|---------|----------|-----------------------|-------|------------|
| 1 | Mode switch (Artifact `wand.and.stars` \| Dev `</>`) | `modeSwitchControl` :1852 | `modeArtifactSegmentFrame`, `modeDevSegmentFrame` | — (toggles mode) | `isModeArtifactHovered`, `isModeDevHovered` (state :679) |
| 2 | Model selector (sparkles + model name + chevron) | `modelButton` :1918 | `modelChipFrame` | `modelMenu` :1091 | `isModelChipHovered` (state :275) |
| 3 | Microphone (mic + chevron) | `iconButton(system:"mic")` :1655 | `micChipFrame` | `micMenu` :1193 | `isMicChipHovered` (state :171) |
| 4 | Coding agent settings (Dev only) | `devSettingsIconButton` :1662 | `devSettingsIconFrame` | `devSettingsMenu` :1235 | `isDevSettingsHovered` (state :681) |
| 5 | Record button (red pill) | `recordPill` :1668 | `recordButtonFrame` :553 | starts recording via `state.onConfirm` | none (carries its own label) |

### The one gotcha that shapes the whole design — control #4

The agent-settings icon is wrapped in `if devMode { … }` inside
`floatingToolbar` (:1660). It **does not exist in the toolbar in Artifact
mode** — in Artifact mode the Record button simply slides left into its place.

Also: flipping the Dev segment calls into the controller and sets
`preferences.devModeEnabled = on` (`AreaSelectorWindowController:912`), and the
selector seeds `isDevMode` from that preference on open (:141). So Dev Mode is a
**persistent user preference**, not an ephemeral toolbar state.

**Implication:** to point a coach-mark at control #4, Dev Mode must be active at
that moment. We have three options; see §5, step 4. The recommended one avoids
permanently changing the user's preference.

---

## 4. Chosen mechanism: coach-marks that reuse the existing tooltip layer

The overlay **already has a custom, controller-driven tooltip system** built
precisely because `.help` (SwiftUI's native tooltip) can't fire through the
hit-test-disabled tree:

- `toolbarTooltip(in:)` (`AreaSelectorView.swift:1683`) draws a small bubble
  with a downward caret, positioned above a control.
- It reads `tooltipInfo(forSelection:in:)` (:1758), which returns
  `(text, anchor: CGRect, maxWidth: CGFloat?)` for whatever control is hovered
  — e.g. it already returns `"Model"`, `"Microphone: <name>"`,
  `"Agent & project"`, `"Artifact"`, `"Dev Mode"`.

The walkthrough should **reuse this exact bubble renderer and the per-control
frame helpers**, but drive the selection from a *walkthrough step index* instead
of hover, and add three things a passive tooltip doesn't have: a dimming
spotlight, richer copy, and Next/Back controls.

> **React analogy.** This is a product tour like Intro.js / Shepherd.js /
> react-joyride. Those libraries dim the page, cut a "spotlight" hole around the
> target element, and float a tooltip with Next/Back. We're building the same
> thing, except our "DOM query for the target rect" is the existing static
> frame helpers, and our "tooltip component" is the existing bubble in
> `toolbarTooltip`.

### Why this over the alternatives

- **Reuses proven geometry.** The frame helpers already position bubbles
  correctly in both `.area` and `.fullScreen` layouts and are unit-tested
  (`AreaSelectorToolbarLayoutTests`). No new anchoring math.
- **Consistent look.** The walkthrough bubble is the same component users see on
  hover afterward — one visual language.
- **No native-tooltip dead end.** We already know `.help` doesn't work here, so
  a "hover tooltips only" approach would fight the framework.

### Trigger reconciliation

You chose **"on first real recording"** and later clarified **"when they open
the overlay for the first time."** These resolve to the same moment: the toolbar
is only visible once the overlay is open with a confirmable selection, and the
overlay is the step that precedes every real recording. So the trigger is:
**the first time the toolbar becomes visible.** (See §6 for the one wrinkle —
guaranteeing the toolbar is on screen.)

> If you'd instead prefer a fully scripted **demo pill** (tour runs on a
> stand-in, not the live overlay), that's a bigger build and would move the
> trigger to "right after onboarding." Flagging as an alternative; this plan
> assumes coach-marks on the real toolbar.

---

## 5. The walkthrough script (UX)

Five steps, matching the toolbar left→right. Each step: dim the overlay, spotlight
the target control's frame, show a bubble with a title + one-line explanation, and
a footer with `Back` / `Next` (right-aligned). There is no Skip button — the tour
is only five short steps; early exit is via `Esc` (see Navigation below). Step 5's
`Next` becomes `Got it`.

Draft copy (tighten later):

1. **Mode switch — "Choose what Zerro makes."**
   *Artifact turns your recording into a ready-to-use output, like a prompt or
   snippet. Dev Mode sends it straight to a coding agent to make the change
   for you.* Spotlight both segments; anchor the bubble to the whole switch.

2. **Model selector — "Pick the AI model."**
   *This model reads your screen and voice. Tap to switch. The current
   model's name shows here.* If `isModelPickerLocked` is true
   (trial), swap copy to: *Upgrade to choose a model.* Anchor: `modelChipFrame`.

3. **Microphone — "Choose your mic."**
   *Zerro records what you say while you point and talk. Pick the input device
   here.* Anchor: `micChipFrame`. (Consider a note if mic permission isn't
   granted yet.)

4. **Coding agent settings — "Set up your coding agent."** *(Dev Mode only)*
   *In Dev Mode, choose which agent runs and which project folder it edits.*
   Anchor: `devSettingsIconFrame`. **Handling visibility (pick one):**
   - **(A) Recommended — reveal, then restore.** When the walkthrough reaches
     step 4, if not already in Dev Mode, programmatically enter Dev Mode so the
     icon renders, but **do not persist** it: snapshot the user's
     `devModeEnabled` at walkthrough start and restore it on finish or early exit. (Needs
     a "set mode for display without writing the pref" path — see §8.)
   - **(B) Conditional step.** Only show step 4 if the user is already in Dev
     Mode; otherwise skip it. Simpler, but users who never toggle Dev Mode never
     learn the control exists.
   - **(C) Teach it on the mode switch.** Fold agent-settings into step 1's copy
     ("switching to Dev reveals agent settings") and drop the dedicated step.
     Fewest moving parts; least direct.

5. **Record button — "Start recording."**
   *Press this (or Return) to begin. You get up to 3 minutes.* Anchor:
   `recordButtonFrame`. On `Got it`, dismiss the walkthrough and leave the
   overlay live so they can actually record. (Optionally: don't auto-advance —
   let the real Record click both finish the tour and start recording.)

**Navigation & dismissal**
- Only two buttons: `Back` and `Next`. `Back` is hidden on step 1; `Next` reads
  `Got it` on step 5 and ends the tour.
- `Esc` dismisses the walkthrough early (marks it seen), and should **not** close
  the overlay while the tour is active (note: `Esc`-to-close-overlay behavior
  exists — see `claude-code-handoff-overlay-refocus-escape.md`; sequence carefully).
- Clicking the spotlighted control could advance that step (nice-to-have).

---

## 6. Trigger, first-run persistence, and making the toolbar visible

**Persistence.** Follow the existing `vf.*` UserDefaults convention (see
`PreferencesStore.Keys`, `PreferencesStore.swift:44`, and the onboarding keys in
`OnboardingState.swift:99`). Add one key:

```
vf.areaSelector.toolbarWalkthroughSeen   // Bool, default false
```

Register it in `PreferencesStore` alongside `devModeEnabled`, and add it to the
`resettable` array (`PreferencesStore.swift:125`) so QA can re-trigger it
(mirrors `reset-for-testing.sh`).

**When it fires.** In `AreaSelectorWindowController.present(...)`
(entry point invoked from `ZerroApp.swift:771`): after the overlay is shown, if
`hasCompletedOnboarding == true` **and** `toolbarWalkthroughSeen == false`,
start the walkthrough. Set `toolbarWalkthroughSeen = true` on **complete or
`Esc` dismiss** (not on mere appearance, so an interrupted first open still
teaches next time — match onboarding's resilience).

**The wrinkle — the toolbar must be on screen to anchor to it.** The toolbar
only renders once `confirmableSelectionRect` is non-nil. On a fresh overlay the
user hasn't dragged a region yet. Options:
- **Recommended:** for the walkthrough's first open, seed a default selection so
  the toolbar is immediately visible — the cleanest is `.fullScreen` mode (the
  whole display becomes the selection and the toolbar pins bottom-center via
  `fullScreenToolbarFrame`). Enter the tour in full-screen, teach the toolbar,
  then let the user drag a custom region afterward.
- Alternative: gate the tour to start only after the user makes their first drag.
  More authentic but the user might start recording before the tour runs.

---

## 7. Analytics

Reuse the `Analytics.captureOnce(_:key:)` pattern (see `OnboardingState.swift:160`)
so events fire once per install. Suggested events:

- `area_toolbar_walkthrough_started` (key `vf.analytics.toolbarWalkthroughStarted`)
- `area_toolbar_walkthrough_step_viewed` — property `step` = control name, deduped per step
- `area_toolbar_walkthrough_completed`
- `area_toolbar_walkthrough_dismissed` — early exit via `Esc`; property `step` = where they bailed

This mirrors the existing onboarding funnel (`onboarding_started` /
`_step_viewed` / `_completed`) so it drops into the same PostHog dashboards.

---

## 8. Build plan (concrete steps)

**New state (in `AreaSelectorState`)**
- `var toolbarWalkthroughStep: Int?` — nil = inactive; 0…4 = active step. Making
  it observable means `toolbarTooltip`/scrim read it reactively, same as hover
  flags.
- A snapshot field for the user's pre-tour `devModeEnabled` (for step-4 option A).
- Methods: `startToolbarWalkthrough()`, `advanceWalkthrough()`,
  `walkthroughBack()`, `endToolbarWalkthrough(completed:)`.
- For step-4 option A: a display-only Dev toggle that sets `isDevMode` for
  rendering **without** calling the controller path that writes
  `preferences.devModeEnabled` (the normal toggle persists — see
  `AreaSelectorWindowController:912`). Add a `setDevModeForDisplay(_:)` that flips
  only the in-memory `isDevMode`, and restore the real value on end.

**New rendering (in `AreaSelectorView`)**
- A `walkthroughScrim(in:)` layer: full-overlay dim with a rounded-rect
  "spotlight" cutout around the current step's frame helper rect. Add it to the
  ZStack in `body` (near `toolbarTooltip(in:)`, :66) so it sits above the toolbar
  but below the bubble.
- Extend the bubble: reuse the `toolbarTooltip` bubble styling but add a title
  line + the Next/Back footer. Cleanest is a small dedicated
  `walkthroughCallout(step:in:)` that shares the caret/`menuFill` styling.
- A `walkthroughStepFrame(_:in:)` helper mapping step index → the right existing
  frame helper (`modeArtifactSegmentFrame` / `modelChipFrame` / `micChipFrame` /
  `devSettingsIconFrame` / `recordButtonFrame`).

**Interaction wiring (in `AreaSelectorWindowController`)** — the important
macOS-specific part:
- Because the SwiftUI tree is hit-test-disabled, the walkthrough's Next/Back
  **buttons won't receive clicks the normal way.** They must be hit-tested by the
  controller's existing mouse monitor, exactly like the toolbar controls are
  today. Add hit rects for the callout buttons and route
  `advanceWalkthrough()` / `walkthroughBack()` / `endToolbarWalkthrough` from the
  controller's mouse-down handler.
- Suppress the normal hover tooltips while the walkthrough is active (early-return
  in `tooltipInfo`, :1758) so the two bubble systems never collide (it already
  suppresses tooltips when menus are open — same pattern).
- Handle `Esc`: while walkthrough active → skip; else existing close behavior.
- In `present(...)`: the trigger check from §6, plus seeding the default
  selection so the toolbar is visible.

**Preferences**
- Add `toolbarWalkthroughSeen` to `PreferencesStore` (getter/setter + `Keys` +
  `resettable`).

**Tests (match existing conventions)**
- Extend/mirror `AreaSelectorToolbarLayoutTests` to assert
  `walkthroughStepFrame` returns each control's rect in both `.area` and
  `.fullScreen`.
- A state test for step advance/back bounds and the
  `toolbarWalkthroughSeen` set-on-complete/dismiss behavior (mirror
  `OnboardingStepTests`).
- Step-4 option A: a test that Dev Mode is restored to its pre-tour value and
  `preferences.devModeEnabled` is untouched after dismiss/complete.
- Add to `reset-for-testing.sh` so the walkthrough re-triggers.

**Rollout**
- Consider gating behind a preference/flag for internal dogfood first
  (the codebase already gates features this way).

---

## 9. Open decisions for you

1. **Step 4 handling** — A (reveal+restore, recommended), B (conditional step),
   or C (fold into mode-switch step)? Depends on how central Dev Mode is to your
   positioning.
2. **Toolbar visibility on first open** — seed a full-screen default selection
   (recommended) vs. wait for the user's first drag?
3. **Step 5 ending** — dismiss on `Got it`, or let the real Record click end the
   tour and start recording in one motion?
4. **Re-entry** — besides first-run, do you want a "Show tutorial again" item in
   the menu-bar panel or Settings? (Cheap once the tour exists — just call
   `startToolbarWalkthrough()`.)

---

## 10. Effort estimate

Roughly (assuming coach-marks-on-real-toolbar, step-4 option A):

- State + preferences plumbing: small
- Scrim + callout rendering: small–medium (reuses existing bubble)
- Controller hit-testing for Next/Back + Esc + trigger: **medium — the
  riskiest part**, because it touches the hand-rolled mouse monitor
- Analytics + tests: small

The single biggest technical risk is routing the callout button clicks through
the controller's mouse monitor rather than SwiftUI. Everything else leans on
infrastructure that already exists.
