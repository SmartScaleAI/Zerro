# Claude Code handoff — Tier 1 analytics (core funnel + segmentation)

Implement four analytics improvements in the Zerro macOS app. These close the
biggest blind spots: nothing can be segmented by billing state, the recording
loop has no terminal event, generation has no start/latency, and the local
processing pipeline is invisible.

## Read first
- `docs/ANALYTICS-CURRENT-STATE.md` (what exists today) and the event list in
  `docs/ANALYTICS-POSTHOG-PLAN.md` (§2 super-properties, §4.4 recording, §4.5
  processing, §4.6 generation) — match those names/properties where they apply.

## Ground rules (do not violate)
- All analytics go through `Observability/Analytics.swift`
  (`Analytics.capture` / `captureOnce`). Do NOT touch the PostHog SDK setup
  beyond adding the super-property updater described below.
- **Metadata only, never content.** Properties may be enums, counts, durations,
  booleans, model ids, and coarse buckets — never prompt/transcript/file-path
  text, raw credit balances, or anything user-identifying. The existing
  privacy contract in `Analytics.swift` / `CrashReporting.swift` is binding.
- Everything stays gated by the existing opt-out — don't bypass it.
- Keep the diff focused; match surrounding code + comment style.

---

## 1. Global super-properties: `entitlement_state` + `credits_remaining_bucket`

Goal: attach billing context to **every** event so all events (existing and
new) can be segmented by monetization state.

- Add a method to `Analytics` (e.g. `updateEntitlementProperties(_:)`) that maps
  the current `EntitlementState` (`Services/Billing/EntitlementState.swift`) to:
  - `entitlement_state`: one of `trial` / `expired` / `byok` /
    `managed_starter` / `managed_pro` / `pre_trial` (use `pre_trial` for
    `.trial(creditsRemaining: nil)`).
  - `credits_remaining_bucket`: bucket the relevant `creditsRemaining` into
    `"0"` / `"1-10"` / `"11-50"` / `"50+"`; use `"n/a"` for `.byok` / `.expired`
    / pre-trial (no meaningful balance). **Never emit the exact balance.**
  - Implement by calling `PostHogSDK.shared.register([...])` (same mechanism as
    the existing super-properties in `start()`); calling `register` again
    overwrites them live.
- Call it (a) once after `Analytics.start()` with the current entitlement, and
  (b) wherever entitlement is set/refreshed in `EntitlementStore`
  (`Services/Billing/EntitlementStore.swift`) and on the trial-credit refresh
  paths in `AppState` (search `applyTrialCreditsRemaining` /
  `applyCreditsRemaining`) so the super-property tracks reality.
- If analytics hasn't started yet, the call should no-op safely.

## 2. Terminal recording events (with duration)

Today `recording_started` fires but nothing closes the loop. Use the existing
`AppState.elapsedSeconds` (live capture duration) as the duration source.

- `recording_completed` — when a recording ends and proceeds to processing
  (covers manual stop and the ~180s auto-stop). Fire from `AppState` where the
  session transitions toward `.processing` (see `stopRecording()` / the
  auto-stop path / the `.processing` transition). Properties:
  `duration_seconds` (rounded Int from `elapsedSeconds`), `end_reason` =
  `manual` / `auto_stop`.
- `recording_cancelled` — in `AppState.cancelRecording()`. Property:
  `duration_seconds`.
- `recording_too_short` — on the `recordingTooShort` failure. Property:
  `duration_seconds`. (This is the `.failed(reason: .recordingTooShort)` path.)

## 3. `generation_started` + `latency_ms` on outcomes

`AppState` currently fires only `generation_succeeded` / `generation_failed`.

- Capture a start timestamp when generation kicks off (the `runPromptGeneration`
  entry / where the proxy or BYOK request is dispatched).
- `generation_started` — fire at that point. Properties: `model`, `route`
  (`managed` / `trial` / `byok`), and `provider` (`openai` / `gemini` /
  `anthropic`) if cheaply derivable from the model id.
- Add `latency_ms` (Int, milliseconds from the start timestamp) to the existing
  `generation_succeeded` AND `generation_failed` captures. Keep their current
  properties intact.

## 4. Processing pipeline events

The local pipeline (frame extraction, transcription, redaction) between
recording and generation is currently invisible. The `.processing` state and a
`processing` error stage already exist (`CrashReporting.capture(... stage:
"processing")`).

- `processing_completed` — when processed artifacts are ready and generation is
  about to start. Properties (best-effort, only if already at hand — don't add
  expensive work to compute them): `duration_seconds`, `frame_count`,
  `audio_seconds`.
- `processing_failed` — on pipeline failure (the `.processingFailed` reason).
  Property: `reason` (reuse the existing failure-reason string mapping, e.g.
  `Self.errorCodeString(...)`).

---

## Verify before finishing
- Project builds (Xcode or `xcodebuild` on the `apps/desktop` target).
- `entitlement_state` / `credits_remaining_bucket` update when entitlement
  changes (trace: fresh trial → credits spent → exhausted → `expired`), and the
  bucket never contains a raw number.
- One `recording_completed` OR `recording_cancelled` (never both) fires per
  session, with a plausible `duration_seconds`.
- `generation_started` precedes every `generation_succeeded`/`_failed`, and
  `latency_ms` is present and sane on the outcomes.
- `processing_*` fire on the right transitions; `processing_failed.reason` is a
  bounded enum string, not free text.
- No raw content or exact balances appear in any property.
- Show me the final diff and a short note on how each verification point holds,
  plus the final list of new/changed events and their properties.
```
New events:   recording_completed, recording_cancelled, recording_too_short,
              generation_started, processing_completed, processing_failed
Enriched:     generation_succeeded (+latency_ms), generation_failed (+latency_ms)
Super-props:  entitlement_state, credits_remaining_bucket (on ALL events)
```
