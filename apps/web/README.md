# Zerro website

The marketing and download site at [getzerro.app](https://getzerro.app),
built with Next.js, React, and Tailwind CSS. Deployed by Vercel.

## Development

```bash
npm install
npm run dev        # local dev server
```

## Checks

```bash
npm run typecheck  # TypeScript
npm run lint       # ESLint
npm test           # unit tests (node --test over lib/**/*.test.ts)
npm run build      # production build
```

## Structure

```
app/                  Routes: home, /privacy, /terms, /checkout-complete,
                      plus sitemap, robots, manifest, and OG/Twitter images
components/
  marketing/          Home-page sections (hero, features, pricing, FAQ,
                      navbar, footer, ...)
  legal/              Shared shell for the privacy and terms pages
  ui/                 Reusable primitives (shadcn/ui-style)
  theme/              Theme provider and toggles
lib/                  Site config, analytics, and shared utilities
public/               Static assets (logo, videos, favicons, llms.txt)
```

## Adding UI components

shadcn/ui components can be generated into `components/ui`:

```bash
npx shadcn@latest add button
```

## Third-party notices

The licenses of the site's production dependencies are reproduced in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), generated from the
dependency tree:

```bash
npm run notices        # regenerate after dependency changes
npm run notices:check  # verify the file matches the lockfile
```
