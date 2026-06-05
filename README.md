# Zerro

Monorepo for Zerro — the macOS app and its marketing/download website.

## Layout

```
apps/
  desktop/   macOS app (Swift / Xcode). Open apps/desktop/Zerro.xcodeproj
  web/       Marketing site at getzerro.app (Next.js). Deployed by Vercel
supabase/    Shared backend: edge functions, migrations, config
docs/        Cross-cutting docs (backend, SEO checklist)
.github/     CI — release-app.yml builds, signs & publishes the macOS app
```

## Desktop app

```bash
open apps/desktop/Zerro.xcodeproj
```

Releases are automated: push a tag like `app-v1.0.7` and GitHub Actions
builds, signs, notarizes, publishes the dmg as a GitHub Release asset, and
commits the updated Sparkle `appcast.xml` to `apps/web/public/` (which Vercel
then deploys). See `apps/desktop/Scripts/RELEASE-AUTOMATION.md`.

## Website

```bash
cd apps/web
npm install
npm run dev
```

Vercel deploys `apps/web` (Root Directory setting) on pushes to `main` that
touch web files. The `/Zerro.dmg` download URL is a rewrite to the latest
GitHub Release asset — the dmg is not stored in this repo.

## History

Merged from two repos on 2026-06-05 with full history
(`smartscale-zerro` → `apps/desktop`, `smartscale-zerro-website` → `apps/web`).
The original repos are archived.
