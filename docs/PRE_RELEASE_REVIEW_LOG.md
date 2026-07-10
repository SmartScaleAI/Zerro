# Zerro — Pre-Release Review Log

Running log of every bug, improvement, and issue found during the pre-launch
codebase review, plus the fix status of each. Sections A–L were each reviewed by
Claude Code against a dedicated handoff prompt; findings are triaged here.

**Started:** 2026-06-22 · **Status:** all 7 launch-blockers fixed in code; pre-launch hardening in progress.

> ⚠️ **COMMIT THIS FILE.** It is an intentional deliverable. It was previously
> kept only as an untracked working-tree file and got wiped by a parallel
> session's `git clean`; this copy is a reconstruction (2026-06-23). Once
> committed it survives `git clean`/`git restore`. Review prompts are told not to
> modify it.

## Legend
- 🔴 launch-blocker · 🟡 post-launch / cheap pre-launch · ⚪ watch/confirm/decision · ✅ done · 🟠 partly done
- **Status:** Open · ✅ fixed (code) · 🟠 partial · Deferred · Accepted · Closed

---

## 🚦 Launch-readiness verdict

**Overall:** Zerro is fundamentally well-engineered. Money path (server + client), secret handling, Sparkle update integrity, telemetry privacy, and Dev-Mode command-execution safety were all independently verified as sound. ~115 findings; **7 launch-blockers**, all now fixed in code. Nothing architectural.

**Status (2026-06-23):** ✅ All 7 blockers fixed + reviewed; deploying to prod for a test pass. X-01 already live (generate v36 / convert v2, source-verified). Hardening phase underway (D-01 done).

### 🔴 Launch-blockers — all fixed in code
| ID | Issue | Status |
|----|-------|--------|
| X-01 | Farmable trials × unmetered `/convert`+`/dev_transcribe` × no global cap → unbounded provider spend | ✅ deployed; B-05 ops cap pending |
| A-04 | Generation slot reclaimed mid-flight (180s<480s) → cap-1 broken → concurrent overspend | ✅ code (600s derived window); Supabase deploy pending |
| G-01 | Failed Dev-Mode revert discards checkpoint → loses uncommitted work | ✅ code; app build |
| F-01 | Dev-Mode anchor crops/OCR bypass Redactor → secrets egress with redaction ON | ✅ code; app build |
| K-01 | License key leaks to PostHog on `/checkout-complete` | ✅ code (+ autocapture vector closed); Vercel pending |
| K-02 | Landing page "processes locally / never leaves your Mac" false on Managed/Trial | ✅ copy rewritten; owner sign-off + Vercel pending |
| A-01 | `LS_VARIANT_YEARLY` misconfig → yearly subs starved | 🟠 fail-loud validation added (code); manual verify + deploy pending |

### Remaining before launch
**Deploys:** Supabase `generate`+`convert` (A-04) + `lemonsqueezy-webhook` (A-01) + D-01 migration (`db push`) · app build (G-01/F-01) · Vercel (K-01/K-02).
**Ops/manual:** B-05 provider budget caps · A-01 yearly-variant verify + test purchase · K-02 wording sign-off · L-09 EdDSA key-pair verify · Apple Developer Program License Agreement acceptance (blocking the release build at notarization).

### Pre-launch hardening list (🟡, cheap) — order
1. ✅ **D-01** revoke anon cron RPC — **deployed + verified 2026-06-23** (advisor 0028/0029 cleared; anon/authenticated can't exec; postgres/cron unaffected)
2. ✅ **C-10**(+**C-12**) force RLS + `service_role` grant on `affiliate_referrals` — **deployed + verified** (relforcerowsecurity=true; service_role INSERT=true)
3. ✅ **E-01** checkout deeplink auto-activation (prefill+confirm; replace-confirm gate; analytics gated) — app build
4. ✅ **H-05 / H-08** in-app privacy/redaction copy (onboarding + Settings; + paywall sweep) — pending owner wording sign-off; app build
5. ✅ **E-02 + K-08** reconcile credits→30 + refresh `llms.txt` (decision: 30; secret already 30) — applied + verified (stale values gone, new facts present); Vercel + app-build deploy pending
6. ✅ **K-03** remove dead `/auth` page (page + layout + 3 auth-only UI components + robots ref; build clean, zero dangling links) — Vercel deploy pending
7. ✅ **K-04** finish security headers — HSTS + X-Content-Type-Options + X-Frame-Options + report-only CSP added (Referrer-Policy from K-01 preserved); Vercel deploy pending. Follow-up: flip CSP report-only→enforce after a clean prod console check.
8. ✅ **L-02/L-03 done** (Sparkle SHA-256 gate + posthog-cli@0.7.30 + Actions SHA-pinned, all verified); **L-01** = no clean swap exists → documented + runbook (decision: accept for launch + Option A post-launch)
9. ⏳ **L-09** verify EdDSA key-pair (manual/owner) — public key confirmed structurally valid (32-byte Ed25519); match-to-CI-private-key still to be verified via a staging "Check for Updates" (or `generate_keys -p` vs Info.plist `SUPublicEDKey`)
Plus: deploy the `affiliate` edge function if used (currently undeployed).

### Decisions to make
H-a11y accessibility scope (H-01–H-04, H-12) · A-18 paused-subscription policy · G-03/G-04 Dev-Mode internal docs + restore-gate-vs-accept · F-04 redaction floor for third-party path.

### Post-launch backlog
X-02 (proper Dev-Mode combined billing, deferred — client+server shared key) · B-04 client (Swift BYOK output caps) · D-02/D-03/D-05 advisor hardening · the test-coverage + perf + code-quality 🟡 tail.

---

## Master findings (by section, with current status)

### A — Payments & billing backend ✅ reviewed
- **A-01** Payments · 🟠 fixed-in-code — `LS_VARIANT_YEARLY` empty/wrong → yearly subs labeled monthly → excluded from yearly-refresh cron → starved. `validateYearlyVariantConfig` + fail-loud `guardYearlyConfig` (500 on subscription_created/_updated, alarm). Manual: verify prod variant value + live variant + test purchase → `billing_interval='yearly'`. Deploy pending. **Config VERIFIED CORRECT 2026-06-23** (digest match: `LS_VARIANT_YEARLY`=`1774512`, `LS_VARIANT_MANAGED`=`1774511,1774512` → yearly ⊆ managed; validation will pass, no `config_invalid`). **Deployed 2026-06-23** (lemonsqueezy-webhook v36). Remaining: confirm the LS yearly variant is published/purchasable + optional end-to-end test purchase.
- **A-02** Reliability · 🟡 — billing test suite not run in CI. Add PR/main workflow (deno test + SQL tests). Reinforced by L-04/L-05.
- **A-03** Security · 🟡 — unsigned `X-Event-Name` header trusted over signed `meta.event_name`. Derive from signed body.
- **A-04** Cost/Reliability · ✅ fixed-in-code — slot stale-window 180s<480s hold. `slotStaleSeconds(n)` derives 600s (generate) / 360s (convert) from `PROVIDER_TIMEOUT_MS`; all 3 slot paths. Deploy pending.
- **A-05** Cost · ⚪ accepted — overspend = one max-cost gen, bounded only while cap-1 holds (restored by A-04). ~$3–5 on GPT-5.5.
- **A-06** Security · 🟡 — `custom_data.trial_grant_id` linked without buyer-email match (confirmed C-06). Match grant email to buyer.
- **A-07** Reliability · 🟡 — `subscription_created` w/ null `order_id` doesn't adopt pending license key. Fails closed.
- **A-09** Reliability · 🟡 — idempotency composite key trusts client `data.id`/`updated_at`; stale comment.
- **A-10** Code quality · 🟡 — dead 1-arg `consume_credit`/`consume_trial_credit` overloads still callable.
- **A-11** Reliability · ⚪ accepted — `single_managed_tier` deploy-ordering window (LS redelivers 500s).
- **A-12** Code quality · 🟡 — `entitlement` accepts POST + reads no body. Restrict to GET.
- **A-13** Security · ⚪ accepted — JWT `iat` signed but not validated; replay bounded by short exp.
- **A-14** Reliability · 🟡 — `webhook_events`/`rate_limits` grow without cleanup; add pg_cron sweep.
- **A-15** Security · 🟡 — rate limiter fails open + fixed-window ~2× boundary burst; alert + sliding window.
- **A-16** Security · ⚪ accepted — wildcard CORS (no credentials/cookies). Comment if cookie auth ever added.
- **A-17** Code quality · 🟡 — test gaps (overspend concurrency, multi-pack FIFO, siblings NULL, alg-confusion).
- **A-18** Payments · ⚪ confirm (decision) — paused LS subs map to `active`; no `subscription_paused` handler → paused user keeps spending current-period credits. Bounded; decide policy.
- *(A-08 mutable search_path → merged into D-02.)*

### B — Generation proxy (the money path) ✅ reviewed
- **B-01** Cost · ✅ fixed via X-01 — `convert` trial-metered + cheapest-model pin. Subscription path still free by design.
- **B-03** Cost · ✅ fixed — Whisper burn: `MAX_AUDIO_BYTES` 12MB→2MB (pre-Whisper enforce); trial dev-transcribe reverted to free ("eat it"). Deployed. Aggregate ceiling = B-05.
- **B-04** Cost · 🟠 — OpenAI/Gemini server output caps added (16384). **Residual:** Swift BYOK adapters still uncapped (post-launch).
- **B-05** Cost · 🔴 (X-01 safety net) — no global/org spend cap. Set provider-console daily budget caps + alerts (ops). Now load-bearing (transcription free + farmable trials).
- **B-06** Cost · 🟡 — missing-usage undercharge: adapters coalesce usage to `?? 0` so fallbackCredits never fires. Report null when absent.
- **B-07** Payments/UX · 🟡 — unkeyed retry / 1-credit floor favor the house. **Section E confirmed** the shipping client sets a stable per-recording Idempotency-Key reused across retries → no double-charge in practice. Surface "1-credit minimum" + add key-stability test (E-10).
- **B-08** Security · ⚪ accepted — prompt injection via untrusted transcript/OCR steers output only (no cross-tenant / no system-prompt leak).
- **B-09** Code quality · ✅ closed by A-04 — slot-reclaim test gap (new `slot_table_fake` honors `staleSeconds`).

### C — Trial, affiliate & anti-abuse ✅ reviewed
- **C-01** Abuse/Cost · 🔴 (via X-01) — trial anti-farming soft (spoofable device hash + catch-all-domain email cap + rotatable/fail-open per-IP). Real fix = endpoint metering (shipped, X-01) + B-05. Device binding confirmed ON in prod.
- **C-04** Abuse · 🟡 — `feedback` unauth + unrate-limited Slack relay; mrkdwn injection (`<!channel>` / link); spoofable email. Sanitize + throttle.
- **C-05** Privacy/Abuse · 🟡 — `trial-start` status oracle + bounded email-bomb. Uniform `code_sent`; per-email send sub-limit.
- **C-07** Abuse/Reliability · 🟡 — trial rate limiter fails open on limiter error. Fail-closed per-IP; alert.
- **C-08** Abuse/Cost · 🟡 — affiliate self-referral + unauth insert amplifier. Confirm LS clawback; throttle/upsert-dedup.
- **C-09** Code quality · 🟡 — `incrementCodeAttempts` non-atomic read-modify-write (moot under 8/hr).
- **C-10** Reliability/Security · ✅ fixed-in-code — `affiliate_referrals` not FORCED → migration `20260623130000` adds `FORCE ROW LEVEL SECURITY` (prune cron via `postgres` + write path via `service_role` both bypass via BYPASSRLS — verified live, rolled-back). Deploy pending. Clears the D-04 exception.
- **C-12** Reliability · ✅ fixed-in-code (discovered during C-10) — `affiliate_referrals` was **missing the `service_role` DML grant**: its creating migration revoked anon/authenticated but never granted DML, and the project default ACL gives `service_role` only `Dxtm` (no `arwd`). The affiliate Edge Function would fail **"permission denied" on first use** (BYPASSRLS waives RLS, not table privileges). Grant added in the same migration; ACL now matches `idempotency_cache`. **Must ship before/with deploying the affiliate function.**
- **C-11** Code quality · 🟡 — test gaps (feedback, device-spoof, fail-open, affiliate window, refresh 401).
- *(C-02/C-03 → merged into D-01; C-06 → A-06.)*

### D — Database: schema, RLS, migrations & advisors ✅ consolidated
- **D-01** Security · ✅ fixed-in-code — anon-executable SECURITY DEFINER (`refresh_agent_models_cron`, `rls_auto_enable`). Migration `20260623120000_revoke_anon_definer_function_execute.sql` REVOKEs PUBLIC/anon/authenticated (cron owner unaffected; `rls_auto_enable` guarded by `to_regprocedure` for replay-safety). Deploy via `db push`; re-run advisor (lints 0028/0029 clear).
- **D-02** Security · 🟡 — 11 functions mutable `search_path`. Not exploitable (INVOKER + service-role + schema-qualified). Follow-up migration `set search_path=''`.
- **D-03** Security · ✅ accepted / won't-fix (2026-07-08) — `pg_net` in public schema. Live introspection: the extension's `extnamespace` is `public` (what the `extension_in_public` advisor keys on), but pg_net is **non-relocatable** (`ALTER EXTENSION … SET SCHEMA` errors, control-file schema is null) and its actual objects (`net.http_post`, `net.http_request_queue`, …) already live in the **`net`** schema — nothing exploitable sits in `public`, so the lint is cosmetic. The only way to clear it is `drop extension pg_net; create extension … with schema extensions`, i.e. dropping/recreating Supabase-managed infra on the prod billing DB; baked into a migration it would re-run on every fresh DB + preview branch. Disproportionate to a cosmetic WARN → accepted as low risk. Revisit only if pg_net becomes relocatable or a real public-schema object appears. If ever desired, clear it once via a controlled dashboard step on staging→prod, verifying the daily `refresh-agent-models` cron's `net.http_post` still fires — NOT via a repo migration.
- **D-04** Security · ✅ accepted — RLS-enabled-no-policy: live shows 13/14 FORCED + service-role-only (auto-forced via `rls_auto_enable` event trigger). Exception `affiliate_referrals` = C-10.
- **D-05** Performance · 🟡 deferred (rechecked 2026-07) — 4 unused indexes; live recheck found every public table still near-zero scale (0–143 rows), where `idx_scan` is not meaningful (tiny tables seq-scan regardless). NO index dropped — retained for scale; re-evaluate once production tables carry real row counts.
- *Consolidation: migration sweep clean (no unscoped destructive ops, 47 idempotency guards); 3 pg_cron jobs healthy; `rls_auto_enable` search_path already pinned (`pg_catalog`) — C-03 residual = commit its body to a migration to end drift.*

### E — Desktop billing & entitlement (client) ✅ reviewed
**Verdict:** No client path spends provider money without server-validated entitlement; no secret leaks. BYOK direct-to-provider; managed body carries only a bearer token; secrets in Keychain.
- **E-01** Security · ✅ fixed-in-code — deeplink no longer auto-activates: prefills key + explicit Activate; `LicenseService.activate` adds a replace-confirm gate BEFORE any POST/Keychain write (covers deeplink + manual paste; decline leaves license intact); purchase analytics gated on a real user-initiated outcome; parse hardening intact. Full suite green (673). Ships in app build.
- **E-02** Payments/UX · ✅ fixed (decision: 30) — **live secret confirmed already 30** (digest = sha256("30"); the grant I first saw at 40 was a stale pre-change test row — my earlier "live=40" read was wrong). Web copy + JSON-LD + FAQ (×2 incl. line 41) → 30; `site-config.ts:26` comment + `EntitlementStore.swift:924` fallback → 30. App reads server value dynamically. Vercel deploy pending. (Optional: clear stale 40-limit test grants.)
- **E-03** Security · 🟡 — Keychain `AfterFirstUnlock` (not `…ThisDeviceOnly`). Confirmed justified; only trial slots merit ThisDeviceOnly.
- **E-04** Reliability · ✅ fixed-in-code (2026-07-10, phase-5-billing) — crash-restored Dev-Mode paid-block resumed via the non-dev path. `PendingPaidGeneration` now persists optional Dev context (project path / agent id / agent model); both restore paths reapply it so the resume keeps the dev prompt + dispatch. Old markers decode nil → non-dev, unchanged. App build.
- **E-05** Payments/UX · ✅ addressed-in-docs (2026-07-10, phase-5-billing) — hardcoded paywall price literals can drift from LS. Sync step added to DEPLOY-RUNBOOK §5 (launch action 6) + `KEEP IN SYNC` comment at the `Price` literals. Display-only; LS stays the charge truth.
- **E-06** Reliability · ✅ fixed-in-code (2026-07-10, phase-5-billing) — BYOK/Managed paywall CTAs now disable when their checkout URL is unresolved (mirrors the top-up gate); placeholder log kept as belt-and-suspenders. App build.
- **E-07** UX · ✅ accepted (2026-07-10) — trial credit line not network-refreshed on activation. Display-only staleness, bounded: the server enforces the trial cap on every generation regardless of what the client shows, and multi-device trial drift is a non-issue at this stage. No code change; revisit only if multi-device trial use becomes real.
- **E-08** Privacy · 🟡 — non-checkout `zerro://` URLs logged at `.public` + flow into diagnostics blob (confirmed I). Log host/scheme only.
- **E-09** Code quality · ✅ fixed-in-code (2026-07-10, phase-5-billing) — `displayedCreditsRemaining` now clamps non-negative at the source (`max(0, …)`); the render-side "Out of Credits" handling is unchanged. App build.
- **E-10** Code quality · 🟡 — money-path invariants under-tested (idempotency-key stability, fail-safe dispatch).
- **E-11** Security · ✅ resolved (Section L) — Release build defines no `DEBUG`; dev hatches compiled out.

### F — Capture & processing pipeline ✅ reviewed
**Verdict:** No catastrophic leak/data-loss/crash; perf healthy. Privacy guarantee is best-effort (OCR + fixed patterns); audio uploaded unredacted.
- **F-01** Privacy · ✅ fixed-in-code — Dev-Mode anchor crops + OCR hints now masked in lock-step (both managed + BYOK; fail-safe-ON default). App build.
- **F-02** Privacy · ⚪ confirm — best-effort redaction scope / audio-not-redacted = copy/consent. Fixes: H-05 (onboarding), H-08 (settings), K-02 (landing, ✅).
- **F-03** Privacy · 🟡 — OCR-fail/no-text frame uploads raw; telemeter OCR-fail rate.
- **F-04** Privacy · ✅ fixed-in-code (Phase 3, decision: floor) — redaction FORCED ON whenever generation routes through Zerro's servers (`AppState.effectiveRedactSecrets`: toggle OR `routesThroughManagedProxy`, nil → force on; evaluated at `startRecording`, superset-of-dispatch on purpose); the toggle only loosens BYOK. Settings toggle gains an "enforced on your plan" caption for Managed/trial. App build.
- **F-05** Functionality/Cost · ✅ fixed-in-code (Phase 3) — anchor frames capped at `ProcessingConfig.maxAnchorFrames` (8; worst-case total 28+8=36), highest-confidence kept with original `refIndex` preserved, cap applied BEFORE the expensive per-reference work. App build.
- **F-06** Functionality · ✅ fixed-in-code (Phase 3) — no-candidates fallback now honors `maxKeyframes` (28), widening its stride so the kept frames still span the recording; min-length guard unchanged. App build.
- **F-07** Reliability/Cost · ✅ fixed-in-code (Phase 3) — client now mirrors the server's `/generate` input fuse (2 MB audio / 60 MB raw body, `ManagedBackend.maxAudioUploadBytes`/`.maxPayloadUploadBytes`, same strictly-greater-than boundary) across all three encode paths; over-cap fails LOCALLY with the distinct `.recordingTooLarge` pill before any upload or token mint. App build.
- **F-08** Performance · ✅ fixed-in-code (Phase 3) — per-iteration `autoreleasepool` around each anchor's crop/OCR/redact/encode; the native frame is scoped per iteration (the decode itself is an `await`, outside the pool). Memory-lifetime only. App build.
- **F-09** Reliability/Privacy · 🟡 — `abandon()` releases SCStream without `stopCapture()` → indicator clear non-deterministic on sleep→wake.
- **F-10** Functionality · ✅ fixed-in-code (Phase 3) — hint now gated on the anchor's client confidence vs `devLowConfidenceThreshold` (0.45, the review card's amber bar): below → hedged "MAY have been referring near here … best guess"; at/above → byte-identical definitive hint. App build.
- **F-11** Reliability · 🟡 — auto-stop finalize-window revocation discards a completed 3-min recording (data loss). Gate on `state==.recording`.
- **F-12** Privacy/Reliability · 🟡 — per-recording sidecars orphaned in temp until next launch sweep.
- **F-13** Performance · ✅ accepted (Phase 3) — `encodeBody` holds whole payload + base64, bounded ~20–30 MB for a ≤3-min tool.
- **F-14** Performance · ✅ accepted (Phase 3) — `AudioActivity.hasSpeech` decodes the whole clip, fine ≤3 min.
- **F-15** Performance/Reliability · ✅ split (Phase 3) — nil free-space read now REFUSES to record (fixed-in-code, `AppState.shouldRefuseRecordingForFreeSpace` — never "nil == OK"); the 30 Hz CursorTracker-on-MainActor poll accepted as info.
- **F-16** Code quality · ✅ split (Phase 3) — stale paid-block working dir now reclaimed: the sweep spares only a FRESH `pending-paid.json` (marker `createdAt` vs the same 7-day `maxAge` the restore uses; garbage marker = stale) (fixed-in-code); position-based anchor pairing accepted as info.
- *Phase 3 accepts (F-13, F-14, F-15/F-16 info sub-parts): accepted as bounded/info at current scale (≤3-min recordings, bounded frame counts); revisit if recordings get longer.*
- **F-17** Code quality · 🟡 — test gaps (OCR-fail redaction, cap boundaries, teardown).

### G — Dev Mode / agent runner ✅ reviewed
**Verdict:** No arbitrary command execution (argv-array spawn, no shell). Apple-Events auto-detect properly gated. Checkpoint/revert safe on happy path.
- **G-01** Data-loss · ✅ fixed-in-code — failed revert (cancel/recovery) no longer discards snapshot/marker; discard gated on verified `isRestored`; scoped `git clean` (agent-added only); atomic restore; pre-flight abort. App build.
- **G-02** Reliability/Data-safety · 🟡 do pre-launch — orphaned agent after quit/cancel (async kill + no process group). Sync SIGTERM + process-group kill (mirror `ManagedDevServer`).
- **G-03** Functionality · ⚪ (docs + decision) — low-confidence gate removed. Website copy clean (K refuted); residual = internal docs + restore-gate decision.
- **G-04** Functionality · ⚪ — review-before-apply not default (auto-apply). Safe-by-construction once G-01 fixed; align internal docs.
- **G-05** Security · 🟡 — no `--` end-of-options before positional prompt (arg injection, not command injection).
- **G-06** Reliability/Security · 🟡 — auto-matched folder path not validated; `0.0.0.0` admitted as loopback.
- **G-07** Reliability · 🟡 — recovery-marker hygiene (resumable revert; surface failed marker write).
- **G-08** Reliability/Functionality · 🟡 — hung-agent stall notification computed but not wired to UI.
- **G-09** Code quality · 🟡 — test gaps (command-construction safety, teardown PID dead, submodules).
- *Env open-question CLOSED (Section I): Dev-agent child inherits only modified PATH; no secret injected.*

### H — UI surfaces, onboarding, permissions & accessibility ✅ reviewed
**Verdict:** Permission/TCC handling is ship-ready (fails closed). Accessibility is the headline gap.
- **H-01** Accessibility · 🟡 — Pill error/recovery controls not VoiceOver/keyboard-reachable.
- **H-02** Accessibility · 🟡 — AreaSelector toolbar mouse-only, invisible to AT.
- **H-03** Accessibility · 🟡 — transient pill state not announced to AT.
- **H-04** Accessibility · 🟡 — no Reduce Motion honoring.
- **H-05** Privacy · ✅ fixed-in-code (copy; pending sign-off) — onboarding consent + screen-recording steps now disclose frames+audio→third-party AI on Managed/Trial + best-effort redaction (BYOK direct). App build.
- **H-06** Reliability · 🟡 — re-consent vs permission-revocation collision → re-onboarding loop.
- **H-07** UX · 🟡 — Pill positions on NSScreen.main only (multi-display); no reposition on display change.
- **H-08** Privacy · ✅ fixed-in-code (copy; pending sign-off) — Settings "Redact secrets" toggle reworded to best-effort + "never redacts spoken audio". Also swept 2 in-app paywall overstatements (where-recordings-go note + BYOK card). App build.
- **H-09** Reliability · 🟡 — stale screen-recording-granted cache can bypass record-start gate.
- **H-10** UX · 🟡 — no Back navigation in onboarding (dead `goBack()`).
- **H-11** UX · 🟡 — non-retryable error pill labeled "Retry" but reopens area selector.
- **H-12** Accessibility · 🟡 — contrast (vfTextTertiary), icon-only labels, placeholder-only fields, no Dynamic Type.
- **H-13** UX · 🟡 — mic picker doesn't refresh on hot-plug.
- **H-14** Code quality · 🟡 — test gaps (permission-denied gate, onboarding transitions, reduce-motion).
- *a11y cluster (H-01–H-04, H-12) = ⚪ decision: accept-as-known-limitation vs fast-follow.*

### I — Lifecycle, Sparkle updates, observability & Keychain ✅ reviewed
**Verdict:** Update integrity + telemetry privacy ship-ready (EdDSA enforced, no downgrade, analytics anonymous/consent-gated/DEBUG-off, dSYM PII-free).
- **I-01** Privacy · 🟡 do pre-launch — `RecentPromptStore` writes prompt + AI-result text to plaintext JSON (no file protection, in backups, world-readable). 0600 + exclude-from-backup + clear-history.
- **I-02** Reliability · 🟡 do pre-launch — auto-update relaunch not idle-gated (interrupts recording / Dev run). Busy/idle guard.
- **I-03** Privacy · 🟡 — anonymous lifecycle/onboarding telemetry sent before consent toggle acted on. Disclosure confirmed honest (K); defer start() or disclose.
- **I-04** Privacy · 🟡 — MetricKit `termination_reason` can embed a username path; strip.
- **I-05** Code quality · 🟡 — PostHog sends `error.localizedDescription`; latent egress if a content-bearing LocalizedError is added.
- **I-06** Code quality · 🟡 — `KeychainStore.write()/delete()` discard OSStatus (silent failure).
- **I-07** Privacy/Reliability · 🟡 (info) — diagnostics pastes mic name; terminate hook ties G-02. (Closed the G env-question.)
- **I-08** Code quality · 🟡 — privacy-contract tests (opt-out halts, DEBUG no-send, scrubber).

### J — Provider adapters & BYOK ✅ reviewed
**Verdict:** BYOK key handling airtight; normal-path prompt + model/cost registry byte-locked against drift.
- **J-01** Functionality · 🟡 do pre-launch — Dev-Mode prompt (`PROMPT_DEV`) not byte-mirrored client↔server → BYOK Dev output can drift. Shared file + byte-identity test.
- **J-02** Functionality · 🟡 do pre-launch — OpenAI BYOK adapter doesn't map 403→auth (dead-end "service unavailable"). One-line `case 401, 403:`.
- **J-03** Functionality · 🟡 — provider quota 429 messaged as transient + wasted retry.
- **J-04** Reliability · 🟡 — uncapped `Retry-After` sleep can wedge the pill (clamp). Ties H pill-stall + I-02.
- **J-05** Reliability · 🟡 — fence-token scrubber deletes trailing real text on malformed open token.
- **J-06** Code quality · 🟡 — Swift BYOK adapter response/error/truncation paths untested.
- **J-07** Code quality · 🟡 (info) — interleave wire-rendering triplicated; no cross-language golden fixture; stale `.fuse_hidden*`.
- **J-08** UX · ⚪ confirm — BYOK needs an OpenAI key for transcription regardless of chat provider; confirm communicated.

### K — Web app, checkout & privacy-copy ✅ reviewed
**Verdict:** Privacy policy strong; two launch-blockers fixed (K-01/K-02). No service-role secret to client; no exploitable XSS.
- **K-00** Security · ✅ resolved — `.env.local` gitignore concern refuted (nested `apps/web/.gitignore` ignores `.env*`).
- **K-01** Privacy/Security · ✅ fixed-in-code — license-key→PostHog leak: clean-URL + `before_send` scrub (incl. `$initial_*` + autocapture `$elements_chain`) + Referrer-Policy. Vercel pending.
- **K-02** Privacy/Legal · ✅ copy rewritten — landing locality claims scoped to BYOK + privacy caveat. Owner sign-off + Vercel pending. **Follow-up — fixed during H-05/H-08:** the BYOK "never leaves your Mac" overstatement spanned ~6 lines (`built-right.tsx:29`, `pricing.tsx:130/139/424`, `structured-data.tsx:95` JSON-LD, `faq-data.ts:51` "Is my data private?"). The original K-02 audit wrongly accepted these as "scoped to BYOK" — but BYOK recordings DO go to the provider, so they were inaccurate. All now use the precise "straight to your provider / never through Zerro's servers" wording; faq-data expanded to match the privacy policy (best-effort redaction + audio-not-redacted). Verified zero remaining locality-overstatement strings site-wide. `privacy/page.tsx:139` left as-is (hardware-ID line — confirm it reflects a salted hash is sent). Site now internally consistent + matches the policy.
- **K-03** Security/UX · ✅ fixed — dead `/auth` page removed (page + layout + 3 auth-only UI components + `robots.ts` ref); `/sign-up` & `/forgot-password` were 404 scaffolding only-linked from `/auth`, now gone; build clean (12/12 pages), grep proves zero dangling links. Vercel deploy pending.
- **K-04** Security · ✅ fixed — added HSTS (`max-age=63072000; includeSubDomains`, no preload), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and a usage-derived **report-only** CSP (`default-src 'self'`; PostHog same-origin `/ingest` + Supabase beacon in connect-src; posthog gzip worker `blob:`; `frame-ancestors 'none'`). Residuals (acceptable): `script-src`/`style-src 'unsafe-inline'` (Next.js App Router hydration + next/font) — no `unsafe-eval`. Verified curl + 0 console violations on home/pricing/checkout-complete; `/Zerro.dmg` redirect intact. **Follow-ups:** flip report-only→enforcing after a clean prod check (PostHog only fires on the live domain); HSTS `preload` optional. Vercel deploy pending.
- **K-05** Security · 🟡 — affiliate beacon sends unvalidated/unbounded `aff`. Clamp.
- **K-06** Code quality · 🟡 (info) — dep advisories not runtime-reachable (static site).
- **K-07** Code quality · 🟡 (info) — `/Zerro.dmg` redirect comment misstates (307 to Supabase, not 302 GitHub).
- **K-08** Payments/Code quality · ✅ fixed — `llms.txt`/`llms-full.txt` refreshed to live facts (verified against pricing.tsx): trial 30, BYOK $69, Managed live $15/mo·$144/yr, 300 credits/mo, +Anthropic, +top-ups (Boost 200/$10, Power 500/$22). Also corrected two **false claims** found in the files: "all future updates" → "1 year of updates"; removed a non-existent "Priority support" line. Vercel deploy pending. **Follow-up (post-launch):** llms files still position Zerro narrowly as "structured prompt for coding agents" — broaden to the full artifact range (prompt/message/snippet/document/answer) to match the site; left as a separate brand task.

### L — Build, release, signing & CI/CD ✅ reviewed
**Verdict:** Release free of DEBUG hatches (E-11 resolved). Signing/notarization/EdDSA-publish chain tamper-resistant, no CI secret leak.
- **L-01** Security · 🟠 documented (decision pending) — service-role key for the DMG Storage upload (over-privileged). **No clean least-priv swap exists** without a Supabase-side change (downloads bucket has no scoped key; `sb_secret` keys are full-access; service_role is the only writer — no RLS write policies). Kept upload working; confirmed key never logged (no `set -x`/`curl -v`; masked GitHub secret); documented inline + runbook (`README-backend.md`) with **Option A** (signed-upload-URL edge function → CI holds no Supabase key) + Option B (RLS + scoped JWT). **Decision: accept residual for launch + do Option A post-launch** (recommended) + rotate the service-role key periodically.
- **L-02** Supply-chain · ✅ fixed — Sparkle tarball now SHA-256-verified (`2.9.2`, hash dual-sourced vs GitHub's published digest) **before** `generate_appcast` gets the EdDSA key; `@posthog/cli` pinned `@0.7.30`. Real test = next release run.
- **L-03** Supply-chain · ✅ fixed — `actions/checkout`→`34e1148…` (v4.3.1) and `softprops/action-gh-release`→`3bb1273…` (v2.6.2), SHAs verified via `git ls-remote` (zero behavior change). 
- **L-04** Reliability · 🟡 — manual backend deploy, no CI gate, ordering-sensitive, no rollback (with A-02).
- **L-05** Reliability · 🟡 — deploy runbook lists 5 of 9 edge functions (drift).
- **L-06** Reliability · 🟡 — `cut-release.sh` emits `v*` tags the workflow no longer triggers on.
- **L-07** Distribution/Reliability · ✅ fixed — release-app.yml uploads each release as the permanent, immutable `downloads/Zerro-<build>.dmg` (the only URL the appcast references; a guard fails the release if any appcast item points at the mutable `Zerro.dmg`, which is now marketing-only), closing the retention gap + release-window signature race. Verified intact 2026-07-10.
- **L-08** Code quality · 🟡 — stale release docs (tags, workflow filename, two-repo topology). *(Also: the notarize step's error-handler fetches a STALE prior submission log on a submit-403, masking the real error — fix to show the real failure.)*
- **L-09** Distribution · ⏳ owner-verify — shipped `SUPublicEDKey` (`IV0J9TIWJpe/…`, confirmed 32-byte Ed25519) ↔ CI `SPARKLE_PRIVATE_KEY` must be a pair or auto-update silently breaks for all users. Verify via staging "Check for Updates" (definitive) or `generate_keys -p` vs Info.plist. Owner/manual — needs the private key + a build.

### X — Cross-cutting
- **X-01** Cost/Abuse · ✅ deployed (B-05 ops cap pending) — see launch-blockers.
- **X-02** Payments/Code quality · 🟢 post-launch (deferred) — proper Dev-Mode combined billing (deposit-and-settle via a shared client/server idempotency key; the eat-it approach shipped instead for launch).

---

## Fix-phase notes
- **Apple notarization** is currently blocking the release build with a 403 "required agreement is missing or has expired" — accept the **Apple Developer Program License Agreement** (Account Holder, developer.apple.com/account) for the team the CI API key belongs to, then re-run. Not a code issue.
- **Xcode project cleanup:** removed a stale top-level `Shortcuts` group from `project.pbxproj` that pointed to a non-existent path (the real code is under the synchronized `Zerro` folder).
