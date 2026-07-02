# Local Whisper — Deferred Fixes / Punchlist

Cross-phase cleanup items found during review, to be handled at the end (or in the
phase noted). None are blockers for proceeding.

## From Phase 1 review

- [x] **P1-1 — `fullText` leading space. RESOLVED in Phase 7.**
  `runEngine` now assembles `fullText` via `assembleFullText(fromSegmentTexts:)`, which joins
  the segment texts and trims the result — no leading/trailing whitespace, parity with
  `OpenAITranscriptionService`. Covered by a pure (engine-free) test plus a no-whitespace
  assertion in the end-to-end transcription test.

- [x] **P1-2 — DTW `t_dtw > 0` first-token edge. RESOLVED in Phase 8.**
  Extracted a pure `tokenTimes(tDTW:t0:t1:)` that treats DTW as present when
  `t_dtw >= 0` (was `> 0`): whisper.cpp's "not computed" sentinel is `-1`, and `0` is a
  legitimate audio-start time, so the first word of a recording now keeps its DTW timing
  instead of falling back to the heuristic. Engine-free tests cover t=0, the `-1` fallback,
  positive DTW, the end≥start clamp, and a zero-start first word through `aggregateWords`.

- [x] **P1-3 — Single-pass `AVAudioConverter` robustness. RESOLVED in Phase 8.**
  `decodeToPCM16kMono` now DRAINS the converter: it feeds the whole input once, signals
  end-of-stream, and pulls output in fixed 16 384-frame chunks (accumulating) until the
  converter reports `.endOfStream`/`.inputRanDry`, instead of a single-pass convert. An
  engine-free test resamples a synthetic 3 s / 44.1 kHz clip and asserts the output is
  ~(16 kHz × 3 s) within 2% (a single non-draining pass would truncate to ~one chunk).

- [x] **P1-4 — Replace `.modelUnavailable → .processingFailed` placeholder. RESOLVED in Phase 6.**
  `AppState.failureReason` now maps `.modelUnavailable → .localModelUnavailable` (new reason,
  "Model needed", actionable copy, excluded from capture). Plus the in-flight-download wait so a
  recording made mid-download proceeds instead of failing.

- [ ] **Housekeeping — commit the restored plan doc.**
  `docs/LOCAL_WHISPER_BYOK_TRANSCRIPTION_PLAN.md` was wiped from the tree (untracked) and
  has been restored. Commit it (alongside Phase 1 or to staging) so later handoffs can
  reference it.

## From Phase 2 review

- [ ] **P2-1 — Don't call `LocalModelManager.isModelReady` on the hot path (Med; design into Phase 3/5).**
  `isModelReady` runs a full SHA-256 over the ~547 MB model on the calling actor. Fine for
  `ensureModel()` (once, on demand) and tests (tiny fixture), but Phase 3 routing and Phase 5
  UI must NOT call it per-recording or on the main actor. Use a cheap readiness signal instead:
  `preferences.localModelVersion == spec.id` + file exists + size == byteSize (the full hash
  already ran at install). Reserve the full hash for install/first-load reconciliation.

- [x] **P2-2 — Narrow cancel-during-install race. RESOLVED in Phase 8.**
  The post-install transition now runs through a pure `stateAfterInstall(outcome:isCancelling:
  version:)` that lets a racing `cancel()` WIN — even a successful install resolves to
  `.notDownloaded` (and `handleFinished` removes the just-installed file + skips the version
  write, so the launch reconcile can't resurrect it). Deterministic tests cover the decision
  (cancel beats success and beats failure; no-cancel paths unchanged).

## Follow-up UX enhancements

- [x] **UX-1 — Config failures open Settings, not Retry. RESOLVED.**
  `.apiKeyMissing` / `.localModelUnavailable` / `.apiAuth` now show an "Open Settings" primary
  (via `RecordingFailureReason.settingsDeepLink` + a `.openSettings` pill card) that deep-links to
  the Account & Billing pane. Also revised the `.apiKeyMissing` copy (no "generate a prompt" framing,
  no em-dashes).

- [x] **UX-2 — Engine picker "OpenAI cloud" stale-disabled after adding a key. RESOLVED.**
  Root cause: `TranscriptionSection` read OpenAI-key presence straight from the (non-observable)
  Keychain, so it never re-rendered when a key was added above it. Fixed with a shared `@Observable`
  `ProviderKeyPresence` refreshed on every key write/delete; the picker now reacts to add/remove
  (plus resets a now-unusable selected engine to `.auto`).

- [x] **UX-3 — Revalidate on an emptied (unblurred) key field resurrected the stored key. RESOLVED.**
  `revalidate()` fell back to `keychain.read()` when the field was empty, validating the still-stored
  key into "Verified" even though the user had cleared it. Fixed by extracting `removeKey()` and having
  an empty field on Revalidate commit the removal (never resurrect); shared with `saveAndValidate()`'s
  empty branch. Bug-lock test asserts the validator is never invoked for an empty field.

## From Phase 8 / manual testing

- [ ] **P8-1 — Test/preview `PreferencesStore` leaks ephemeral UserDefaults suites (Low, test hygiene).**
  Tests/previews create persistent `UserDefaults(suiteName: "com.zerro.ephemeral.<UUID>")` and never
  remove them, so `defaults domains` accumulates hundreds of `com.zerro.ephemeral.*` entries over many
  runs. Cosmetic (doesn't affect the real app domain `com.cbreeding.Zerro[.staging]`), but tests should
  tear them down (`removePersistentDomain(forName:)` in tearDown) — or use a non-persisting defaults.

## From Phase 7 review

- [x] **P7-1 — `isLocal` recompute can disagree with the built service in a race. RESOLVED in Phase 8.**
  `STTResolution.service` now carries `isLocal`, set by `STTRouting.resolve` from what it ACTUALLY
  built (local branch → true, cloud branch → false). `defaultResolveTranscriptionService` reads that
  flag instead of recomputing `modelInstalled && engine != .cloud`, so the `.auto` vanished-file
  fallback to cloud is tagged `isLocal: false` — no phantom $0 log. Tested: `.auto` with
  `buildLocal` returning nil + an OpenAI key falls back to cloud AND reports `isLocal == false`;
  the truth table asserts locality for every `.service` case.

## From Phase 3 review

- [x] **P3-1 — `sttWasLocal` via concrete-type check. RESOLVED in Phase 7.**
  The resolver now returns `AppState.ResolvedTranscription { service, isLocal }`.
  `defaultResolveTranscriptionService` reports `isLocal` (model installed AND engine not
  cloud-forced — the same inputs `STTRouting` routes on, so it can't disagree with the built
  service), and the transcription step reads `resolved.isLocal` instead of
  `service is WhisperCppTranscriptionService`. `STTRouting` itself is unchanged; the test
  injections were updated to the struct.
