# PostHog Dashboard Plan — Zerro macOS App

Status: build guide · Structure: lean funnel/AARRR sections · Last updated: 2026-06-15

A click-by-click plan to build one dashboard for the Mac app, organized into
labeled sections (Activation → Engagement → Monetization → Reliability) with 2–4
tiles each. Every tile below names the exact event(s) and properties you
instrumented across Tier 1–4, so each is buildable directly in PostHog.

---

## 0. Setup (do this once, before adding tiles)

1. **New dashboard → "Start from scratch."** Don't use a template — the
   Product Analytics / Mobile Analytics templates assume autocapture, `$pageview`,
   and `$screen` events that this manual-instrumented app never sends, so they'd
   populate empty. Name it **`Zerro — macOS App`**.
2. **Dashboard-wide filters** (gear/filter on the dashboard, applied to all tiles):
   - **Date range:** Last 30 days (Activation/Reliability) — you can override per
     tile where noted.
   - **Property filter:** `environment = production`. Debug builds route to a
     separate key/environment, but add this as belt-and-suspenders so no dev
     traffic leaks in. Optionally also `build_channel = release`.
3. **Section headers:** PostHog has no native sections, so add a **Text** tile
   above each group as a divider (e.g. a tile containing `## Activation`). This
   gives the "lean labeled rows" layout.
4. **Naming:** prefix saved insights with `[App]` so they're easy to find and
   don't collide with the future website dashboard's insights.

**Identity caveat that affects every "users" tile:** the app never calls
`identify`, so "unique users" = PostHog anonymous **device** ids. DAU/WAU and
funnels are accurate; cross-reinstall retention is approximate. That's expected
and fine.

**Super-properties available as breakdowns/filters on every event:**
`app_version`, `build_channel`, `environment`, `entitlement_state`,
`credits_remaining_bucket` (plus PostHog auto props like `$os_version`).

---

## 1. ACTIVATION  *(do new users reach the aha moment?)*

| Tile | Insight type | How to build |
|---|---|---|
| **Onboarding step funnel** | Funnel | Steps, each = event `onboarding_step_viewed` filtered by `step` =, in order: `welcome` → `consent` → `email` → `screen_recording` → `microphone` → `all_set`, then a final step `onboarding_completed`. Conversion window: 1 day. Shows exactly where new users drop — watch the **consent** and **screen_recording** steps especially. |
| **Activation funnel (first record → first copy)** | Funnel | Steps: `onboarding_completed` → `recording_started` → `generation_succeeded` → `artifact_copied`. Conversion window: 7 days. This is your **north-star** funnel — first run to first usable output. |
| **Activation trend** | Trend | Series A = unique users of `onboarding_completed`; Series B = unique users of `artifact_copied`. Weekly. The gap = installs that finished setup but never got value. |

Optional: break the onboarding funnel down by `app_version` to see if a specific
build regressed setup.

---

## 2. ENGAGEMENT  *(are users coming back and using it?)*

| Tile | Insight type | How to build |
|---|---|---|
| **Weekly active creators** | Trend | Unique users of `recording_started`, weekly (WAU of the core action). Add a second series of unique users of *any* event for total WAU. |
| **Recording volume** | Trend | Total count of `recording_completed`, daily. Add `recording_cancelled` + `recording_too_short` as secondary series to see abandoned captures. |
| **Model mix** | Trend (pie or bar) | Event `generation_succeeded`, total count, **breakdown by `model`**. Shows which models users actually use — pairs with `model_changed` to see switching. |
| **Retention** *(optional)* | Retention | "Performed event" `recording_started`, returning to `recording_started`, weekly. Are users who record once recording again next week? |

---

## 3. MONETIZATION  *(are users converting to paid?)*

> Requires the webhook deployed with `POSTHOG_API_KEY` set — `subscription_*`
> events are server-side. Expect low volume early.

| Tile | Insight type | How to build |
|---|---|---|
| **Paywall → paid funnel** | Funnel | Steps: `paywall_shown` → `checkout_opened` → `subscription_activated`. Conversion window: 14–30 days (purchase decisions are slow). Optionally break down by `product` / `tier`. |
| **Trial funnel** | Funnel | Steps: `trial_started` → `trial_exhausted` → `paywall_shown`. Window: 30 days. Shows how many trial users burn through credits and see the wall. |
| **Subscriptions over time (net)** | Trend | Series A = count of `subscription_activated` (breakdown by `tier`); Series B = count of `subscription_lapsed`. Weekly. A minus B ≈ net adds. |
| **Checkout starts by surface** *(optional)* | Trend | `checkout_opened`, breakdown by `product` (`subscription_pro` / `byok` / `topup_boost` / `topup_power`). Which offers get clicked. |

---

## 4. RELIABILITY / QUALITY  *(is the core loop dependable?)*

| Tile | Insight type | How to build |
|---|---|---|
| **Generation success rate** | Trend (formula) | Series A = count of `generation_succeeded`, Series B = count of `generation_failed`. Add **formula** `A / (A + B)`, displayed as a %. Weekly. Optionally break down by `route` (managed/trial/byok). |
| **Failures by reason** | Trend (bar) | Event `generation_failed`, total count, **breakdown by `reason`**. Add a second tile (or series) for `processing_failed` broken down by `reason`. Pinpoints the top failure causes to fix. |
| **Generation latency (p50/p90)** | Trend | Event `generation_succeeded`, math = **90th percentile of `latency_ms`**; add a second series at **median (p50)**. Watch for slow models / proxy regressions. |
| **Crashes / exceptions** | Trend | Count of `$exception` over time, **breakdown by `label`** (the handled-error message) or `stage`. For a crash-free proxy, add a formula tile: `1 - (users with $exception / users with Application Opened)`. |

Optional reliability extras you have the data for: `generation_retried` count
(breakdown by `reason` / `attempt`) to see how often users fight a failure, and
`permission_denied` / `permission_revoked` to quantify permission friction.

---

## 5. Suggested build order & polish

1. Build **Activation** first (it's your most important early signal and the
   events most likely to already have data).
2. Then **Reliability**, **Engagement**, **Monetization**.
3. Arrange tiles in 2–3 columns under each text-header divider; drag the
   north-star activation funnel to the top-left.
4. **Alerts (optional but worth it):** set a PostHog alert on *Generation
   success rate* (notify if it drops below, say, 90% week-over-week) and on
   *Crashes* (notify on a spike). These turn the dashboard into early warning.
5. **Pin** the dashboard and set it as a default for the project.

---

## 6. Data-readiness reality check

Build all tiles now so the dashboard is ready, but know that tiles populate as
data arrives:

- **Has data today** (original MVP events, if a build shipped with them):
  `onboarding_started`, `onboarding_completed`, `recording_started`,
  `generation_succeeded`, `generation_failed`, `artifact_copied`,
  `paywall_shown`, lifecycle, `$exception`.
- **Lights up after the Tier 1–4 build ships:** `onboarding_step_viewed`,
  `recording_completed/cancelled/too_short`, `processing_*`, `generation_started`,
  `latency_ms`, `artifact_produced`, `model_changed`, `permission_*`,
  `recovery_*`, `trial_*`, `byok_key_*`, and the `entitlement_state` /
  `credits_remaining_bucket` breakdowns.
- **Lights up after the webhook deploys** (with `POSTHOG_API_KEY` secret):
  `subscription_activated`, `subscription_lapsed`.

A tile over an event with no data shows empty rather than breaking — that's fine;
it'll fill in once the build/webhook is live.
