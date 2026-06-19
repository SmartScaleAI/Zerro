# Task: Preserve a credit-blocked recording and let the user resume generation after they pay

## Summary
Today, when a user records while out of credits, the recording is captured and
processed, then generation fails at the proxy with a paid-block reason
(trial credits exhausted / out of monthly credits / lapsed subscription). The
pill shows a dismiss-only failure. If the user goes and pays, **there is no way
to continue the same recording** — the only pill action (Dismiss) throws the
recording away, and quitting the app during browser checkout lets the launch
sweep delete the processed working directory. The user has to re-record.

We want to keep that recording around (even across an app quit/relaunch) and
give the user an explicit **"Continue"** button to finish the generation once
they've paid.

## Decisions (already made — build to these)
1. **Resume trigger:** an explicit **"Continue" button** on the failure pill (NOT
   auto-resume). Tapping it re-checks entitlement; if the user is now paid, it
   resumes generation; if not yet paid, it opens the paywall. The recording is
   preserved either way so they can pay and come back.
2. **Persistence:** the held recording must **survive an app quit/relaunch**
   during checkout — persisted to disk and protected from the launch sweep, then
   restored at next launch.
3. **Scope:** applies to **all paid-blocked reasons** — `.trialCreditsExhausted`,
   `.outOfCredits`, and `.subscriptionInactive`.

---

## How the current flow works (verified — use these anchors)

All paths below are in `apps/desktop/Zerro/`.

- **Failure origin:** `AppState.runProxyGeneration(...)` (`AppState.swift` ~line 1520).
  Its `catch` (~1603–1631) maps the proxy error via `trialFailureReason` /
  `managedFailureReason` and sets `state = .failed(reason:)`. The three paid
  reasons land here: `.trialCreditsExhausted` (~1645), `.outOfCredits`,
  `.subscriptionInactive`.
- **The recording is still on disk at failure time.** `self.processedRecording`
  (`ProcessedRecording`) is still set, and its `workingDirectory` (containing
  `audio.m4a`, `frame-NNN.jpg`, `manifest.json`) is intact — `runProcessing`
  deletes only the source `.mov`, never the working dir, and both catch blocks
  leave the working dir in place. So generation can be re-run with no
  re-recording/re-processing.
- **Existing retry infra to mirror (don't reuse directly):**
  `AppState.canRetryFailure` (~2182) + `AppState.retryFailedPrompt()` (~2195)
  re-run `runPromptGeneration(processed:)` against the in-memory
  `processedRecording`, reusing `processed.idempotencyKey`. But `canRetryFailure`
  is gated on `reason.isRetryable`, and the three paid reasons are deliberately
  **not** retryable (`RecordingFailureReason.isRetryable`, ~line 207). Do **not**
  flip those to retryable — that would change unrelated behavior. Add a parallel
  resume path instead.
- **Working directory + sweep:** `WorkingDirectory` (`Processing/WorkingDirectory.swift`)
  creates dirs in `FileManager.default.temporaryDirectory` with prefix
  `zerro-work-`. `sweep()` (~207) runs at launch and deletes every `zerro-`
  entry except an optional `keeping:` URL. **This is why a quit-during-checkout
  loses the recording.** There's already a precedent for protecting a file across
  launches: `recoverableMarkerSuffix = "recoverable"` + `markRecoverable(_:)` for
  orphaned `.mov`s.
- **Recovery precedent to model the UX on:** the sleep/launch recovery flow uses
  a dedicated `.confirmingRecovery` state + `pendingRecoveryURL` +
  `resolveRecovery(generate:)` (`AppState.swift` ~1162–1237) to OFFER a recording
  with explicit user consent before spending a credit. The persist-and-restore
  pattern there is the model for this feature.
- **Manifest:** `RecordingManifest` (`Processing/ProcessingModels.swift` ~153) is
  written by `ProcessingPipeline.writeManifest` (~672) and holds everything needed
  to rebuild a `ProcessedRecording` — `audioFilename`, `durationSeconds`,
  `hasSpeech`, `frames[]` (index, filename, timestampSeconds, ocrText), `clicks[]`.
  **There is currently no manifest *reader*** — you'll add one. The in-memory-only
  `ExtractedFrame.lines` are not needed for generation (clicks are already
  resolved). **`ProcessedRecording.idempotencyKey` (~104) is a `let = UUID()`
  excluded from the memberwise init** — it is NOT in the manifest, so to preserve
  it across relaunch you must persist it separately AND add a way to inject it
  when reconstructing (see step 3).
- **Entitlement / purchase:** purchasing happens via LemonSqueezy checkout in the
  browser (`PaywallView.swift`); the user then activates a license key →
  `EntitlementStore.activate(licenseKey:)` (`Services/Billing/EntitlementStore.swift`
  ~334), which sets `state = .managed/.byok` and dismisses the paywall window.
  `EntitlementStore.canGenerate` (~262) and `refresh()` / `refreshManagedEntitlement()`
  tell you whether the user can now generate. `AppState` holds `weak var entitlements`.
  Paywall is opened programmatically via `AppDelegate.openPaywall()` (`ZerroApp.swift` ~511).
- **Pill wiring anchors:**
  - `PillStateBridge.swift` ~66–78 maps `.failed(reason)` → `.error(message:, retryable:)`.
  - `PillView.swift`: `ResultPillState.error(message, retryable)` (~261) →
    `ErrorPillContent` with `onRetry`/`onDismiss` (~262–265); injected actions
    `onRetryError` / `onDismissError` (~70–76).
  - `PillWindowController.swift` ~322 wires `onRetryError: { appState.retryFailedPrompt() }`.
  - App wiring: `ZerroApp.swift` ~89–90 injects `entitlements`/`managedProxyClient`;
    ~187–192 starts the wake observer and runs `recoverOrphanedRecordingIfAny(.launch)`.

---

## Implementation plan

### Step 1 — Persist a "pending paid generation" pointer
Create a small Codable record (e.g. `PendingPaidGeneration` in a new file under
`Services/Billing/` or `Processing/`) holding what's needed to restore + resume:
`workingDirectoryPath` (or just the dir's last path component), `idempotencyKey`,
`modelID` (the value `runProxyGeneration` would pass — `recordingModelID ??
preferences?.selectedModelID ?? ModelRegistry.defaultModelID`), the blocking
`reason` (so the restored pill shows the right copy), and `createdAt`.

Persist it via `UserDefaults` (follow the existing pattern — see
`EntitlementStore`'s `managedSnapshotKey` save/load at ~654–659, and
`PreferencesStore`'s keyed `defaults` usage). Add a single owner with
`save` / `load` / `clear` helpers.

### Step 2 — Protect the working directory from the launch sweep
When a pending paid generation is saved, drop a marker file inside its working
directory (e.g. `pending-paid.json` containing the same record, which doubles as
the on-disk source of truth). Update `WorkingDirectory.sweep()` so it **skips any
`zerro-work-` directory that contains the marker file** (in addition to the
existing `keeping:` param). Keep this check cheap and best-effort. This guarantees
the recording survives quit/relaunch during checkout.

### Step 3 — Make `ProcessedRecording` reconstructable from disk
- Add a manifest **reader**: a function that decodes `manifest.json` from a working
  directory and rebuilds a `ProcessedRecording` (audio URL from `audioFilename`,
  `frames` from the relative filenames + `timestampSeconds` + `ocrText`,
  `duration` from `durationSeconds`, `clicks`, `hasSpeech`). Put it next to
  `RecordingManifest`/`ProcessingPipeline`.
- Allow injecting a known `idempotencyKey` on reconstruction so the resumed
  generation reuses the original key (the proxy replays a charged-but-dropped
  response instead of double-charging). Since the field is currently a
  `let = UUID()` excluded from the init, add an explicit initializer (or a
  dedicated reconstruction factory) that accepts `idempotencyKey`, defaulting to a
  fresh UUID so all existing construction sites keep compiling unchanged.

### Step 4 — Capture the pending generation when a paid block occurs
In `runProxyGeneration`'s `catch` (after `state = .failed(reason:)`, ~1626): if
`reason` is one of the three paid reasons **and** `processedRecording != nil`,
save the pending record (Step 1) + write the marker (Step 2) using the current
`processedRecording.workingDirectory` and `processedRecording.idempotencyKey`.
Keep `processedRecording` in memory as-is (in-session resume needs no disk reload).

### Step 5 — Add the resume path in `AppState`
Mirror the retry infra:
- `var canResumePaidGeneration: Bool` — true when `state` is `.failed` with a paid
  reason and a pending paid generation exists (in memory or persisted).
- `func resumePaidGeneration()`:
  1. Refresh entitlement (`entitlements?.refresh()`; for managed also
     `await entitlements?.refreshManagedEntitlement()`).
  2. If the user **can now generate** (`entitlements?.canGenerate == true`, or the
     route is no longer a paid block): reconstruct `processedRecording` from disk
     if it isn't already in memory (Step 3), set `state = .processing`, and call
     `runPromptGeneration(processed:)`. On success the normal `.done` path runs;
     clear the pending record + marker. (Idempotency key is reused, so no double
     charge.)
  3. If the user **still can't generate**: open the paywall via
     `AppDelegate.openPaywall()` and leave the pending record intact so they can
     pay and tap Continue again.
- Update `dismissFailure()` / `resetToIdle()` / `resetTransientRecordingState()`
  so that **explicitly dismissing** a paid-blocked failure clears the pending
  record AND deletes the protected working directory (Dismiss = "give up on this
  recording"). Make sure the normal success path and a normal (non-paid) failure
  dismissal also clear any stale pending record + marker.

### Step 6 — Restore the pending generation at launch
In the launch path (`ZerroApp.swift` ~187–192, alongside
`recoverOrphanedRecordingIfAny(.launch)`), before/instead of sweeping: if a
pending paid generation is persisted AND its working directory still exists with a
valid marker + manifest, restore `AppState` into `.failed(reason:)` for the saved
reason with the pending record loaded, so the pill comes back up with the
"Continue" button. Ensure the launch `sweep()` does not delete that directory
(Step 2 handles this). If the persisted dir is missing/invalid, clear the stale
pending record and proceed normally.

Order matters: restore (or at least read the protected path) must happen before
the blanket launch `sweep()` runs.

### Step 7 — Surface the "Continue" button in the pill
- `PillStateBridge.swift` (~66–78): when mapping a `.failed` paid-blocked state
  that `canResumePaidGeneration`, carry a flag/extra field so the pill knows to
  show a Continue affordance (extend the `.error` case, or add a sibling case like
  `.errorResumable(message:, ...)` — your call; the `.error` case already carries a
  `retryable` bool, so a parallel `resumable` bool is the lightest touch).
- `PillView.swift`: in `ErrorPillContent`, render a primary **"Continue"** button
  (next to Dismiss) when resumable, wired to a new injected action
  `onResumePaidGeneration` (mirror `onRetryError` at ~70–76 and the Retry button).
- `PillWindowController.swift` (~322): wire
  `onResumePaidGeneration: { appState.resumePaidGeneration() }`.
- Keep the message copy as-is (`RecordingFailureReason.userMessage`); just add the
  button. The trial-credits string already reads "subscribe or add your own API
  keys to keep going," which pairs well with a Continue button.

---

## Edge cases to handle
- **Double charge:** always reuse the original `idempotencyKey` on resume. Verify
  the reconstruction path carries it through to `proxy.generate(..., idempotencyKey:)`.
- **User pays with BYOK / their own API keys** instead of subscribing: after
  activation the route may become `.local`/`.byok`. `resumePaidGeneration` should
  resume through whatever `runPromptGeneration`'s route resolves to, not assume the
  proxy.
- **Stale / orphaned pending record:** working dir deleted out from under us,
  corrupt manifest, or a pending record older than some sanity bound — detect,
  clear the pending record + marker, and fall back to idle without crashing.
- **Only one pending generation at a time:** a brand-new recording supersedes any
  held one — when a new recording starts/processes, clear the previous pending
  record + delete its protected working dir so we don't leak or resume the wrong one.
- **Disk-cleanup paths:** audit every existing call that deletes a working dir or
  calls `resetTransientRecordingState` (`cancelRecording`, `resetToIdle`,
  `dismissFailure`, the `handleTermination` `.processing` branch, the sweep) so the
  protected dir is only deleted on an intentional discard — and the marker/pending
  record never leak after a successful resume or an intentional dismiss.
- **Sweep correctness:** confirm `sweep()` still reclaims genuinely orphaned
  `zerro-work-` dirs that have no marker.

## Verification
- Build the `Zerro` scheme (`xcodebuild` or Xcode) → must compile.
- Add unit tests (there's an existing `ZerroTests` target with billing/credit
  tests — see `CreditDisplayTests.swift`, and the `BYOKRoutingTests` referenced
  earlier) covering:
  - Paid-block failure persists a pending record + marker and keeps the working dir.
  - `sweep()` preserves a marked working dir and still deletes unmarked ones.
  - Manifest round-trip: write → read → reconstruct a `ProcessedRecording` whose
    `idempotencyKey` equals the persisted one.
  - `resumePaidGeneration` when entitled re-runs generation (reusing the key) and
    clears the pending record; when not entitled, opens the paywall and keeps it.
  - `dismissFailure` on a paid-block clears the pending record and deletes the dir.
- Manual smoke test: exhaust trial credits → record → see Continue button → quit
  app mid-"checkout" → relaunch → Continue button still there → simulate
  activation → tap Continue → generation completes against the original recording
  with no second charge.
- Note: the report should call out that `BYOKRoutingTests.testAnthropicBodyMatchesServerAdapterShape`
  is a pre-existing failure on the clean tree (unrelated), so it isn't mistaken for
  a regression.

## Out of scope
- No auto-resume (explicit Continue button only, per decision 1).
- No change to the proxy/server contract or billing logic beyond reusing the
  idempotency key that already exists.
- No change to `RecordingFailureReason.isRetryable` semantics.
