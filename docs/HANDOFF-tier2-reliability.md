# Claude Code handoff — Tier 2 analytics (reliability + permissions) + a Tier 1 fix

Implement reliability/permission analytics in the Zerro macOS app, plus one
small carryover fix from Tier 1. These quantify the two biggest sources of
silent churn: permission friction (the Screen Recording SIGKILL) and
recording/generation failures.

## Read first
- `docs/HANDOFF-tier1-core-funnel.md` and `docs/ANALYTICS-POSTHOG-PLAN.md`
  (§4.3 permissions, §4.4 recovery, §4.6 generation). Match those names.

## Ground rules (unchanged, binding)
- All events go through `Observability/Analytics.swift` (`Analytics.capture`).
  Metadata only — enums, counts, durations, booleans, model ids. Never content,
  never an exact credit balance, never a hotkey/path/email string.
- Everything stays behind the existing opt-out gate. Don't bypass it.
- Keep the diff focused; match surrounding code + comment style.

---

## 0. Tier 1 carryover fix — consistent `model` across a generation

Today `generation_started` uses the effective model id
(`recordingModelID ?? selectedModelID ?? default`) while
`generation_succeeded` / `generation_failed` still use
`preferences?.selectedModelID`. With a per-recording model override these
disagree, so one generation gets reported under two different models — which
corrupts per-model funnels and economics.

Fix: resolve the model id **once** at generation start and reuse it everywhere.
- Add a field `private var generationModelID: String?` next to
  `generationStartInstant` in `AppState`.
- In `runPromptGeneration`, where the `generation_started` `model` is computed,
  assign it to `generationModelID` (reset per attempt, same as the instant).
- In all four outcome captures (the two `generation_succeeded` and two
  `generation_failed`), replace `self.preferences?.selectedModelID ?? "unknown"`
  with `self.generationModelID ?? "unknown"`.
- Leave `route`, `artifact_type`, `reason`, `latency_ms` exactly as they are.

Net: a generation is reported under one model id from start to outcome.

---

## 1. Permission events

Single chokepoint already exists: `PermissionsManager.refreshStatuses()` computes
`prevScreen`/`prevMic` vs the freshly computed statuses on each poll. Emit the
transitions there, **after** the new statuses are assigned and **gated by the
existing `hasPerformedInitialRefresh`** flag so the synthetic
`notDetermined → granted` step during init doesn't fire events.

Track Screen Recording and Microphone only (skip Accessibility — it's
informational and never reports `.denied`). `permission` property is
`screen_recording` / `microphone`.

| Event | Transition (per permission) | Properties |
|---|---|---|
| `permission_granted` | `prev != .granted` → `new == .granted` | `permission` |
| `permission_denied` | `prev != .denied` → `new == .denied` | `permission` |
| `permission_revoked` | `prev == .granted` → `new != .granted` | `permission` |

Notes:
- Each transition fires at most once because `prev` is captured fresh each call
  and the event only fires on an actual change. Don't add extra dedup.
- A small shared helper that takes `(permission, prev, new)` and emits the right
  event keeps this DRY for both permissions.
- Do **not** infer a `context` (onboarding/settings) property for v1 — leave it
  off rather than guess; it can be added later if needed.

## 2. Recovery events (orphaned recordings after sleep/crash)

In `AppState`:

| Event | Where | Properties |
|---|---|---|
| `recovery_offered` | `recoverOrphanedRecordingIfAny(trigger:)`, right where `state = .confirmingRecovery` is set | `trigger` = `wake` / `launch` (from `RecoveryTrigger`) |
| `recovery_accepted` | `resolveRecovery(generate:)`, the `generate == true` branch | — |
| `recovery_discarded` | `resolveRecovery(generate:)`, the `else` (Discard) branch | — |

Note: a recovery that's accepted runs through processing/generation, so it will
also emit `processing_*` and `generation_*` — that's correct and expected.

## 3. `generation_retried`

In `AppState.retryFailedPrompt()`. The state is `.failed(reason:)` on entry —
read the reason **before** `state = .processing`, and read `attempt` after the
`failureRetryAttempts += 1` increment.

| Event | Where | Properties |
|---|---|---|
| `generation_retried` | `retryFailedPrompt()` (only when it proceeds past the `canRetryFailure` guard) | `reason` = `Self.errorCodeString(reason)`, `attempt` = `failureRetryAttempts` (Int, 1-based) |

The subsequent re-run re-enters `runPromptGeneration`, which already fires a
fresh `generation_started` and resets the latency/model — so a retry produces:
`generation_retried → generation_started → generation_succeeded/_failed`.

---

## Verify before finishing
- Project builds (Xcode or `xcodebuild` on the `apps/desktop` target).
- Permission transitions fire once each, with no event on app launch's initial
  status computation (the `hasPerformedInitialRefresh` guard holds). Trace:
  grant Screen Recording → `permission_granted{screen_recording}`; later revoke
  in System Settings → `permission_revoked{screen_recording}`.
- `recovery_offered` carries the right `trigger`; accepted vs discarded are
  mutually exclusive per offer.
- `generation_retried.attempt` increments 1,2,… across consecutive retries and
  the event stops once `canRetryFailure` is false (cap reached).
- Tier 1 fix: `generation_started` and its matching outcome now report the SAME
  `model`, including when a per-recording override is set.
- No content, paths, hotkeys, emails, or exact balances in any property.
- Show me the final diff, how each verification point holds, and the event list:
```
New events:   permission_granted   { permission: screen_recording|microphone }
              permission_denied    { permission: screen_recording|microphone }
              permission_revoked   { permission: screen_recording|microphone }
              recovery_offered     { trigger: wake|launch }
              recovery_accepted    { }
              recovery_discarded   { }
              generation_retried   { reason: <RecordingFailureReason case>, attempt:Int }
Changed:      generation_succeeded / generation_failed now use the resolved
              per-generation model id (consistent with generation_started)
```
