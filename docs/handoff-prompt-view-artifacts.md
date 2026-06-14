# Claude Code handoff — update the website "prompt view" to the typed-artifact model

## Goal

The marketing site's output section in `apps/web/components/templates/axis/tools.tsx`
still illustrates the **old** product model: one recording → two *modes*
("Instruct" / "Explain") toggled above a single prompt card.

The app has since moved to a **typed-artifact** model: a recording produces one
of several typed artifacts, each with its own card title, one-line description,
body rendering, icon, and copy-button label.

Rework this section so it accurately illustrates the new model, with a toggle
above the card that switches between **four artifact types**, each rendering a
true-to-app example card. Match the app's current card design exactly
(including the credits footer).

## Source of truth — do not invent type behavior

The artifact contract lives in
`apps/desktop/Zerro/Services/ResponseModels.swift` (`enum ArtifactType`). Use it
verbatim for button labels, icons, and body rendering. The four types to show:

| Type (toggle label) | Button label | Icon (lucide-react) | Body rendering        |
|---------------------|--------------|---------------------|-----------------------|
| Agent prompt        | Copy Prompt  | `Braces` (`{}`)     | markdown, mono-leaning |
| Message             | Copy draft   | `Mail` (envelope)   | prose                  |
| Snippet             | Copy snippet | `Code` (`</>`)      | monospace, exact       |
| Document            | Copy text    | `FileText` (doc)    | prose                  |

Do **not** include the fifth type, `generic` — it's an internal fallback, not a
marketed capability.

## Card design — match the app exactly

Replicate the app's artifact card (reference: the in-app screenshot). The card
chrome stays fixed gray (`bg-[#202022]`) in both themes, as it is today. Layout
top to bottom:

1. **Header row**
   - Left: a green circular check (reuse the existing `Check` badge) followed by
     the **artifact title** in bold white (~15px). The title changes per type
     (this replaces the old static "Prompt ready" label).
   - Right: a muted "Hide ⌃" control and a small "×" close glyph. These are
     decorative (non-functional) — they exist to match the app shell.

2. **Description line** — one sentence in muted white (~`text-white/60`), sitting
   directly below the header, above the body. Changes per type.

3. **Body** — inset near-black panel (`bg-[#0a0a0b]`, the existing inset style).
   Render per the table above: monospace for Snippet and the mono-leaning Agent
   prompt; prose paragraphs for Message and Document. Reuse the current
   bullet/paragraph rendering helpers where they fit.

4. **Footer row**
   - Left: muted small text `−4 credits · 147 left` (static representative value;
     keep it constant across types unless trivial to vary).
   - Right: a white pill button showing the type's **icon + button label** (e.g.
     "Copy Prompt", "Copy draft"). Keep the existing copy-to-clipboard behavior —
     copy the **body only**, verbatim (per the contract, copy payload is body-only
     for every type). Keep the "Copied" confirmation state.

## Toggle — replace the Instruct/Explain switcher

Replace the two-button mode switch with a segmented control of four options:
**Agent prompt · Message · Snippet · Document**. Keep the existing pill/segment
styling, `role="group"`, `aria-pressed`, and keyboard focus behavior. Selecting a
type updates the card's title, description, body, body rendering, footer button
icon + label.

On narrow screens the four labels must not overflow — allow wrapping or shorten
labels responsively as needed.

## Section copy

- Keep the eyebrow "The output" and headline "The prompt writes itself." (or
  adjust the headline if you find a cleaner fit for the multi-type story).
- Change the intro paragraph to reflect typed artifacts rather than two modes.
- Change the switcher's left-hand label from "Same recording, two modes" to
  **"One recording. The right artifact."**
- Keep the closing line "Example output. Every prompt is generated from your real
  recording."

## Exact example content for each type

Use these verbatim as the example data (model after the current
`INSTRUCT_EXAMPLE` raw-string approach so Copy grabs the body exactly).

### 1. Agent prompt
- **Title:** Show an inline error when an invalid promo code is applied
- **Description:** Instructs your AI agent to fix the silent failure on the
  checkout promo-code field and surface a clear validation error.
- **Body:**
  ```
  Fix the promo-code validation on the checkout Order Summary.

  1. Locate the "Apply" button beside the promo-code field (current value: SAVE20) in the Order Summary panel.
  2. When an applied code is invalid or expired, the field currently does nothing — no error, no spinner, no state change.
  3. On an invalid code, render an inline error directly beneath the field in red (e.g. "This code is expired or invalid").
  4. Keep the existing layout and totals; this is a validation fix, not a redesign.
  ```

### 2. Message
- **Title:** Email Sarah: launch slipping Tuesday → Friday
- **Description:** A ready-to-send note about the timeline change — apologetic,
  but not groveling.
- **Body:**
  ```
  Subject: Launch moving to Friday

  Hi Sarah,

  Quick heads-up on the launch timeline. The API migration ran longer than we scoped, so we're moving the launch from Tuesday to Friday to land the cutover cleanly rather than rush it.

  The Thursday demo is unaffected — everything we're showing there is already in place.

  Sorry for the shift. I'll send a firm Friday window by end of day tomorrow.

  Thanks,
  [You]
  ```

### 3. Snippet
- **Title:** SUMIF — total of column C where column B is "Paid"
- **Description:** The exact formula to paste into your cell — totals column C
  for every row marked Paid in column B.
- **Body:**
  ```
  =SUMIF(B:B, "Paid", C:C)
  ```

### 4. Document
- **Title:** Roadmap offsite — team summary
- **Description:** Your raw offsite notes written up as a shareable summary,
  organized into what's decided, what's open, and who owns what.
- **Body:**
  ```
  Roadmap Offsite — Summary

  Decided
  - Q3 priorities are locked and dated.
  - Checkout revamp ships first, ahead of the billing work.

  Open
  - Platform rewrite — still under discussion; not committed for Q3.
  - Mobile parity — scope TBD pending the rewrite call.

  Owners
  - Checkout revamp — Priya
  - Billing — Marcus
  - Platform rewrite decision — Sarah, by end of month
  ```

## Constraints

- This is a **marketing illustration**, not a live tool: example data only, no
  network calls. The only real interaction is the type toggle and the
  body-only Copy button (keep both).
- Stay within the existing styling conventions of the file (Tailwind classes,
  `motion/react` entrance animation, lucide-react icons, the fixed-gray card
  chrome). Don't introduce new dependencies.
- Preserve accessibility: `aria-pressed` on toggle buttons, `aria-label` on the
  group, focus-visible states, and meaningful button labels.
- Keep the component a single client component; don't split files.

## Verify before done

- Toggle through all four types: title, description, body, body font, footer
  icon, and footer button label each update correctly and match the contract
  table.
- Copy copies the **body only**, verbatim, for the selected type, and shows the
  "Copied" state.
- Layout holds at mobile width (no overflow in the four-way toggle or footer).
- Light and dark themes both render the fixed-gray card correctly.
- `npm run build` (or lint/typecheck) in `apps/web` passes.
