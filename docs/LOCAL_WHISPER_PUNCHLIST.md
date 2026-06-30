# Local Whisper — Deferred Fixes / Punchlist

Cross-phase cleanup items found during review, to be handled at the end (or in the
phase noted). None are blockers for proceeding.

## From Phase 1 review

- [ ] **P1-1 — `fullText` leading space (cosmetic, Low).**
  `WhisperCppTranscriptionService.runEngine` builds `fullText` from `rawTextParts.joined()`,
  so it carries a leading space (whisper segments each start with " "). Harmless (the
  timeline uses the trimmed segments), but trim the final joined string for parity with
  `OpenAITranscriptionService`.

- [ ] **P1-2 — DTW `t_dtw > 0` first-token edge (Low; validate Phase 8).**
  In `rawTokens`, a token with `t_dtw == 0` falls back to heuristic `t0/t1`. A legitimate
  word at audio start (t=0) would use heuristic timing. Irrelevant given the deixis window
  slop; confirm in Phase 8 Dev Mode validation.

- [ ] **P1-3 — Single-pass `AVAudioConverter` robustness (Low/Med; validate Phase 8).**
  `decodeToPCM16kMono` converts in a single pass with a +16 KB slack output buffer. Fine for
  ≤3-min recordings, but verify a full-length real recording drains completely (or loop until
  `.endOfStream`).

- [ ] **P1-4 — Replace `.modelUnavailable → .processingFailed` placeholder (Med; Phase 6).**
  `AppState.failureReason` currently maps `.modelUnavailable` to the generic
  `.processingFailed` as an unreachable Phase-1 placeholder. Phase 6 must replace it with a
  real, actionable `RecordingFailureReason` ("model still downloading" / offer cloud STT).

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
