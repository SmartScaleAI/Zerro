# Dev Mode Phase 2 — Milestone 0: client/server data-flow plan

**Status: awaiting review. No code written yet.** This resolves *where each deixis
step runs* before M1, per the Phase-2 handoff. Decisions marked **★ CONFIRM** are
the ones I want your explicit sign-off on.

## TL;DR decision

**Anchor resolution is fully client-side (the Mac), on both the BYOK and managed
paths.** The Mac owns the cursor track, native-res frames, the speech↔cursor
alignment, Apple Vision OCR, and crosshair marker compositing — it produces
*marked anchor frames + OCR strings + a referring-expression list + the word-level
transcript*, and feeds those into whichever **generation** path runs (local for
BYOK, the `/generate` edge function for managed). Generation returns the
`agent_prompt` **and** a structured per-reference anchor list (label/type/region/
confidence); the client then runs the M6 confidence gate (`confirmAnchors`) before
the agent ever touches the repo.

The only thing that differs by path is **where the word transcript comes from** and
**where generation runs** — never where anchors are resolved.

## Why anchor resolution can't be server-side

The deixis engine (§7) has four hard Mac-only steps with **no server equivalent**:
cursor polling (`NSEvent.mouseLocation`), native-Retina frame retention (the
downsampled JPEGs shipped to the server are too low-res for 11–13px UI text, §11),
Apple **Vision** OCR (`VNRecognizeTextRequest`), and Core Graphics **marker**
compositing. These run at the *aligned anchor moments*, and the alignment that
picks those moments needs **word-level timing** (the `[phrase−800ms, phrase+200ms]`
window, §7). So the client must hold the word transcript locally before it can
OCR/mark. → resolution is client-side; the server's only deixis role is producing
the transcript (managed) and weaving anchors into the prompt (managed generation).

## Where each step runs

| Step | BYOK (local) | Managed (server) | Notes |
|---|---|---|---|
| Cursor track (M1) | **client** | **client** | `NSEvent.mouseLocation` @~30Hz, rebased to `sessionStartPTS`. No permission. |
| Audio isolation + frames (existing) | client | client | unchanged `ProcessingPipeline`. |
| Native-res anchor frames (M3) | **client** | **client** | retain full-res frame near candidate moments; downsampled frames still ship for context. |
| Word-level transcript (M2) | **client** (local Whisper, add `word`) | **server → returned to client** (★) | see "Managed word timing" below. |
| Referring-expression scan + window + dwell (M4) | **client** | **client** | pure compute over (words, cursor track). |
| Coord map global→frame px (M4) | **client** | **client** | reuse `normalizedClick` transform (`RecordingSession.swift:1258`). |
| Marker compositing (M5) | **client** | **client** | Core Graphics on the native-res frame. |
| Apple Vision OCR (M5) | **client** | **client** | `VNRecognizeTextRequest(.accurate)`, on-device. |
| Generation → `agent_prompt` + structured anchors (M5/M7) | **client** (`OpenAIPromptGenerationService`) | **server** (`/generate`) | fed marked frames + OCR + referring-exprs + transcript + dev prompt. |
| Confidence combine + `confirmAnchors` gate (M6) | **client** | **client** | `AppState` dev pill machine. |
| Checkpoint → dispatch → revert (Phase 1) | client | client | unchanged. |

## ★ CONFIRM #1 — Managed word timing: server transcribes, returns the transcript (2-call managed)

Managed has no client transcript today (server STT, audio-only upload). Three options:

- **(A) client-local transcription pass for managed** — needs an OpenAI key the
  managed user deliberately *doesn't* have, or a bundled `whisper.cpp` (new
  dependency). ✗ contradicts the managed value prop / adds weight.
- **(B) server transcribes with word timestamps and returns them; the client
  resolves anchors, then calls `/generate` with the transcript + anchors. ✓ RECOMMENDED**
- (C) dwell-only single-call managed (mark/OCR *every* cursor dwell with no speech
  gate, let the server align). ✗ ships many native-res frames, diverges the
  architecture (client resolves for BYOK, server resolves for managed).

**Recommended: (B).** It keeps anchor resolution *symmetric* (same client code on
both paths), needs no client key or new dependency, and reuses the server's
existing Whisper. Cost: managed Dev Mode becomes **two server round-trips**:

```
MANAGED Dev Mode:
  1. POST /generate  {mode:"dev-transcribe", audio, has_speech}
        → returns { transcript: [(word,start,end)], segments }   (word-level; no generation yet)
  2. CLIENT resolves anchors locally (cursor+native frames+OCR+marker+align+client-confidence)
  3. CLIENT M6 gate: any low-confidence anchor → confirmAnchors pill, wait for confirm
  4. POST /generate  {mode:"dev", transcript, referring_exprs, marked_frames[], ocr[], frames[], clicks[]}
        → returns { agent_prompt, anchors:[{label,type,region,current_state,confidence,alt_candidates}] }

BYOK Dev Mode:
  1. CLIENT transcribes locally (existing Whisper pass + word granularity) — reused for both
  2. CLIENT resolves anchors locally
  3. CLIENT M6 gate
  4. CLIENT generates locally (OpenAIPromptGenerationService) with the same inputs → same output shape
```

`/generate` call 2 accepts a **pre-supplied transcript** (skips re-STT) so the
prompt is generated against the *exact* transcript the anchors were resolved
against, and we don't pay STT twice. (dwell-only single-call (C) is noted as a
possible future optimization if the 2nd round-trip ever matters.)

## ★ CONFIRM #2 — Element-ID folds into the generation call; the confidence gate runs *after* generation

§7/§8 put `confirmAnchors` **between `checkpointing` and `dispatching`** — i.e.
*after* the prompt is generated, *before* the agent runs. So I do **not** add a
separate per-reference "element-ID" model call. Instead the existing generation
call (already multimodal) is given the **marked native-res anchor frames + OCR
strings + the referring-expression list**, and the dev system prompt (M7) makes it
return, alongside the `agent_prompt`, a structured anchor per reference:

```
{ label, type(button|link|text|image|icon|input|container),
  region(header|nav|hero|sidebar|main|footer),
  current_state, confidence(0–1), alt_candidates[] }
```

This matches §7's "the **same** generation call … returns a structured anchor" and
avoids an extra call (and an extra managed round-trip). Generation is cheap
relative to an agent edit, so generating first and *then* confirming a low-confidence
anchor is the right order (and the confirm UI shows the model's resolved label).

### Confidence model (drives the M6 gate)

Per reference, two confidence sources combine **conservatively (take the lower)**:

- **Client signal** (computed in M4/M5, no model): `click` → high; strong cursor
  **dwell** + a clean dominant OCR label at the point → high; dwell + ambiguous/no
  OCR label → medium; transit / "this" said mid-move / empty space → low.
- **Model signal** (from generation): the model's agreement that the marked
  element matches a visible label → high/medium/low.

`combined = min(client, model)`. **Net rule (§7): all combined high/medium →
dispatch immediately; any combined low → `confirmAnchors` first.** This honors both
§7 confidence inputs (cursor *stillness* = client, *OCR/vision agreement* = model).

## Data contracts (new fields, all Dev-Mode-only)

Client→generation inputs gain (alongside today's frames/clicks/transcript):
- `referring_exprs: [{phrase, t_start, t_end, point:{x,y}, source:click|dwell|transit, dwell_confidence}]`
- `marked_frames: [{ref_index, native_jpeg, point:{x,y}}]` (only the few anchor moments, native res)
- `ocr: [{ref_index, strings:[{text, box}]}]`
- `transcript: [{word, start, end}]` (BYOK: local; managed: from call 1)

Generation→client output gains (Dev Mode only):
- the `agent_prompt` artifact (unchanged transport), **plus**
- `anchors: [{ref_index, label, type, region, current_state, confidence, alt_candidates}]`

Parsed defensively — unknown shapes degrade, never crash (mirrors the Phase-1
stream-json parser discipline).

## Extended pill state machine (§8)

```
processing → transcribing → resolvingAnchors → writingPrompt
   → devCheckpointing → confirmAnchors?(only if any combined-low) → devAgentDispatching
   → devAgentRunning → devDone | devFailed
```

`resolvingAnchors` is the new client step (cursor align + native frame + OCR +
marker). `confirmAnchors` is the new gate state (shows the resolved anchors;
dispatch only on confirm). Both are **Dev-Mode-only** additions to the existing
RecordingState; normal mode never enters them.

## Normal-mode invariance

Every new field, state, and step is gated behind a Dev-Mode recording
(`recordingIsDevMode` / a dev `RecordingState`). A normal recording: no cursor
track, no word-granularity request, no native-res retention, no anchor fields,
byte-identical generation request + prompt (the `prompt.ts` / Swift mirror test
still holds for the no-arg/normal path). The cursor tracker is only *started* for a
Dev Mode recording.

## Milestone landing map (where each future milestone's code lives)

- **M1 cursor track** — `Capture/CursorTracker.swift` (new) + `RecordingSession` (start/stop, rebase to `sessionStartPTS`), sidecar like `clicks.json`.
- **M2 word timing** — `OpenAITranscriptionService` (add `timestamp_granularities:["word"]`) for BYOK; the server STT return (call 1) for managed; optional domain dictionary from `package.json` before generation.
- **M3 native-res frames** — `ProcessingPipeline` (retain full-res `CGImage` near candidate moments, before downsample at lines ~384–394).
- **M4 alignment** — `Services/Dev/DeixisResolver.swift` (new): referring-expression scan, windowing, dwell, coord map.
- **M5 element-ID** — `DeixisResolver` + `Services/Dev/VisionOCR.swift` (new): marker + Vision OCR; generation inputs/outputs extended (Swift `OpenAIPromptGenerationService` + server `generate`).
- **M6 confidence + confirmAnchors** — `AppState` dev pill machine + `Surfaces/Pill/PillView.swift`; emit `dev_anchor_resolution`.
- **M7 prompt wiring** — `PromptGenerationSystemPrompt.swift` + `supabase/functions/generate/prompt.ts` (kept in sync; mirror test green).

## Open questions for review

1. **Confirm #1** — OK to make managed Dev Mode a 2-call flow (server returns the
   word transcript, then generates with anchors)? Or do you prefer a bundled
   `whisper.cpp` client pass to keep managed single-call?
2. **Confirm #2** — OK to fold element-ID into the one generation call (no separate
   per-reference model call) and gate `confirmAnchors` *after* generation, per §8?
3. Native-res marked anchor frames are the only large new payload on the managed
   path — capped to the few referring-expression moments (typically 1–5). Acceptable?
