# Zerro — PostHog Analytics Tracking Plan

Status: proposal · Scope: macOS app + getzerro.app website · Last updated: 2026-06-13

This is the event taxonomy to implement for product analytics in PostHog. It
covers the desktop app and the marketing site, the properties each event should
carry, where in the code each should fire, the funnels they unlock, and a
privacy/identity section that matters more than usual here because Zerro's whole
posture is "your content stays on your machine."

---

## 1. Guiding principles

**Track metadata, never content.** Zerro deliberately keeps recordings,
transcripts, OCR text, and generated prompts local (Sentry is crash-only with
`sendDefaultPii = false`, and BYOK requests go straight to the user's own
provider). PostHog must not undermine that. No event property may ever contain
prompt text, transcript text, artifact bodies, file paths, hotkey strings,
email addresses in the clear, microphone device names, or any redacted secret.
Properties are limited to enums, counts, durations, booleans, model ids, and
coarse buckets.

**Manual events only on the app — no autocapture.** Autocapture and session
replay are for web SPAs and would be both privacy-hostile and meaningless in a
native menu-bar app. Every desktop event is fired explicitly from code.

**Consistent naming.** `object_action`, snake_case, past tense for things that
happened (`recording_started`, `artifact_copied`). Screen/step views use
`_viewed`. This matches PostHog conventions and keeps the events list legible.

**One thin wrapper.** Add a single `Analytics` type (sibling to the existing
`Log` and `CrashReporting` in `apps/desktop/Zerro/Observability/`) that owns the
PostHog client, the opt-out gate, super properties, and a `capture(_:props:)`
surface mirroring the `Log` call-site style. Every event below flows through it.
This gives one chokepoint to enforce the no-content rule, exactly like
`CrashReporting` is the one chokepoint for Sentry.

---

## 2. Identity & super properties

### Identity

The app has no accounts in the traditional sense — there's a trial email, a
LemonSqueezy-backed managed subscription, and BYOK keys. Recommended approach:

- Start every install **anonymous** with a locally generated, persisted UUID as
  the PostHog `distinct_id` (store in UserDefaults alongside the onboarding
  flags). This is the device identity.
- On email verification in onboarding, **do not** send the raw email as the
  distinct id. Either keep the user anonymous, or `identify` with a **hashed**
  email so trial → subscription can be stitched without storing PII in
  PostHog. Decide this with the privacy policy in mind (see §7).
- The website and the app are effectively separate identity spaces. Stitching
  web → app is only reliably possible via the email at trial signup; treat the
  cross-property funnel as approximate unless you pass a hashed email through
  `/auth`.

### Super properties (attached to every app event)

| Property | Example | Source |
|---|---|---|
| `app_version` | `1.0.7` | bundle short version |
| `build_channel` | `release` / `debug` | build config |
| `os_version` | `macOS 15.4` | `ProcessInfo` |
| `entitlement_state` | `trial` / `expired` / `byok` / `managed_starter` / `managed_pro` | `EntitlementState` |
| `selected_model` | `gemini-3.5-flash` | `PreferencesStore.selectedModelID` |
| `credits_remaining_bucket` | `0` / `1-10` / `11-50` / `50+` | bucketed, never exact if you prefer |

Bucketing `credits_remaining` avoids a high-cardinality, near-PII-ish exact
balance while still letting you see "users near zero."

### Web super properties

`@vercel/analytics` is already installed and gives aggregate pageviews. PostHog
adds funnel/conversion capability. Standard web props are fine (referrer, UTM,
path, device) — these are not sensitive. Keep `person_profiles` set to
`identified_only` so anonymous visitors don't each create a person record.

---

## 3. Website events (getzerro.app)

The site is a single landing page (`hero`, `what-is-zerro`, `tools`, `feature`,
`comparison`, `pricing`, `faq`, `final-cta`, `now-talking`, `built-right`) plus
`/auth`, `/privacy`, `/terms`. The download CTA is the conversion that matters —
it appears in `navbar.tsx`, `hero.tsx`, `pricing.tsx`, and `final-cta.tsx`, all
pointing at `DOWNLOAD_URL` (`/Zerro.dmg`).

| Event | When | Key properties |
|---|---|---|
| `$pageview` | every route (PostHog auto) | `path`, `referrer`, UTM params |
| `download_clicked` | any "Download for macOS" CTA | `placement` = `navbar` / `hero` / `pricing` / `final_cta` |
| `pricing_viewed` | pricing section scrolled into view | `plan_visible` |
| `pricing_plan_cta_clicked` | a plan's CTA in `pricing.tsx` | `plan` = `starter` / `pro` |
| `faq_item_opened` | FAQ accordion expand | `question_id` |
| `comparison_viewed` | comparison section in view | — |
| `auth_signup_started` | `/auth` email field focused/submitted | — |
| `auth_signup_submitted` | trial email submitted on web | `success` (bool) |
| `external_link_clicked` | privacy/terms/footer/social | `destination` |

The single most important web metric is `download_clicked` segmented by
`placement` and UTM — it's the top of the acquisition funnel.

---

## 4. macOS app events

### 4.1 Lifecycle

| Event | When | Properties |
|---|---|---|
| `app_first_launched` | first ever launch (no prior install flag) | — |
| `app_launched` | each cold start | `launch_at_login` (bool) |
| `app_updated` | version changed since last launch | `from_version`, `to_version` |
| `update_offered` | Sparkle presents an update | `to_version` |
| `update_installed` | Sparkle applies an update | `to_version` |

`app_first_launched` is your true install/activation denominator and pairs with
web `download_clicked` for the acquisition funnel.

### 4.2 Onboarding

Steps (from `OnboardingStep`): `welcome → email → screen_recording →
microphone → all_set`. Note the OS issues a SIGKILL when Screen Recording is
granted and `OnboardingState` persists `currentStep` to survive it — so
`onboarding_step_viewed` will legitimately re-fire for the screen step across
the kill. De-dupe in analysis by taking first-occurrence per step per user.

| Event | When | Properties |
|---|---|---|
| `onboarding_started` | welcome step first shown | — |
| `onboarding_step_viewed` | each step rendered | `step` (welcome/email/screen_recording/microphone/all_set), `step_index` |
| `onboarding_step_completed` | advance() from a step | `step` |
| `onboarding_email_submitted` | email entered in email step | `success` (bool) |
| `onboarding_email_verified` | trial credits granted after verify | `credits_granted` |
| `onboarding_completed` | `completeOnboarding()` (All Set → Done) | `duration_seconds` |
| `onboarding_abandoned` | onboarding window closed before All Set | `last_step` |

### 4.3 Permissions

`PermissionsManager` tracks screen recording + microphone. Track grants/denies
both inside onboarding and any later revocation (which can also surface as
recording failures — see 4.5).

| Event | When | Properties |
|---|---|---|
| `permission_requested` | system prompt opened | `permission` = `screen_recording` / `microphone` |
| `permission_granted` | status flips to authorized | `permission`, `context` = `onboarding` / `settings` / `preflight` |
| `permission_denied` | status flips to denied/restricted | `permission`, `context` |
| `permission_revoked` | previously-granted permission lost | `permission` |

### 4.4 Recording (the core loop)

State machine (`RecordingState`): `idle → recording → wrappingUp /
autoStopped → processing → done / failed`, plus `confirmingRecovery`. Fire on
the transitions in `AppState`.

| Event | When | Properties |
|---|---|---|
| `recording_started` | `startRecording()` succeeds | `trigger` = `hotkey` / `menu_bar`, `display_count`, `model`, `entitlement_state` |
| `recording_stopped` | manual `stopRecording()` | `duration_seconds` |
| `recording_auto_stopped` | hit the ~180s auto-stop cap | `duration_seconds` |
| `recording_wrapping_up` | crossed the ~150s soft threshold | — |
| `recording_cancelled` | `cancelRecording()` | `duration_seconds` |
| `recording_too_short` | `recordingTooShort` failure | `duration_seconds` |
| `recording_preflight_blocked` | `presentPreflightBlock()` stops a start | `reason` = `out_of_credits` / `subscription_inactive` / `api_key_missing` |

Recovery (orphaned / sleep-interrupted recordings):

| Event | When | Properties |
|---|---|---|
| `recovery_offered` | `confirmingRecovery` entered | `trigger` = `wake` / `launch` |
| `recovery_accepted` | `resolveRecovery(generate: true)` | — |
| `recovery_discarded` | `resolveRecovery(generate: false)` or dismissed | — |

### 4.5 Processing

Local pipeline: frame extraction, audio isolation, secret redaction
(`ProcessingPipeline`, `Redactor`, `SecretDetector`).

| Event | When | Properties |
|---|---|---|
| `processing_started` | `.processing` entered | — |
| `processing_completed` | processed artifacts ready | `duration_seconds`, `frame_count`, `audio_seconds` |
| `processing_failed` | pipeline threw | `reason` = `processing_failed` / `disk_full` / `artifact_unreadable` |
| `secrets_redacted` | redactor masked ≥1 secret | `redaction_count` (count only — never the content) |

`secrets_redacted` is a nice trust/feature-usage signal and is safe as long as
it carries only a count.

### 4.6 Generation (AI prompt creation)

Routing (`runPromptGeneration`): `managedProxy`, `trialProxy`,
`trialNeedsEmail`, `local` (BYOK). Models and credit prices live in
`ModelRegistry`. This is where most of the cost and most of the value is, so
instrument it richly.

| Event | When | Properties |
|---|---|---|
| `generation_started` | generation kicks off | `model`, `provider` (openai/gemini/anthropic), `route` = `managed` / `trial` / `byok`, `credit_price` |
| `generation_succeeded` | `.done` reached with output | `model`, `route`, `latency_ms`, `artifact_type`, `credits_charged`, `is_converted` |
| `generation_failed` | `.failed` from API stage | `reason` (see enum below), `model`, `route`, `is_retryable` |
| `generation_retried` | Retry button on a retryable failure | `reason`, `attempt` |

`generation_failed.reason` maps to the existing `RecordingFailureReason` cases —
this is a ready-made, well-documented error taxonomy, so reuse the case names:
`api_key_missing`, `api_auth`, `network_offline`, `rate_limited`,
`provider_error`, `provider_unavailable`, `artifact_unreadable`,
`out_of_credits`, `subscription_inactive`, `trial_verification_required`,
`trial_credits_exhausted`. (Capture-side failures like `screen_recording_revoked`
or `disk_full` belong on the recording/processing events, not here.)

### 4.7 Artifact / output

Artifact types (`ArtifactType`): `agent_prompt`, `message`, `snippet`,
`document`, `generic`. The card lives in `ArtifactCardView` with a copy button
and the ghost "Write agent prompt" conversion button (chat-only responses).

| Event | When | Properties |
|---|---|---|
| `artifact_produced` | parsed result shown in pill | `artifact_type`, `was_chat_only` (bool) |
| `artifact_copied` | copy button tapped | `artifact_type`, `source` = `pill` / `history` |
| `artifact_conversion_started` | "Write agent prompt" tapped | — |
| `artifact_conversion_completed` | conversion result returned | `success` (bool) |
| `artifact_dismissed` | pill dismissed | `artifact_type`, `copied_first` (bool) |
| `artifact_collapsed` | card collapsed | `artifact_type` |
| `history_opened` | Recent Prompts opened | `item_count` |
| `history_item_copied` | copy from history row | `artifact_type` |

`artifact_copied` is the activation north-star: it means the user got a usable
result out of the product. `copied_first` on dismiss tells you the success vs.
abandon ratio per session.

### 4.8 Billing & monetization

States: `trial → expired`, `byok`, `managed(starter|pro)`. Paywall in
`PaywallView`/`PaywallScene`; entitlement in `EntitlementStore`; LemonSqueezy
webhook on the backend.

| Event | When | Properties |
|---|---|---|
| `trial_started` | trial credits first granted | `credits_granted` |
| `trial_exhausted` | `trial_credits_exhausted` hit | — |
| `paywall_shown` | paywall presented | `trigger` = `trial_exhausted` / `out_of_credits` / `subscription_inactive` / `manual` |
| `paywall_plan_selected` | a plan chosen on the paywall | `tier` = `starter` / `pro` |
| `checkout_opened` | LemonSqueezy checkout link opened | `tier` |
| `subscription_activated` | entitlement flips to `managed` | `tier` |
| `subscription_lapsed` | entitlement flips to `subscription_inactive`/`expired` | `previous_tier` |
| `byok_key_added` | API key saved in Settings | `provider` |
| `byok_key_removed` | API key cleared | `provider` |
| `out_of_credits_hit` | `out_of_credits` failure surfaces | `route` |

Note: `subscription_activated` is most reliably fired server-side from the
LemonSqueezy webhook (`supabase/functions/lemonsqueezy-webhook`) so you capture
conversions even if the user closes the app — consider PostHog's server-side
capture there with the same distinct id / hashed email.

### 4.9 Settings & configuration

| Event | When | Properties |
|---|---|---|
| `settings_opened` | settings window shown | `section` |
| `model_changed` | model picker selection | `from_model`, `to_model` |
| `hotkey_changed` | capture hotkey reassigned | — (never the key string) |
| `launch_at_login_toggled` | toggle | `enabled` |
| `redact_secrets_toggled` | toggle | `enabled` |
| `crash_reporting_toggled` | Sentry opt-in toggle | `enabled` |
| `analytics_opt_out_toggled` | the new PostHog opt-out (see §7) | `enabled` |

---

## 5. Funnels & questions these unlock

**Acquisition** → `download_clicked` (web) → `app_first_launched` →
`onboarding_started` → `onboarding_completed`. Where do people drop:
download-but-never-launch (Gatekeeper/notarization friction?), or
launch-but-never-finish-onboarding (permissions friction?).

**Permission friction** → `onboarding_step_viewed{screen_recording}` →
`permission_granted{screen_recording}` and same for microphone. The SIGKILL on
screen-recording grant is a known sharp edge; this funnel quantifies its cost.

**Activation (aha moment)** → `onboarding_completed` → `recording_started` →
`processing_completed` → `generation_succeeded` → `artifact_copied`. The single
most important funnel — first recording to first copied artifact.

**Core-loop reliability** → `recording_started` → `processing_completed` →
`generation_succeeded`, with `generation_failed` / `processing_failed` broken
out by `reason`. This is your quality dashboard.

**Monetization** → `trial_started` → `trial_exhausted` → `paywall_shown` →
`checkout_opened` → `subscription_activated`, segmented by `tier`. Plus
BYOK-vs-managed split via `byok_key_added` vs `subscription_activated`.

**Model economics** → `generation_succeeded` grouped by `model` /
`credit_price` / `latency_ms` — which models people actually pick, what they
cost you, and whether the "recommended" Flash default is sticky.

---

## 6. Suggested implementation order

1. **Web first** — it's the cheapest (PostHog JS snippet in `app/layout.tsx`
   alongside the existing Vercel `Analytics`), and `download_clicked` +
   pageviews immediately light up the top of the funnel.
2. **App scaffolding** — the `Analytics` wrapper, super properties, anonymous
   distinct id, opt-out toggle, opt-out gate. Ship with zero events to validate
   the privacy posture and the toggle.
3. **Activation core** — lifecycle, onboarding, permissions, recording,
   generation, `artifact_copied`. This is 80% of the value.
4. **Monetization** — paywall, trial, subscription (incl. server-side
   `subscription_activated` from the LemonSqueezy webhook).
5. **Polish** — settings, history, conversion, recovery.

---

## 7. Privacy & compliance (do not skip)

Zerro's privacy story is a selling point on the marketing site and in the
in-app copy, so adding analytics has to be done carefully and disclosed.

- **Add an opt-out toggle** next to the existing "Send anonymous crash reports"
  control, defaulting per your policy stance, and gate the `Analytics` wrapper
  on it exactly like `CrashReporting` gates Sentry. When off, capture returns
  immediately and nothing leaves the machine.
- **No content, ever.** Enforce in the wrapper: properties are a fixed allowlist
  of enums/counts/durations/ids. Re-use the `Log` privacy discipline.
- **Disable session replay and autocapture** on the app; set
  `person_profiles: 'identified_only'` on web.
- **Prefer EU hosting or self-host** of PostHog if any EU users are expected,
  and keep IP collection off / anonymized.
- **Hash emails** if you identify at all; don't store raw email in PostHog.
- **Update the privacy policy.** `apps/web/app/privacy/page.tsx` currently
  discloses only Vercel Analytics ("aggregated, privacy-focused") and AI
  provider processing. Adding PostHog requires updating that section to name
  PostHog, what's collected (product usage metadata, no content), the opt-out,
  and the legal basis. Treat the policy edit as part of shipping, not after.

---

## 8. Event summary (quick reference)

Web: `download_clicked`, `pricing_viewed`, `pricing_plan_cta_clicked`,
`faq_item_opened`, `comparison_viewed`, `auth_signup_started`,
`auth_signup_submitted`, `external_link_clicked`.

App lifecycle: `app_first_launched`, `app_launched`, `app_updated`,
`update_offered`, `update_installed`.

Onboarding: `onboarding_started`, `onboarding_step_viewed`,
`onboarding_step_completed`, `onboarding_email_submitted`,
`onboarding_email_verified`, `onboarding_completed`, `onboarding_abandoned`.

Permissions: `permission_requested`, `permission_granted`, `permission_denied`,
`permission_revoked`.

Recording: `recording_started`, `recording_stopped`, `recording_auto_stopped`,
`recording_wrapping_up`, `recording_cancelled`, `recording_too_short`,
`recording_preflight_blocked`, `recovery_offered`, `recovery_accepted`,
`recovery_discarded`.

Processing: `processing_started`, `processing_completed`, `processing_failed`,
`secrets_redacted`.

Generation: `generation_started`, `generation_succeeded`, `generation_failed`,
`generation_retried`.

Artifact: `artifact_produced`, `artifact_copied`,
`artifact_conversion_started`, `artifact_conversion_completed`,
`artifact_dismissed`, `artifact_collapsed`, `history_opened`,
`history_item_copied`.

Billing: `trial_started`, `trial_exhausted`, `paywall_shown`,
`paywall_plan_selected`, `checkout_opened`, `subscription_activated`,
`subscription_lapsed`, `byok_key_added`, `byok_key_removed`,
`out_of_credits_hit`.

Settings: `settings_opened`, `model_changed`, `hotkey_changed`,
`launch_at_login_toggled`, `redact_secrets_toggled`, `crash_reporting_toggled`,
`analytics_opt_out_toggled`.
