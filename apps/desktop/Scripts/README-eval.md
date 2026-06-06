# Model eval harness

Compare chat/vision models on real Zerro recordings **without** deploying,
Supabase, JWTs, or burning credits. The harness replicates the production
pipeline exactly — same whisper-1 transcription request, same locked system
prompt, same chronological frame/speech interleaving, same per-provider wire
formats — so what you see here is what the Managed path will produce.

Phase 0 also makes the loop **re-runnable end to end**: the raw `.mov` and the
extracted working dir can both be retained and captured, and a real-pipeline
runner (`zerro-extract`) re-extracts frames/audio/manifest from a captured
`.mov`. That's what lets upcoming phases (frame sampling, resolution, OCR) be
measured through production code instead of a reimplementation.

## One-time setup

```bash
export OPENAI_API_KEY=sk-...    # always required (whisper STT)
export GEMINI_API_KEY=...       # required for gemini:* models
chmod +x Scripts/capture-recording.sh Scripts/zerro-extract.sh
```

Requires Node 18+ (uses built-in fetch/FormData). No npm installs.
`zerro-extract` additionally needs Xcode command-line tools.

## Workflow

### 1. Capture a recording (working dir **and** raw `.mov`)

The app deletes its artifacts after a successful generation, so retain them and
snapshot to the corpus.

**Turn on eval retention (DEBUG only):** in Xcode, *Edit Scheme ▸ Run ▸
Arguments* add the launch argument `-RetainEvalArtifacts YES`, then run the app
from Xcode. With it on, both the source `zerro-<UUID>.mov` and the
`zerro-work-<UUID>` working dir survive a full record → generate cycle. (Without
it, only the working dir can be captured — fine for model A/B, but you can't
re-extract.) Retention is compiled out of Release builds; production cleanup is
unchanged. The next app launch still sweeps tmp, so retained artifacts don't
accumulate — capture them in the same session.

```bash
./Scripts/capture-recording.sh     # leave running
# …record something in Zerro as normal…
# → "captured: eval-recordings/zerro-work-<UUID> (31 frames + source.mov)"
```

Each capture lands in `eval-recordings/<name>/` containing the working dir
contents (manifest.json + audio + frames) plus `source.mov` (when retention was
on). The `.mov` is paired to the working dir by recency, since their UUIDs
differ.

### 2. (Optional) re-extract from the raw `.mov`

Run the **real** `ProcessingPipeline` on a captured recording and write a fresh
working dir. Use this to evaluate a frame-sampling / resolution / OCR change:
re-extract, then diff against the originally captured manifest.

```bash
Scripts/zerro-extract.sh eval-recordings/<name>/source.mov --out /tmp/reextract
# prints frame count + first/last timestamps; writes manifest.json + frames + audio
```

Sanity check (same config → same result): the re-extracted frame count and
timestamps should match `eval-recordings/<name>/manifest.json`. Under the hood
this drives the `EvalExtractionRunnerTests/testExtract` XCTest (`@testable
import Zerro`) so extraction is never duplicated — it's the production pipeline.

### 3. (Optional) add a ground-truth note

Drop a `meta.json` beside the manifest so accuracy/hallucination scoring has a
reference. All fields optional:

```json
{
  "scenario": "Refactoring a Swift error handler",
  "groundTruth": "On screen: ProcessingError.swift, func isolateAudio, button labeled \"Save\"",
  "expectation": "Instruction that names isolateAudio and the Save action without inventing values"
}
```

It's surfaced at the top of the scorecard.

### 4. Run the comparison

```bash
node Scripts/eval-models.mjs eval-recordings/<name> \
  --mode instruct \
  --models gemini:gemini-3.5-flash,gemini:gemini-3.1-pro-preview,openai:gpt-4o
```

Flags:
- `--mode instruct|explain` (default instruct)
- `--models provider:model,...` — must be priced in the script's table to get
  cost estimates; unpriced models still run, cost shows "unpriced"
- `--thinking low|high` — Gemini only (default low). For the Pro A/B run it at
  BOTH levels so model quality is isolated from thinking depth.
- `--out dir` (default `eval-results/`)

### 5. Compare

Outputs land in `eval-results/`:
- **`<stamp>_<mode>_<model>.md`** — one per model, headed with recording name,
  **frame count**, **input/output token counts**, latency, and estimated cost.
- **`SCORECARD.md`** — combined, per run-batch. Puts every model SIDE BY SIDE
  with the recording name, frame count, an inline visual index of the frames
  (markdown image links, paths relative to the scorecard — no copying, no npm
  dep), each model's full output, its latency/tokens/cost, the `meta.json`
  ground-truth note (if present), and a blank **1–5 rubric grid** to fill in.

Whisper runs once per recording (cached as `transcript.eval.json` in the
captured dir), so re-running against more models costs only the chat calls.

## Rubric (filled into SCORECARD.md, score 1–5)

- **Small-text fidelity** — did it read on-screen code/UI text correctly?
- **Deixis** — did it resolve "this/that/here" to the right frame/element?
- **Hallucination** — did it invent names/values not shown or said? (5 = none)
- **Faithfulness** — to intent (instruct mode) / accuracy (explain mode)
- **Cost (USD)** and **Latency (s)** — recorded automatically.

## Suggested eval matrix before rollout

3–5 recordings covering your real use cases (dense code on screen, small UI
text, mixed app windows), each through:

| run | model | thinking |
|---|---|---|
| 1 | gemini:gemini-3.5-flash | low |
| 2 | gemini:gemini-3.1-pro-preview | low |
| 3 | gemini:gemini-3.1-pro-preview | high |
| 4 | openai:gpt-4o | — |

Whichever wins becomes `CHAT_MODEL` at rollout — no code change.

## Keep in sync

The system prompt, interleaving, wire formats, and pricing are mirrored from:
`supabase/functions/generate/{prompt,interleave,cost}.ts` and
`providers/{openai,gemini}.ts`. If those change, update `eval-models.mjs`. The
`CHAT_PRICING` table must price every model in the matrix above (a 1:1 mirror of
`cost.ts`) so no run shows "unpriced".
