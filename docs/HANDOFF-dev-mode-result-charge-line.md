# Claude Code handoff — show the credits charge line on the Dev Mode result card

The Dev Mode result card doesn't show the **"−N credits · M left"** line that the
artifact-mode result card shows bottom-left. Managed Dev Mode *does* incur a metered
charge (the prompt generation / "eyes" step), and the data is already captured — it's
just suppressed and not plumbed into the dev card. Surface it, matching artifact mode.

App-only (Swift), UI/wiring. Small + focused.

## The facts (already in place)
- `AppState.lastGenerationCharge: GenerationCharge?` (charged, remaining) is set on
  the **managed** generation path **including dev** (`AppState.swift` ~2184/2212,
  inside the `recordingIsDevMode` branch) and stays **nil for BYOK** (no managed
  call). So the dev charge data exists at `.devDone` for managed, and is correctly
  absent for BYOK.
- `ArtifactCardView` already renders the charge line: `chargeLine: String?` ("−N
  credits · M left", ~line 41), drawn in the footer at **~line 304** — but the
  condition is `if let chargeLine, failure == nil, devResult == nil` — the
  **`devResult == nil` explicitly suppresses it for the dev card.**
- The bridge builds the dev card via `devResultCard` (`PillStateBridge.swift` ~167)
  → `.devDone(card:expanded:)` — and **does not pass a charge line**.

## The fix
1. **Plumb the charge line into the dev card.** Where the bridge builds the artifact
   result's `chargeLine` string from `lastGenerationCharge` (the "−N credits · M
   left" formatting — find that exact formatter and **reuse it verbatim** so dev and
   artifact read identically), produce the same string for the `.devDone` path and
   carry it into the card (add a `chargeLine` to the `.devDone` PillState / the
   `DevResultConfig`, or pass it alongside). When `lastGenerationCharge` is nil
   (BYOK), it's nil → nothing shows (exactly like artifact mode with no
   `credits_charged`).
2. **Un-suppress it for the dev card.** In `ArtifactCardView` ~304, drop the
   `devResult == nil` clause so the charge line renders for the dev result too:
   `if let chargeLine, failure == nil { … }`. (Keep the `failure == nil` guard — the
   charge line is a success-only readout; `.devFailed` shouldn't show it.)
3. **Place it bottom-left, aligned like artifact mode.** The dev footer has the
   View changes / Undo / Accept buttons; put the charge line in the **bottom-left**
   of that footer row (charge left, buttons right), the same position artifact mode
   uses (charge left, copy capsule right). Make sure it doesn't collide with or push
   the buttons — it shares the footer row, not a new line below it.
4. Match artifact mode's collapsed/expanded behavior: show the charge line wherever
   the artifact result shows it (the expanded card footer at minimum, per the
   screenshot; mirror the compact-pill treatment if artifact mode has one).

## Tests
- Bridge: a managed dev result with a `lastGenerationCharge` produces the `.devDone`
  card carrying the same "−N credits · M left" string artifact mode would; a BYOK dev
  result (nil charge) carries no charge line.
- Render: `.devDone` with a charge line shows it bottom-left in the footer alongside
  Undo/Accept; without one, the footer is unchanged. `.devFailed` never shows it.
- Artifact result charge line unchanged (the `devResult == nil` removal doesn't
  affect the artifact path — `devResult` is already nil there).

## Acceptance criteria
- A **managed** Dev Mode run shows "−N credits · M left" bottom-left on the result
  card, identical formatting + position to artifact mode; **BYOK** shows nothing.
- The charge line never appears on `.devFailed`; the artifact result card is
  unchanged.
- Build + tests green.

## Notes
- Conceptually correct: managed Dev Mode bills the prompt generation just like
  artifact mode (the agent's own runtime is never billed), so the same charge
  readout belongs on both result cards. This was only suppressed as result-card
  chrome earlier — now it's wanted.
