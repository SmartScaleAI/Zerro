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
   Recommended: the official **`whisper.spm`** package / the **whisper.cpp release
   XCFramework** (binary target). It ships the Metal kernels and avoids a from-source
   build in CI. `SwiftWhisper` (exPHAT) is an easier ergonomic wrapper but adds a
   third-party maintenance dependency and less control over `whisper_full` params
   (we need DTW word timestamps, see #3) — prefer the official framework, wrap it
   ourselves. (Sources at bottom.)

2. **Model: `large-v3-turbo`, quantized (q5_0), as the default.**
   `whisper-1` is the open `large-v2` model, so to **match current quality** we want a
   large-family model. `large-v3-turbo` (q5_0, ≈0.5–1 GB) gives near-large quality,
   is markedly faster on Apple Silicon, and keeps the download reasonable. Quality is
   **model-size-determined and identical to the cloud for the same weights** — so this
   is the lever. **This is a tuning decision; validate in Phase 8** against the eval
   harness. Fallback if quality is short: full `large-v3` (bigger/slower).

3. **Word timestamps (Dev Mode deixis): use DTW (`token_timestamps` + `dtw_aheads`).**
   Dev Mode requests word-level timing (`wordTimestamps: true`) for the deixis resolver's
   `[phrase−800ms, phrase+200ms]` window. whisper.cpp produces word timing via **DTW**
   (requires the model's alignment-head preset, which must match the chosen model).
   Local vs cloud word timestamps can differ **100–400 ms**; the resolver window is
   ~1 s and **early-biased**, so this is *probably* within slop — **must be validated in
   Phase 8** before we trust Dev Mode on local STT. If DTW proves too coarse, Dev Mode
   can stay on cloud STT (require OpenAI key only for Dev Mode) as a fallback.

4. **Cloud STT stays as a fallback/option.** Introduce an `sttEngine` preference
   (`auto` / `local` / `cloud`). Default `auto` = local when the model is ready, else
   cloud when an OpenAI key exists. This makes the change non-breaking: existing
   OpenAI-key users keep working exactly as today until the local model is present.

---

## Architecture: the seam

The codebase already has the right abstractions — we extend them, we don't rewrite.

- **`TranscriptionService` protocol** (`Services/TranscriptionService.swift`) is already
  provider-neutral and returns the neutral `Transcript` (segments + `fullText` + optional
  `words` + `durationSeconds`). We add a **second conformer**: `WhisperCppTranscriptionService`.
- **STT selection** mirrors the existing chat routing in `Services/BYOKRouting.swift`
  (`ProviderKeys` / `BYOKRouting.effectiveEntry` / `BYOKRouting.service`). We add an
  analogous **STT router** that returns the right `TranscriptionService`.
- **The single call site** to rewire is `AppState.runLocalPromptGeneration`
  (`apps/desktop/Zerro/AppState.swift:2814`), which currently hardcodes
  `OpenAITranscriptionService()`.

---

## Confirmed codebase reference map (verified — use these exact references)

**Transcription / generation pipeline** — `apps/desktop/Zerro/AppState.swift`
- `runLocalPromptGeneration(processed:)` — lines **2789–2920**. Hardcoded transcription
  call at **2814**: `OpenAITranscriptionService().transcribe(audioFileURL:wordTimestamps:)`.
  `hasSpeech` gate at **2807**; `wordTimestamps: self.recordingIsDevMode` at ~2817;
  `catch` → `failureReason` → `state = .failed` at **2837–2913**.
- `runGeneration(...)` (chat half) calls `logCost(...)` at ~**2973**.
- `logCost(audioDuration:usage:requestedModelID:)` — **4382–4399**; uses
  `OpenAITranscriptionService.estimatedCost(...)` (cloud STT $/min). Local must log `$0`.
- `TranscriptionError` → `RecordingFailureReason` mapping — **4190–4206**;
  `errorCodeString` — ~**4064**; `shouldCapture` (crash-report gate) — ~**4040**.
- User-facing "OpenAI required for transcription" copy — **381** (pill) and **481**
  (expanded detail).

**Entitlement / route gating**
- `AppState.hasOwnAPIKeyProvider` closure — **856–861** (currently reads **only**
  `KeychainStore.openAIAPIKey`). Read at `ZerroApp.swift:717` (preflight) and
  `AppState.swift:2212` (route decision).
- `runPromptGeneration(...)` route switch — **2197–2255** (`.local` → `runLocalPromptGeneration`).
- `EntitlementStore.generationRoute(hasOwnAPIKey:)` — **442–462**; `preflightBlock(...)` ~**510**.

**Key entry UI** — `apps/desktop/Zerro/Surfaces/Settings/Sections/APIAuthSection.swift`
- `APIKeyFieldModel.State` enum — **60–65**; `run(validating:writeOnValid:writeOnInconclusive:)`
  — **157–175**; the success transition `.valid → writeKeyTrackingAdd → state = .verified`
  at ~**164–165**; `writeKeyTrackingAdd` (first-key-of-provider detection via `hadKey`) — **149–155**;
  key removal at **110–125**. OpenAI row copy at **34**. Analytics `byok_key_added` (**119/153**).
- First-key-across-all-providers = `ProviderKeys.availableProviders().isEmpty` **checked before write**.
- **No BYOK key step in onboarding** (`Surfaces/Onboarding/OnboardingStep.swift` 13–36) — keys are
  entered only in Settings, so the consent prompt lives entirely in Settings.

**Keychain** — `apps/desktop/Zerro/Preferences/KeychainStore.swift`
- Slots **196–198**: `openAIAPIKey`, `geminiAPIKey`, `anthropicAPIKey`. `readResult()`/`write`/`delete`.

**Preferences / persistence** — `apps/desktop/Zerro/Preferences/PreferencesStore.swift`
- `@MainActor @Observable`, UserDefaults-backed, centralized `enum Keys`; add fields via the
  `didSet`-persist pattern + load-with-default in `init`. `resettable` array controls Reset-to-Defaults.

**File storage pattern** — `apps/desktop/Zerro/History/RecentPromptStore.swift:208–227`
- Application Support resolution pattern → store model at
  `~/Library/Application Support/Zerro/models/<model>.bin`. Do **not** use the temp
  `WorkingDirectory` (it is swept at launch).

**Networking foundation** — `apps/desktop/Zerro/Services/Managed/ManagedBackend.swift:497–518`
- `URLSession` config + `ManagedTransport` protocol (async/await). **No large-file/download-task
  pattern exists yet** — Phase 2 adds one (`URLSession.downloadTask` + delegate for progress).

**Pill UI** — `Surfaces/Pill/PillView.swift` (`PillState` enum incl. `.processing(stepLabel:)`,
`.devProgress(label:cancellable:)`), `PillStateBridge.swift`, and `AppState.setProcessingLabel(_:)`
~**2332** (elapsed suffix auto-appended). `startThinkingRotation()` ~**2363**.

**Model registry / mirrors** — `Services/ModelRegistry.swift` (`ModelProvider` enum),
plus the cost mirror note in `Services/BYOKRouting.swift` (`BYOKCostEstimator`). STT cost has a
server mirror at `supabase/functions/generate/cost.ts` (not touched on BYOK, but note for copy).

---

## Risks & how the plan de-risks them

- **Entitlement routing is the riskiest change.** `hasOwnAPIKeyProvider` currently means
  "has OpenAI key → can run locally." A Claude-only user returns `false` today and would route
  to trial/managed. **Phase 4 isolates this change** and tests the full trial/byok/managed matrix.
- **Native build/CI fragility** (Metal, code signing the xcframework). **Phase 1 lands the
  dependency + a fixture transcription test first**, before any app wiring.
- **Word-timestamp accuracy for Dev Mode.** Quantified above; **Phase 8 validates** and we keep
  cloud-STT-for-Dev-Mode as a documented fallback.
- **Non-breaking rollout.** Default `sttEngine = auto` and keep cloud STT, so nothing changes for
  current OpenAI-key users until the local model is downloaded.

---

# Phases

Each phase below is a standalone handoff. Header line for each: **Depends on** / **Touches** /
**Done when**.

---

## Phase 1 — Integrate whisper.cpp + `WhisperCppTranscriptionService`

**Depends on:** none. **Touches:** new SPM dependency, new
`Services/Whisper/WhisperCppTranscriptionService.swift`, `ZerroTests`. **Done when:** a unit test
transcribes a bundled audio fixture locally and produces a `Transcript` matching expected text,
with segment timestamps (and word timestamps when requested) — **not yet wired into the app
pipeline.**

### Goal
Add the on-device engine behind the existing `TranscriptionService` protocol, proven by a test,
with zero behavior change to the running app.

### Work
1. Add the **whisper.cpp XCFramework** as a SwiftPM dependency (prefer `whisper.spm` / the official
   release xcframework binary target). Confirm it builds for macOS (arm64 + the project's min target),
   links Metal, and passes signing/validation. Commit the chosen pin/version.
2. Decide the bundled model id (default **`ggml-large-v3-turbo-q5_0.bin`** — see decision #2) and
   record its expected SHA-256 + byte size as constants (used by Phase 2 verification). The model is
   **not** added to the repo or the app bundle; it is referenced by URL + checksum only.
3. Implement `WhisperCppTranscriptionService: TranscriptionService`:
   - `transcribe(audioFileURL:wordTimestamps:) async throws -> Transcript`.
   - Decode `audio.m4a` to the 16 kHz mono float PCM whisper.cpp expects (AVFoundation/`AVAudioConverter`).
   - Run `whisper_full` off the main actor. Map output segments → `TranscriptSegment(start,end,text)`
     (trim leading spaces, matching `OpenAITranscriptionService.parseTranscript`), set `fullText`,
     and `durationSeconds` from the measured audio.
   - When `wordTimestamps == true`, enable `token_timestamps` + **DTW** with the model's
     `dtw_aheads` preset and emit `WordTiming(word,start,end)`. (Window slop tolerated; see #3.)
   - Map failures to `TranscriptionError` (`.decodeFailure` for PCM/convert errors, `.server`-equivalent
     for engine init failure → reuse `.decodeFailure`/a new internal case if needed; **do not** invent
     user-facing strings here — reuse the existing taxonomy so Phase 3's failure mapping works unchanged).
   - **No API key, no network.** A missing **model file** is surfaced as a distinct error the router
     handles in Phase 3 (e.g. `TranscriptionError`-level `.modelUnavailable`; add this case to the enum
     in `Services/TranscriptionService.swift` and map it in Phase 3).
4. Take the model path via init injection (e.g. `init(modelURL: URL)`), so the test points at a small
   fixture model and Phase 3 supplies the real cached path.

### Tests
- Bundle a short spoken `.m4a` fixture + a **small** whisper model (e.g. `tiny`/`base`) used only for
  tests. Assert transcript text contains expected phrase, segments are ordered & non-empty, and (with
  `wordTimestamps: true`) `words` is populated and monotonic.
- Parsing/mapping is unit-testable without the engine where possible (mirror the
  `parseTranscript` fixture style).

---

## Phase 2 — `LocalModelManager` (download, storage, verification, state)

**Depends on:** Phase 1 (knows the model id/checksum). **Touches:** new
`Services/Whisper/LocalModelManager.swift`, `PreferencesStore.swift`, `ZerroTests`.
**Done when:** the manager can download the model with progress to Application Support, verify it,
expose readiness/version, and persist that state — **not yet triggered by any UI.**

### Goal
A `@MainActor @Observable` manager that owns the model file lifecycle and download progress.

### Work
1. **PreferencesStore** — add persisted fields following the existing `Keys` + `didSet` pattern:
   `sttEngine: String` (default `"auto"`), `localModelVersion: String` (default `""`),
   `localModelDownloadedAt` (optional). Decide whether these belong in `resettable`.
2. **Storage path:** `~/Library/Application Support/Zerro/models/<modelId>.bin` using the
   `RecentPromptStore` Application-Support pattern (`FileManager.url(for: .applicationSupportDirectory…)`).
   Create the `models/` dir on demand. Provide `modelURL(for:)` + `isModelReady` (file exists AND
   checksum/version matches the Phase 1 constants).
3. **Download:** `URLSession.downloadTask` with a `URLSessionDownloadDelegate` for progress
   (`downloadedBytes`/`totalBytes`), written to a temp file then atomically moved into place. Verify
   **SHA-256** before commit; reject/delete on mismatch. Support cancel + a clear failure result.
   Use a generous resource timeout (model is large). Resumable/background download is a nice-to-have,
   not required for v1.
4. Expose observable state for the UI: `.notDownloaded`, `.downloading(progress, downloadedMB, totalMB)`,
   `.ready(version)`, `.failed(reason)`. On success set `preferences.localModelVersion`.
5. **Disk-space pre-check** helper (`volumeAvailableCapacityForImportantUsage`) so callers can warn
   "needs ~1 GB free" before starting.
6. Host the model file in our own CDN/bucket (or a pinned Hugging Face release URL). Put the URL behind
   a constant; note that App Store On-Demand Resources do **not** apply (direct-distribution app w/ Sparkle).

### Tests
- Point the manager at a **local file:// fixture URL** for a tiny file; assert progress callbacks fire,
  checksum verification passes/fails correctly, atomic move lands the file, and `isModelReady` flips.
- Corrupt-file path deletes and reports `.failed`.

---

## Phase 3 — STT routing seam + rewire the local pipeline

**Depends on:** Phases 1–2. **Touches:** `Services/BYOKRouting.swift` (or a new
`Services/Whisper/STTRouting.swift`), `AppState.swift` (call site + `logCost`),
`Services/TranscriptionService.swift` (error case), `ZerroTests`. **Done when:**
`runLocalPromptGeneration` uses the routed STT service; with the model absent and an OpenAI key present,
behavior is **byte-identical to today** (cloud Whisper); with the model present and `sttEngine` allowing
local, it transcribes locally and logs `$0`.

### Goal
Choose local vs cloud STT centrally and replace the hardcoded `OpenAITranscriptionService()`.

### Work
1. Add an STT router (mirror `BYOKRouting`):
   ```
   enum STTRouting {
     static func service(
       sttEngine: PreferencesStore.STTEngine,
       modelReady: Bool,
       openAIKeyPresent: Bool,
       modelURL: URL?
     ) -> (any TranscriptionService)?   // nil = no usable STT
   }
   ```
   Rules: `auto` → local if `modelReady`, else cloud if `openAIKeyPresent`, else `nil`.
   `local` → local if `modelReady` else `nil`. `cloud` → cloud if key else `nil`.
   Keep it **pure** (inputs as params) so it's fully unit-testable, exactly like `BYOKRouting.effectiveEntry`.
2. **Rewire** `AppState.swift:2814`: resolve the service via `STTRouting.service(...)`. If `nil`, throw the
   appropriate `TranscriptionError` (`.modelUnavailable` when local selected but missing → maps to a new
   `RecordingFailureReason` in Phase 6; `.missingAPIKey` when cloud selected w/o key). Pass
   `wordTimestamps: self.recordingIsDevMode` unchanged. The `hasSpeech` skip stays as-is.
3. **Cost:** in `logCost` (4382), branch on which engine ran — local logs `$0.00` for STT (chat cost
   unchanged). Simplest: pass the STT engine into `logCost` or compute STT cost as 0 when local.
4. Add `.modelUnavailable` to `TranscriptionError` (if not added in Phase 1) and to the
   `TranscriptionError → RecordingFailureReason` map (4190–4206) — temporary mapping to an existing
   reason is fine until Phase 6 adds a dedicated state.

### Tests
- `STTRouting.service` truth-table across `{auto,local,cloud} × {modelReady} × {keyPresent}`.
- AppState-level: with a fake transcription service injected, the local path calls **local** when model
  ready and **cloud** when not (engine=auto). Confirm `$0` STT cost log when local.

> Implementation note: prefer injecting the resolved `TranscriptionService` (or a factory closure) into
> AppState the way `hasOwnAPIKeyProvider` is injected, so tests don't touch the Keychain or disk.

---

## Phase 4 — Decouple trial/preflight routing from the OpenAI key

**Depends on:** Phase 3. **Touches:** `AppState.swift` (`hasOwnAPIKeyProvider` + callers),
`ZerroApp.swift:717`, `Services/Billing/EntitlementStore.swift` (`generationRoute`, `preflightBlock`),
`ZerroTests`. **Done when:** a user with **any chat key + a ready local model (or an OpenAI key)** routes
`.local`; the trial/byok/managed matrix is fully covered by tests; no regression for existing OpenAI users.

### Goal
Make "can I generate on my own keys locally?" mean *chat key present AND a usable STT path*, instead of
"OpenAI key present."

### Work
1. Replace the OpenAI-only `hasOwnAPIKeyProvider` (856–861) with a capability check, e.g.
   `canGenerateLocallyProvider: () -> Bool` =
   `!ProviderKeys.availableProviders().isEmpty  &&  (localModelReady || openAIKeyPresent)`.
   Keep it an injected closure for testability. Update both readers (`ZerroApp.swift:717`,
   `AppState.swift:2212`) and rename for clarity.
2. Update `EntitlementStore.generationRoute(hasOwnAPIKey:)` (442–462) and `preflightBlock` (~510)
   parameter semantics accordingly (rename the param to `canGenerateLocally`). The `.trial` branch:
   if `canGenerateLocally` → `.local` (their keys, their local model); else existing trial/managed logic.
3. Audit any other reader that assumes "own key == OpenAI key" (search `hasOwnAPIKey`, `openAIAPIKey`)
   and update.

### Tests
- Entitlement matrix: `.byok` / `.trial` / `.managed` / `.expired` × `{claude-only, gemini-only,
  openai-only, none}` × `{localModelReady}` → expected route. Special focus: Claude-only + model ready →
  `.local`; Claude-only + model **not** ready + no OpenAI → trial/managed (or the right failure), not a crash.
- Preflight block matrix mirrors the above.

---

## Phase 5 — First-key consent prompt + Settings model status UI

**Depends on:** Phases 2 & 4. **Touches:** `APIAuthSection.swift`, a new Settings model-status view,
`PreferencesStore.swift` (a "prompt shown" flag), `ZerroTests`/UI. **Done when:** saving the **first**
BYOK key shows the one-time consent prompt; accepting starts the Phase 2 download with progress visible
in Settings; declining defers and can be retried; managed users never see it.

### Goal
The "ask on first key paste" UX, plus a place to see/redo the download.

### Work
1. Add a persisted `localModelPromptShown: Bool` (PreferencesStore) so the prompt is **once**, not every launch.
2. In `APIKeyFieldModel.run(...)` at the `.valid` branch (~164), **before** `writeKeyTrackingAdd`,
   capture `isFirstKey = ProviderKeys.availableProviders().isEmpty`. After the write + `state = .verified`,
   if `isFirstKey && !localModelPromptShown && !LocalModelManager.isModelReady`, present the consent
   `NSAlert` (reuse the pattern from `AppBehaviorSection.confirmAndReset` 223 / `HistorySection` 57):
   - Title: **"On-device transcription"**
   - Body: "Zerro transcribes your recordings locally so your audio never leaves your Mac. This needs a
     one-time ~1 GB download." (+ disk-space note when low).
   - Buttons: **Download** / **Later**. Set `localModelPromptShown = true` on either choice.
   - **Download** → `LocalModelManager.download()`. **Later** → defer (re-surfaced in Phase 6 when they
     actually record locally).
3. **Settings model-status row** (in the API Keys / a new "Transcription" section): show state from
   `LocalModelManager` — Not downloaded (with a Download button), Downloading (progress bar + MB/MB +
   Cancel), Ready (version + Remove/Re-download), Failed (Retry). Also add the `sttEngine` control
   (Auto / On-device / OpenAI cloud) — disabled options explained (e.g. cloud needs an OpenAI key).
4. Analytics: `local_model_prompt_shown`, `local_model_download_started/_succeeded/_failed`,
   `stt_engine_changed`. (Match the existing `Analytics.capture(name, props)` style.)

### Tests
- First-key detection: with no keys, saving a Claude key → prompt; saving a *second* key → no prompt.
- `localModelPromptShown` suppresses re-prompt. Managed entitlement state never prompts.
- Status view renders each `LocalModelManager` state (snapshot/state tests).

---

## Phase 6 — Recording-time UX: mid-download wait + local-STT failure handling

**Depends on:** Phases 3 & 5. **Touches:** `PillView.swift`/`PillStateBridge.swift`, `AppState.swift`
(pipeline + a new `RecordingFailureReason`), `ZerroTests`. **Done when:** recording before the model is
ready shows a clear "finishing setup" pill and proceeds when ready (or fails gracefully); a failed/absent
local model produces a helpful, actionable error (offer cloud STT if an OpenAI key exists).

### Goal
Handle the edge where a user records before the download finishes, and any local-STT failure.

### Work
1. If `runLocalPromptGeneration` resolves an STT service but the **local model is still downloading**,
   surface a transient state — reuse `.processing` via `setProcessingLabel("Finishing local
   transcription setup… (\(downloadedMB) MB / \(totalMB) MB)")` (elapsed suffix auto-appends), or add a
   dedicated `PillState.modelDownloading(progress:)`. When the download completes, continue into
   transcription automatically; on cancel/failure, fail with the new reason below.
2. Add `RecordingFailureReason.localModelUnavailable` (or reuse `.apiKeyMissing` family) with copy that
   reflects on-device reality and offers the fix: download the model, **or** (if `openAIKeyPresent`)
   switch to cloud STT. Wire it into `failureReason`/`errorCodeString`/`shouldCapture` (4040–4206) and
   the expanded failure card.
3. Decide the **defer→record** behavior from Phase 5's "Later": first local recording with no model →
   either auto-start the download behind the "finishing setup" pill, or fail with the actionable error.
   Recommended: auto-start + wait pill (smoothest).

### Tests
- Pipeline test: model downloading → pill shows setup label → completes → transcription runs.
- Model failed/absent + no OpenAI key → `localModelUnavailable` failure with correct copy; + OpenAI key
  present → `auto` routing falls back to cloud (no failure).

---

## Phase 7 — Copy, cost notes, and "OpenAI optional" cleanup

**Depends on:** Phases 3–6. **Touches:** `AppState.swift` (381, 481), `APIAuthSection.swift` (34),
`KeychainStore.swift` (193 comment), `BYOKRouting.swift` (estimator notes), `docs/`. **Done when:** no
remaining UI/string asserts "OpenAI is required for transcription," the OpenAI key is presented as
optional, and the relevant docs reflect on-device STT.

### Goal
Remove the now-false "OpenAI required" messaging and update the key rows.

### Work
1. AppState pill/detail copy (381/481): replace "an OpenAI key is required for transcription" with copy
   that reflects on-device transcription + the actual missing prerequisite (chat key and/or local model).
2. APIAuthSection OpenAI row (34): change "Required — transcription always runs on OpenAI…" to
   "Optional — used only if you choose OpenAI for chat or for cloud transcription. On-device transcription
   needs no key." Re-order rows if OpenAI no longer deserves top/"required" placement.
3. Update the `KeychainStore` comment (193) and `BYOKRouting`/`BYOKCostEstimator` notes to mention the
   local STT path ($0). Leave the server cost mirror (`supabase/functions/generate/cost.ts`) unchanged
   (managed path untouched) but add a one-line note that BYOK STT can be local.
4. Add a short `docs/` entry (or update this file's status) describing the shipped behavior.

### Tests
- Grep guard / snapshot: no user-facing string says OpenAI is required for transcription. Settings renders
  OpenAI as optional.

---

## Phase 8 — Quality + Dev Mode validation, performance, and sign-off

**Depends on:** Phases 1–7. **Touches:** `apps/desktop/Scripts/` eval harness, `eval-results/`, test
fixtures; no shipping-code changes expected (bug-fixes only). **Done when:** local transcription quality
is verified ≈ cloud `whisper-1` on representative recordings, Dev Mode deixis still resolves correctly
with DTW timestamps, performance is acceptable on target hardware, and the BYOK-Claude-only flow passes
end-to-end.

### Goal
Prove the swap doesn't regress quality, Dev Mode, or perf — and lock the model choice.

### Work
1. **Transcription quality:** run a set of representative recordings through both cloud `whisper-1` and
   the chosen local model; compare WER / qualitative accuracy. Confirm `large-v3-turbo q5_0` is good
   enough; if not, escalate to `large-v3`. Record the decision + numbers in `eval-results/`.
2. **Dev Mode deixis:** verify DTW word timestamps land references inside the resolver's
   `[phrase−800ms, +200ms]` window despite 100–400 ms local/cloud drift. If they don't, gate Dev Mode to
   cloud STT (require OpenAI key for Dev Mode) and document it.
3. **Performance:** measure transcription latency for a typical 3-min recording on Apple Silicon (and an
   older/Intel Mac if supported). Confirm the "thinking" pill covers it acceptably; tune model/threads.
4. **End-to-end:** fresh profile, paste only a Claude key → consent prompt → download → record with speech
   → local transcription → Claude generation → result. Confirm no OpenAI prompt anywhere and audio never
   left the device (network inspection).

### Tests / acceptance
- Eval numbers committed; Dev Mode deixis regression suite passes (or documented cloud-gating);
  perf within target; manual e2e checklist signed off.

---

## Suggested handoff order & rough sequencing

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Phases 1–2 are parallelizable (engine vs. download manager). Phase 4 is the
highest-risk (entitlements) — review carefully. Phases 1, 3, 4 are the load-bearing correctness work;
5–6 are UX; 7 is cleanup; 8 is validation/sign-off.

---

## Appendix — references

- whisper.cpp (engine, models, DTW `--dtw`): https://github.com/ggml-org/whisper.cpp
- whisper.spm (SwiftPM package / xcframework): https://github.com/ggerganov/whisper.spm
- SwiftWhisper (ergonomic wrapper, alternative): https://github.com/exPHAT/SwiftWhisper
- OpenAI Whisper open weights (whisper-1 = large-v2): https://github.com/openai/whisper
- DTW word-timestamp accuracy background (CrisperWhisper): https://arxiv.org/abs/2408.16589
