# Zerro — SEO & AI-Discoverability Checklist

What was set up, how to verify it, and what to re-check after meaningful site changes.
All metadata uses native Next.js App Router primitives — no `next-seo`, no hand-rolled `<Head>`.

## What's in place

| Area | File | Notes |
| --- | --- | --- |
| Root metadata | `app/layout.tsx` | `title.template`, description, canonical, keywords, robots, OG/Twitter, Vercel Analytics |
| Homepage metadata | `app/page.tsx` | Server Component; `title.absolute`, own OG/Twitter, canonical `/` |
| Auth noindex | `app/auth/layout.tsx` | `robots: { index: false }` |
| Robots | `app/robots.ts` | Allow `/`, disallow `/auth`, explicit AI-crawler allow-list, sitemap ref |
| Sitemap | `app/sitemap.ts` | Homepage entry; static `LAST_MODIFIED` constant |
| Manifest | `app/manifest.ts` | PWA manifest (replaced the old static `site.webmanifest`) |
| OG image | `app/opengraph-image.tsx` | Dynamic `ImageResponse`, 1200×630 |
| Twitter image | `app/twitter-image.tsx` | Re-exports the OG image |
| Structured data | `components/structured-data.tsx` | Organization + WebSite (site-wide), SoftwareApplication + FAQPage (homepage) |
| New content | `components/templates/axis/{what-is-zerro,comparison,faq}.tsx` | Definition block, comparison table, FAQ |
| FAQ source of truth | `components/templates/axis/faq-data.ts` | Shared by the FAQ UI and FAQPage JSON-LD — keep in sync automatically |
| AI ingestion | `public/llms.txt`, `public/llms-full.txt` | Concise + full Markdown |

## Pre-launch checklist

Run a production build and serve it locally:

```bash
npm run build && npm run start   # serves on http://localhost:3000
```

Then verify (swap `localhost:3000` for `getzerro.app` once deployed):

- [ ] **All routes 200 with correct content-type**
  ```bash
  for r in "" robots.txt sitemap.xml manifest.webmanifest opengraph-image twitter-image llms.txt llms-full.txt; do
    printf "%-22s " "/$r"; curl -s -o /dev/null -w "%{http_code} %{content_type}\n" "http://localhost:3000/$r"
  done
  ```
  Expect: `/robots.txt`→text/plain, `/sitemap.xml`→application/xml, `/manifest.webmanifest`→application/manifest+json,
  `/opengraph-image` & `/twitter-image`→image/png, `/llms*.txt`→text/plain.

- [ ] **Metadata is server-rendered** (not injected client-side)
  ```bash
  curl -s http://localhost:3000/ | grep -iE "og:|twitter:|canonical|ld\+json|<title"
  ```
  Expect: `<title>`, canonical, og:image + twitter:image, and 4 `application/ld+json` blocks.

- [ ] **Auth page is noindex**
  ```bash
  curl -s http://localhost:3000/auth | grep -i 'name="robots"'   # -> noindex, nofollow
  ```

- [ ] **JSON-LD passes Google Rich Results Test** — paste the homepage HTML (or URL once live) into
  https://search.google.com/test/rich-results — expect Organization, SoftwareApplication, FAQPage detected, 0 errors.

- [ ] **OG card renders** — check https://www.opengraph.xyz/ (or X/Slack/LinkedIn preview) for `getzerro.app`.

- [ ] **Lighthouse** (Chrome installed):
  ```bash
  CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  npx lighthouse@latest http://localhost:3000/ \
    --only-categories=seo,performance,accessibility,best-practices \
    --chrome-flags="--headless=new" --view
  ```
  Baseline at handoff (local prod build): **SEO 100, Accessibility 100, Best Practices 100, Performance ~75**.
  Performance is held down mainly by `motion/react` (~188KB) loaded across the client section components;
  production CDN compression scores higher. To inspect the bundle: `ANALYZE=true npm run build`.

- [ ] **Post-deploy: submit sitemap** in Google Search Console (`https://getzerro.app/sitemap.xml`).

## After any meaningful content change, re-check

- [ ] If you changed product facts (pricing, features, platform): update **all three** in lockstep —
      the on-page copy, `components/structured-data.tsx` (SoftwareApplication offers/featureList),
      and `public/llms.txt` + `public/llms-full.txt`.
- [ ] If you edited the FAQ: only edit `components/templates/axis/faq-data.ts` — the visible FAQ and the
      FAQPage JSON-LD both read from it, so they stay in sync. Mirror the change into `llms-full.txt`.
- [ ] If you added a new page/route: add it to `app/sitemap.ts`, give it its own `metadata` export with a
      canonical, and bump `LAST_MODIFIED` in `app/sitemap.ts`.
- [ ] If you changed the tagline/brand: update `app/opengraph-image.tsx` (the social card art) and re-check the OG preview.
- [ ] Re-run the "Metadata is server-rendered" and Rich Results checks above.

## Outstanding / optional follow-ups

- **Google Search Console verification token** — placeholder is commented in `app/layout.tsx` (`verification`).
  Paste the token when you have it.
- **Organization `sameAs`** — omitted because the footer renders no social links. Add social URLs to
  `OrganizationJsonLd` in `components/structured-data.tsx` (and optionally wire `public/icons/*.svg` into the footer).
- **Performance** — if you want to push past ~75, the lever is replacing scroll-reveal `motion` with CSS
  `@keyframes` + `IntersectionObserver` in the purely-presentational sections. Separate effort; brand-feel tradeoff.
- **Comparison table** — competitor cells (`components/templates/axis/comparison.tsx`) are conservative/factual.
  Review periodically; competitor capabilities change.
