# Claude Code handoff — Dev Mode, Phase 2 (the deixis engine)

Implement **Phase 2** of Dev Mode: resolve pointing language ("make *this*
bigger", "the header", "that button") to the on-screen element by fusing the
narration, a continuous cursor track, and the video frames — then anchor the
generated prompt to the element's **visible text** so the agent lands the edit.
This replaces Phase 1's click-only anchoring with reliable hover-anchored deixis.

## Read first
- `docs/DEV-MODE-DESIGN.md` — §6 (the dev prompt), §7 (the deixis engine — the
  core spec), §11 (research corrections: cursor polling, native-res OCR frames,
  approximate Whisper word timing, the transcription dictionary). **Binding.**
- `docs/HANDOFF-dev-mode-phase1.md` — what's already built (toolbar, registry,
  checkpoint, runner, `mode:"dev"` prompt, AppState dev branch, pill states).
- The pipeline you're extending: `Capture/RecordingSession.swift` (clock anchor),
  `Processing/ProcessingPipeline.swift` (frames + audio + manifest), the
  `Interleaver` (frames + transcript + clicks merge — the alignment engine),
  the transcription step, and the two prompt definitions
  (`PromptGenerationSystemPrompt.swift` + `supabase/functions/generate/prompt.ts`).

## Ground rules
- Everything stays gated behind a Dev Mode recording. Normal recordings and
  normal-mode generation must be byte-identical to today.
- Match surrounding code + comment style; focused, reviewable diffs.
- Analytics: metadata only, behind the opt-out gate (§14.5). The `dev_anchor_resolution`
  event (count + confidence histogram) lands here.
- Work milestone by milestone, build + test after each. **STOP for review after
  Milestone 0 (the data-flow plan) and again after Milestone 6 (confidence/confirm)
  before the live E2E.**

## Scope — Phase 2 ONLY
In: continuous cursor track; word-level transcript timing; native-res anchor
frames; the deixis alignment (referring-expression scan, windowing, dwell
detection); element-ID via marker compositing + Apple Vision OCR + the multimodal
call; the confidence/fallback policy + the `confirmAnchors` pill state; wiring
resolved anchors into the dev prompt.

Out (later/other phases): Codex/Cursor adapters, port→folder detection,
review-before-apply, the self-correction loop, quit-recovery, vision-capable agent
handoff (passing keyframes to the agent itself).

---

## Milestone 0 — Data-flow architecture plan (STOP for review)
Before any code, produce a short written plan (append to this doc or a new
`docs/HANDOFF-dev-mode-phase2-dataflow.md`) answering **where each step runs**,
because the pieces split across client/server:
- **Client-only (must be):** cursor capture, native-res frame grab, Apple Vision
  OCR, crosshair marker compositing. Apple Vision has no server equivalent.
- **Split by path:** word-level transcript timing is local in BYOK but server-side
  in managed; the heavy generation is local in BYOK, server (`/generate`) in managed.

Resolve: does anchor resolution run fully client-side (producing marked frames +
a structured anchor list + transcript that both paths then feed into generation),
or is some of it server-side? Recommended default: **client-side anchor
resolution** — the Mac resolves anchors and ships marked frames + the anchor list
+ transcript to whichever generation path runs. State how managed gets word
timing under that model (e.g. the existing transcription result is returned and
reused, or a client transcription pass for Dev Mode). Get this reviewed before M1.

## Milestone 1 — Continuous cursor track
Files: `Capture/RecordingSession.swift` (or a new `Capture/CursorTracker.swift`).
- Sample the global cursor at ~30Hz by **polling `NSEvent.mouseLocation` on a
  timer** (research-confirmed more reliable than a `.mouseMoved` monitor; needs
  **no permission**). Do NOT add an event monitor.
- Stamp each sample on the **same clock** as audio/video — rebase to
  `RecordingSession`'s first-sample-buffer anchor (§7 clock sync).
- Store the track alongside the recording (a compact `[(t, x, y)]`).
*Test:* samples are monotonic in `t`, rebased to recording-zero, captured for the
recording's full duration.

## Milestone 2 — Word-level transcript timing
Files: the transcription step (BYOK local Whisper call + the managed
`generate`/transcription path as decided in M0).
- Request word-level timestamps (`timestamp_granularities: ["word"]` /
  whisper.cpp word timing). Carry `[(word, start, end)]` through to the resolver.
- Note (§11): word timing is approximate (~0.1–0.2s, worse near pauses) — the
  early-biased window (M4) absorbs it; don't assume frame accuracy.
- Optional include (§11): a **domain dictionary** seeded from the project's
  `package.json` deps + component filenames to fix mangled library/component names
  before prompt generation.
*Test:* a known clip yields per-word start/end; the dictionary swaps a seeded term.

## Milestone 3 — Native-resolution anchor frames
Files: `Processing/ProcessingPipeline.swift`.
- The ~5fps downsampled JPEGs are too low-res for OCR of 11–13px UI text (§11).
  At/near candidate anchor moments, retain a **native-Retina full-res** frame for
  the OCR + marker step. Keep the downsampled frames for everything else.
*Test:* a full-res frame is available for a given anchor timestamp at backing scale.

## Milestone 4 — Deixis alignment
Files: extend the `Interleaver` (or a new `Services/Dev/DeixisResolver.swift`).
- Scan the timestamped transcript for **referring expressions**: deictics (this,
  that, these, here, it) AND definite noun phrases ("the header", "the button").
- For each, open a window **biased earlier** than the phrase (pointing precedes
  speech): `[phrase_start − 800ms, phrase_end + 200ms]`.
- Pick the target point by priority **click > hover-dwell > last-known**; dwell =
  the stillest cursor cluster in the window. Stillness → a confidence input.
- Map the point from global screen space → the recorded cropped-region pixel space
  (Y-flip + Retina scale, same transform the selector uses).
- Grab the nearest native-res frame (M3). Output: candidate anchors
  `[(phrase, t, point, frameRef, dwellConfidence)]`.
*Test:* a hover-dwell during "this" selects the dwell point; transit movement is
not chosen; the coordinate maps into frame pixels correctly.

## Milestone 5 — Element-ID (marker + OCR + model)
Files: `Services/Dev/DeixisResolver.swift`, a new `Services/Dev/VisionOCR.swift`.
- Composite a crosshair **marker** on the native-res frame at the cursor point.
- Run Apple **Vision** `VNRecognizeTextRequest` (`.accurate`, on-device, no
  permission) on the region near the point → exact visible strings + boxes.
- Feed marked frame + nearby OCR strings + the narration to the multimodal model
  (the same generation call). It returns, per reference, a structured anchor:
  `{ label, type(button|link|text|image|icon|input|container), region(header|nav|
  hero|sidebar|main|footer), current_state, confidence(0–1), alt_candidates[] }`.
- Defensive: unknown shapes degrade, never crash.
*Test:* a marked frame + OCR strings for a labeled element yields the right
`label` at high confidence; an unlabeled icon yields lower confidence + alts.

## Milestone 6 — Confidence policy + confirmAnchors pill (STOP for review)
Files: `AppState.swift`, `Surfaces/Pill/PillView.swift`, the dev pill state machine.
- Per-reference confidence drives dispatch (§7):
  - **High** (click, or clean dwell whose OCR label matches) → stated as fact;
    dispatch proceeds automatically.
  - **Medium** (dwell, fuzzy label) → hedged "likely the X" + disambiguating
    context (region + nearby text) in the prompt; still auto-dispatches.
  - **Low** (said "this" mid-move, empty space, OCR/vision disagree) → insert a
    **`confirmAnchors`** pill state BEFORE `checkpointing`: show the resolved
    anchor(s) for a one-glance confirm; dispatch only on confirm.
- Net rule: **all high/medium → dispatch immediately; any low → confirm first.**
- Emit `dev_anchor_resolution` (count + confidence histogram) here.
*Test:* an all-high recording dispatches with no confirm; a deliberately ambiguous
reference routes to `confirmAnchors` and waits.

## Milestone 7 — Wire anchors into the dev prompt
Files: `PromptGenerationSystemPrompt.swift` + `supabase/functions/generate/prompt.ts`.
- Replace Phase 1's click-only anchoring: weave the resolved anchors (label +
  current→desired + region) into the `Goal/Changes/Scope` body, ordered as spoken.
- Keep §6/§11 constraints (visible-label anchors, route context, runtime note,
  CSS/token/flex/dark-mode/minimal, preserve the user's literal phrasing).
- Keep both definitions in sync; the no-arg/normal path stays byte-identical
  (mirror test holds).
*Test:* the dev prompt cases assert anchored changes + the constraints; mirror test green.

## Milestone 8 — Tests + live E2E
- Unit: cursor track, alignment/dwell, OCR parse, confidence routing, prompt shape.
- Live (throwaway repo, real localhost): record and say "make *this* bigger" while
  hovering an element with no click → resolves to the correct labeled element and
  edits it. Then a deliberately vague/ambiguous point → the `confirmAnchors` step
  appears instead of a wrong edit.

---

## Acceptance criteria (Phase 2 done)
- A **hover-only** reference (no click) resolves to the correct element by its
  visible label at high confidence and the agent edits the right thing.
- A deliberately **ambiguous** reference triggers `confirmAnchors` rather than a
  confident wrong edit.
- Cursor tracking adds **no new permission**; OCR is on-device; normal mode is
  unchanged.
- The dev prompt is anchored to visible text with the §11 constraints; mirror test
  green.

## Suggested commit boundaries
M0 plan (doc only); then one commit per milestone. M4 (alignment) and M5
(element-ID) are the substantive services — good standalone, well-tested commits.
