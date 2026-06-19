# Claude Code handoff — "Auto-Detect Project" toggle (in the dev-settings menu)

Surface the port→folder feature as an explicit, **default-OFF** toggle named
**Auto-Detect Project** inside the toolbar's **Agent & Project** (dev-settings)
menu. Turning it ON is the opt-in that requests browser permission; an **info icon**
next to the label shows a short explanation on hover.

**This REVISES Part 5 of `docs/HANDOFF-dev-mode-port-folder.md`:**
- the toggle lives in the **dev-settings menu**, not App Behavior settings;
- it is **OFF by default** (was on) — nothing reads the browser until the user
  explicitly enables it, so a first-time user is never surprised;
- the macOS Automation prompt fires **when the user flips it on** (not lazily on
  first detection), so the system dialog has obvious context — the user just asked
  for this. (This replaces the "pre-primer" idea — the toggle IS the primer.)

The reader + port extraction + `devProjectByPort` map + the detection/fallback
wiring (that handoff's Parts 1–4) are unchanged — this only changes the gate's
location/default and how it's presented. App-only (Swift), build + tests, then a
quick manual check.

## Read first
- `Surfaces/AreaSelector/AreaSelectorView.swift`:
  - the dev-settings menu render (`devSettingsMenu`) and its **Project section**
    (header + the single "Change…" row today).
  - the geometry the menu is hit-tested by — `devSettingsMenuFrame` (~634; Project
    section is `menuSectionHeaderHeight + devMenuRowHeight`, ~651) and
    `devSettingsProjectRowFrame` (~730). The menu is FULLY geometry-hit-tested, so
    adding a row means updating this math in lockstep (same discipline as the model
    scroll work).
  - the **custom tooltip system**: `toolbarTooltip` (~1210) + `tooltipInfo` (~1246).
    NOTE (~1203): the overlay is hit-test-disabled so **`.help()` never fires** —
    the info-icon tooltip MUST go through `tooltipInfo`, not `.help`.
- `Surfaces/AreaSelector/AreaSelectorWindowController.swift` — the mouse-monitor
  hit-testing for menu rows (`.leftMouseDown` clicks + `.mouseMoved` hover that
  feeds the tooltip/highlight). The new toggle row + info-icon hover hit-test go here.
- `Surfaces/AreaSelector/AreaSelectorState.swift` — the dev-settings menu state +
  setters; add the toggle state/action here.
- `Preferences/PreferencesStore.swift` — `Keys` (mirror `devProjectPath` etc.).
- `Services/Dev/BrowserURLReader.swift` — `detectLocalhostURL()` (call once on
  enable to trigger the permission prompt).

## Part 1 — the preference (default OFF)
`PreferencesStore`: add `Keys.devAutoDetectProject` (`vf.dev.autoDetectProject`),
a `Bool` **defaulting to false**, with get/set, and add it to `Keys.resettable`.
This is THE gate: `BrowserURLReader` is only ever invoked when it's true (replaces
the port→folder handoff's Part-5 "enabled" flag, now default-off and menu-driven).

## Part 2 — the toggle row in the Project section
Add an **Auto-Detect Project** row to the dev-settings menu's Project section
(directly under the "Project" header, above the folder/"Change…" row). It's a row
with the label on the left, a small **switch** on the right reflecting on/off
(use `vfDevAccent` green for the ON track, neutral for OFF — matching the menu's
accent language), and an **info icon** (`info.circle`, `vfTextTertiary`) immediately
after the label. Clicking anywhere on the row toggles it. Match the existing menu
row metrics (`devMenuRowHeight`) and chrome.

## Part 3 — geometry + hit-testing (keep lockstep)
The Project section grows from 1 row to 2 (toggle + Change…). Update, using the
SAME values in render and hit-test:
- `devSettingsMenuFrame`: Project section height → `menuSectionHeaderHeight + 2 *
  devMenuRowHeight`.
- `devSettingsProjectRowFrame`: the "Change…" row shifts DOWN by one `devMenuRowHeight`
  (the toggle row sits above it).
- add `devSettingsAutoDetectRowFrame(...)` (the toggle row's rect) for the click
  hit-test, and an **info-icon sub-rect** within it for the hover hit-test.
- the renderer must place the toggle row at exactly that rect and the Change… row /
  git line shifted accordingly — renderer and hit-test math stay in lockstep (this
  menu's core invariant).
Wire the toggle-row click in the controller's `.leftMouseDown` handler (alongside
the agent/model/project hit-tests).

## Part 4 — behavior: enable requests permission
- Clicking the row flips `devAutoDetectProject` and persists it.
- **On OFF → ON:** immediately call `BrowserURLReader.detectLocalhostURL()` once
  (off-main, as built) so an Apple Event is sent → macOS shows the per-browser
  Automation prompt **in the context of the user having just enabled the feature**.
  (Only browsers currently running can be prompted now; any other browser prompts
  on first real use — inherent to per-target Automation TCC. If no supported
  browser is running, the grant simply happens on first use later. Don't block on
  the result — the toggle is on regardless.)
- **On ON → OFF:** never read the browser again (the Part-1 gate).
- **Denied grant:** keep the toggle ON (it reflects the user's intent) and let
  detection silently no-op (graceful fallback already exists). Optionally show a
  subtle one-line "needs permission" hint on the row; don't flip the toggle back or
  show a blocking modal.
- Detection-on-Dev-entry (port→folder Part 4) now runs **only when this is ON**.

## Part 5 — the info-icon tooltip (custom, not `.help`)
Hook the info icon into the existing `tooltipInfo` path:
- in the controller's `.mouseMoved` hit-testing, detect hover over the info-icon
  sub-rect (Part 3) and set the hover state the tooltip reads;
- extend `tooltipInfo` to return `(text, anchor)` for that icon, anchored to the
  icon's rect, so `toolbarTooltip` draws it — exactly like the toolbar icon
  tooltips. Do NOT use `.help()` (it won't fire in this overlay).
- Copy (short, plain): **"Auto-matches your project folder to the localhost site
  you're recording, by reading your browser's address. Turning this on asks for
  browser permission once."**

## Part 6 — tests
- Pref defaults to **false**; persists; is in `resettable`.
- Geometry/hit-test: the new toggle row maps clicks correctly; the "Change…" row
  and git line are at their shifted positions for the 2-row Project section; the
  info-icon sub-rect hit-tests for hover; menu height accounts for the extra row.
- Behavior (reader stubbed): OFF→ON triggers exactly one detection/permission
  attempt; ON→OFF and OFF state never invoke the reader; the Dev-entry detection is
  gated on the toggle.
- `tooltipInfo` returns the explanation text for the info-icon anchor.

## Acceptance criteria
- The dev-settings (Agent & Project) menu has an **Auto-Detect Project** toggle,
  **off by default**, with an info icon whose hover shows the explanation (via the
  custom tooltip, working in the overlay).
- Turning it on triggers the macOS browser-permission prompt then; turning it off
  (or leaving it off) means the browser is never read. A first-time user sees
  nothing browser-related until they opt in.
- Menu geometry stays in lockstep (render == hit-test) with the extra Project row;
  short/long model lists and the scroll viewport still behave.
- The reader/map/fallback from the port→folder handoff are unchanged; build + tests
  green; normal mode unaffected.

## Notes
- Default-off is the whole point — no Automation prompt, no browser read, nothing
  surprising until the user explicitly enables it.
- This pairs with the port→folder handoff: that one builds the reader/map/wiring
  (and should drop its Part-5 Settings toggle in favor of this menu toggle, default
  off). If you build them together, fold Part 5 of that doc into this.
