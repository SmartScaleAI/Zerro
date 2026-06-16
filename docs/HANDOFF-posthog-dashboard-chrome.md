# Claude-in-Chrome handoff — build the Zerro macOS PostHog dashboard

You are operating a browser to build a PostHog dashboard for the Zerro macOS app.
Work through the PHASES in order. Build one tile at a time, save each, confirm it
lands on the dashboard, then continue. Report progress after each phase.

## How to operate PostHog (read first — the UI may shift, so navigate by LABELS)

- PostHog changes its layout often. Treat the click-paths below as guidance:
  find controls by their visible text, not a fixed position. The underlying
  CONCEPTS are stable — insight **type** (Trends / Funnels / Retention),
  **series** (the event), **math** (Total count / Unique users / Property value
  percentile), **breakdown** (by a property), **conversion window** (funnels),
  and **formula** (Trends). If a control isn't where described, read the page
  and look for that concept by name.
- An insight that shows "There is no data" is FINE — many events aren't flowing
  yet (see "Data readiness" at the end). Save it anyway; it fills in later.
- Event and property names are **case- and spelling-sensitive** — type them
  exactly as written (e.g. `generation_succeeded`, `latency_ms`, `screen_recording`).
- After building each insight, set its **title** (top-left, editable) to the name
  given, then **Save**. When creating from within the dashboard, use the
  "Save & add to dashboard" path so it attaches to `Zerro — macOS App`.

---

## PHASE 0 — Access & orient

1. Go to the PostHog app (the instance the user uses — `us.posthog.com` /
   `eu.posthog.com` / self-host). If you're not logged in and have no
   credentials, STOP and ask the user to log in, then continue.
2. Open the **project switcher** (top-left). Select the **Zerro** project. If
   there are multiple Zerro projects/environments, choose the **production** one
   (this is where the live app key `phc_tW2Qm…` sends). Do NOT build in a
   dev/debug project.
3. Confirm by opening **Activity → Events** (or "Activity explorer") and checking
   that events like `recording_started` or `generation_succeeded` appear. If the
   project has zero events of any kind, tell the user you may be in the wrong
   project and ask them to confirm before proceeding.

---

## PHASE 1 — Create the dashboard + global filters

1. Left nav → **Dashboards** → **New dashboard** → on the template picker choose
   **"Start from scratch"** (NOT a template — they assume autocapture/$pageview
   events this app doesn't send).
2. Name it exactly: **`Zerro — macOS App`**. Save/create.
3. On the new (empty) dashboard, set **dashboard-level filters** (top of the
   dashboard):
   - **Date range:** Last 30 days.
   - **Add a property filter:** `environment` equals `production` (excludes any
     dev traffic). If the property doesn't exist yet because data isn't flowing,
     skip it and note that you skipped it.
4. Confirm the dashboard saved and is empty, then proceed to add tiles.

For every tile below: from the dashboard click **Add insight → New insight**
(opens the insight editor in dashboard context). Build it, title it, then
**Save & add to dashboard**. Before each section's tiles, first add a **Text**
tile as a section header.

---

## PHASE 2 — Activation section

**Add a Text tile** first with content: `## Activation` (use Add insight → Text).

### 2.1 — `[App] Onboarding step funnel`  (Funnel)
- Insight type: **Funnels**.
- Add these steps IN ORDER. Steps 1–6 are all the SAME event
  `onboarding_step_viewed` with a property filter on `step`; step 7 is a
  different event:
  1. `onboarding_step_viewed` where `step` = `welcome`
  2. `onboarding_step_viewed` where `step` = `consent`
  3. `onboarding_step_viewed` where `step` = `email`
  4. `onboarding_step_viewed` where `step` = `screen_recording`
  5. `onboarding_step_viewed` where `step` = `microphone`
  6. `onboarding_step_viewed` where `step` = `all_set`
  7. `onboarding_completed`
- Set **conversion window** to **1 day**.
- Title `[App] Onboarding step funnel`. Save & add to dashboard.

### 2.2 — `[App] Activation funnel (first record → first copy)`  (Funnel)
- Insight type: **Funnels**. Steps in order:
  1. `onboarding_completed`
  2. `recording_started`
  3. `generation_succeeded`
  4. `artifact_copied`
- **Conversion window: 7 days.** Title it, save & add.

### 2.3 — `[App] Activation trend`  (Trends)
- Insight type: **Trends**.
- Series A: event `onboarding_completed`, math **Unique users**.
- Series B: event `artifact_copied`, math **Unique users**.
- Interval: **Weekly**. Display: line chart. Title it, save & add.

---

## PHASE 3 — Engagement section

**Add a Text tile:** `## Engagement`.

### 3.1 — `[App] Weekly active creators`  (Trends)
- Series A: `recording_started`, math **Unique users**, interval **Weekly**.
- Series B (optional): **All events** (or `Application Opened`), math **Unique
  users** — total WAU for comparison. Title, save & add.

### 3.2 — `[App] Recording volume`  (Trends)
- Series A: `recording_completed`, math **Total count**, interval **Daily**.
- Series B: `recording_cancelled`, Total count.
- Series C: `recording_too_short`, Total count.
- Title, save & add.

### 3.3 — `[App] Model mix`  (Trends)
- Series: `generation_succeeded`, math **Total count**.
- **Breakdown by** event property `model`.
- Display type: **pie** (or bar). Title, save & add.

### 3.4 (optional) — `[App] Recording retention`  (Retention)
- Insight type: **Retention**. Target/"Performed event": `recording_started`;
  returning event: `recording_started`; period **Weekly**. Title, save & add.

---

## PHASE 4 — Monetization section

**Add a Text tile:** `## Monetization` (and inside it note: "subscription_* are
server-side from the LemonSqueezy webhook — empty until the webhook is deployed").

### 4.1 — `[App] Paywall → paid funnel`  (Funnel)
- Steps in order:
  1. `paywall_shown`
  2. `checkout_opened`
  3. `subscription_activated`
- **Conversion window: 30 days.** Title, save & add.

### 4.2 — `[App] Trial funnel`  (Funnel)
- Steps: `trial_started` → `trial_exhausted` → `paywall_shown`.
- Conversion window: **30 days.** Title, save & add.

### 4.3 — `[App] Subscriptions over time (net)`  (Trends)
- Series A: `subscription_activated`, Total count, **breakdown by `tier`**.
- Series B: `subscription_lapsed`, Total count.
- Interval **Weekly**. Title, save & add.

### 4.4 (optional) — `[App] Checkout starts by surface`  (Trends)
- Series: `checkout_opened`, Total count, **breakdown by `product`**. Title, save.

---

## PHASE 5 — Reliability / quality section

**Add a Text tile:** `## Reliability`.

### 5.1 — `[App] Generation success rate`  (Trends + formula)
- Series A: `generation_succeeded`, math **Total count**.
- Series B: `generation_failed`, math **Total count**.
- Enable **formula** mode and enter: `A / (A + B)`.
- Format the result as a **percentage**; interval **Weekly**. Title, save & add.

### 5.2 — `[App] Generation failures by reason`  (Trends, bar)
- Series: `generation_failed`, Total count, **breakdown by `reason`**.
- Display: **bar**. Title, save & add.
- (If quick: add a second insight `[App] Processing failures by reason` =
  `processing_failed` broken down by `reason`.)

### 5.3 — `[App] Generation latency (p50 / p90)`  (Trends)
- Series A: `generation_succeeded`, math **Property value → 90th percentile** of
  property `latency_ms`.
- Series B: `generation_succeeded`, math **Property value → Median (p50)** of
  `latency_ms`. Interval **Weekly**. Title, save & add.

### 5.4 — `[App] Crashes / exceptions`  (Trends)
- Series: `$exception`, math **Total count**, **breakdown by `label`** (fall back
  to `stage` if `label` isn't present). Interval **Daily**. Title, save & add.

---

## PHASE 6 — Layout, alerts, finish

1. **Arrange** tiles into a tidy 2–3 column grid under each text header; drag
   `[App] Activation funnel (first record → first copy)` to the top-left as the
   hero tile.
2. **Alerts (optional but recommended):** on `[App] Generation success rate`,
   open the insight → set an **alert** to notify if the value drops below ~0.9.
   On `[App] Crashes / exceptions`, set an alert on a spike. (Alerts live in the
   insight's menu — "Alerts"/"Subscribe".)
3. **Pin** the dashboard (dashboard menu → Pin) so it's easy to find.
4. Final check: confirm all section headers + ~13 tiles are present on
   `Zerro — macOS App`, each titled with its `[App] …` name. Empty tiles are
   expected for not-yet-flowing events.
5. **Report back** to the user: the dashboard URL, the list of tiles created, and
   any tiles you had to skip or that showed "no data" (so they know which await
   the new build / webhook deploy).

---

## Data readiness (so empty tiles don't alarm you)

- **Has data now (if a build already shipped these):** `onboarding_started`,
  `onboarding_completed`, `recording_started`, `generation_succeeded`,
  `generation_failed`, `artifact_copied`, `paywall_shown`, lifecycle events,
  `$exception`.
- **Empty until the Tier 1–4 app build ships:** `onboarding_step_viewed`,
  `recording_completed/cancelled/too_short`, `processing_*`, `generation_started`,
  `latency_ms`, `model_changed`, `permission_*`, `recovery_*`, `trial_*`.
- **Empty until the webhook deploys with the PostHog key:**
  `subscription_activated`, `subscription_lapsed`.

Build every tile regardless — they populate automatically as data arrives.
```
Sections: Activation (3) · Engagement (3–4) · Monetization (3–4) · Reliability (4)
Total: ~13 insight tiles + 4 text headers on one dashboard "Zerro — macOS App"
```
