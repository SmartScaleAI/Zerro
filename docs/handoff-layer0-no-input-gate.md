# Handoff — Layer 0: Local "no input" gate (don't charge for empty recordings)

**Date:** 2026-06-27
**Owner:** _unassigned_
**Status:** Ready to implement
**Scope:** Item #1 only. Item #2 (server-side no-charge on the `ZERRO_NO_REQUEST` sentinel) is a separate follow-up and is intentionally **out of scope** here.

---

## 1. Problem

When a recording contains no usable request (mic muted / not picked up / silent screen-only clip), Zerro still uploads it and fires the billable generation call. The model returns its no-request sentinel, the client shows "Nothing to change" (Dev Mode) or a bare chat line (normal mode), **and the user is charged a credit** for a result they can't use. That looks bad and generates support friction.

The charge happens server-side on any successful model call; the no-request signal is only detected on the client *after* the charge. See the prior analysis for the full trace.

## 2. Goal

Catch the unambiguous "nothing to act on" case **entirely on-device, before any network/provider call**, so it costs the user nothing and costs us nothing. Show a friendly "didn't catch that — nothing was charged" state instead of a failure that looks like a billing event.

This is the highest-value, lowest-risk slice. It does **not** attempt to catch the harder "spoke, but unclear / no actionable request" case — that is what item #2 (server sentinel no-charge) handles.

## 3. The gate condition (and why it's safe)

Skip generation when:

```
!processed.hasSpeech && processed.clicks.isEmpty
```

Why this exact condition has **no false negatives** (never drops a real request):

- `hasSpeech` is the existing on-device RMS energy check (`AudioActivity`). It is deliberately biased toward `true` — any window above threshold, or any decode failure, returns `true`. So `hasSpeech == false` means we are confident the clip is silent.
- In **normal mode**, the request is carried by narration. No narration → the server prompt's empty-narration rule already returns `ZERRO_NO_REQUEST`.
- In **Dev Mode**, deixis/dwell anchors are resolved *around spoken phrases* (`DeixisResolver` windows on word timings). With no speech there are no phrases and therefore no anchors — the only remaining non-speech carrier of intent is the **click stream** (`clicks`). So "no speech AND no clicks" leaves the model with nothing a request could come from.
- Net: the only recordings this skips are exactly the ones the model itself already answers with `ZERRO_NO_REQUEST`. We are short-circuiting a guaranteed no-op, not making a judgment call.

Cursor dwell is intentionally **not** part of the condition: dwell is only meaningful as a referent for a spoken phrase ("change *this*"), so it carries no intent without speech.

> Conservative by design. If we ever want to also skip "no speech + clicks-only-but-trivial" or normal-mode "no speech regardless of clicks," that's a future tightening — not this change.

## 4. Where it goes

Single insertion point: the top of `runPromptGeneration(processed:)` in `apps/desktop/Zerro/AppState.swift` (currently ~line 2168). This is the one routing branch that fans out to **managed / trial / BYOK**, so gating here covers every path at once, and it runs **before** the `generation_started` analytics event and before any client/server dispatch.

```
private func runPromptGeneration(processed: ProcessedRecording) {
    // Layer 0 — local no-input gate. Before any analytics/dispatch/charge.
    if RecordingInputGate.shouldSkipGeneration(
        hasSpeech: processed.hasSpeech,
        clickCount: processed.clicks.count
    ) {
        handleNoInputCaptured(processed: processed)   // see §5.3
        return
    }

    // …existing route resolution + switch unchanged…
}
```

## 5. Implementation steps

### 5.1 New pure, testable helper
Create `apps/desktop/Zerro/Processing/RecordingInputGate.swift`. Mirror the `AudioActivity` design — pure function, no side effects, unit-testable without `AppState`:

```swift
enum RecordingInputGate {
    /// True when a recording has no on-device signal a request could come from
    /// (silent audio AND no clicks), so generation would be a guaranteed
    /// ZERRO_NO_REQUEST. Skipping it avoids a charge for an empty recording.
    static func shouldSkipGeneration(hasSpeech: Bool, clickCount: Int) -> Bool {
        !hasSpeech && clickCount == 0
    }
}
```

Keep the signature primitive (`Bool`, `Int`) so tests don't need to build a full `ProcessedRecording`.

### 5.2 New failure reason + copy
In `AppState.swift`, add a `RecordingFailureReason` case and wire all three switches (mirror `.recordingTooShort`, which is the closest analog — non-retryable, user-actionable, nothing charged):

- New case, e.g. `case noInputCaptured`.
- `isRetryable`: **false** (re-running identical silent audio fails the same way; the fix is to record again with the mic working).
- `userMessage`: friendly + reassuring that nothing was charged. Suggested copy:
  `"Didn't catch anything to act on — nothing was charged. Check your mic and record again."`
- Add it to `Self.errorCodeString(_:)` (analytics string), e.g. `"no_input_captured"`.

> Presentation note: because the gate is shared, a **Dev Mode** recording that hits this path shows this amber pill, **not** the Dev "Nothing to change" card. That's intended — it's a clearer, non-billing-looking message. The Dev `.noChangeRequested` card remains for the residual "spoke but no change" case (handled by item #2).

### 5.3 Skip handler
Add `handleNoInputCaptured(processed:)` that:

1. Sets `state = .failed(reason: .noInputCaptured)`.
2. **Discards** the working directory (nothing to retry/resume — no Continue/Revert). Reuse the existing processed-recording teardown the discard path uses; do not retain it as a pending paid generation.
3. Fires a distinct analytics event so the funnel shows skips vs. real generations, e.g.:
   `Analytics.capture("generation_skipped", ["reason": "no_input", "is_dev_mode": recordingIsDevMode])`
   (Do **not** fire `generation_started`/`generation_succeeded`/`generation_failed` for this path — it never dispatched.)

### 5.4 Confirm no charge / no network
Verify the early return happens before: `entitlements?.generationRoute(...)`, the `generation_started` event, and any `runProxyGeneration` / `runLocalPromptGeneration` call. No credit gate is touched, no request is sent.

## 6. Tests

Add `apps/desktop/ZerroTests/RecordingInputGateTests.swift` (pure-function coverage):

- `hasSpeech=false, clicks=0` → skip == true
- `hasSpeech=false, clicks>0` → skip == false (Dev click-only request survives)
- `hasSpeech=true,  clicks=0` → skip == false (narration survives)
- `hasSpeech=true,  clicks>0` → skip == false

Add an `AppState`-level test (mirror `MinRecordingDurationTests`) asserting that a processed recording with `hasSpeech=false, clicks=[]` lands in `.failed(reason: .noInputCaptured)` **without** invoking the proxy/local generation (use the existing test seams / a stub proxy to assert zero dispatch), and that the working dir is torn down.

## 7. Acceptance criteria

- A silent recording with no clicks (both normal and Dev Mode) ends in the "didn't catch anything — nothing was charged" pill.
- No `/generate`, `/dev-transcribe`, or BYOK provider call is made for that recording (verify via logs/network stub).
- Credits balance is unchanged after such a recording.
- A recording with speech, or with clicks, is completely unaffected (byte-identical to today's behavior).
- New + existing tests pass; `RecordingInputGate` is covered.

## 8. Risks & mitigations

- **False negative (dropping a real request):** Bounded to zero relative to the model's own behavior — see §3. The RMS gate's bias-to-`true` is the safety margin.
- **User recorded a genuine silent/click-only intent we don't yet support:** Out of scope; today that already yields a no-result. The new copy is clearer than the status quo.
- **Copy tone:** Make sure it reads as informational, not an error/billing event. Amber pill is fine; wording matters.

## 9. Out of scope (do not build here)

- Item #2: server-side no-charge when the model returns `<<<ZERRO_NO_REQUEST>>>` (the backstop for "spoke but unclear"). Separate handoff after this lands.
- Better on-device VAD / on-device transcription (macOS 26 `SpeechAnalyzer`/`SpeechDetector`).
- Server-side transcript gate between STT and the chat call.
- Any "Send anyway" escape hatch (consider only if real-world false negatives appear).

## 10. Key references

- `apps/desktop/Zerro/AppState.swift` — `runPromptGeneration(processed:)` (~2168, insertion point); `RecordingFailureReason` enum + `isRetryable`/`userMessage`/`errorCodeString` switches (~200–360, ~3486).
- `apps/desktop/Zerro/Processing/AudioActivity.swift` — existing on-device `hasSpeech` (the design to mirror).
- `apps/desktop/Zerro/Processing/ProcessingModels.swift` — `ProcessedRecording` (`hasSpeech`, `clicks`, `cursorTrack`); `ResolvedClick`, `CursorSample`.
- `apps/desktop/Zerro/Services/Dev/DeixisResolver.swift` — confirms dwell anchors require spoken phrases (basis for the §3 safety argument).
- `apps/desktop/ZerroTests/MinRecordingDurationTests.swift`, `AudioActivityTests.swift` — patterns to mirror for the new tests.
