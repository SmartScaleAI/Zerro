# Zerro — Post-Launch Backlog

Deferred items from the pre-release review. Full detail for every ID is in
`PRE_RELEASE_REVIEW_LOG.md`; this is the prioritized work queue for after launch.

**Created:** 2026-06-23 · Source: pre-release review (Sections A–L).

---

## ⚠️ Tier 0 — Pre-launch candidates NOT yet done (decide before you ship)

These were individually tagged "do pre-launch" but didn't make the 9-item hardening
walkthrough. All are small. **Decide: do them before launch (a few Claude Code handoffs) or
accept as immediate post-launch.**

| ID | Item | Type | Effort |
|----|------|------|--------|
| **G-02** | Orphaned Dev-Mode agent keeps editing files after quit/cancel (async kill + no process group). Sync SIGTERM + process-group kill (mirror `ManagedDevServer`). | Reliability / data-safety | Small |
| **I-01** | `RecentPromptStore` writes prompt + AI-result text to plaintext JSON (no file protection, in backups, world-readable). Add `0600` + exclude-from-backup + a "clear history" path. | Privacy | Small |
| **I-02** | Auto-update relaunch not idle-gated — can interrupt a recording / mid-edit Dev run. Add a busy/idle guard before relaunch. | Reliability | Small |
| **J-01** | Dev-Mode prompt (`PROMPT_DEV`) not byte-mirrored client↔server → BYOK Dev output can silently drift. Shared file + byte-identity test. | Functionality | Small |
| **J-02** | OpenAI BYOK adapter doesn't map `403`→auth → "service unavailable" dead-end on a rejected key. One-line `case 401, 403:`. | Functionality | Tiny |

---

## Tier 1 — High-value (do soon after launch)

| ID | Item | Type |
|----|------|------|
| **A-02 / L-04 / L-05** | Backend deploy is fully manual: no CI test gate, no migrate→deploy script, no rollback path, and the runbook lists only 5 of 9 functions. Add a CI job (deno test + SQL tests; migrate then deploy all 9 with correct `verify_jwt`) + a rollback note. | Reliability / CI |
| **L-01 (Option A)** | Replace the service-role key in the DMG upload with a signed-upload-URL edge function (runbook in `README-backend.md`); then rotate `SUPABASE_SERVICE_ROLE_KEY`. | Security |
| **F-11** | Auto-stop finalize-window permission revocation discards a *completed* recording (data loss). Gate on `state == .recording`. | Reliability |
| **B-04 (client)** | Cap output tokens on the Swift BYOK OpenAI/Gemini adapters (server already capped). | Cost |
| **X-02** | Proper Dev-Mode combined billing (deposit-and-settle) once the client/server share one idempotency key — replaces the "eat transcription" launch approach. | Payments |
| **C-03** | Commit `rls_auto_enable` / `ensure_rls` definition into a migration (end the live-only schema drift). | DB hygiene |
| **D-02** | Pin `search_path = ''` on the ~10 legacy SECURITY INVOKER functions (advisor 0011). | DB security |
| **B-07** | Surface the "1-credit minimum" in the app UX + add the idempotency-key-stability regression test. | UX / tests |

---

## Tier 2 — Security / privacy hardening

| ID | Item |
|----|------|
| C-04 | `feedback` is an unauth, unrate-limited Slack relay (mrkdwn `<!channel>`/link injection, spoofable email) — sanitize + throttle + validate. |
| C-05 | `trial-start` status oracle + email-bomb — return uniform `code_sent`; add a per-email send sub-limit. |
| C-07 | Trial rate limiter fails open — fail closed on the per-IP key; alert on limiter errors. |
| C-08 | Affiliate self-referral + unauth insert amplifier — per-IP throttle / upsert-dedup; confirm LemonSqueezy clawback is on. |
| A-06 | `trial_grant_id` link should match buyer email before linking. |
| A-15 | Rate limiter: sliding window + alert on the fail-open path. |
| A-03 | Derive webhook event name from the signed body, not the `X-Event-Name` header. |
| A-14 | pg_cron sweep for `webhook_events` / `rate_limits` growth. |
| D-03 | Move `pg_net` out of the `public` schema. **ACCEPTED / won't-fix (2026-07-08):** non-relocatable + objects already in the `net` schema (not `public`), so the `extension_in_public` lint is cosmetic; the only fix is a risky drop/recreate of managed infra. See PRE_RELEASE_REVIEW_LOG.md. |
| E-03 | Keychain `…ThisDeviceOnly` for the trial slots specifically. |
| E-08 | Log `url.host`/scheme (not full `absoluteString`) — also flows into the diagnostics blob. |
| I-03 | Defer anonymous launch telemetry until after consent (or disclose default-on). |
| I-04 | Strip `/Users/<name>/…` from MetricKit `termination_reason` before forwarding. |
| F-03 | Telemeter OCR-fail frequency (a silent redaction-disable signal). |
| F-12 | Per-session temp sidecar cleanup (don't wait for the next launch sweep). |

---

## Tier 3 — Reliability / UX / functionality nits

| ID | Item |
|----|------|
| F-04 | Decision: enforce a redaction floor (or confirm) for the third-party Managed/Trial path. |
| F-05 / F-06 | Cap Dev-Mode anchor frames; re-apply the 28-frame ceiling to the no-candidates fallback. |
| F-07 | Client-side pre-upload payload/audio-byte cap (fail fast locally). |
| F-08 | `autoreleasepool` around the full-res decode loop (5K memory spike). |
| F-09 | `abandon()` should call `stopCapture()` so the recording indicator clears on sleep→wake. |
| F-10 | Gate the "developer pointed here" hint on a confidence threshold. |
| F-13–F-16 | encodeBody memory, AudioActivity decode, CursorTracker cadence, anchor-pairing (info-level). |
| G-05 | Add `--` end-of-options before the agent prompt (arg-injection hardening). |
| G-06 | Validate auto-matched folder exists/is a git repo; tighten loopback check (exclude `0.0.0.0`). |
| G-07 | Resumable recovery-Undo; surface a failed recovery-marker write. |
| G-08 | Wire the hung-agent stall notification to a "Cancel?" UI affordance. |
| E-04 | Persist Dev-Mode context in `PendingPaidGeneration` (crash-resume doesn't degrade to the non-dev path). |
| E-05 | Release-checklist item to update hardcoded paywall price literals on any LS change. |
| E-06 | Disable paywall CTAs when the checkout URL is unresolved. |
| E-07 | Trial-balance ping on activation (if multi-device drift matters). |
| E-09 | Clamp `displayedCreditsRemaining` (or route all rendering through `balanceLabel`). |
| H-06 | Fix the re-consent vs permission-revocation collision (returning-user loop). |
| H-07 | Position the Pill on the active recording's display (multi-monitor) + reposition on display change. |
| H-09 | Reset the stale screen-recording-granted cache on an idle revocation. |
| H-10 | Wire onboarding Back navigation (or remove dead `goBack()`). |
| H-11 | Relabel the non-retryable error pill "Record again" (not "Retry"). |
| H-13 | Refresh the mic picker on device hot-plug. |
| J-03 | Message provider-quota 429 distinctly (not a transient rate-limit retry). |
| J-04 | Clamp the `Retry-After` sleep (avoid an arbitrarily wedged pill). |
| J-05 | Anchor the fence-token scrubber regex so trailing prose survives. |
| J-08 | Communicate that BYOK needs an OpenAI key for transcription regardless of chat provider. |
| A-07 | Warn-log + drain pending license keys when `subscription_created` lacks `order_id`. |
| A-09 | Add an X-Signature discriminator to the idempotency key; fix the stale table comment. |
| A-10 | Drop the dead 1-arg `consume_credit` / `consume_trial_credit` overloads. |
| A-12 | Restrict `entitlement` to GET. |
| A-13 | Optional JWT `jti`/iat-sanity anti-replay. |
| B-06 | Report missing usage as null (not `?? 0`) so `fallbackCredits` fires. |
| C-09 | Make `incrementCodeAttempts` atomic. |
| D-05 | Re-check the 4 unused indexes before dropping. *Rechecked 2026-07 — deferred, NO drop: every public table is still near-zero scale (0–143 rows), so `idx_scan` counts aren't meaningful (Postgres seq-scans tiny tables regardless of indexes). Indexes retained for scale; re-evaluate once production tables carry real row counts.* |
| K-05 | Clamp the affiliate beacon `aff` value (length/charset). |
| K-07 | Fix the `/Zerro.dmg` redirect doc comment. |
| L-06 | `cut-release.sh` should emit `app-v*` tags (not the no-op `v*`). |
| L-07 | Versioned DMG object name (retention + no release-window signature race). |
| L-08 | Refresh stale release docs; fix the notarize step's misleading stale-log error handler. |
| `llms` | Broaden the `llms.txt`/`llms-full.txt` positioning beyond "coding agents" to the full artifact range. |

---

## Tier 4 — Test coverage (add alongside the related fix)
A-17 · C-11 · E-10 · F-17 · G-09 · H-14 · I-08 · J-06 · J-07 — the per-section test-gap items (overspend concurrency, device-spoof, money-path invariants, redaction false-negatives, command-construction safety, a11y labels, privacy-contract tests, BYOK adapter tests, cross-language golden fixtures).

---

## Decisions still open (not code, but resolve)
- **A-18** — paused-subscription policy (retain paid access vs revoke).
- **Accessibility scope** (H-01–H-04, H-12) — accept-as-known-limitation vs fast-follow.
- **G-03 / G-04** — Dev-Mode internal docs ("pauses if unsure"/review) vs restore the low-confidence gate.
- **L-01** — accept the service-role-in-CI residual for launch vs implement Option A now.
