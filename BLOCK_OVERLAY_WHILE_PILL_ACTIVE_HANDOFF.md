# Handoff: Block opening a new Zerro overlay while any session pill is still showing

## Goal

The record hotkey must not start a **new** Zerro session while the **previous** session is still unresolved. Today it already blocks (flash/shake the pill) while a generation is in flight. Extend that same behavior to **every** terminal "resting pill" state — a success result, an error pill, a dev-mode "changes applied" card, and a dev-mode failure card. In all of these the user must explicitly dismiss/accept/undo the current pill **before** the hotkey is allowed to open a new overlay.

In short: the hotkey may only start a new session from a truly clean slate (`.idle`, with no pill on screen). In any non-idle, non-recording state it should flash the existing pill instead of starting fresh.

## Where this lives

All of the relevant logic is in the macOS app under `apps/desktop/Zerro/`.

- **Hotkey handler:** `apps/desktop/Zerro/ZerroApp.swift` → `private static func handleHotkey(...)` (around line 492).
- **State machine:** `apps/desktop/Zerro/AppState.swift` → `public enum RecordingState` (line 38) and the computed guards `isRecordingActive` (line 954), `isDevBusy` (line 3319), `isDevDispatchActive` (line 3303).
- **Shake animation (already built, reuse as-is):** `apps/desktop/Zerro/Surfaces/Pill/PillWindowController.swift` → `func flashBusy()` (increments `viewModel.flashTrigger`, drives a ~180ms scale pulse 1.0 → 0.96 → 1.0). **Do not build a new animation** — `pillController?.flashBusy()` is the exact affordance to reuse.

## Current behavior (what's already guarded)

`handleHotkey(...)` runs a sequence of early-return guards before it reaches the "present area selector / start recording" path. Today it already handles:

1. `state.isRecordingActive` (`.recording` / `.wrappingUp` / `.autoStopped`) → **stop** the recording (toggle). Leave this first guard exactly as-is.
2. `state.state == .processing` → `flashBusy(); return`
3. `case .confirmingRecovery` → `flashBusy(); return`
4. `case .confirmingDevRecovery` → `flashBusy(); return`
5. `state.isDevBusy` (`.devCheckpointing` / `.devAgentDispatching` / `.devAgentRunning` / `.reviewingPrompt` / `.devReverting`) → `flashBusy(); return`

## The gap (what to fix)

Four terminal states are **NOT** guarded today, so the hotkey falls through them and starts a brand-new recording (implicitly tearing down the current pill via `resetToIdle` / `dismissFailure`):

- `.done` — the success result pill (artifact card) is showing.
- `.failed(reason:)` — any error pill is showing (compact `error`, `failureExpanded`, or `paidBlockResume`).
- `.devDone` — the dev-mode "Changes applied" card is showing (changes done, user hasn't dismissed/undone).
- `.devFailed` — the dev-mode agent-failure card is showing.

**Required change:** add a guard so that in **all four** of these states the hotkey flashes the pill (`pillController?.flashBusy()`) and returns, instead of starting a new session. The user must dismiss/accept/undo via the pill's own controls (the result's "x", the error's dismiss/retry, the dev card's Undo/keep) before the hotkey will open a new overlay.

## Decisions already made (confirmed with the product owner)

- **All four states block**, including the normal `.done` success pill. Yes — pressing the hotkey on a finished result should now **flash, not dismiss-and-restart**. The user dismisses the result pill explicitly first. (This is a deliberate behavior change from today, where the hotkey on `.done` falls through.)
- **Blocked behavior = the existing shake only.** Reuse `flashBusy()`. No new tooltip/hint copy.
- **Do not touch** the `isRecordingActive` stop-toggle (guard #1) or any of the already-working guards (#2–#5).

## Suggested implementation

The cleanest approach is a single new guard placed **after** the existing `isDevBusy` guard (#5) and **before** the onboarding/permission gates, so the resting-pill states are caught alongside the other "resolve the pill first" cases. Something like:

```swift
// Terminal "resting pill" states — a finished result, an error, or a
// dev-mode result/failure card is still on screen and the user hasn't
// dismissed it. The record hotkey must NOT silently tear it down and start
// a new session; the user resolves the pill via its own controls first.
// Flash like .processing to signal "registered — clear the pill first".
switch state.state {
case .done, .failed, .devDone, .devFailed:
    Log.hotkey.notice("resting pill showing (\(String(describing: state.state), privacy: .public)) — flashing instead of starting")
    pillController?.flashBusy()
    return
default:
    break
}
```

Match the existing guard style (log line + `flashBusy()` + `return`). Prefer a single consolidated guard over four separate `if` blocks for readability, but either is acceptable as long as all four states are covered.

### Double-check before finalizing

- Confirm there is no **other** entry point that opens the overlay / starts a recording and bypasses `handleHotkey` (e.g. a menu-bar item, a deep link, a dock action, or a "Record" button in any window). Search for callers of `startRecording`, `areaSelector.present`, and the `toggleRecording` shortcut. If another path exists, apply the same resting-pill guard there (or, better, factor the guard into a shared `canStartNewSession` check on `AppState` that both paths consult).
- Verify the **pill controls themselves still work** after this change. The hotkey no longer dismisses these pills, so dismissing must remain possible via: the result card's "x" (`onDismissResult` → `resetToIdle`), the error's dismiss (`onDismissError` → `dismissFailure`), and the dev card's Undo/keep. Confirm none of those relied on the hotkey.
- Make sure `.idle` still starts a new session normally, and that `isRecordingActive` still toggles-stop.

## Acceptance criteria

1. Pressing the record hotkey while a generation is in flight (`.processing`) → pill shakes, no new overlay. *(unchanged — regression check only)*
2. Pressing the hotkey while a **success result pill** (`.done`) is showing → pill shakes, no new overlay. The result is NOT dismissed.
3. Pressing the hotkey while **any error pill** (`.failed` — compact error, expanded failure, or paid-block resume) is showing → pill shakes, no new overlay.
4. Pressing the hotkey while the dev-mode **"Changes applied"** card (`.devDone`) is showing → pill shakes, no new overlay. Changes are NOT discarded and no new session starts.
5. Pressing the hotkey while the dev-mode **failure** card (`.devFailed`) is showing → pill shakes, no new overlay.
6. After the user dismisses/accepts/undoes the pill (state returns to `.idle`), pressing the hotkey opens the area selector and starts a new session normally.
7. Pressing the hotkey during an **active recording** still stops it (toggle preserved).
8. No other overlay entry point can bypass these guards.

## Files likely to change

- `apps/desktop/Zerro/ZerroApp.swift` (the new guard in `handleHotkey`) — primary change.
- Possibly a small helper on `apps/desktop/Zerro/AppState.swift` (e.g. a `var isShowingRestingPill: Bool` computed property) if you prefer to centralize the state set rather than inline the `switch`. Optional but cleaner if a second entry point needs the same check.

No UI/animation files should need changes — `flashBusy()` already exists and is reused as-is.
