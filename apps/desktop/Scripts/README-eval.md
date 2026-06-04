# Model eval harness

Compare chat/vision models on real Zerro recordings **without** deploying,
Supabase, JWTs, or burning credits. The harness replicates the production
pipeline exactly — same whisper-1 transcription request, same locked system
prompt, same chronological frame/speech interleaving, same per-provider wire
formats — so what you see here is what the Managed path will produce.

## One-time setup

```bash
export OPENAI_API_KEY=sk-...    # always required (whisper STT)
export GEMINI_API_KEY=...       # required for gemini:* models
chmod +x Scripts/capture-recording.sh
```

Requires Node 18+ (uses built-in fetch/FormData). No npm installs.

## Workflow

**1. Capture a recording.** The app deletes its working directory after a
successful generation, so snapshot it while recording:

```bash
./Scripts/capture-recording.sh     # leave running
# …record something in Zerro as normal…
# → "captured: eval-recordings/zerro-work-<UUID> (31 frames)"
```

**2. Run the comparison:**

```bash
node Scripts/eval-models.mjs eval-recordings/zerro-work-<UUID> \
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

**3. Compare.** One markdown file per model in `eval-results/`, each headed
with latency / tokens / estimated cost, plus a summary table on stderr.
Whisper runs once per recording (cached as `transcript.eval.json` in the
captured dir), so re-running against more models costs only the chat calls.

## Suggested eval matrix before rollout

3–5 recordings covering your real use cases (dense code on screen, small UI
text, mixed app windows), each through:

| run | model | thinking |
|---|---|---|
| 1 | gemini:gemini-3.5-flash | low |
| 2 | gemini:gemini-3.1-pro-preview | low |
| 3 | gemini:gemini-3.1-pro-preview | high |
| 4 | openai:gpt-4o | — |

Judge on: did it read the small UI text correctly, did it resolve "this/that"
references against the right frame, did it hallucinate names/values, cost,
latency. Whichever wins becomes `CHAT_MODEL` at rollout — no code change.

## Keep in sync

The system prompt, interleaving, wire formats, and pricing are mirrored from:
`supabase/functions/generate/{prompt,interleave,cost}.ts` and
`providers/{openai,gemini}.ts`. If those change, update `eval-models.mjs`.
