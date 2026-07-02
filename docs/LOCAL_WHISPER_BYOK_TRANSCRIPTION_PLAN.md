# Implementation Plan: Local (on-device) transcription for BYOK

## Summary

Today every BYOK recording is transcribed by **OpenAI Whisper** (`whisper-1`), so a
BYOK user must supply an **OpenAI key even if they only want to chat with Claude or
Gemini**. This plan replaces the cloud transcription step on the BYOK/local path with
an **on-device whisper.cpp** engine, so a BYOK user brings **one chat key** and audio
**never leaves the Mac**.

Scope is **BYOK/local only**. The managed (server-credits) path keeps server-side
Whisper untouched — that cost is funded by credits and is not where the friction is.

The ~1 GB Whisper model is **not bundled in the app**. It is downloaded **on demand**,
with a **one-time consent prompt shown the moment the user saves their first BYOK key**.
Managed users never trigger the download.

This document is split into **8 phases**. Each phase is self-contained, compiles, is
independently testable, and is written so it can be handed to Claude Code on its own.
Implement them in order — later phases depend on earlier ones.

---

## Goals / Non-goals

**Goals**
- A BYOK user with only a Claude (or only a Gemini) key can record and generate, with
  transcription running locally — no OpenAI key required.
- Audio for local transcription never leaves the device.
- Drop the per-minute Whisper STT cost on the BYOK path (local = $0).
- Prompt for the model download once, at first-key save, with explicit consent.

**Non-goals (this plan)**
- No change to the managed/trial server path's transcription (stays server Whisper).
- No removal of cloud STT — it remains a fallback/option when an OpenAI key is present.
- No new chat providers; chat routing (`BYOKRouting`) is unchanged.

---

## Key product/technical decisions (decide before Phase 1)

1. **Dependency: use the prebuilt whisper.cpp XCFramework via SwiftPM.**
   Recommended: the official **`whisper.spm`** package / the whisper.cpp release
   XCFramework (binary target). It ships the Metal kernels and avoids a from-source
   build in CI. `SwiftWhisper` (exPHAT) is an easier ergonomic wrapper but adds a
   third-party maintenance dependency and less control over `whisper_full` params
   (we need DTW word timestamps, see #3) — prefer the official framework, wrap it
   ourselves.
   **Phase 1 outcome:** `whisper.spm` is being archived (builds from source, Metal
   disabled, no version pin), so we vendored the official whisper.cpp **v1.9.1**
   `whisper.xcframework` as a local SwiftPM `binaryTarget` (URL + SHA-256), imported
   as `import whisper`. This is the sanctioned alternative and satisfies "links Metal"
   + "pin the version."

2. **Model: `large-v3-turbo`, quantized (q5_0), as the default.**
   `whisper-1` is the open `large-v2` model, so to **match current quality** we want a
   large-family model. `large-v3-turbo` (q5_0, ≈547 MB) gives near-large quality, is
   markedly faster on Apple Silicon, and keeps the download reasonable. Quality is
   **model-size-determined and identical to the cloud for the same weights** — so this
   is the lever. **Validate in Phase 8** against the eval harness. Fallback if quality
   is short: full `large-v3`.

3. **Word timestamps (Dev Mode deixis): use DTW (`token_timestamps` + `dtw_aheads`).**
   Dev Mode requests word-level timing for the deixis resolver's
   `[phrase−800ms, phrase+200ms]` window. whisper.cpp produces word timing via **DTW**
   (requires the model's alignment-head preset, which must match the chosen model).
   Local vs cloud word timestamps can differ **100–400 ms**; the resolver window is
   ~1 s and **early-biased**, so this is *probably* within slop — **validate in Phase 8**.
   If DTW proves too coarse, Dev Mode can stay on cloud STT (require OpenAI key only for
   Dev Mode) as a fallback.

4. **Cloud STT stays as a fallback/option.** Introduce an `sttEngine` preference
   (`auto` / `local` / `cloud`). Default `auto` = local when the model is ready, else
   cloud when an OpenAI key exists. This makes the change non-breaking.

---

## Architecture: the seam

- **`TranscriptionService` protocol** (`Services/TranscriptionService.swift`) is already
  provider-neutral and returns the neutral `Transcript` (segments + `fullText` + optional
  `words` + `durationSeconds`). We add a **second conformer**: `WhisperCppTranscriptionService`.
- **STT selection** mirrors the existing chat routing in `Services/BYOKRouting.swift`.
  We add an analogous **STT router** that returns the right `TranscriptionService`.
- **The single call site** to rewire is `AppState.runLocalPromptGeneration`
  (`apps/desktop/Zerro/AppState.swift:2814`), which currently hardcodes
  `OpenAITranscriptionService()`.

---

## Confirmed codebase reference map (verified — use these exact references)

**Transcription / generation pipeline** — `apps/desktop/Zerro/AppState.swift`
- `runLocalPromptGeneration(processed:)` — lines **2789–2920**. Hardcoded transcription
  call at **2814**. `hasSpeech` gate at **2807**; `wordTimestamps: self.recordingIsDevMode`;
  `catch` → `failureReason` → `state = .failed` at **2837–2913**.
- `logCost(...)` — **4382–4399**; uses `OpenAITranscriptionService.estimatedCost(...)`.
- `TranscriptionError` → `RecordingFailureReason` mapping — **4190–4215** (now includes
  `.modelUnavailable` → `.processingFailed` Phase-1 placeholder); `errorCodeString` ~**4064**;
  `shouldCapture` ~**4040**.
- "OpenAI required for transcription" copy — **381** (pill) and **481** (expanded detail).

**Entitlement / route gating**
- `AppState.hasOwnAPIKeyProvider` closure — **856–861** (currently reads **only**
  `KeychainStore.openAIAPIKey`). Read at `ZerroApp.swift:717` and `AppState.swift:2212`.
- `runPromptGeneration(...)` route switch — **2197–2255**.
- `EntitlementStore.generationRoute(hasOwnAPIKey:)` — **442–462**; `preflightBlock(...)` ~**510**.

**Key entry UI** — `apps/desktop/Zerro/Surfaces/Settings/Sections/APIAuthSection.swift`
- `APIKeyFieldModel.run(...)` — **157–175**; success transition at ~**164–165**;
  `writeKeyTrackingAdd` — **149–155**; OpenAI row copy at **34**.
- First-key-across-all-providers = `ProviderKeys.availableProviders().isEmpty` checked before write.
- **No BYOK key step in onboarding** — keys entered only in Settings.

**Keychain** — `Preferences/KeychainStore.swift` slots **196–198**.
**Preferences** — `Preferences/PreferencesStore.swift` (`@MainActor @Observable`, UserDefaults, `enum Keys`).
**File storage pattern** — `History/RecentPromptStore.swift:208–227` → model at
`~/Library/Application Support/Zerro/models/<model>.bin` (not temp WorkingDirectory).
**Networking** — `Services/Managed/ManagedBackend.swift:497–518`. No download-task pattern yet (Phase 2 adds one).
**Pill UI** — `Surfaces/Pill/PillView.swift`, `PillStateBridge.swift`, `AppState.setProcessingLabel(_:)` ~**2332**.
**Model registry** — `Services/ModelRegistry.swift` (`ModelProvider`); cost mirror note in `BYOKRouting.swift`.

---

## Risks & how the plan de-risks them

- **Entitlement routing is the riskiest change** (Phase 4). A Claude-only user returns
  `false` from `hasOwnAPIKeyProvider` today and would route to trial/managed. Phase 4
  isolates and tests the full matrix.
- **Native build/CI fragility** — Phase 1 lands the dependency + a fixture transcription
  test first (done).
- **Word-timestamp accuracy for Dev Mode** — quantified; Phase 8 validates, cloud-STT
  fallback documented.
- **Non-breaking rollout** — default `sttEngine = auto` + keep cloud STT.

---

# Phases

## Phase 1 — Integrate whisper.cpp + `WhisperCppTranscriptionService` ✅ COMPLETE
**Done when:** a unit test transcribes a bundled audio fixture locally and produces a
`Transcript` with segment (and optional word) timestamps — not yet wired into the pipeline.
**Shipped:** whisper.cpp v1.9.1 xcframework (vendored SwiftPM `binaryTarget`);
`Services/Whisper/WhisperCppTranscriptionService.swift`; `.modelUnavailable` added to
`TranscriptionError` + placeholder map in `AppState.failureReason`; 13/13 tests green
(engine test uses tiny.en downloaded on-demand + CI guard that fails if it didn't run).
Production model constants recorded: `ggml-large-v3-turbo-q5_0`, ~547 MB, DTW preset
`WHISPER_AHEADS_LARGE_V3_TURBO`.

## Phase 2 — `LocalModelManager` (download, storage, verification, state) ✅ COMPLETE
On-demand download of the production model to `~/Library/Application Support/Zerro/models/`
with progress, SHA-256 verification, atomic install, cancel, disk-space pre-check, and
`@MainActor @Observable` state. Add `PreferencesStore` fields: `sttEngine` (default `auto`),
`localModelVersion`, `localModelDownloadedAt`. Not yet triggered by UI. Tests use a small
file:// fixture URL.

## Phase 3 — STT routing seam + rewire the local pipeline ✅ COMPLETE
Add a pure `STTRouting.service(sttEngine:modelReady:openAIKeyPresent:modelURL:)` mirroring
`BYOKRouting`. Rewire `AppState.swift:2814` to the routed service; `nil` → throw the right
`TranscriptionError`. Branch `logCost` so local STT logs `$0`. With model absent + OpenAI
key present, behavior is byte-identical to today. Truth-table tests.

## Phase 4 — Decouple trial/preflight routing from the OpenAI key ✅ COMPLETE
Replace OpenAI-only `hasOwnAPIKeyProvider` with `canGenerateLocally` =
`!ProviderKeys.availableProviders().isEmpty && (localModelReady || openAIKeyPresent)`.
Update both readers + `EntitlementStore.generationRoute`/`preflightBlock`. **Highest-risk
phase** — full byok/trial/managed × {claude-only, gemini-only, openai-only, none} ×
{modelReady} matrix tests.

## Phase 5 — First-key consent prompt + Settings model status UI ✅ COMPLETE
In `APIKeyFieldModel.run(...)` `.valid` branch, capture `isFirstKey =
ProviderKeys.availableProviders().isEmpty` before write; if first key & not previously
prompted & model not ready, show an `NSAlert` consent (Download / Later) and kick off the
Phase 2 download. Add `localModelPromptShown` flag, a Settings model-status row (progress /
ready / re-download), and the `sttEngine` control. Managed users never prompted. Analytics.

## Phase 6 — Recording-time UX: mid-download wait + local-STT failure handling ✅ COMPLETE
If a recording starts before the model is ready, show "Finishing local transcription
setup… (X MB / Y MB)" (reuse `.processing` label or a new `PillState`), proceed when ready.
Add `RecordingFailureReason.localModelUnavailable` with actionable copy (download model, or
switch to cloud STT if an OpenAI key exists). Replaces the Phase-1 `.processingFailed`
placeholder mapping.

## Phase 7 — Copy, cost notes, and "OpenAI optional" cleanup ✅ COMPLETE
Update AppState copy (381/481), APIAuthSection OpenAI row (34) to "optional," KeychainStore
comment (193), BYOKRouting/BYOKCostEstimator notes. Grep guard: no string says OpenAI is
required for transcription.

## Phase 8 — Quality + Dev Mode validation, performance, sign-off ⏳ Part A DONE
**Part A (code + harness) DONE:** the deferred punchlist fixes P1-2, P1-3, P2-2, P7-1 landed
with tests (all green), and a repeatable local-vs-cloud comparison harness + a Dev-Mode
DTW-timing check ship as gated XCTest cases
(`apps/desktop/ZerroTests/TranscriptionEvalHarness.swift`, run per
`apps/desktop/Scripts/README-transcription-eval.md`), writing JSON + scorecards to
`eval-results/transcription/`. **Pending (human, the sign-off below):** run the harness on
representative recordings to lock the model choice, confirm Dev-Mode deixis survives DTW
drift, and record latency numbers. (The ~547 MB model was not present in the build env, so
the numbers themselves are the human's to produce.)

Compare local `large-v3-turbo q5_0` vs cloud `whisper-1` (WER/qualitative) on representative
recordings; lock the model choice. Verify Dev Mode deixis resolves with DTW timestamps
despite 100–400 ms drift (else gate Dev Mode to cloud). Measure latency on Apple Silicon
(+ Intel if supported). End-to-end Claude-only flow with network inspection (audio never
leaves device). Commit eval numbers.

---

## Suggested handoff order
1 ✅ → 2 ✅ → 3 ✅ → 4 ✅ → 5 ✅ → 6 ✅ → 7 ✅ → 8 (Part A ✅; sign-off pending). Phases 1–2 parallelizable. Phase 4 highest-risk.
1, 3, 4 are load-bearing correctness; 5–6 UX; 7 cleanup; 8 validation.

---

## Appendix — references
- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- whisper.spm (archived): https://github.com/ggerganov/whisper.spm
- SwiftWhisper (alt): https://github.com/exPHAT/SwiftWhisper
- OpenAI Whisper weights (whisper-1 = large-v2): https://github.com/openai/whisper
- DTW timestamp accuracy (CrisperWhisper): https://arxiv.org/abs/2408.16589
