# Claude Code handoff — Retain appcast history + versioned dmgs (unblock the BYOK 1-year update window)

> **⚠️ PARTIALLY SUPERSEDED (2026-06-27).** The cumulative/versioned-dmg goal of
> this doc shipped, but the **appcast publish mechanism described below is no
> longer used.** The release no longer seeds from `origin/main:apps/web/public/appcast.xml`
> or commits/pushes the appcast to `main` (that push silently broke once `main`
> required PRs — see 1.4.19). The appcast is now **uploaded to Supabase Storage**
> (`downloads/appcast.xml`) and served at `getzerro.app/appcast.xml` via a Vercel
> rewrite; the cumulative feed is seeded over HTTP from the published feed. See
> `.github/workflows/release-app.yml` (steps "Generate signed appcast" /
> "Publish appcast to Supabase Storage") and `apps/web/next.config.ts`. Treat the
> "git fetch origin main / push to main" instructions here as historical only.

## TL;DR for the agent

Change the release pipeline so the published Sparkle appcast **keeps every past
release** and every release's `.dmg` lives at a **permanent, versioned URL**.
Right now the appcast lists only the newest build and the download object is
overwritten each release, so lapsed BYOK users get stranded on whatever build
they have installed instead of the last version they were entitled to.

**This is a CI + storage change only.** Do not modify any app Swift code — the
update-window logic is already correct and well-tested. You are fixing the data
the app receives, not the app.

---

## Background (why this is needed)

- BYOK is a $69 one-time license that includes **1 year of updates** measured
  from the license's `created_at`. After the year, the app keeps working but
  should only be offered builds that shipped **within** that year.
- The enforcement is `apps/desktop/Zerro/Services/Billing/UpdateWindowPolicy.swift`.
  Its `decide(...)` filters the appcast and, for a lapsed user, returns
  `.bestInWindow(index:)` — the highest-versioned item whose `<pubDate>` is
  inside the window. That is exactly the behavior we want.
- **That branch can never fire today**, because the appcast only ever has one
  item (the latest). A lapsed user therefore falls into `.noUpdate` ("you're up
  to date") while stuck on an old build, even when a newer in-window build
  existed.
- Already tracked in part as **L-07** in `docs/PRE_RELEASE_REVIEW_LOG.md`
  (mutable single-`Zerro.dmg` URL → no old-version retention + an appcast/dmg
  signature race). This change closes L-07 and unblocks the BYOK window together.

---

## What the pipeline does now (the problem)

All in `.github/workflows/release-app.yml`. Key facts:

- `APP_NAME` = `Zerro`; build number = `${{ steps.ver.outputs.build }}` (commit
  count, used as Sparkle `sparkle:version`); marketing version =
  `${{ steps.ver.outputs.marketing }}`.
- `DL_PREFIX = https://wjxqmurgwyxwkezncxke.supabase.co/storage/v1/object/public/downloads/`
- Published appcast path (`SITE_APPCAST_PATH`) = `apps/web/public/appcast.xml`,
  committed to `main`.

1. **Step "Upload notarized dmg to Supabase Storage"** uploads to
   `downloads/${APP_NAME}.dmg` (`downloads/Zerro.dmg`) with `x-upsert: true` —
   one object, overwritten every release. Only the latest dmg is ever
   downloadable, and after the next release build N's advertised signature is
   served by build N+1's bytes.

2. **Step "Generate signed appcast"** runs
   `generate_appcast --ed-key-file - --download-url-prefix "$DL_PREFIX" --link "https://getzerro.app/" -o dist/appcast.xml dist`
   over a `dist` dir that holds only the one new dmg → a single-item appcast.

3. **Step "Publish appcast to website (apps/web)"** `cp`s that single-item
   appcast over `apps/web/public/appcast.xml` on `main`, discarding all prior
   items.

Current published appcast (`apps/web/public/appcast.xml`) has one item: build
**238** / version **1.4.16**, enclosure `…/downloads/Zerro.dmg`.

---

## Target behavior

1. Each release uploads its dmg to a **permanent, immutable** object
   `downloads/Zerro-<build>.dmg` (e.g. `Zerro-238.dmg`). The appcast item for
   that build references this versioned URL.
2. The stable `downloads/Zerro.dmg` object is **still overwritten each release**
   (`x-upsert: true`), used **only** as the marketing "download latest" target.
   The appcast must **never** reference `Zerro.dmg`, so it carries no signature
   constraint.
3. The published appcast is **multi-item and cumulative** — each release appends
   its item and preserves every prior item (with correct `<pubDate>`,
   `length`, `edSignature`, and versioned enclosure URL).

---

## Required changes

### A. `.github/workflows/release-app.yml`

1. **Build dmg under its versioned name.** Ensure the dmg `generate_appcast`
   reads is named `dist/Zerro-${BUILD}.dmg` (generate_appcast derives each
   item's enclosure filename from the archive filename + `--download-url-prefix`).
   Rename/copy the built dmg accordingly before the generate step.

2. **Upload twice** in the Supabase upload step (keep the existing
   `SUPABASE_SERVICE_ROLE_KEY` security notes — no `set -x`, no token echo):
   - `downloads/Zerro-${BUILD}.dmg` — permanent, immutable (referenced by the
     appcast).
   - `downloads/Zerro.dmg` — overwrite, marketing latest-download only.

3. **Merge, don't regenerate, the appcast.** Before `generate_appcast`:
   - `git fetch origin main` and copy `origin/main:apps/web/public/appcast.xml`
     into `dist/appcast.xml` if it exists (the runner is on the **release tag**,
     so the up-to-date appcast must come from `main`, not the tag tree).
   - Run `generate_appcast` over `dist`. It appends the new item and preserves
     existing ones, reusing each prior item's recorded `length`/`edSignature`
     (it does **not** need the old dmgs present). Confirm the new item resolves
     to `${DL_PREFIX}Zerro-${BUILD}.dmg`.
   - Set `--maximum-versions` **explicitly** to a value that comfortably exceeds
     ~18 months of releases (so nothing inside a 1-year window is ever pruned);
     do not rely on the default. Verify the merge/prune behavior against the
     pinned Sparkle version's docs.

4. **Publish step** is otherwise unchanged (`cp dist/appcast.xml` →
   `apps/web/public/appcast.xml`, commit to `main`, keep the
   `git diff --cached --quiet` no-op guard) — it now carries full history.

### B. One-time migration (required for correctness)

The current published item (build 238) points at the mutable
`downloads/Zerro.dmg`. Once that object starts getting overwritten by future
"latest" uploads, 238's advertised signature will no longer match its bytes.
Fix it once:

1. Copy `downloads/Zerro.dmg` → `downloads/Zerro-238.dmg` (server-side copy, or
   re-upload **byte-identical** bytes — do not rebuild).
2. Edit `apps/web/public/appcast.xml` so build 238's `<enclosure url=...>` points
   at `…/downloads/Zerro-238.dmg`. Leave `length` and `edSignature` unchanged.
3. Commit that edit to `main`.

### C. Docs

- `apps/desktop/Scripts/RELEASE-AUTOMATION.md`: note the appcast is now
  multi-item, dmgs are versioned + retained, and `Zerro.dmg` is marketing-only.
- `docs/PRE_RELEASE_REVIEW_LOG.md`: mark **L-07** resolved (reference this
  change) and note it unblocks the BYOK update window.

---

## Do NOT touch

- `apps/desktop/Zerro/Services/Billing/UpdateWindowPolicy.swift` and its
  `bestInWindow` logic — correct; this change is what lets it run.
- `apps/desktop/Zerro/Services/Billing/LicenseService.swift` window math
  (`created_at + 1 year`) — correct.
- LemonSqueezy product config — license length is intentionally **unlimited**;
  the 1-year cap is client-derived, never an LS expiry.
- The web "Download" path / `/Zerro.dmg` rewrite in `apps/web` — confirm what it
  points at and leave it working unchanged.

---

## Verification

1. **Multi-item appcast.** After a test release, `apps/web/public/appcast.xml`
   contains the new item **plus** all prior items, each with a distinct
   `…/Zerro-<build>.dmg` enclosure and correct `<pubDate>`.
2. **Immutable old URLs.** `curl -I` each historical enclosure → `200`; a later
   release does not change those bytes.
3. **Signatures match.** Advertised `length`/`edSignature` match the object at
   each versioned URL (re-check with `sign_update`).
4. **Lapsed-user path.** `UpdateWindowPolicyTests` (and a manual
   `UpdateWindowPolicy.decide` over a straddling multi-item appcast) returns
   `.bestInWindow` pointing at the newest in-window build — not `.noUpdate`.
5. **Marketing download intact.** The web "Download" button still serves the
   latest dmg.
6. **Idempotent CI.** Re-running a release doesn't duplicate items or corrupt
   the appcast; an unchanged appcast still no-ops.

---

## References

- `.github/workflows/release-app.yml` — upload / generate-appcast / publish steps
- `apps/web/public/appcast.xml` — current single-item appcast (build 238)
- `apps/desktop/Zerro/Services/Billing/UpdateWindowPolicy.swift` — policy unblocked by this
- `apps/desktop/ZerroTests/UpdateWindowPolicyTests.swift` — multi-item expectations
- `docs/PRE_RELEASE_REVIEW_LOG.md` — L-07
- `apps/desktop/Scripts/RELEASE-AUTOMATION.md` — release flow doc to update
- Sparkle — Publishing an update: https://sparkle-project.org/documentation/publishing/
