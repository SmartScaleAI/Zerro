# Claude Code handoff — scrollable Model section in the dev-settings menu

The dev-settings **Model** list can now be long (Cursor exposes ~25–30 curated
rows), and the menu grows with it until it runs off the bottom of the screen.
Cap the Model section to a **max-height scrollable viewport** so the menu stays
on-screen and the user scrolls to reach the rest. Agent + Project + the git line
stay fixed; only the Model rows scroll.

App-only (Swift), AreaSelector overlay. Build + previews + tests, no STOP needed
(self-contained UI fix), but adversarial-check the hit-testing math.

## Why this isn't a one-line `ScrollView`
The dev-settings menu is **not** a SwiftUI scroll view — it's a fixed panel whose
rows are laid out by absolute geometry, and the overlay disables hit-testing at the
root and drives everything through an `NSEvent` monitor that maps clicks to rows by
y-band math (`AreaSelectorWindowController`, the `mouseMonitor`). So a `ScrollView`
won't receive scroll events, and its internal offset would desync from the
geometry-based hit-testing. The fix has to: cap the height, carry a **scroll
offset** routed through the same monitor, and make the row math offset-aware.

## Read first
- `Surfaces/AreaSelector/AreaSelectorView.swift`:
  - `devSettingsMenuFrame(...)` (~631) — sums section heights; the Model term
    `menuSectionHeaderHeight + modelCount * devMenuRowHeight` (~636) is the
    unbounded part (root cause).
  - `devSettingsModelRowIndex(...)` (~666) — click→model-row y-band math.
  - `devSettingsProjectRowFrame(...)` (~689) and the frame height both add the
    FULL `modelCount * devMenuRowHeight`, so Project + git currently sit below the
    entire list — they must shift to below the **capped** viewport.
  - `devSettingsMenu(in:)` render (~885) and the Model rows (~903–928).
  - constants: `devMenuRowHeight = 38` (~624), `menuSectionHeaderHeight`,
    `menuVPad`, `devMenuDividerBand`, `anchoredMenuFrame(...)` (positions/anchors
    the panel — a capped height is what keeps it on-screen).
- `Surfaces/AreaSelector/AreaSelectorState.swift` — `isDevSettingsMenuOpen` (~400,
  set true ~478), `setHighlightedDevModelIndex`, the agent-selection setter (where
  the model list changes). No scroll state yet — add it here.
- `Surfaces/AreaSelector/AreaSelectorWindowController.swift` — the `mouseMonitor`
  (mask ~324: `.leftMouseDown/.leftMouseDragged/.leftMouseUp/.mouseMoved`),
  `.mouseMoved` model hover (~406) and `.leftMouseDown` model click (~517) both
  calling `devSettingsModelRowIndex`. These callers must pass the new offset.

## Part 1 — scroll-offset state
In `AreaSelectorState`, add `private(set) var devModelScrollOffset: Int = 0` (the
index of the top visible model row) with a clamped setter
`setDevModelScrollOffset(_:)` that pins it to `0...max(0, modelCount - maxVisible)`.
Reset/clamp it:
- to `0` (or to reveal the selected model — see Part 5 nice-to-have) when the menu
  opens (~478) and when the **selected agent changes** (the model list swaps, so a
  stale offset would be wrong),
- re-clamp whenever `modelCount` shrinks.

## Part 2 — cap the menu height (geometry)
- Add `static let maxVisibleModelRows = 7` (tune so the whole panel — Agent rows +
  capped Model viewport + Project + git line — fits comfortably within a typical
  `visibleFrame`).
- In `devSettingsMenuFrame`, replace the Model term with the **capped** count:
  `menuSectionHeaderHeight + CGFloat(min(modelCount, maxVisibleModelRows)) * devMenuRowHeight`.
- In `devSettingsProjectRowFrame` (and anywhere else that advances past the Model
  section), use the same `min(modelCount, maxVisibleModelRows)` so Project + git
  sit directly under the viewport, not under the full list.
- Agent section stays full height (it's only ~3 rows — no need to scroll it).

## Part 3 — route scroll-wheel through the monitor
- Add `.scrollWheel` to the `mouseMonitor` mask (~324).
- In the handler, when `state.isDevSettingsMenuOpen` AND the pointer is within the
  **Model viewport rect** (compute it from the menu frame: the band starting after
  Agent section + divider + Model header, height `min(modelCount, maxVisible) *
  devMenuRowHeight`), translate the wheel into row steps and call
  `setDevModelScrollOffset`. Recommended: accumulate `event.scrollingDeltaY` and
  step the offset by ±1 each time the accumulator crosses `devMenuRowHeight`
  (row-stepped keeps hit-testing clean; avoids partial rows). Respect natural
  scroll direction. Consume the event when handled.
- Only scroll when `modelCount > maxVisibleModelRows`; otherwise no-op.

## Part 4 — offset- + viewport-aware hit-testing
Thread `scrollOffset` into `devSettingsModelRowIndex`:
- the visible band is `visibleCount = min(modelCount, maxVisibleModelRows)` rows
  tall — reject a point below it (it's now Project/git territory),
- `visibleIndex = Int(localY / devMenuRowHeight)`, guard `0..<visibleCount`,
- return `visibleIndex + scrollOffset` (guard `< modelCount`).
Update BOTH callers — the `.mouseMoved` hover (~406) and the `.leftMouseDown` click
(~517) — to pass `state.devModelScrollOffset`. (The hover highlight must track the
scrolled list too.)

## Part 5 — render the clipped viewport
In `devSettingsMenu`, render the Model section as a fixed-height viewport
(`visibleCount * devMenuRowHeight`) that shows rows `[scrollOffset, scrollOffset +
visibleCount)`, clipped so rows don't bleed past the band. Keep the green checkmark
on the selected row when it's scrolled into view. Add a subtle scrollability
affordance (a top/bottom fade or a thin scrollbar) so it's discoverable that more
rows exist. Everything below (divider → Project → git line) renders at the capped
offset, matching Part 2's geometry exactly (the renderer and the hit-test math must
stay in lockstep — that's the invariant this menu relies on).
- **Nice-to-have:** when the menu opens, set `devModelScrollOffset` so the
  currently-selected model is visible (e.g. clamp the selected index to the top of
  the viewport), so a deep pick isn't hidden on open.

## Part 6 — tests
- `devSettingsMenuFrame` height is **bounded** for a large `modelCount` (equals the
  `maxVisibleModelRows` cap, not `modelCount`).
- `devSettingsModelRowIndex(scrollOffset:)`: visible band maps to `visibleIndex +
  offset`; a point below the viewport → nil; offset at max clamps; small list
  (≤ cap) behaves exactly as today (offset 0).
- `devSettingsProjectRowFrame` y is correct for a large `modelCount` (sits under
  the capped viewport, not the full list).
- Offset clamp: `setDevModelScrollOffset` pins to `0...(modelCount - visibleCount)`
  and re-clamps when the list shrinks / the agent changes.

## Acceptance criteria
- With Cursor's ~30-row list, the dev-settings menu fits on screen; the Model
  section scrolls (wheel/trackpad); hovering and clicking a scrolled-into-view
  model selects the right one; the selected checkmark shows when scrolled to.
- Agent, Project ("Change…"), and the git line stay fixed and correctly placed
  below the capped viewport.
- A short list (Claude Code / Codex — a handful of models, ≤ cap) renders **exactly
  as before**: no scroll, no clipping, no layout shift.
- Renderer geometry and the controller's hit-test math stay in lockstep (same
  `min(modelCount, maxVisible)` everywhere). Build + previews + tests green.

## Notes
- Only the Model rows scroll; the Agent picker stays visible (it's short). If you'd
  rather make the *whole* menu scroll, don't — pinning Agent/Project is better UX
  and keeps the hit-testing simpler.
- The model menu for the *eyes* model (`modelMenu`, ~787, `modelMenuRowIndex`) has
  the same latent issue but a much shorter list; out of scope here, but if you
  factor the viewport/offset helper cleanly, note it for reuse.
