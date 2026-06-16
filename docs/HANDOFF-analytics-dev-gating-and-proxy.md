# Claude Code handoff — disable analytics in dev (app + website) + website reverse proxy

Two goals:
1. **Stop development builds from sending any analytics.** Only production should
   send to PostHog — for both the macOS app and the website. (The user is deleting
   the separate "Zerro-Development" PostHog project, so dev must send *nowhere*,
   not to a dev project.)
2. **Add a reverse proxy for the website** so ad-blockers don't drop events.

Keep diffs minimal and match existing code style.

---

## Part A — macOS app: disable PostHog entirely in DEBUG builds

File: `apps/desktop/Zerro/Observability/Analytics.swift`

Today DEBUG builds read `POSTHOG_API_KEY_DEBUG` and send to the dev project.
That project is going away, so DEBUG should initialize nothing (this disables
both product analytics AND PostHog error/crash tracking in dev — local crashes
still appear in Xcode/Console, just nothing is transmitted).

1. At the very top of `Analytics.start()` (right after the `guard !didStart`
   line), add an early return for DEBUG:
   ```swift
   #if DEBUG
   Log.crashReporting.notice("Analytics & error tracking disabled in DEBUG builds — nothing sent to PostHog during development.")
   return
   #endif
   ```
   Everything after it now runs in Release only. Because `didStart` stays `false`
   in DEBUG, `capture(...)`, `captureOnce(...)`, `setEnabled(...)`, and
   `CrashReporting.capture(...)` all no-op automatically — no other call sites need
   changing.

2. `readKey()` is now only ever called in Release, so its `#if DEBUG` branch is
   dead. Simplify it to always read the production key:
   ```swift
   private static func readKey() -> String? {
       Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
   }
   ```

3. File: `apps/desktop/Zerro/Info.plist` — remove the now-unused
   `POSTHOG_API_KEY_DEBUG` key (and its explanatory comment). Leave
   `POSTHOG_API_KEY` and `POSTHOG_HOST` as-is.

4. (Optional, only if trivially safe) the `#if DEBUG` branches in `channel()` /
   `environment()` are now dead code; you may simplify them to always return
   `"release"` / `"production"`, or leave them. Don't risk churn.

Verify: a DEBUG build logs the "disabled in DEBUG" line and sends no events
(confirm `didStart` stays false / no PostHog network requests). A Release build
is unchanged. Project builds.

> Note: the reverse proxy is **website-only** — a native app isn't affected by
> browser ad-blockers, so the app keeps talking to PostHog directly.

---

## Part B — website: don't send from dev/preview, and proxy through our domain

### B1. Host-guard the init (no events from localhost or Vercel previews)

File: `apps/web/app/providers.tsx` — in the `posthog.init` `useEffect`, before
`init`, bail out unless we're on the real production host. `NODE_ENV` is *not*
enough (Vercel preview deploys run production builds), so gate on hostname:

```ts
const allowedHosts = ["getzerro.app", "www.getzerro.app"];
if (!allowedHosts.includes(window.location.hostname)) return;
```

Put it alongside the existing `if (!key) return;` guard. Result: localhost and
`*.vercel.app` previews initialize nothing; only the live domain sends.

### B2. Reverse proxy via Next.js rewrites

**Check PostHog's current "Next.js reverse proxy" docs** for the exact rewrite
paths (they occasionally change, e.g. `/decide` → `/flags`, and the US asset
host). The known-good US-region setup:

File: `apps/web/next.config.ts` — **merge into the existing `rewrites()`** (there's
already a `/Zerro.dmg` rewrite — keep it). Order matters: the `static` rule must
come before the catch-all.
```ts
async rewrites() {
  return [
    // ...existing rewrites (e.g. /Zerro.dmg)...
    { source: "/ingest/static/:path*", destination: "https://us-assets.i.posthog.com/static/:path*" },
    { source: "/ingest/:path*", destination: "https://us.i.posthog.com/:path*" },
  ];
},
// add at top level of the config object:
skipTrailingSlashRedirect: true,
```

File: `apps/web/app/providers.tsx` — point the SDK at the proxy instead of the
direct host:
```ts
api_host: "/ingest",
ui_host: "https://us.posthog.com",
```
Remove the `NEXT_PUBLIC_POSTHOG_HOST` usage for `api_host` (it's now the relative
`/ingest` path). `NEXT_PUBLIC_POSTHOG_KEY` is still required (from Vercel env).

---

## Verify before finishing
- **App:** DEBUG build → "disabled in DEBUG" log, zero PostHog requests. Release
  build compiles unchanged. `POSTHOG_API_KEY_DEBUG` is gone from Info.plist.
- **Website:** `npm run build` passes. In `npm run dev` (localhost) → PostHog does
  **not** initialize and **no** network requests fire (host guard). When run as if
  on the production host, events POST to **`getzerro.app/ingest/...`** (your
  domain), not `us.i.posthog.com` — confirm in the Network tab. Events still land
  in PostHog.
- Show the final diff for both codebases and confirm: dev sends nothing (app +
  web), and website events route through `/ingest`.

```
App:     DEBUG builds disable PostHog entirely (analytics + error tracking).
         POSTHOG_API_KEY_DEBUG removed; only Release sends, to the prod project.
Website: init gated to getzerro.app / www.getzerro.app (no localhost/preview);
         events + assets proxied via /ingest (next.config rewrites);
         api_host:"/ingest", ui_host:"https://us.posthog.com".
```
