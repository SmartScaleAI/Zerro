# PostHog Dashboard Plan — Zerro Website (Conversion)

Status: build guide · Scope: getzerro.app · Last updated: 2026-06-16

A small custom dashboard for the website's **conversion + on-page engagement**
events. It deliberately does NOT rebuild traffic/sources/geo — those live in
PostHog's built-in **Web analytics** tab (fed automatically by
`$pageview`/autocapture). This dashboard covers only the manual events the Web
analytics tab can't see.

## What lives where (don't duplicate)

- **Web analytics tab (no build):** visitors, pageviews, sessions, sources /
  UTM / channel, top paths, devices, geography, bounce, retention. Also: set
  **`download_clicked` as the tab's conversion goal** so it shows download
  conversion rate by source for free.
- **This custom dashboard:** `download_clicked` (by placement), the
  `section_viewed` scroll funnel, `pricing_billing_toggled`, `faq_opened`,
  `demo_played`.

## Setup

1. New dashboard → **Start from scratch** → name **`Zerro — Website`**.
2. It's in the **same project** as the macOS app, so prefix every insight with
   **`[Web]`** to keep it distinct from the `[App]` tiles.
3. Dashboard filters: **Date range** Last 30 days; ensure **"Filter test
   accounts" is ON** (the `$host` localhost rule we added keeps dev events out).
4. Add a **Text** tile above each group as a section header (same pattern as the
   app dashboard).

Note (cookieless caveat): "unique visitors" is approximate (returning visitors
look new). Within-visit funnels — `section_viewed` → `download_clicked` — are
accurate, which is what most of these tiles measure.

---

## 1. CONVERSION  *(the website's whole job)*

| Tile | Insight type | How to build |
|---|---|---|
| **`[Web] Downloads over time`** | Trend | Event `download_clicked`, **Total count**, weekly. Add a second series **Unique users**. Your #1 KPI volume. |
| **`[Web] Downloads by placement`** | Trend (bar/pie) | `download_clicked`, Total count, **breakdown by `placement`** (`navbar`/`navbar_mobile`/`hero`/`pricing_managed`/`pricing_byok`/`final_cta`). Which CTA actually drives downloads. |
| **`[Web] Download conversion rate`** | Trend (formula) | Series A = `download_clicked` **Unique users**; Series B = `$pageview` **Unique users**. Formula `A / B`, shown as a **%**, weekly. Overall visit → download rate. |
| **`[Web] Pricing → download funnel`** | Funnel | Steps: `section_viewed` where `section = pricing` → `download_clicked`. Conversion window 1 day. Do people who reach pricing actually download? |

---

## 2. ENGAGEMENT / PAGE ATTENTION  *(where do people drop before downloading?)*

| Tile | Insight type | How to build |
|---|---|---|
| **`[Web] Scroll-depth funnel`** | Funnel | Steps = `section_viewed` filtered by `section` in page order: `hero` → `how_it_works` → `output` → `built_right` → `comparison` → `the_shift` → `pricing` → `faq` → `final_cta`. Window 1 day. Shows exactly where attention dies before pricing. |
| **`[Web] Sections reached`** | Trend (bar) | `section_viewed`, Unique users, **breakdown by `section`**. Flatter view of reach per section. |
| **`[Web] Demo plays`** | Trend | `demo_played`, Total count, weekly. Optionally a formula vs `section_viewed[hero]` for a play-rate. |
| **`[Web] Pricing interest (monthly vs yearly)`** | Trend (pie) | `pricing_billing_toggled`, **breakdown by `interval`**. Price-plan sensitivity. |
| **`[Web] FAQ opens by question`** | Trend (bar) | `faq_opened`, Total count, **breakdown by `question`**. Your top objections, ranked. |

---

## 3. ACQUISITION → CONVERSION  *(optional — which channels convert)*

| Tile | Insight type | How to build |
|---|---|---|
| **`[Web] Downloads by channel`** | Trend (bar) | `download_clicked`, Total count, **breakdown by `$channel_type`** (or `$referring_domain` / initial UTM). Which traffic sources actually convert to downloads. Complements the Web analytics conversion goal. |

The rest of acquisition (volume, sources, geo, devices) stays in the Web
analytics tab — don't rebuild it here.

---

## Funnels & questions this answers

- **Does the page convert?** `[Web] Download conversion rate` + `Downloads by
  placement` — overall rate and which CTA earns it.
- **Where do visitors bail?** `[Web] Scroll-depth funnel` — the drop between
  `hero` and `pricing` is your biggest leak.
- **Does reaching pricing matter?** `[Web] Pricing → download funnel`.
- **What's stopping them?** `faq_opened` (objections) + `pricing_billing_toggled`
  (price sensitivity).
- **Which channels pay off?** `[Web] Downloads by channel`.

## Build order

1. **Conversion** section first (the point of the site).
2. **Engagement** (the scroll funnel is the most actionable diagnostic).
3. **Acquisition → conversion** (optional).
4. Set `download_clicked` as the **Web analytics conversion goal** (separate from
   this dashboard, one-time config).
5. Optional later: an **alert** on `download_clicked` dropping week-over-week, and
   a cross-property **`download_clicked` (web) → `Application Installed` (app)**
   comparison insight (aggregate — separate anonymous identities).

~10 tiles + 3 text headers on one dashboard, `Zerro — Website`.
