# Claude Code handoff — Permissions dropdown + remove the confirmAnchors gate

Two coupled changes that consolidate Dev Mode's pre-edit checkpoints into **one**:

1. **Replace the App Behavior "Review prompt before applying changes" toggle with a
   `Permissions` dropdown in the dev-settings (Agent & Project) menu**, with two
   options:
   - **Ask Permission** — show the generated prompt before it goes to the agent
     (today's review-on); the user reads exactly what will be sent.
   - **Auto Approve** — dispatch immediately, no prompt (today's review-off).
2. **Remove the `confirmAnchors` gate and pill entirely.** The low-confidence
   anchor-confirm step goes away; the prompt review (under Ask Permission) becomes
   the SOLE pre-edit checkpoint. Under Auto Approve there is **no** pre-edit pill at
   all — a wrong target is caught only by Undo (product-owner confirmed).

App-only (Swift). It's a sizable removal (~70 `confirmAnchors` references) plus a
new menu section, so build + test after each part.

## Keep vs. remove — read this first (don't over-delete)
The **anchor RESOLUTION stays** — only the confirm *gate* and its *pill* go:
- **KEEP:** `devResolvedAnchors`, `devModelAnchors`, `ConfirmAnchorRow` (the struct),
  and `devConfirmAnchorSummaries` (the resolved target labels) — the **review card's
  "Targeting: X" rows reuse all of these**. Resolution still runs to build the
  prompt and the review targets, and feeds anchor analytics.
- **REMOVE:** the gate (`awaitAnchorConfirmation`, `devNeedsConfirm`), the state
  (`.confirmAnchors`), the actions (`confirmAnchorsAndProceed`, `declineAnchors`),
  the continuation (`devConfirmContinuation`, `resolvePendingAnchorConfirmation`),
  the pill (`ConfirmAnchorsPillContent`, the `.confirmAnchors` pill-state +
  `onConfirmAnchors`/`onDeclineAnchors`), the bridge mapping, and the
  `.confirmAnchors` arm of `prepareForTermination`.
- `combinedConfidence`/the `isLow` flag were only the gate's trigger — keep them if
  analytics still wants the confidence signal, otherwise simplify
  `devConfirmAnchorSummaries` to just the labels. Your call; don't break the review
  card's target rows.

## Read first
- `AppState.swift`: the `confirmGate` composition in `beginDevDispatch` (~2874,
  currently anchors-then-review), `awaitReviewApproval` (~3075, reads
  `devReviewBeforeApply` at ~3079), `awaitAnchorConfirmation`/`confirmAnchorsAndProceed`/
  `declineAnchors`, the teardown floor (`resolvePending…`), `prepareForTermination`,
  `devConfirmAnchorSummaries`.
- `Preferences/PreferencesStore.swift`: `devReviewBeforeApply` (key ~67, var ~221,
  init ~260, reset ~286) — the flag to replace.
- The App Behavior settings section where the "Review prompt before applying
  changes" toggle was added (find it — it's the one to delete).
- `PillStateBridge.swift` (~126 `.confirmAnchors`, ~133 `.reviewPrompt`) and
  `Surfaces/Pill/PillView.swift` (the `.confirmAnchors`/`ConfirmAnchorsPillContent`
  to remove; `.reviewPrompt`/`ConfirmAnchorRow` to keep) +
  `PillWindowController.swift` (the confirmAnchors wiring to remove).
- `Surfaces/AreaSelector/AreaSelectorView.swift` + `AreaSelectorState.swift` +
  `AreaSelectorWindowController.swift`: the dev-settings menu sections (Agent/Model/
  Project) + their geometry/hit-test/render — the pattern to clone for a Permissions
  section. (The Auto-Detect toggle + model-scroll work established the lockstep
  discipline; follow it.)

## Part 1 — the setting becomes a two-mode enum
Replace the `devReviewBeforeApply` Bool with `DevPermissionMode { askPermission,
autoApprove }`:
- `PreferencesStore`: a persisted `devPermissionMode` (store the raw value),
  **default `.autoApprove`** (preserves today's default-off behavior — flag for the
  product owner if they'd rather default to Ask Permission). Migrate the old Bool if
  present (`true → .askPermission`). Keep it in `resettable`.
- `awaitReviewApproval`: change the guard to
  `guard preferences?.devPermissionMode == .askPermission else { return true }`
  (Auto Approve ⇒ instant pass, exactly like review-off today).
- **Delete** the App Behavior "Review prompt before applying changes" toggle.

## Part 2 — the Permissions section in the dev-settings menu
Add a **Permissions** section to `devSettingsMenu` (a header + two selectable rows,
checkmark on the active mode — same shape as the Agent/Model sections), e.g. placed
after Model / before Project:
- rows: **"Ask Permission"** and **"Auto Approve"**, green checkmark on the current
  (`vfDevAccent`), click selects it and persists `devPermissionMode`.
- Geometry in lockstep: extend `devSettingsMenuFrame` by the new section
  (`menuSectionHeaderHeight + 2 * devMenuRowHeight`), add its row hit-test, shift the
  sections below it, and render the rows at the matching rects — render == hit-test,
  the invariant this menu lives by. Wire the row clicks in the controller's
  `.leftMouseDown` handler.
- (A short tooltip/subtitle is optional; keep it consistent with the menu's style.)

## Part 3 — remove the confirmAnchors gate + pill
- **Gate:** in `beginDevDispatch`, collapse the `confirmGate` from anchors-then-review
  to **review-only**:
  `confirmGate: { [weak self] in await self?.awaitReviewApproval(gen: gen, prompt: …) ?? false }`.
  Delete `awaitAnchorConfirmation`, `confirmAnchorsAndProceed`, `declineAnchors`,
  `devConfirmContinuation`, `resolvePendingAnchorConfirmation`, `devNeedsConfirm`.
- **State:** remove `case confirmAnchors` from `RecordingState`; fix the exhaustive
  switches — its `prepareForTermination` arm now applies to `.reviewingPrompt` only
  (which was folded in with it); the sweep/idle guards lose the `.confirmAnchors`
  entry.
- **Pill:** remove `ConfirmAnchorsPillContent`, the `.confirmAnchors` `PillState`
  case, `onConfirmAnchors`/`onDeclineAnchors`, and the bridge mapping (~126). Keep
  `ConfirmAnchorRow` and `.reviewPrompt` — the review card uses them.
- **Recovery marker:** unaffected — `approveReviewAndProceed` already persists it for
  review-only runs (it was added precisely because `confirmAnchorsAndProceed` doesn't
  fire). Just confirm it still does after the gate collapses.

## Part 4 — tests
- Setting: `devPermissionMode` defaults `.autoApprove`, persists, in `resettable`;
  old-Bool migration (`true→askPermission`).
- Gate: `.autoApprove` ⇒ `awaitReviewApproval` returns true without `.reviewingPrompt`
  (immediate dispatch); `.askPermission` ⇒ enters `.reviewingPrompt`, approve →
  dispatch, cancel → abort + checkpoint discarded.
- **No confirmAnchors anywhere:** a low-confidence anchor no longer pauses — it
  resolves and dispatches (or shows only the review pill under Ask Permission). The
  `.confirmAnchors` state/pill/gate are gone (compile-time + a test that a
  low-confidence resolution doesn't enter a confirm state).
- The review card still renders its **target rows** from `devConfirmAnchorSummaries`.
- Menu: the Permissions rows hit-test correctly; selecting persists the mode; the
  geometry stays in lockstep (sections below shift correctly).
- Teardown: a reset/quit during `.reviewingPrompt` resolves the review continuation
  (no hang) — unchanged.

## Part 5 — manual check
- Menu shows **Permissions: Ask Permission / Auto Approve** with the checkmark; the
  old App Behavior toggle is gone.
- **Ask Permission:** record → the prompt review card appears (showing the agent,
  the target, the prompt) → Approve dispatches, Cancel aborts. Even on an ambiguous
  point, you get only the **one** review card — no separate confirm pill.
- **Auto Approve:** record → dispatches immediately, no pill, even on an ambiguous
  point (Undo is the catch).

## Acceptance criteria
- The dev-settings menu has a Permissions dropdown (Ask Permission / Auto Approve);
  the App Behavior toggle is removed; the mode persists.
- Ask Permission shows the prompt-review card as the SINGLE pre-edit checkpoint;
  Auto Approve shows nothing pre-edit. The `confirmAnchors` gate/state/pill are fully
  removed; anchor resolution + the review card's target rows still work.
- Menu geometry stays in lockstep; build + tests green; normal/artifact mode and the
  stall/feed work unaffected.

## Notes
- Why this is safe: the prompt-review *subsumes* the anchor-confirm — the review card
  already shows the resolved target(s) **and** the full prompt, so under Ask
  Permission you catch a wrong element by reading it. Auto Approve trades that for
  speed, with Undo (and cross-launch Undo) as the net — the product owner's explicit
  choice.
- This removes a Phase 2 milestone's worth of code; lean on the compiler + the
  exhaustive `switch`es to find every `.confirmAnchors` site, and keep the diff
  reviewable (the gate removal and the menu addition can be separate commits).
