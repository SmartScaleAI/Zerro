# Local Whisper — Deferred Fixes / Punchlist

Cross-phase cleanup items found during review, to be handled at the end (or in the
phase noted). None are blockers for proceeding.

## From Phase 1 review

- [x] **P1-1 — `fullText` leading space. RESOLVED in Phase 7.**
  `runEngine` now assembles `fullText` via `assembleFullText(fromSegmentTexts:)`, which joins
  the segment texts and trims the result — no leading/trailing whitespace, parity with
  `OpenAITranscriptionService`. Covered by a pure (engine-free) test plus a no-whitespace
  assertion in the end-to-end transcription test.

- [ ] **P1-2 — DTW `t_dtw > 0` first-token edge (Low; validate Phase 8).**
  In `rawTokens`, a token with `t_dtw == 0` falls back to heuristic `t0/t1`. A legitimate
  word at audio start (t=0) would use heuristic timing. Irrelevant given the deixis window
  slop; confirm in Phase 8 Dev Mode validation.

- [ ] **P1-3 — Single-pass `AVAudioConverter` robustness (Low/Med; validate Phase 8).**
  `decodeToPCM16kMono` converts in a single pass with a +16 KB slack output buffer. Fine for
  ≤3-min recordings, but verify a full-length real recording drains completely (or loop until
  `.endOfStream`).

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

- [ ] **P2-2 — Narrow cancel-during-install race (Low).**
  A `cancel()` arriving after `didFinishDownloadingTo` (file fully downloaded) but before
  `verifyAndInstall` finishes can still resolve to `.ready`, since the post-install block
  doesn't re-check for cancellation. Very narrow; low severity. Re-check `isCancelling`/state
  before the final `.ready` transition if tightening.

## From Phase 7 review

- [ ] **P7-1 — `isLocal` recompute can disagree with the built service in a race (Very Low).**
  P3-1 replaced `service is WhisperCppTranscriptionService` with a recompute
  `isLocal = modelInstalled && engine != .cloud` in `defaultResolveTranscriptionService`. But under
  `.auto`, `STTRouting.resolve`'s `buildLocal` uses `try?`; if it returns nil (model file vanished
  between the cheap size-check and construction) `.auto` returns a CLOUD service while `isLocal`
  stays true → a cloud transcription logged at $0. Cost-LOG only (no real charge), microsecond race,
  negligible in practice. Airtight fix: have `STTRouting.resolve` report the locality it actually
  built (distinct `.localService`/`.cloudService`, or return isLocal), so the caller doesn't
  recompute. Candidate to fold into Phase 8.

## From Phase 3 review

- [x] **P3-1 — `sttWasLocal` via concrete-type check. RESOLVED in Phase 7.**
  The resolver now returns `AppState.ResolvedTranscription { service, isLocal }`.
  `defaultResolveTranscriptionService` reports `isLocal` (model installed AND engine not
  cloud-forced — the same inputs `STTRouting` routes on, so it can't disagree with the built
  service), and the transcription step reads `resolved.isLocal` instead of
  `service is WhisperCppTranscriptionService`. `STTRouting` itself is unchanged; the test
  injections were updated to the struct.
