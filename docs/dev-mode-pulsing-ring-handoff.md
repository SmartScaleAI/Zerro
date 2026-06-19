# Dev Mode — pulsing green screen-edge ring (Claude Code handoff)

## What to build

Add a thin, sleek, **green pulsing ring** that hugs the **outer edge of all four sides of the screen** while a Dev Mode coding-agent run is actively in progress. It is the desktop analogue of the orange ring Claude draws around a browser window while it's controlling a tab: an ambient "the agent is touching your machine right now" signal.

- **Color:** the existing Dev Mode accent, `Color.vfDevAccent` (#34E27A). Nothing renders green when Dev Mode is off, and this ring is no exception.
- **Look:** thin and sleek — a soft inner glow that fades inward from the screen edge, not a hard rectangular stroke. It pulses (breathes) continuously while active.
- **Coverage:** all four edges, full perimeter, on the screen(s) — see multi-display note below.
- **Non-interactive:** purely decorative. It must never intercept clicks, key events, or hit-testing. The user keeps working underneath it normally.

## When it starts and stops (this is the important part)

The ring's lifetime must be bound **exactly** to the window in which the coding agent is actually allowed to edit — not to checkpointing, not to prompt review.

**START** the ring the instant the agent is dispatched to begin implementing:
- On **Auto Approve**, that's as soon as the prompt is submitted to the agent.
- On **Ask Permission**, that's the moment the user *accepts* the review (not when the card appears).

Both of these collapse to a single, already-existing signal: `AppState.applyDevPhase(_:)` receiving the **`.dispatching`** phase. The coordinator emits `.dispatching` only *after* the confirm gate resolves to proceed and the checkpoint is taken — so it is already the precise "agent is now allowed to edit" instant for **both** permission modes. (See `DevDispatchCoordinator.dispatch` — `onPhase(.dispatching)` fires right before `runner.run(...)`, after `confirmGate()` passes; and `AppState.applyDevPhase`'s `.dispatching` case, which already sets `devAgentStarted = true` and persists the recovery marker at exactly this point.)

**STOP** the ring when the run is no longer in progress — i.e. when the agent completes, errors, or is cancelled. Per the product decision: **stop as soon as the agent completes/idles** (no lingering, no red error state). The clean stop signal is `AppState.applyDevOutcome(_:)` (it runs on both `.succeeded` and `.failed`, including `.cancelled`). Also stop on any transition out of the active dev-run states (cancel/revert/teardown) so the ring can never outlive the run.

Concretely, the ring should be **visible while, and only while**, `state` is in the active agent-run window: from `.devAgentDispatching` through `.devAgentRunning`, and hidden in every other state (`.devCheckpointing` is *before* dispatch — your call whether to include it, but the spec is to start at `.dispatching`, so **do not** show it during checkpointing or prompt review). When in doubt, drive purely off `applyDevPhase(.dispatching)` to show and `applyDevOutcome` (+ cancel/reset paths) to hide.

## How to wire it (follow existing patterns — do not invent new infrastructure)

This is a native macOS SwiftUI menu-bar app (`apps/desktop`, target `Zerro`). There are already two borderless always-on-top overlay windows; model the ring on them rather than rolling something new:

1. **New `DevRingWindowController`** (put it under `Zerro/Surfaces/` — e.g. `Surfaces/DevRing/DevRingWindowController.swift`). Model it on **`AreaSelectorWindowController`**: a borderless, transparent, **`.nonactivatingPanel`** that floats above normal windows and **does not activate the app**. Key window/panel config to copy:
   - `styleMask = [.borderless, .nonactivatingPanel]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`.
   - High window level so it sits above app windows (e.g. `.statusBar` or `.screenSaver`-ish; match what AreaSelector uses for "above everything but the cursor").
   - `ignoresMouseEvents = true` and `collectionBehavior` including `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary` so it shows over fullscreen apps and across Spaces and never steals interaction.
   - Frame = the target screen's **`screen.frame`** (full screen including the menu-bar/Dock area — this is an *edge* ring, so use `frame`, not `visibleFrame`).
   - Content view = an `NSHostingView` of a SwiftUI ring view, set **directly as `contentView`** (AreaSelector's header explicitly warns that wrapping it in another NSView can leave the hosting view zero-sized — follow that note).

2. **Own it where the other controllers are owned** — in `ZerroApp` alongside `pillController` / `areaSelectorController` (around lines 87–120 and the `_…Controller = State(initialValue:)` block). Construct it once for the app's lifetime.

3. **Drive it from `AppState`** using the **same observation bridge `PillWindowController` uses** (`startObservingAppState()` → a `Task` looping on `withObservationTracking { _ = appState.<thing> }`). Add a single observable boolean on `AppState`, e.g. `@Published`/observable `devRingActive` (or a computed `var devRingActive: Bool { … }` derived from `state`), set it `true` in `applyDevPhase`'s `.dispatching` case and `false` in `applyDevOutcome` and in the cancel/revert/`resetTransientRecordingState` teardown paths (line ~1200 / ~1227, where `devDispatchTask` is torn down). The controller observes `devRingActive` and calls a single `setActive(_:)` entry point that shows+starts the animation or fades+hides. Keep the on/off logic in `AppState` so it stays the single source of truth for dev-run lifecycle; the controller is dumb.

## Visual spec (the SwiftUI ring view)

- A full-bleed view that draws a **soft inner glow fading inward from all four edges**. Implement as an inset/edge gradient — e.g. a `Rectangle` stroked with a blurred line, or four edge `LinearGradient`s (`vfDevAccent` at the edge → clear inward), or a rounded-rect `.stroke` with a `.blur`/`shadow`. Aim for a band roughly **3–6 pt** of crisp line plus a soft falloff of maybe **16–28 pt** — thin and sleek, present but not heavy. Tune against the screenshot below.
- **Pulse:** animate **opacity** (and optionally a *tiny* glow-radius change) between ~0.45 and ~1.0 on a gentle ~1.6–2.2s ease-in-out `autoreverses` `repeatForever` loop. A slow breathing pulse, not a strobe.
- **Corners:** slightly rounded so the four edges meet cleanly at the corners (a small corner radius reads better than a hard right-angle box at the screen corner).
- **Enter/exit:** fade in over ~0.2–0.3s on start; fade out over ~0.2–0.3s on stop (don't just pop it out). Stop the `repeatForever` animation on hide so nothing animates while hidden.

### Performance — do NOT repeat Claude-in-Chrome's mistake

The web version of this exact effect shipped with a real bug: it animated layered `box-shadow`s every frame, which isn't GPU-composited, and pinned Chrome Helper at ~50% CPU on an M1 while active ([anthropics/claude-code#20070](https://github.com/anthropics/claude-code/issues/20070)). Don't recreate that here:

- Animate **compositor-friendly properties only** — opacity (and transform if you want a subtle scale), driven by Core Animation. Do **not** animate a `shadow`/blur radius per frame, and do **not** drive the pulse from a SwiftUI `Timer`/`TimelineView` that re-renders the gradient every tick.
- Render the glow **once** (static gradient/shadow layer) and animate **only its layer opacity** in a `repeatForever` `withAnimation`/`CABasicAnimation`. The expensive blur is rasterized once; the GPU just cross-fades opacity.
- Consider `layer.shouldRasterize = true` (with correct `rasterizationScale`) on the glow layer so the soft edge is cached as a bitmap and the pulse is a pure opacity composite.
- This overlay can be on screen for minutes during a long agent run, so idle cost matters. Verify CPU/GPU impact is near-zero while pulsing (Instruments / Activity Monitor) as part of acceptance.

## Multi-display

`AreaSelectorWindowController` today presents on a **single** screen (the one under the cursor) and explicitly defers full multi-monitor coverage. For the ring, **single-screen is an acceptable first cut** — put it on `NSScreen.main` (or the screen under the cursor at dispatch time). If it's low-effort, support all displays by creating **one ring window per `NSScreen`** (loop `NSScreen.screens`) and observe `NSApplication.didChangeScreenParametersNotification` to rebuild on display changes — mirror how AreaSelector tracks `screenChangeObserver`. Don't block the feature on multi-display; ship single-screen if per-screen windows add meaningful weight.

## Acceptance criteria

- In Dev Mode with **Auto Approve**: the ring fades in the instant the prompt is submitted to the agent, pulses green (#34E27A) on all four screen edges throughout the run, and fades out the moment the run finishes (success, error, or cancel).
- In Dev Mode with **Ask Permission**: the ring does **not** appear while the review card is up; it fades in only when the user accepts, then behaves as above.
- The ring never appears outside an active agent run, and never when Dev Mode is off.
- The ring is fully click-through — interacting with anything underneath is unaffected.
- Pulsing is a slow, smooth breathe; CPU/GPU cost while pulsing is negligible (no `box-shadow`-style per-frame repaint; opacity is the only animated property; verified in Activity Monitor/Instruments).
- Existing Dev Mode dispatch/cancel/revert behavior is unchanged — the ring is additive and driven entirely off existing lifecycle signals.

## Files to read first

- `Zerro/AppState.swift` — `applyDevPhase(_:)` (`.dispatching` = start signal), `applyDevOutcome(_:)` (stop signal), and the dev teardown paths (`resetTransientRecordingState`, `devDispatchTask` cancel ~lines 1200–1230). Add the `devRingActive` source-of-truth here.
- `Zerro/Services/Dev/DevDispatchCoordinator.swift` — confirms `.dispatching` fires after the confirm gate, before `runner.run`, for both permission modes.
- `Zerro/Surfaces/AreaSelector/AreaSelectorWindowController.swift` — the borderless transparent non-activating panel pattern to copy (window config, NSHostingView-as-contentView note, screen-change observer).
- `Zerro/Surfaces/Pill/PillWindowController.swift` — the `startObservingAppState()` / `withObservationTracking` bridge to copy for driving the controller from AppState.
- `Zerro/DesignSystem/Colors.swift` — `vfDevAccent` (#34E27A).
- `Zerro/ZerroApp.swift` — where window controllers are constructed and held in `@State` for the app lifetime (~lines 87–120); own the new controller here.

## Out of scope (don't do these)

- No red/error flash state — stop cleanly on completion (per product decision).
- No persistence after the run; no user-dismiss affordance.
- Don't touch the agent runner, git checkpoint, or analytics. This is presentation only.
