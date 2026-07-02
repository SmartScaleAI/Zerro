# Transcription eval — on-device vs cloud (Phase 8)

A repeatable, human-run comparison of Zerro's two speech-to-text paths:

- **on-device** — `large-v3-turbo-q5_0` via `WhisperCppTranscriptionService` (the real production engine)
- **cloud** — `whisper-1` via `OpenAITranscriptionService` (the real production request)

It reuses the production services and the real `DeixisResolver` — no duplicated
transcription or anchoring logic — so what you measure is what ships. It lives as
two **gated** XCTest cases in
[`ZerroTests/TranscriptionEvalHarness.swift`](../ZerroTests/TranscriptionEvalHarness.swift):
with no env vars set they `XCTSkip`, so CI and normal test runs never transcribe
or hit the network.

Results are written under `apps/desktop/eval-results/transcription/` as a JSON
blob + a Markdown scorecard (same convention as `eval-models.mjs` /
`eval-results/`). **Secrets are read from env and never written to results.**

## Prerequisites

- The production model on disk. Either download it once in the app (Settings ›
  Transcription) — the harness auto-finds it — or point at a copy:
  ```sh
  export ZERRO_WHISPER_MODEL_PATH=/path/to/ggml-large-v3-turbo-q5_0.bin
  ```
- A **dedicated dev** OpenAI key for the cloud leg (never a production key):
  ```sh
  export OPENAI_API_KEY_DEV=sk-...        # or OPENAI_API_KEY
  ```
  The harness installs it into the OpenAI Keychain slot only for the run, then
  restores your prior value.

## 1. Transcription comparison — WER + timing (`testEvalTranscriptionComparison`)

Point at a folder of audio files. For each `foo.m4a`, an optional reference
transcript `foo.ref.txt` (or `foo.txt`) next to it enables WER.

```sh
export ZERRO_STT_EVAL_DIR=/path/to/audio-folder      # .m4a .wav .mp3 .caf .aiff .flac
xcodebuild test -scheme Zerro -destination 'platform=macOS' \
  -only-testing:ZerroTests/TranscriptionEvalHarness/testEvalTranscriptionComparison
```

Per file it records, for BOTH engines: the transcript, wall-clock transcription
time, real-time factor (audio ÷ transcription seconds), and — when a reference is
present — **WER** (word-level edit distance ÷ reference words; lower is better).

## 2. Dev-Mode deixis timing — DTW drift vs the resolver window (`testEvalDevModeTiming`)

Checks whether on-device DTW word timings drift enough to move a deictic anchor
outside the resolver's window `[phrase − 0.8s, phrase + 0.2s]` (the real
`DeixisResolver.Config.default`), which is what would make Dev-Mode "point at
this" anchoring diverge between local and cloud.

```sh
export ZERRO_STT_DEVEVAL_DIR=/path/to/devmode-working-dir   # manifest.json + audio
xcodebuild test -scheme Zerro -destination 'platform=macOS' \
  -only-testing:ZerroTests/TranscriptionEvalHarness/testEvalDevModeTiming
```

Clicks come from the recording's `manifest.json`. Cursor samples aren't persisted
in the manifest; drop an optional `cursor.eval.json` in the working dir to feed
the dwell path — an array matching `CursorSample`:

```json
[ { "seconds": 1.20, "x": 0.42, "y": 0.31 }, { "seconds": 1.25, "x": 0.42, "y": 0.30 } ]
```

Without it the window/drift analysis still holds (the window derives from the word
timings). The scorecard flags any phrase where drift moves the anchor outside the
other engine's window — the signal to widen the window or gate Dev Mode to cloud.

## Notes

- Override the output dir with `ZERRO_STT_EVAL_OUT=/some/dir` (default:
  `apps/desktop/eval-results/transcription/`).
- Do **not** commit the ~547 MB model or any API key.
- These are diagnostics, not pass/fail gates — read the scorecards to make the
  model-choice + Dev-Mode-DTW sign-off calls (Phase 8).
