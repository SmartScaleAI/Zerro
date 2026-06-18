# Claude Code handoff — compact icon toolbar (Figma/CleanShot style)

Redesign the recording toolbar from labeled chips into a **compact icon toolbar**
(Figma/CleanShot aesthetic): a two-icon **mode segmented switch** on the left, then
icon+chevron controls that open CleanShot-style dropdowns, then the labeled Record
button. In Dev Mode, the agent + project folder collapse into a single **dev-settings
menu** behind one icon.

This SUPERSEDES the prior toolbar layout/toggle instructions (the two-container +
real-toggle prompt). The `vfDevAccent` token (#34E27A) and the green **selection-region
border** come from the separate visual handoff — don't redo the border here; just reuse
`vfDevAccent` (add it to DesignSystem/Colors.swift if it isn't there yet:
`Color(red: 0.204, green: 0.886, blue: 0.478)`).

## Read first
- `Surfaces/AreaSelector/AreaSelectorView.swift` — toolbar rendering (the chip views +
  the static geometry helpers `toolbarClusterWidth`, `modelChipFrame`, `micChipFrame`,
  `recordButtonFrame`, `devToggleFrame`, `agentChipFrame`, `folderChipFrame`) and the
  existing `modelMenu`/`micMenu` dropdowns.
- `Surfaces/AreaSelector/AreaSelectorState.swift` — `isDevMode`, `selectedModelID`,
  `selectedAgentID`, `projectURL`, the menu-open flags, `toggleDevMode`, `setProjectURL`.
- `Surfaces/AreaSelector/AreaSelectorWindowController.swift` — the mouse-monitor
  hit-testing, `presentFolderPicker`, `toggleDevMode`, `beginAgentDetection`, the
  dropdown row hit-tests.
- `Services/DevAgentRegistry.swift` / `Services/Dev/DevAgentDetection.swift` — the
  detected-agent list for the dev-settings menu.
- The recording pill (`Surfaces/Pill/PillView.swift`) — match its capsule treatment
  (background material, corner radius, hairline) so the toolbar reads as the same family.

## Ground rules
- **Palette:** the whole toolbar uses the current/pill neutral palette. Green
  (`vfDevAccent`) appears ONLY on: the active Dev segment of the mode switch, the
  dev-settings readiness dot (green state), and the dev-settings menu's accents
  (checkmark + shield). Record stays red (`vfRecordingRed`). Model/mic dropdowns are
  neutral (white checkmark).
- "Dev off" is now **Artifact mode** — the existing normal recording flow, unchanged in
  behavior. Only the toolbar's look changes; generation/clipboard behavior is identical.
- Build + run the AreaSelector previews after each part. Keep diffs focused.

## Part 1 — mode segmented switch (replaces the Dev Mode toggle)
A two-segment icon control on the left, Figma-style:
- Segment A = **Artifact mode**, icon `ti-wand` (SF Symbol equivalent — pick the closest,
  e.g. `wand.and.stars` or `doc`); Segment B = **Dev mode**, icon `ti-code` (SF:
  `chevron.left.forwardslash.chevron.right`).
- The **active** segment is highlighted: Artifact active → neutral fill
  (white ~10–12% opacity); Dev active → `vfDevAccent` tint fill + green icon. Inactive
  segment icon is dimmed (`vfTextTertiary`).
- **Hover tooltip** per segment via `.help("Artifact")` / `.help("Dev Mode")`.
- Clicking Artifact sets Dev Mode OFF; clicking Dev sets it ON. Replace the toggle's
  `toggleDevMode()` with explicit set-on/set-off so the segment maps to a mode (it still
  drives `state.isDevMode` + persistence + the `dev_mode_toggled` analytics).
- A vertical hairline divider separates the switch from the controls.

## Part 2 — model + mic as icon+chevron controls + CleanShot dropdowns
- Replace the labeled model/mic chips with **icon + chevron** buttons (no inline label):
  model = `ti-sparkles` (SF `sparkles`) + chevron; mic = `ti-microphone` (SF `mic`) +
  chevron. The icon AND chevron are one click target that opens the dropdown.
- **Hover tooltip** shows the current value: `.help("Model: \(state.selectedModelName)")`,
  `.help("Microphone: \(selectedMicName)")`.
- **Dropdowns — CleanShot style** (restyle the existing `modelMenu`/`micMenu`): dark
  rounded menu anchored under the icon, a small gray **section header** ("Model" /
  "Microphone"), each option a row with a **checkmark on the selected one**. Preserve the
  model's "Recommended" badge and the gated/BYOK affordances; mic lists "None" + devices.
  Neutral colors (white checkmark) — these are not dev-specific.

## Part 3 — dev-settings icon + consolidated menu (Dev mode only)
Replace the separate agent + folder chips with ONE icon that appears only in Dev mode:
- Icon `ti-terminal-2` (SF `terminal`) + chevron, with a **readiness status dot** at the
  corner: **green** when an agent is installed/selected AND a folder is set; **amber**
  when either is missing. Hover tooltip `.help("Agent & project")`.
- Click opens a **CleanShot-style menu**:
  - Section "**Agent**": the detected CLIs (`DevAgentDetection`) listed, a **green
    checkmark** on the active one; installed agents show a small "Detected" badge,
    not-installed shows a dim "install" hint that opens the install docs (reuse the
    existing logic). Selecting one sets `selectedAgentID`.
  - Section "**Model**": the selected agent's current models with a checkmark on the
    pick, newest-first, default = first (pinned list, no Default/Custom rows). **Specced
    in `docs/HANDOFF-dev-mode-agent-models.md` (Part 6)** — build that feature's app
    integration alongside this section; it reads the server manifest (Claude Code/Codex)
    or the Cursor CLI.
  - Section "**Project**": the folder name/path (monospace) on a row with a "**Change…**"
    action (accent-colored) that opens the existing `presentFolderPicker` NSOpenPanel.
    When unset, show the amber "Select folder" state here.
  - A git-reassurance hint line with a green `ti-shield-check` (SF `checkmark.shield`):
    "Snapshots with git before each change — undo anything."
  - The menu's accents (checkmark, shield) use `vfDevAccent`; otherwise it matches the
    neutral menu chrome from Part 2.
- **Auto-open:** when Dev mode is entered (Dev segment clicked) AND it's the first entry
  this session OR the folder is unset, auto-open this menu so setup is discoverable; it
  stays closed otherwise and on subsequent entries. (Add an `isDevSettingsMenuOpen` flag +
  a "has auto-opened" guard to `AreaSelectorState`.)
- Record-time validation is unchanged (blocks Dev recording with no agent/folder); the
  readiness dot + auto-open are the at-a-glance / first-run affordances.

## Part 4 — Record
Keep the labeled red **"● Record"** button (`vfRecordingRed`), prominent, at the right.

## Part 5 — geometry + hit-testing
This replaces the chip-based layout, so update the static frame helpers and the
`AreaSelectorWindowController` mouse-monitor hit-testing for the new compact layout:
- mode switch = TWO hit regions (Artifact segment, Dev segment) — hit-test separately.
- model icon, mic icon, dev-settings icon (Dev only), Record — each its own frame.
- the dropdowns/menus anchor under their icons (reuse the existing menu-frame + row
  hit-test pattern, restyled). The dev-settings menu's rows (agent items, "Change…")
  need their own hit-tests.
- Recompute `toolbarClusterWidth` for the compact widths (icons are far narrower than the
  old chips — this also fixes the narrow-selection overflow we'd deferred).

## Acceptance criteria
- Toolbar is compact icons: [Artifact|Dev mode switch] · model · mic · (dev-settings, Dev
  only) · Record. Tooltips show on hover; current model/mic value is in the tooltip.
- Mode switch: two icon segments, active highlighted (Dev = green, Artifact = neutral),
  clicking switches mode; behavior identical to the old toggle.
- Model/mic open CleanShot-style dropdowns with a checkmark on the current pick.
- In Dev mode, ONE dev-settings icon opens the agent+folder+git menu; its dot is green
  when ready / amber when not; the menu auto-opens on first Dev entry or when the folder
  is unset; "Change…" opens the folder picker; selecting an agent works.
- Palette neutral everywhere except the green dev pieces; Record red; selection-region
  green border (other handoff) still works.
- Normal/Artifact-mode behavior byte-identical; record-time validation still blocks an
  unconfigured Dev recording. Build + previews green.

## Suggested order
Part 1 (mode switch) → Part 2 (model/mic icons + dropdowns) → Part 4 (Record) →
Part 3 (dev-settings menu — the biggest) → Part 5 (geometry/hit-testing threads through
all). Build + test after each; pause for review after Part 3 if it gets large.
