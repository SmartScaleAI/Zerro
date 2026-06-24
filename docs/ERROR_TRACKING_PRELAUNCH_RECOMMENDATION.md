# Zerro — Error Tracking Audit & Pre-Launch Recommendation

**Scope:** the macOS desktop app (`apps/desktop`). **Backend:** PostHog (`posthog-ios` 3.60.0), used for both product analytics and error tracking. **Date:** June 21, 2026.

---

## Bottom line

The *architecture* of your error tracking is genuinely good — better than most apps at this stage. The single-chokepoint design, privacy discipline, and consent gating are all solid and you should keep them. But there is **one true launch blocker**: you generate dSYM symbol files and never upload them, so every crash that arrives in PostHog will be a wall of raw memory addresses you can't read. There are also four secondary gaps (no alerting, silent updater failures, a Swift-crash fidelity limitation, and an unverified production pipeline) that are worth closing before or shortly after going public.

Fix the dSYM upload before you ship. Everything else can be staged.

---

## What's already in place (and worth keeping)

The observability layer (`apps/desktop/Zerro/Observability/`) is deliberately designed around a single point of egress, and it shows.

`Analytics.swift` is the sole owner of the PostHog SDK lifecycle. It enables `errorTrackingConfig.autoCapture`, so Mach exceptions, POSIX signals, and uncaught `NSException`s are persisted to disk and sent as `$exception` events (level `fatal`) on the next launch. `CrashReporting.swift` is a thin wrapper for the *handled*-error path, and you call it at the eleven points in the pipeline that actually matter — recording, processing, transcription, and prompt/dev generation failures in `AppState.swift`, plus a few service layers.

The privacy model is the strongest part. The opt-out toggle (`crashReporting.isEnabled`) gates everything through `optOut()`/`optIn()` with no restart required; `personProfiles = .identifiedOnly` keeps every user anonymous; the `capture(message:)` label is a `StaticString`, so the compiler mechanically prevents runtime data (paths, response bodies, `localizedDescription`) from ever entering an event label; and the `context` dictionary is run through an allowlist plus secret-shaped/length scrubbing. DEBUG builds transmit nothing at all. This is the kind of discipline that keeps you out of trouble with a screen-recording app.

Supporting pieces are in good shape too: unified `os.Logger` logging with explicit `.public`/`.private` qualifiers, a local breadcrumb trail, and `DiagnosticsCollector` ("Copy diagnostic info") that bundles app/OS version, permission state, the last error's `diagnostic_id`, and the last 60s of `notice+` logs for support emails. Release builds are already set to `dwarf-with-dsym`, and every event carries `app_version`, `build_channel`, `environment`, and entitlement super-properties.

---

## Gaps, ranked by severity

### 1. Critical — dSYMs are generated but never uploaded (launch blocker)

The Release config produces dSYM files, but `release-app.yml` archives, exports, notarizes, and ships — with **no symbol-upload step anywhere**. PostHog symbolicates crash stack traces server-side using uploaded dSYMs; without them, fatal `$exception` events arrive as unsymbolicated memory offsets. You will see *that* you crashed and roughly how often, but not *where*. For a launch, that turns your crash dashboard into noise.

The fix is a `posthog-cli dsym upload` step (PostHog ships `upload-symbols.sh` for exactly this). It requires the dSYMs from the archive and `ENABLE_USER_SCRIPT_SANDBOXING = NO` if run as an Xcode build phase; in CI it's cleaner to run it as a dedicated step against the `.xcarchive`'s `dSYMs/` directory after the Archive step. This needs a PostHog **personal API key** with the right scope stored as a GitHub Actions secret.

### 2. High — no release/version registration, so symbols can't be matched to builds

dSYM upload only helps if PostHog can tie a given crash to the exact build that produced it. `posthog-cli` records a release keyed to a version/commit and stores that link inside the uploaded symbols. You should pass your existing build identifiers — `CURRENT_PROJECT_VERSION` (your commit-count build number) and `MARKETING_VERSION` — as the release/build when uploading, so a crash from build 1742 resolves against build 1742's dSYMs. Without this, symbolication silently fails or mismatches after a couple of releases.

### 3. High — no alerting configured

Nothing notifies you when a new crash type appears or an existing one spikes. PostHog error tracking supports issue-creation alerts and spike-detection alerts routed to Slack or a webhook. You already run a Slack relay for in-app feedback, so wiring error alerts to a `#zerro-alerts` channel is low-effort and high-value — on launch day you want to hear about a bad build within minutes, not when a user emails you.

### 4. Medium — Swift crash fidelity limitation (architectural, not a bug)

PostHog's Apple crash capture is PLCrashReporter-based, and it has a documented limitation: pure-Swift runtime traps (force-unwrapped `nil`, out-of-bounds, `fatalError`, failed `precondition`) surface as a bare `SIGTRAP`/`SIGILL` with no Swift-level error detail, and system frames aren't symbolicated. Since a lot of real-world Swift crashes are exactly these traps, PostHog alone will under-report their root cause. This is the main thing you lost by consolidating off Sentry.

You don't need to reverse that decision. The pragmatic path: ship PostHog + dSYM upload now, add **MetricKit** (`MXDiagnosticPayload`) as a near-free complement — it's an OS-level, on-device, privacy-preserving feed of crash, hang, and CPU-exception diagnostics that fills exactly this gap — and only revisit a dedicated crash reporter if, after a few weeks of real traffic, your crash signal still isn't actionable.

### 5. Medium — Sparkle auto-update failures are invisible

For a self-updating app, a broken updater is a silent, compounding failure: users quietly strand on old builds and you never find out. Sparkle exposes a delegate (`SPUUpdaterDelegate`) where failed update checks and failed installs can be routed to `CrashReporting.capture(...)` as handled errors with a stage label. Right now those failures aren't captured.

### 6. Low — verify the production pipeline before GA

The connected PostHog project ("Agency", id 473237) shows **zero `$exception` issues in 90 days and none of Zerro's custom events** (`recording_started`, `generation_succeeded`, etc.) in its taxonomy. That's consistent with a pre-release app (DEBUG sends nothing), but it also means the production path has never been observed end-to-end. Two things to confirm: (a) the `phc_…` key in `Info.plist` resolves to the project you actually intend to monitor, and (b) a real Release build, when crashed on purpose, produces a *symbolicated* `$exception` you can see. Don't let launch day be the first time that path runs.

### 7. Low — minor doc drift / noise tuning

`CrashReporting.swift` and `DiagnosticsCollector.swift` comments reference a `beforeSend` hook that "drops everything when the toggle is off," but `Analytics.swift` actually enforces this via `optOut()`. Functionally correct, comment is stale — worth a one-line cleanup so the next reader isn't misled. Separately, as real traffic arrives, tune what gets `CrashReporting.capture`'d versus merely logged: expected user errors (an invalid BYOK key, a deliberately cancelled run) shouldn't land in the crash dashboard as issues, or they'll bury the real signal.

---

## Recommended target state

A professional setup for a macOS app of this maturity, keeping PostHog as the single backend:

1. **Crashes are symbolicated and attributable.** dSYM upload runs automatically in CI on every tagged release, keyed to the build number, so any crash resolves to a readable stack trace against the exact build that produced it.
2. **You're told, not asked.** New-issue and spike alerts route to Slack so regressions surface in minutes.
3. **Coverage spans the whole failure surface.** PostHog autocapture for native exceptions/signals + your handled-error call sites + MetricKit for Swift traps and hangs + Sparkle updater failures. Network/API failures are captured but de-noised so expected user errors don't pollute issues.
4. **The pipeline is verified.** A forced-crash smoke test on a Release build is part of your pre-launch checklist, and you've confirmed the key/project.
5. **Privacy and consent stay exactly as they are.** No change — the current model is the right one.

---

## Prioritized pre-launch action plan

| # | Action | Severity | Effort | Do it before launch? |
|---|--------|----------|--------|----------------------|
| 1 | Add `posthog-cli dsym upload` step to `release-app.yml` (PostHog personal API key as a CI secret) | Critical | ~Half day | **Yes — blocker** |
| 2 | Key dSYM upload to the release/build (`CURRENT_PROJECT_VERSION` + `MARKETING_VERSION`) | High | Folded into #1 | **Yes** |
| 3 | Configure PostHog error-tracking alerts (new issue + spike) → Slack | High | ~1–2 hrs | **Yes** |
| 4 | Forced-crash smoke test on a Release build; confirm symbolicated `$exception` in the intended project | Low (but gating) | ~1 hr | **Yes** |
| 5 | Capture Sparkle update failures via `SPUUpdaterDelegate` → `CrashReporting.capture` | Medium | ~Half day | Nice to have |
| 6 | Add MetricKit (`MXMetricManager` subscriber) for Swift traps, hangs, CPU diagnostics | Medium | ~1 day | Post-launch OK |
| 7 | Fix stale `beforeSend` comments; tune capture-vs-log noise | Low | ~1 hr | Post-launch OK |

**Minimum bar to ship publicly:** items 1–4. Everything else is staged improvement.

---

## Sources

- [PostHog — iOS error tracking installation](https://posthog.com/docs/error-tracking/installation/ios)
- [PostHog — Stack traces & dSYM symbolication](https://posthog.com/docs/error-tracking/stack-traces)
- [PostHog — Capture exceptions](https://posthog.com/docs/error-tracking/capture)
- [PostHog — Releases & version tracking](https://posthog.com/docs/error-tracking/releases)
- [PostHog — Send error tracking alerts](https://posthog.com/docs/error-tracking/alerts)
- [PostHog — Monitor and search issues](https://posthog.com/docs/error-tracking/monitoring)
- [PostHog — Handling dSYM uploading within Xcode Cloud](https://posthog.com/questions/how-to-handle-dsym-uploading-within-xcode-cloud)
- [Apple — MetricKit / MXDiagnosticPayload](https://developer.apple.com/documentation/metrickit)
- Live PostHog project "Agency" (id 473237): 0 error-tracking issues in 90 days; Zerro app events absent from taxonomy (verified via MCP).
