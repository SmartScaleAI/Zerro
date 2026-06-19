# Claude Code handoff — remove the "Write agent prompt" convert affordance

Remove the **"✎ Write agent prompt"** button from the artifact result card. It's the
sole entry point to the Phase 6 "convert a chat/transcription artifact into an agent
prompt" feature — now **redundant**, since Dev Mode generates agent prompts natively.

**Scope: remove the whole feature, not just the button.** The button is the only
trigger, so hiding it would orphan all the conversion machinery. Remove the button +
its UI + the controller wiring + the AppState conversion path. (Leave the backend
`convert` edge function deployed-but-unused — retiring it is a separate ops step.)

App-only (Swift). Lean on the compiler's "unused"/exhaustive errors to find every
reference; keep it one clean, reviewable removal.

## What to remove (the full surface)
- **`Surfaces/Pill/ArtifactCardView.swift`** — `conversionButton` (~495, the "Write
  agent prompt" Button), `conversionFailureNote` (~525), the `conversion:
  ConversionAffordance` (~47) and `onConvert` (~56) parameters, their render sites
  (the `else if conversion != .hidden { conversionButton }` at ~325–326 and the
  failure-note branch at ~160–161), and the `ConversionAffordance` type wherever it's
  defined/passed. The chat-only result then renders its text + charge line + `×` with
  no convert footer.
- **`Surfaces/Pill/PillView.swift`** — the conversion-affordance plumbing/comments
  (~18–22) that thread `ConversionAffordance`/`onConvert` through.
- **`Surfaces/Pill/PillWindowController.swift`** — `conversionAffordance` (~292) and
  the `conversion:`/`onConvert: { appState.convertToAgentPrompt() }` wiring (~353–354).
- **`AppState.swift`** — `convertToAgentPrompt()` (~3410), `canConvertToAgentPrompt`,
  `ConversionStatus` (~3378), `conversionStatus` (~3382), `conversionTask` (~3384),
  the convert `Task` + its `proxy.convert(...)` / BYOK `convert(...)` calls
  (~3427–3512), and the teardown cleanup (`conversionTask?.cancel()` + status reset at
  ~993–995 and ~1214–1216). Remove any conversion analytics events too.
- **The `convert` client methods** — `ManagedProxyClient.convert` and the BYOK
  `convert` (BYOKRouting) — remove them **only if** they're exclusively used by this
  path (grep to confirm no other caller). If something else uses them, leave them.

## What to KEEP
- The backend `supabase/functions/convert` (if it exists) — leave it deployed; it's
  just unused now. (Out of scope; retire separately.)
- Everything else on the artifact card — chat text, body well, copy capsule, the
  charge line, the `×` dismiss, the failure card — unchanged.
- Dev Mode's agent-prompt generation — entirely separate, untouched.

## Tests
- Delete the conversion tests (the convert lifecycle / affordance-mapping tests).
- Add/adjust: a chat-only (artifact == nil) result card renders correctly **without**
  a convert button — text + charge line + dismiss, no layout break.
- The build is green with no dangling references (the compiler confirms the removal is
  complete); artifact + dev result cards and the failure card are unaffected.

## Acceptance criteria
- The "Write agent prompt" button is gone from the artifact response view; there's no
  remaining conversion UI, state, task, or app-side `convert` call.
- A chat/transcription result still shows its content, charge line, and dismiss —
  just no convert affordance.
- Artifact mode (minus this button), Dev Mode, and the failure/result cards all still
  work; build + tests green.

## Notes
- This is a straight feature deletion — the cleanest signal you've got it all is a
  green build with the conversion symbols fully gone. Keep it a self-contained commit
  so it's easy to review (and to revert if ever needed).
