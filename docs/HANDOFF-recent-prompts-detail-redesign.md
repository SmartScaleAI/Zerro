# Claude Code handoff — redesign the Recent Prompts detail header + toolbar

**Goal:** the Recent Prompts detail pane crams the prompt **title** and the **Copy /
Delete buttons** into the same top row. When the title wraps to two lines it fights the
buttons for horizontal space and the header reads as "smashed together." Fix the layout
so the title owns its own row and the actions live in a dedicated toolbar, with the
destructive Delete separated and guarded by a confirm step.

App-only (Swift/SwiftUI), UI-layout only. No store, model, or copy-semantics changes.
Keep the two-pane (list + detail) layout — that stays.

## Where the code is
All in `apps/desktop/Zerro/Surfaces/RecentPrompts/RecentPromptsView.swift`:
- `DetailPane` (~lines 233–338) — the pane being redesigned.
  - The cramped header `HStack` is lines **241–258** (title `VStack` + `Spacer()` +
    `actions`).
  - `actions` computed (Copy button + trash button) is lines **312–330**.
- `SidebarRow` (~lines 172–229) — `lineLimit(2)` at **192**, selection `fill` at
  **218–222**.
- View-level `copy(_:)` **137–149** and `delete(_:)` **151–167** — reuse as-is (only
  the delete trigger gains a confirm step; the delete logic itself, including the
  next-selection pre-pick, does not change).

Tokens/styles already in the codebase — reuse, don't invent:
- `DesignSystem/Colors.swift`: `Color.vfAccentBlue` (#0A84FF), `Color.vfDestructive`
  (#FF453A), `Color.vfHairline`, `Color.vfTextPrimary/Secondary/Tertiary`,
  `Color.vfCardBackground`, `Color.vfPanelBackground`.
- `Surfaces/Settings/SettingsCard.swift`: `SettingsSecondaryButtonStyle`,
  `SettingsDestructiveButtonStyle`.
- `VFSpacing` (xs/sm/md/lg) and `VFRadius` (sm/md) for spacing + corners.

## Part 1 — detail header: give the title its own row
Restructure `DetailPane.body`'s top `HStack` (241–258) into a **vertical header** with
no buttons in it:
- **Line 1 (metadata):** the type glyph (`entry.displayIconName`) + the absolute
  timestamp (`Self.absolute.string(from:)`) in `vfTextSecondary`, ~11pt. If a
  human-readable type name is trivially available from `entry.resolvedArtifactType`,
  you may render it as a small pill here — otherwise skip the pill, don't invent a
  type→label API.
- **Line 2 (title):** `entry.title` on its **own full-width row**, ~15pt semibold,
  `vfTextPrimary`, `lineLimit(2)`, no trailing button competing for space.
- Then the existing 0.5pt `vfHairline` divider (261–263).

## Part 2 — a dedicated action toolbar (replaces the header's `actions`)
Add a horizontal toolbar row **below the hairline, above the ScrollView**:
- **Copy** stays the primary action, left-aligned, keeping
  `SettingsSecondaryButtonStyle`, the `doc.on.doc` → `checkmark` swap, and the per-type
  `buttonLabel` ("Copy Prompt" / "Copied") exactly as today (312–322).
- `Spacer()` to push Delete to the far edge.
- **Delete** becomes an **icon-only** trash button (`SettingsDestructiveButtonStyle`,
  keep `.help("Delete this prompt")`) on the **far right**, visually separated from
  Copy so it can't be fat-fingered.
- Do **not** add a Pin/other new action — out of scope (no backing store for it).

## Part 3 — confirm before delete
Delete is currently immediate. Add a standard SwiftUI **`.confirmationDialog`** (there's
no existing confirm pattern in the app, so introduce one here):
- The trash button sets a `@State private var pendingDelete: RecentPrompt?` (or a bool),
  and the dialog's destructive "Delete" role button calls the existing `onDelete()`.
  Keep "Cancel" as the cancel role.
- Wording per the design-system content rules: title like `Delete this prompt?`, a
  destructive button labeled `Delete`. Verb-first, sentence case, no "Are you sure."

## Part 4 — sidebar rows: single-line + clearer selection
In `SidebarRow` (172–229):
- Change the title `lineLimit(2)` → **`lineLimit(1)`** with `.truncationMode(.tail)` so
  rows are single-line and scannable (the timestamp line stays).
- Strengthen the **selected** state so it's obviously the active row rather than the
  current faint gray: selected `fill` → a subtle accent tint
  (`Color.vfAccentBlue.opacity(~0.16)`), and tint the leading glyph + title toward the
  accent when selected. Keep the three-tier model (clear → faint hover → selected) and
  the existing inset-pill shape.
- **Date grouping (optional, view-only):** if low-risk, group the flat
  `recentPrompts.prompts` into "Today / Yesterday / Earlier" sections with small
  `vfTextTertiary` section headers, derived purely from `entry.timestamp` in the view.
  No store change. If it complicates the `selectedID`/`ensureSelection` flow, skip it
  and keep the single flat list — the header/toolbar fix (Parts 1–3) is the priority.

## Non-goals (do not change)
- `RecentPromptStore`, the `RecentPrompt` model, the on-disk JSON, the 50-entry cap,
  dedup, or title derivation.
- `copyPayload` / per-type copy semantics, and the `delete(_:)` next-selection pre-pick.
- The empty state, the HSplitView min/ideal/max widths, and the column hairline seam.

## Verification
- Select a prompt with a **long, two-line title**: the title no longer collides with
  any button; the toolbar sits on its own row; Copy left, Delete far right.
- Copy still swaps to "Copied" + checkmark and puts the right per-type payload on the
  clipboard; the reset-after-~1.4s tick still works.
- Delete now shows a confirm dialog; confirming removes the row and advances selection
  exactly as before; canceling leaves it untouched.
- Sidebar rows are single-line/truncated; the selected row is clearly distinct from
  hover and idle. If grouping was added, sections render and selection still survives a
  delete.
- Both `#Preview("Populated")` and `#Preview("Empty")` still render; build + tests green.

## Acceptance criteria
- Detail header shows metadata + a full-width title with the actions pulled out into a
  separate toolbar; Delete is icon-only, separated, and confirm-guarded.
- Sidebar rows are single-line with a clearly stronger selected state.
- No store/model/copy-semantics changes; two-pane layout preserved; build + tests green.

## Notes
- Rationale: the header was doing three jobs (title, Copy, Delete) in one row, so a
  wrapping title had nowhere to go. Splitting title (owns its row) from actions (own
  toolbar) removes the contention; separating + confirming Delete removes the
  accidental-destroy risk of it sitting flush against Copy.
