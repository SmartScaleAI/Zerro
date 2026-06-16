# Zerro Analytics — Current State Report

Status: as-implemented audit · Scope: macOS app + getzerro.app website · Date: 2026-06-15

This documents what is **actually wired up today**, measured against the
aspirational taxonomy in `ANALYTICS-POSTHOG-PLAN.md`. Short version: the desktop
app has a clean, privacy-safe PostHog foundation with a handful of events live;
the website has **no PostHog at all** yet (only Vercel Analytics).

---

## 1. Headline status

| Surface | Analytics backend | State |
|---|---|---|
| **macOS app** | PostHog (`posthog-ios`) | Live — SDK + error tracking + 7 manual events + auto lifecycle |
| **getzerro.app** | Vercel Analytics only | **No PostHog.** Aggregate pageviews only; zero custom/funnel events |

The privacy policy (`apps/web/app/privacy/page.tsx`) is already updated and
correctly describes this split — PostHog for the app, Vercel Analytics for the
site — so disclosure is ahead of the web implementation, not behind it.

---

## 2. macOS app — what's implemented

### Foundation (solid)

The wrapper layer described in the plan exists and is well-built:

- **`Observability/Analytics.swift`** — single owner of the PostHog SDK
  lifecycle. All product events flow through `Analytics.capture(_:_:)` /
  `captureOnce(...)`.
- **`Observability/CrashReporting.swift`** — thin PostHog-backed shim for
  handled errors (migrated off Sentry). Same public API as the Sentry era.
- **`posthog-ios` SPM dependency** is in the Xcode project and resolved.
- **Keys are configured for real** in `Info.plist` (not placeholders):
  - `POSTHOG_API_KEY` (production / Release builds) — `phc_tW2Qm…`
  - `POSTHOG_API_KEY_DEBUG` (Debug builds) — `phc_BmNU…`
  - `POSTHOG_HOST` — `https://us.i.posthog.com` (US hosting)

### Privacy posture (matches the plan's intent)

- Gated by the existing **"Send Anonymous Usage Data & Crash Reports"** toggle
  (`crashReporting.isEnabled`). Off → `optOut()`, nothing leaves the machine; flips live, no restart.
- `personProfiles = .identifiedOnly` — anonymous installs never create a person
  profile. The app **never calls `identify`**, so every user stays anonymous
  (device-scoped PostHog anonymous id). No email, hashed or otherwise, is sent.
- Strict no-content rule enforced at the chokepoint: properties limited to
  enums, counts, durations, booleans, model ids. Handled-error context runs
  through an allowlist (`errorCode`, `modelName`, `networkReachable`,
  `frameCount`, `durationSecondsBucket`) with secret-shaped / overlong values dropped.
- Debug and Release send to **separate PostHog environments** (per-build key +
  an `environment` super-property as belt-and-suspenders).

### Events live today

**Auto lifecycle** (`captureApplicationLifecycleEvents = true`):
Application Installed / Opened / Updated — fired by the SDK, no code.

**Error tracking:**

- Native crash autocapture (`errorTrackingConfig.autoCapture`) — Mach
  exceptions, POSIX signals, uncaught NSExceptions, surfaced as `$exception`.
- Handled errors via `CrashReporting.capture(...)` with `label`, `stage`,
  `diagnostic_id` (+ scrubbed context). Currently called from the generation
  failure paths in `AppState.swift`.

**Manual product events (7):**

| Event | Fires from | Properties sent today |
|---|---|---|
| `onboarding_started` | `OnboardingState` (welcome step, once per install) | — |
| `onboarding_completed` | `OnboardingState.completeOnboarding()` | — |
| `recording_started` | `AppState` on `.recording` | `model` |
| `generation_succeeded` | `AppState` (managed + BYOK paths) | `route`, `model`, `artifact_type` |
| `generation_failed` | `AppState` (managed + BYOK paths) | `route`, `reason` |
| `artifact_copied` | `ArtifactCardView.handleCopy()` | `artifact_type` |
| `paywall_shown` | `PaywallView.onAppear` | — |

**Super properties registered on every event:** `app_version`, `build_channel`
(release/debug), `environment` (production/development). PostHog also auto-adds
standard device/OS properties (`$os_version`, etc.).

---

## 3. Website — what's implemented

`apps/web` has **no PostHog**. The only analytics is `@vercel/analytics`
(`<Analytics />` in `app/layout.tsx`), which gives aggregate, cookie-less
pageviews. There is **no PostHog JS snippet**, no `download_clicked` tracking,
and none of the funnel/conversion events from §3 of the plan. The string
"PostHog" appears in the web app only in the privacy policy copy.

The download CTA — the single most important acquisition signal — is currently
**untracked** (it lives in `navbar`, `hero`, `pricing`, `final-cta`, all
pointing at `DOWNLOAD_URL`).

---

## 4. Gap vs. the plan (`ANALYTICS-POSTHOG-PLAN.md`)

The plan defines ~70 events across both surfaces. Implemented coverage:

### Website (0 of 8) — entirely unbuilt
Missing: PostHog itself, plus `download_clicked`, `pricing_viewed`,
`pricing_plan_cta_clicked`, `faq_item_opened`, `comparison_viewed`,
`auth_signup_started`, `auth_signup_submitted`, `external_link_clicked`.

### App lifecycle — partial via auto-capture
SDK auto events cover the spirit of `app_first_launched` / `app_launched` /
`app_updated`. **Missing:** Sparkle `update_offered` / `update_installed`.

### Onboarding (2 of 7)
✓ `onboarding_started`, `onboarding_completed`.
**Missing:** `onboarding_step_viewed`, `onboarding_step_completed`,
`onboarding_email_submitted`, `onboarding_email_verified`,
`onboarding_abandoned`. (Note: `onboarding_completed` is sent with no
`duration_seconds`.)

### Permissions (0 of 4) — none
Missing all of `permission_requested` / `_granted` / `_denied` / `_revoked`.
This is the screen-recording-grant SIGKILL funnel the plan flagged as a sharp edge.

### Recording (1 of 10)
✓ `recording_started`, but only with `model` — **missing** `trigger`,
`display_count`, `entitlement_state`. **Missing** all of `recording_stopped`,
`recording_auto_stopped`, `recording_wrapping_up`, `recording_cancelled`,
`recording_too_short`, `recording_preflight_blocked`, and the recovery trio.

### Processing (0 of 4) — none
Missing `processing_started` / `_completed` / `_failed` / `secrets_redacted`.
No visibility into the local pipeline (frame count, audio seconds, redactions).

### Generation (2 of 4) — best-covered area
✓ `generation_succeeded` (`route`, `model`, `artifact_type`),
✓ `generation_failed` (`route`, `reason`).
**Missing events:** `generation_started`, `generation_retried`.
**Missing properties** vs plan: `provider`, `credit_price`, `latency_ms`,
`credits_charged`, `is_converted`, `is_retryable`.

### Artifact (1 of 8)
✓ `artifact_copied` (`artifact_type`; **missing** `source`).
**Missing:** `artifact_produced`, conversion events, `artifact_dismissed`
(and its `copied_first` success/abandon signal), `artifact_collapsed`,
`history_opened`, `history_item_copied`.

### Billing (1 of 10)
✓ `paywall_shown` (**missing** its `trigger` property).
**Missing:** `trial_started`, `trial_exhausted`, `paywall_plan_selected`,
`checkout_opened`, `subscription_activated` (the plan recommends firing this
server-side from the LemonSqueezy webhook), `subscription_lapsed`,
`byok_key_added/removed`, `out_of_credits_hit`.

### Settings (0 of 7) — none
Missing all toggle/config events including `analytics_opt_out_toggled`.

### Super properties — partial
Implemented: `app_version`, `build_channel`, `environment`.
**Missing from the plan's set:** `entitlement_state`, `selected_model`,
`credits_remaining_bucket` as global super-properties (`model` rides on
individual events instead, `os_version` comes from PostHog auto-props).

---

## 5. Bottom line / what's missing to "stand up" analytics

**Where you stand:** the hard part — a privacy-safe, single-chokepoint PostHog
foundation with a working opt-out and error tracking — is done on the desktop
app, with real keys and prod/dev separation. Roughly **7 manual events + auto
lifecycle + crash/error capture** are flowing.

**Biggest gaps, in priority order:**

1. **Website PostHog is entirely missing.** No top-of-funnel. Adding the JS
   snippet + `download_clicked` is the cheapest, highest-leverage next step
   (plan §6 lists it first).
2. **No activation funnel can be measured end-to-end.** The plan's north-star
   funnel (onboarding → recording → processing → generation → copy) is broken
   by missing **permissions**, **processing**, and most **recording** events.
3. **Monetization is nearly dark** — only `paywall_shown` (without `trigger`).
   No checkout, subscription, trial, or BYOK events; `subscription_activated`
   should come from the LemonSqueezy webhook server-side.
4. **Thin properties on the events that do exist** — e.g. `recording_started`
   lacks `trigger`/`entitlement_state`; generation events lack `latency_ms`/
   `credits_charged`; `paywall_shown` lacks `trigger`.
5. **Missing global super-properties** (`entitlement_state`,
   `credits_remaining_bucket`) that would let you segment every event by user
   monetization state.
