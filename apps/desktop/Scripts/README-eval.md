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
export OPENAI_API_KEY=sk-...    # always required (whisper STT) + openai:* models
export GEMINI_API_KEY=...       # required for gemini:* models
export ANTHROPIC_API_KEY=sk-ant-...  # required for anthropic:* models (Phase 0)
chmod +x Scripts/capture-recording.sh Scripts/zerro-extract.sh
```

> The three keys live in `supabase/.env.local` (`OPENAI_API_KEY`, `GEMINI_API_KEY`,
> `ANTHROPIC_API_KEY`). Export them into your shell before running, e.g.
> `set -a; source ../../supabase/.env.local; set +a` from `apps/desktop/`.

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
  --models gemini:gemini-3.5-flash,anthropic:claude-opus-4-7,openai:gpt-5.5
```

Flags:
- (typed-artifact refactor: `--mode` is GONE — there is one unified v2 prompt,
  read at run time from `Scripts/artifact-eval/prompt-v2.md`; output filenames
  carry a `v2` label where the mode used to be)
- `--models provider:model,...` — `provider` is one of `openai`, `gemini`,
  `anthropic`; must be priced in the script's table to get cost estimates;
  unpriced models still run, cost shows "unpriced"
- `--thinking low|high` — Gemini only (default low; ignored by openai/anthropic).
  For the Pro A/B run it at BOTH levels so model quality is isolated from
  thinking depth.
- `--out dir` (default `eval-results/`)

Anthropic models run with **thinking off** and no sampling params — the minimal
Messages-API shape (`model` + `max_tokens` + `system` + one user turn). That is
the cleanest test of whether the model obeys "Output ONLY the final result"
without a thinking scaffold doing the work, and it mirrors what Phase 3's
`providers/anthropic.ts` is expected to send.

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

## Phase 0 eval matrix (multi-model gate)

The six candidate models from the multi-model plan §1.1, run on ≥5 real
recordings spanning dense code/terminal text, small UI text, and mixed windows
(`eval-recordings/` already has these). HISTORICAL (pre-refactor): this matrix
was run in BOTH v1 modes; the `--mode` flag no longer exists — the commands
below are kept as a record of the Phase 0 gate, not as runnable recipes:

| # | provider:model | tier (by cost) | thinking |
|---|---|---|---|
| 1 | `openai:gpt-5.4-mini` ⚠️ | Lowest cost | — |
| 2 | `gemini:gemini-3.5-flash` ⭐ | Lowest cost | low |
| 3 | `gemini:gemini-3.1-pro-preview` | Mid | low |
| 4 | `gemini:gemini-3.1-pro-preview` | Mid | high |
| 5 | `anthropic:claude-sonnet-4-6` | Mid | off |
| 6 | `anthropic:claude-opus-4-7` | Highest cost | off |
| 7 | `openai:gpt-5.5` | Highest cost | — |

⚠️ **`gpt-5-mini` (plan §1.1) does not exist** at OpenAI. `gpt-5.4-mini` is the
current cheapest GPT-5-family mini and stands in for it pending Colin's
confirmation of the intended id. ⭐ Gemini 3.5 Flash is the plan's recommended
model. Gemini Pro is run at BOTH thinking levels so model quality is isolated
from thinking depth.

One full pass per recording is two invocations (instruct + explain), e.g.:

```bash
REC=eval-recordings/zerro-work-6C25EA65-1546-410F-8C93-565AF2E30670
MODELS=openai:gpt-5.4-mini,gemini:gemini-3.5-flash,gemini:gemini-3.1-pro-preview,anthropic:claude-sonnet-4-6,anthropic:claude-opus-4-7,openai:gpt-5.5
node Scripts/eval-models.mjs "$REC" --mode instruct --models "$MODELS" --out eval-results/<rec>/instruct
node Scripts/eval-models.mjs "$REC" --mode explain  --models "$MODELS" --out eval-results/<rec>/explain
# then a separate Gemini-Pro high-thinking pass for run #4:
node Scripts/eval-models.mjs "$REC" --mode instruct --models gemini:gemini-3.1-pro-preview --thinking high --out eval-results/<rec>/instruct-pro-high
```

### Phase 0 pass criteria

A model **PASSES** the gate if it reliably produces valid, contract-compliant
output: output-ONLY (no preamble, no "Here is…", no closing remarks), never
wraps the whole result in a code fence, no fabrication of values/names not
shown or said, and it reads frames/on-screen text correctly. A model that
produces *differently-styled but valid* output PASSES (user preference decides).
A model that breaks the output contract (preamble, refusals, fabrication, can't
read frames) **FAILS and is dropped** from the menu. Pay special attention to
Opus 4.7's documented tendency to add preamble/caveats and "argue" with the
"Output ONLY" instruction — verify it on real clips, both modes.

## Artifact-contract eval (modes → typed-artifact refactor, Phase 0)

`--artifact` scores models against the typed-artifact output contract
(`docs/refactor-artifact-response-plan.md` §2) instead of running a recording.
Input is the labeled, text-only fixture set
`Scripts/artifact-eval/fixtures.json` — 40 cases of
`{ id, transcript, ocr_summary, clicks, expected: { has_artifact, type|null, notes } }`
spanning ~14 `agent_prompt`, ~6 `message`, ~5 `snippet`, ~5 `document`,
~8 chat-only, and 2 empty-narration cases (including the plan's hard ambiguous
pair: "how do I center this?" → attach, "this is broken" with no ask → don't).

No recording, no Whisper, no images: each fixture is synthesized into the same
timeline TEXT shape production emits (`on-screen text:` line, `clicked "X"`
lines, `[M:SS]` speech segments), so the model sees familiar input structure.
API keys are only needed for the providers you actually run.

```bash
node Scripts/eval-models.mjs --artifact \
  --models gemini:gemini-3.5-flash,anthropic:claude-sonnet-4-6,openai:gpt-5.4-mini
```

Flags (artifact mode):
- `--fixtures path` — default `Scripts/artifact-eval/fixtures.json` (resolved
  relative to the script, so it works from any cwd)
- `--system-prompt path` — score a prompt from a file instead of the built-in
  mirror. A `.txt` path is read raw; a `.md` path yields its first fenced
  block — so the locked in-repo mirror `Scripts/artifact-eval/prompt-v2.md`
  (provenance header + fenced prompt, byte-identical to
  `zerro-prompt-system.md` v2) is directly usable:
  `--system-prompt Scripts/artifact-eval/prompt-v2.md`. Default: the locked v2
  mirror (the same file) — so a bare `--artifact` run now scores the SHIPPED
  prompt.
- `--only id1,id2` — run a subset of fixture ids while iterating
- `--parser-tests [file]` — run the §2 parser edge-case suite instead of an
  eval (no API calls); default file `Scripts/artifact-eval/parser-tests.json`
- `--concurrency N` — per-model request parallelism (default 4). Drop to 1–2
  for rate-limited models (`gemini-3.1-pro-preview` and `claude-sonnet-4-6`
  both 429 heavily at 4).
- `--models`, `--thinking`, `--out` — as in recording mode
  (default out: `eval-results/artifact/`)

Cases run `--concurrency`-at-a-time per model. Output per run:
- **`<stamp>_artifact_<model>.json`** — per-case raw outputs + scores (the
  full record, for digging into any miss)
- **`ARTIFACT-SCORECARD.md`** — metrics table per model, a per-case ✓/✗ grid,
  and a Failures section quoting every miss's raw output

Metrics (the four from the plan, all computed automatically — no manual rubric):
- **attach / no-attach accuracy** — artifact attached iff the label says so
- **type accuracy** — right type, among cases where the label expects an
  artifact AND the model attached one (a hallucinated type string counts as a
  miss even though the parser coerces it to `generic`)
- **contract validity** — §2 fences well-formed: at most one block, delimiters
  alone at line start, parseable `type`/`title` attrs. A clean chat-only
  response is valid; unclosed/multiple/mid-line fences are not. Over-long
  titles (> 80 chars) and trailing text after the close fence are warnings,
  not validity failures. The parser includes the §2 RECOVERY TIER (amendment
  2026-06-11): exactly three closed rules — R1 wrong trailing chevron count on
  the open fence, R2 open-fence body spillover, R3 close fence glued to the
  last body line. Recovered parses count as valid but are flagged.
- **recovery rate** — recovered parses / artifact-bearing responses, reported
  separately from validity. If this climbs after a prompt edit, the edit
  degraded fence discipline even though validity looks fine — treat it as a
  regression signal.
- **voice check** — `agent_prompt` bodies must never say "the user"; chat text
  should address the user directly ("you")

Phase 1 pass bar (default model): attach/no-attach ≥ 90%, contract validity
≥ 98%, type accuracy ≥ 85%.

The harness's `parseArtifactResponse` is the JS reference for Phase 2's
`ArtifactParser.swift` — once that exists, keep the two in sync (same
discipline as the prompt mirrors). The parser's executable spec lives in
`Scripts/artifact-eval/parser-tests.json` (strict + recovery-tier cases,
including the real model outputs that motivated the tier); run it with:

```bash
node Scripts/eval-models.mjs --parser-tests   # no API keys needed
```

Phase 2's `ArtifactParserTests.swift` ports the same list and must pass all
of it. Add a case to the JSON whenever a new real-world malformation shows up.

## Keep in sync

The system prompt, interleaving, wire formats, and pricing are mirrored from:
`supabase/functions/generate/{prompt,interleave,cost}.ts` and
`providers/{openai,gemini}.ts`. If those change, update `eval-models.mjs`. The
`CHAT_PRICING` table must price every model in the matrix above so no run shows
"unpriced".

Phase 0 sync status (2026-06-09):
- `prompt.ts` (BASE/INSTRUCT/EXPLAIN) — **in sync**, verified verbatim.
- `interleave.ts` (mmss, tiebreak, tags, OCR/click lines) — **in sync**.
- `providers/openai.ts`, `providers/gemini.ts` wire shapes — **in sync**.
- `providers/anthropic.ts` — does not exist yet (Phase 3); the harness's
  `chatAnthropic` is the reference shape for it.
- `cost.ts` `CHAT_PRICING` — **intentionally behind** the harness this phase.
  cost.ts still prices only `gpt-4o` + the two Gemini models; the six-model
  table here is ahead of it and must be mirrored INTO cost.ts in Phase 2.
