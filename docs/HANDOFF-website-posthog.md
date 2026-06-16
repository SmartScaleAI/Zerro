# Claude Code handoff — instrument PostHog on the Zerro website

Add PostHog product analytics to the Next.js marketing site (`apps/web`),
consolidating off Vercel Analytics. Full rationale + event taxonomy is in
`docs/ANALYTICS-WEBSITE-PLAN.md` — read it first. This is the implementation.

## Decided configuration (don't deviate)
- `posthog-js` web SDK, initialized in a client provider wired into `app/layout.tsx`.
- **Autocapture ON**, **`$pageview` captured manually on route change** (Next App
  Router), **`$pageleave` ON**.
- **Heatmaps ON** (`enable_heatmaps: true`), **session replay OFF**
  (`disable_session_recording: true`).
- **`person_profiles: 'identified_only'`**.
- **Cookieless: `persistence: 'memory'`** (no consent banner).
- **Remove `@vercel/analytics`** entirely (import, `<Analytics/>`, dependency).
- Env keys: `NEXT_PUBLIC_POSTHOG_KEY`, `NEXT_PUBLIC_POSTHOG_HOST`
  (`https://us.i.posthog.com`). **Reuse the macOS app's PostHog project** — same
  project (`469499`), production key `phc_tW2Qm…` (confirm the exact value with
  the user / `apps/desktop/Zerro/Info.plist`). This is intentional: the app sends
  no pageviews, so web traffic surfaces cleanly in PostHog's built-in **Web
  analytics** tab without polluting the app's dashboards.

## Ground rules
- Privacy/metadata only — never capture form input, email, or PII in event props.
- Keep the existing markup/styling; add tracking with the lightest touch.
- Match the codebase's TypeScript + component conventions.

---

## 1. Install + provider

1. `npm i posthog-js` in `apps/web`; remove `@vercel/analytics` from
   `package.json`.
2. Create `app/providers.tsx` (client component):
   - `posthog.init(NEXT_PUBLIC_POSTHOG_KEY, { api_host, person_profiles:'identified_only', persistence:'memory', autocapture:true, capture_pageview:false, capture_pageleave:true, disable_session_recording:true, enable_heatmaps:true })` inside a `useEffect`.
   - Export a `PostHogProvider` wrapping `children` with `posthog-js/react`'s provider.
3. Create a `PostHogPageView` client component that captures `$pageview` on route
   change using `usePathname()` + `useSearchParams()` in a `useEffect`, and wrap
   it in `<Suspense fallback={null}>` (required because `useSearchParams` suspends).
4. In `app/layout.tsx`: remove the Vercel `import { Analytics }` and `<Analytics />`;
   wrap the body's children in `<PostHogProvider>` and render `<PostHogPageView />`
   inside it.

## 2. Tracking helper

Create `lib/analytics.ts`:
```ts
import posthog from "posthog-js";
export function track(event: string, props?: Record<string, unknown>) {
  if (typeof window !== "undefined") posthog.capture(event, props);
}
```
All manual events below go through `track(...)`.

## 3. `download_clicked` (most important)

Every "Download for macOS" CTA renders `<a href={DOWNLOAD_URL} download>`. Create
one reusable client component `components/download-button.tsx` that renders the
same anchor/Button and fires `track("download_clicked", { placement })` in
`onClick`, taking a `placement` prop. Replace the raw download anchors with it at:

- `components/templates/axis/navbar.tsx` (~line 103 desktop → `navbar`; ~line 116 mobile → `navbar_mobile`)
- `components/templates/axis/hero.tsx` (~line 190 → `hero`)
- `components/templates/axis/pricing.tsx` (Managed card → `pricing_managed`; BYOK card → `pricing_byok`)
- `components/templates/axis/final-cta.tsx` (~line 79 → `final_cta`)

Keep the `download` attribute and styling identical — only add the click event.

## 4. `section_viewed`

Create a client component `components/section-view.tsx` that wraps its children,
uses an `IntersectionObserver` (threshold ~0.3) to fire `track("section_viewed",
{ section })` **once** per mount, then disconnects. In `app/page.tsx`, wrap each
section with `<SectionView section="...">`:
`hero`, `what_is_zerro`, `how_it_works`, `output`, `built_right`, `comparison`,
`the_shift`, `pricing`, `faq`, `final_cta`. (Use the section ids already present
for anchor nav where they exist.)

## 5. The remaining interaction events

- **`pricing_billing_toggled`** — in `components/templates/axis/pricing.tsx`, the
  `setBilling(option)` `onClick` (~line 254): also `track("pricing_billing_toggled", { interval: option })`.
- **`faq_opened`** — in `components/templates/axis/faq.tsx`, the `onToggle` (~line 90):
  fire `track("faq_opened", { question })` only when **opening** (not closing).
  Use the question text or a stable index as `question`.
- **`demo_played`** — in `components/templates/axis/hero.tsx`, the "Watch it work"
  control (~line 198): `track("demo_played")` on click.
- **Optional** `nav_link_clicked` (navbar anchor links, `{ target }`) and
  `outbound_clicked` (footer privacy/terms/support, `{ destination }`).

Do **not** instrument `/auth` (dormant, robots-disallowed).

## 6. Privacy policy

In `app/privacy/page.tsx`, the website-analytics section currently names Vercel
Analytics. Since Vercel is being removed, update it to disclose **PostHog** for
the website (anonymous product-usage metadata + heatmaps, **no session
recording**, no cross-site tracking cookies / cookieless). Keep the existing
app-side PostHog disclosure intact.

## 7. Env + verify
- Add `NEXT_PUBLIC_POSTHOG_KEY` and `NEXT_PUBLIC_POSTHOG_HOST` to `.env.local`
  (and note they must be set in Vercel project env for production).
- `npm run build` succeeds; `npm run dev` and confirm in the browser/PostHog
  Activity that `$pageview` fires on load and route change, `download_clicked`
  fires with the right `placement`, `section_viewed` fires once per section,
  and the toggle/FAQ/demo events fire. Confirm **no cookies** are set by PostHog
  and **no session recordings** appear.
- Show the final diff, confirm Vercel Analytics is fully removed, and list the
  events observed firing with their properties.
- Note: once `$pageview`s flow, PostHog's built-in **Web analytics** tab (in the
  shared project) will begin populating automatically — no dashboard work needed
  for traffic/sources/geo. The custom conversion events are surfaced separately.

```
SDK:     posthog-js — autocapture + manual $pageview, heatmaps on, replay off,
         cookieless (memory), identified_only. Vercel Analytics removed.
Events:  download_clicked{placement}, section_viewed{section},
         pricing_billing_toggled{interval}, faq_opened{question}, demo_played,
         (optional) nav_link_clicked{target}, outbound_clicked{destination}
```
