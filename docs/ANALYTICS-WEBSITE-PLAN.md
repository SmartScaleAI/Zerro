# Zerro Website — PostHog Analytics Plan

Status: proposal · Scope: getzerro.app (Next.js marketing site) · Last updated: 2026-06-15

## Context

`apps/web` is a single Next.js 16 landing page (`/`) plus `/auth`, `/privacy`,
`/terms`. Today it runs **only Vercel Analytics** (`@vercel/analytics` in
`app/layout.tsx`) — no PostHog. The site's **only conversion is the "Download
for macOS" CTA** (`DOWNLOAD_URL` → `/Zerro.dmg`, a 302 to the latest GitHub
release). Every pricing CTA — both Managed and BYOK — points at the download;
`MANAGED_CHECKOUT_URL` is an empty TODO, so **purchase happens entirely in the
app, not on the site.** `/auth` is `robots.txt`-disallowed and not linked from
any CTA — it's dormant and out of scope.

So the website's job is **acquisition → on-page engagement → download**, and the
download is the bridge to the app's `Application Installed`.

## Approach (deliberately opposite of the macOS app)

The app uses manual events only, no autocapture. A **marketing site is the
opposite** — autocapture is the right default. Decided configuration:

- **`posthog-js` web SDK** in `app/layout.tsx` via a client provider.
- **Autocapture ON**, **pageviews ON** (manual `$pageview` on route change, per
  Next App Router), **`$pageleave` ON**.
- **Heatmaps ON**, **session replay OFF**.
- **`person_profiles: 'identified_only'`** — no profile per anonymous visitor.
- **Cookieless (`persistence: 'memory'`)** — no consent banner needed, keeps the
  privacy-first posture (and parity with the cookieless Vercel setup it
  replaces). Tradeoff: a visitor returning days later looks new; the in-session
  download funnel is unaffected.
- **Remove `@vercel/analytics`** — consolidating to PostHog.
- **Same PostHog project as the macOS app** (project `469499`). This is safe
  here because the app sends **no** pageviews/web-sessions (`captureScreenViews =
  false`), so web traffic and app events don't pollute each other: PostHog's
  built-in **Web analytics** tab shows essentially website-only data, and every
  app dashboard tile filters on native events (`Application Opened`,
  `recording_started`, …) that web visitors never fire. Reuse the app's
  production key (`phc_tW2Qm…`). *(The only reason to split into a separate
  "Zerro Website" project later is event-volume/billing hygiene — web
  autocapture is high-volume. Not worth it at current scale.)*

## Where the metrics live

Two surfaces, no overlap:

- **PostHog's built-in Web analytics tab** (zero build) — fed automatically by
  `$pageview`/`$pageleave`/autocapture. Covers visitors, pageviews, sessions,
  **sources by channel / UTM**, top paths, devices, geography, bounce, retention,
  web vitals. This is the whole "traffic + acquisition" half — you don't build a
  dashboard for it.
- **A small custom "Website — Conversion" dashboard** (a handful of insights) for
  the things the Web analytics tab can't see: the manual conversion events below.

## Events

Autocapture + `$pageview` already give traffic, **referrer / UTM / source**, top
pages, devices, geography, and bounce for free (via the Web analytics tab). On
top of that, these manual events power the conversion dashboard:

| Event | When | Properties |
|---|---|---|
| `download_clicked` | any "Download for macOS" CTA | `placement` = `navbar` / `navbar_mobile` / `hero` / `pricing_managed` / `pricing_byok` / `final_cta` |
| `section_viewed` | a page section scrolls into view (once each) | `section` = `hero` / `what_is_zerro` / `how_it_works` / `output` / `built_right` / `comparison` / `the_shift` / `pricing` / `faq` / `final_cta` |
| `pricing_billing_toggled` | monthly/yearly toggle in pricing | `interval` = `monthly` / `yearly` |
| `faq_opened` | an FAQ item is expanded | `question` (the question text or a stable id) |
| `demo_played` | hero "Watch it work" clicked | — |
| `nav_link_clicked` *(optional)* | navbar anchor links | `target` = `how_it_works` / `output` / `built_right` / `pricing` |
| `outbound_clicked` *(optional)* | privacy / terms / support email | `destination` |

`download_clicked` segmented by `placement` is the single most important web
metric. `/auth` is intentionally **not** instrumented.

## Funnels & questions this unlocks

- **Acquisition (the #1 web KPI):** `$pageview` (landing) → `download_clicked`,
  segmented by `placement` and by traffic **source / UTM / referrer**. Which
  channels convert, and which CTA placement does the work.
- **On-page engagement:** `section_viewed[hero]` → `[pricing]` →
  `download_clicked` — where attention drops before people ever reach pricing.
- **Pricing intent:** `pricing_billing_toggled` (monthly vs yearly interest) and
  `faq_opened` (top objections) as qualitative-to-quantitative signals.
- **Cross-property (aggregate only):** web `download_clicked` vs app
  `Application Installed` — a download→install conversion rate. Not per-user
  (no shared id survives a `.dmg` download); compare the two numbers.

## Must-dos before shipping

- **Privacy policy:** `app/privacy/page.tsx` currently discloses Vercel
  Analytics for the website. Since we're removing Vercel and adding PostHog,
  update that section to name PostHog (product-usage metadata, heatmaps, no
  session recording, no cross-site cookies).
- **`www` redirect:** `getzerro.app` 302s to `www.getzerro.app`. With cookieless
  memory persistence this is a non-issue (PostHog only ever loads on `www`), but
  keep it in mind if you later switch to cookies.
- **Env:** `NEXT_PUBLIC_POSTHOG_KEY` (a client-safe `phc_…` key) and
  `NEXT_PUBLIC_POSTHOG_HOST` (`https://us.i.posthog.com`) in `.env` and Vercel.
- **Optional:** reverse-proxy PostHog through a Next.js rewrite to reduce
  ad-blocker loss.

## Then

Lean on the built-in **Web analytics** tab for traffic/acquisition, and build a
small **"Website — Conversion"** dashboard for the manual events
(`download_clicked` by placement, the `section_viewed` funnel,
`pricing_billing_toggled`, `faq_opened`, `demo_played`) — same approach as the
macOS app dashboard. Separate doc once events are flowing.
