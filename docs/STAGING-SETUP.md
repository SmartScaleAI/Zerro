# Staging environment + automated deploy pipeline — setup plan

Goal: you and a friend test new features against a **separate hosted backend**
before real users see them, **and** the whole deploy process is automated so you
spend your time implementing features, not running migrations / deploying
functions / cutting builds.

Decisions made:

- **Backend:** upgrade `SmartScale AI` to **Pro**; run `Zerro` as `main`
  (production) + a persistent **`staging`** branch.
- **App:** a side-by-side **`Zerro Staging.app`** with its own update feed.
- **Automation:** adopt the **Supabase GitHub integration** so DB + edge-function
  deploys happen automatically on git push/merge; **GitHub Actions** builds the
  apps. You push branches and approve releases — nothing else.

---

## 0. How "production branch + staging branch" maps to Supabase

In Supabase, **the project's base branch _is_ production** — you can't create or
reassign a separate production branch. `Zerro` already shows `main | PRODUCTION`.
So:

- **`main` (production)** — already exists; nothing to create.
- **`staging`** — one new **persistent** branch off `Zerro`: a fully isolated
  instance (own DB, Auth, Storage, Edge Functions, own API URL + keys).

That's the prod + staging split, and each is wired to a git branch of the same
name so deploys are driven by git (see §3–§4).

---

## 1. Why a separate instance (not "two envs on one database")

A Supabase instance has **one** DB, Auth pool, Storage, set of Edge Functions,
and set of secrets — there's no prod/staging switch inside one instance, by
design (it keeps a bad migration, a runaway `pg_cron` job, or a leaked secret off
production). A `staging` **branch** is a separate managed instance, which is what
gives real isolation. Faking it with a `staging` schema or `*-staging` function
copies means shared secrets/auth/storage and 10 duplicated functions to juggle.

---

## 2. The backend: Pro + a persistent `staging` branch

Verified current state: org `SmartScale AI` is **free**; projects `Zerro`
(`wjxqmurgwyxwkezncxke`) + `AI-Agency` (`rlbkeslfyxqimblomvit`). Branching
requires **Pro** — the `Create branch` button on Free routes to upgrade.

**Cost:** Pro base **$25/mo** (includes a $10 compute credit covering the prod
project's compute, **not** branch compute). The `staging` branch on Micro compute
is **$0.01344/hr ≈ $9.60/mo** always-on, and isn't under the spend cap. Target
total ≈ **$35/mo**.

> **Billing gotcha — do first:** an org can't mix free + paid projects, so
> upgrading makes `AI-Agency` billable (~$10/mo). **Pause `AI-Agency`** (no
> compute while paused; reversible, offline meanwhile) *before* upgrading, so Pro
> covers only `Zerro` + `staging`.

**Pro bonus for production:** your prod `Zerro` on Free has **no automated
backups** and a paused-DB risk; Pro adds daily backups, optional PITR, and no
auto-pause — worth having regardless.

---

## 3. The automated daily workflow (what your loop looks like)

Two git branches drive everything: `staging` (→ Supabase staging branch + staging
app) and `main` (→ production + prod app). You work in feature branches off
`staging`.

**Stage 0 — Local dev against staging (no Docker).** `git checkout staging &&
git checkout -b feature/x`. Your DEBUG build runs in Xcode pointed at the
**staging branch** (`ZERRO_FUNCTIONS_BASE_URL =
https://waripvlpcpwdmacpjiqc.supabase.co/functions/v1` in the scheme) — **no
local Supabase / Docker stack.**
- **App / Swift changes:** just Run (Cmd-R) — nothing to deploy.
- **Backend changes** (a function or a migration): push only that change to
  staging with one command — `supabase functions deploy <name> --project-ref
  waripvlpcpwdmacpjiqc` or `supabase db push --project-ref waripvlpcpwdmacpjiqc`
  — and your local app sees it immediately. Generate migrations with
  `supabase db diff`.
- *Trade-offs you've accepted:* a backend change needs that one deploy command
  (vs instant locally), staging is **shared with your friend**, and dev needs a
  network connection. You can still spin up Docker ad hoc if you ever want full
  isolation, but the default loop is staging.

**Stage 1 — Open a PR into `staging`.** *Automated:*
- Supabase spins up an **ephemeral preview branch** for the PR — applies
  migrations, deploys functions, seeds it — so the migration is validated on a
  throwaway hosted DB, torn down when the PR closes.
- GitHub Actions CI runs `ZerroTests`, `supabase db lint`, the curl tests, and a
  type-gen check. Red CI never reaches staging.

**Stage 2 — Merge the PR to `staging`.** *Automated:*
- Supabase applies the merged migrations + deploys functions to the **persistent
  staging branch** (config-as-code from `config.toml`).
- GitHub Actions builds + notarizes **`Zerro Staging.app`** (Staging config,
  pointed at the staging-branch URL) and publishes `appcast-staging.xml`.
- A few minutes later, the staging backend **and** your + your friend's staging
  app (via Sparkle) are current. You just open the app and test.

**Stage 3 — Promote to prod (the one gate).** In the `staging → main` PR, **bump
`apps/desktop/VERSION`** to the new marketing version (e.g. `1.4.18` → `1.4.19`),
then approve the PR (your single human "go"). On merge to `main`: *Automated:*
- Supabase deploys migrations + functions to **production**.
- `auto-release.yml` (triggered only by a change to `apps/desktop/VERSION` on
  `main`) reads the file and, if no `app-v<version>` tag exists yet, creates and
  pushes it with `RELEASE_PAT` → that tag push fires your existing
  `release-app.yml` → prod appcast → users auto-update. Merge a PR that doesn't
  touch `VERSION` and no release is cut; if `VERSION` is unchanged from the last
  shipped version, the tag already exists and the workflow skips cleanly.

> **The version bump _is_ the release decision.** Editing the `VERSION` line in
> the promotion PR is what cuts the build — there's no separate manual
> `git tag && git push`. `RELEASE_PAT` (not the default `GITHUB_TOKEN`) is
> required so the tag push is allowed to trigger `release-app.yml`. Introducing
> the file at the already-shipped version is a no-op, so adding it doesn't
> release anything — it just arms the next bump.

Net: branch → PR (preview + CI) → merge to staging (auto deploy + staging app) →
test → approve `staging→main` (auto prod deploy + app release). **Zero manual
`supabase` deploy commands.**

---

## 4. The two deploy engines (automated vs manual)

| Concern | Engine | Trigger | Manual? |
|---|---|---|---|
| DB migrations | Supabase GitHub integration | push/merge to a wired git branch | no |
| Edge functions | Supabase GitHub integration | push/merge (declared in `config.toml`) | no |
| Per-env config | `config.toml [remotes]` | push | no |
| Secrets | dotenvx-encrypted `.env.preview` / per-branch | push (set once) | set once, then no |
| Staging app build | GitHub Actions (`release-staging.yml`) | push to `staging` | no |
| Prod app build | GitHub Actions (`release-app.yml`, existing) | `app-v*` tag | auto-tagged by `auto-release.yml` |
| Prod app tag | GitHub Actions (`auto-release.yml`) | `apps/desktop/VERSION` change on `main` | no (bump the file in the PR) |
| Prod **release approval** | you | `staging → main` PR (bump `apps/desktop/VERSION`) | **yes (intentional gate)** |
| Secret rotation / LemonSqueezy live dashboard | you | — | **yes (security)** |

This **adopts the Supabase GitHub integration** (reversing the earlier
CLI-managed choice). Trade-off: it becomes the deploy system for DB + functions;
the tag-based workflow still owns the app. That's the swap that removes the manual
DB work.

On every push to a git branch wired to a Supabase branch, the integration runs:
Clone → Pull → Health → Configure (`config.toml`) → Migrate → Seed → Deploy
(functions + function secrets). Merging to the production git branch runs the same
against prod.

---

## 5. The staging app

### The constraint
The release build is hard-pinned to prod —
`apps/desktop/Zerro/Services/Managed/ManagedBackend.swift:43` hardcodes the prod
functions URL; the override is `#if DEBUG` only; and one Sparkle feed
(`Info.plist SUFeedURL = getzerro.app/appcast.xml`) serves every user. So today
there's no signed build that points elsewhere and no way to ship to just you two.

### Phase 1 — test today (no app changes)
DEBUG build with `ZERRO_FUNCTIONS_BASE_URL = <staging-branch URL>`; for your
friend, a signed DEBUG dmg with that env baked in. Good enough to start; no
auto-update, DEBUG-only paths.

### Phase 2 — the real side-by-side staging app (part of the automation)
1. **Backend URL build-time configurable** — add `Info.plist` key
   `ZerroFunctionsBaseURL`, set per-configuration via `.xcconfig`, read in
   `ManagedBackend.baseURL` (fallback = prod constant). Only source change.
2. **`Staging` build configuration** — `PRODUCT_BUNDLE_IDENTIFIER =
   com.cbreeding.Zerro.staging` (installs side-by-side), `ZerroFunctionsBaseURL` =
   staging URL (from a `STAGING_FUNCTIONS_URL` Actions variable), `SUFeedURL` =
   staging feed, distinct name/icon.
3. **Separate feed** `appcast-staging.xml`, hosted as a public object in the
   staging branch Storage (no website change; same signing key).
4. **`release-staging.yml`** — copy of `release-app.yml`, triggered on push to
   `staging`, builds the Staging config, uploads dmg + `appcast-staging.xml` to
   branch Storage. Prod stays on `app-v*`.

---

## 6. What we'll build — one-time setup checklist

Backend / Supabase:
- [ ] Pause `AI-Agency`; upgrade `SmartScale AI` to Pro (you, in dashboard).
- [ ] Connect the **Supabase GitHub integration** to `SmartScaleAI/smartscale-zerro`; set production branch = `main`.
- [ ] Create the persistent **`staging`** branch (I do this; cost confirmed first), wired to a `staging` git branch.
- [ ] `config.toml [remotes]` for `staging` + `production` (per-env config).
- [ ] Branch secrets via **dotenvx-encrypted** `.env.preview` (dev/test-mode keys, fresh `SESSION_JWT_SECRET`, LemonSqueezy **test** mode).
- [ ] Confirm `pg_cron` enabled on the branch; verify the 21 migrations + 10 functions landed; run the curl tests.

App / CI:
- [ ] Make the functions URL build-time configurable (`Info.plist` + `.xcconfig` + `ManagedBackend` patch).
- [ ] Add the `Staging` build config + `com.cbreeding.Zerro.staging` + staging feed.
- [x] `release-staging.yml` (staging app build → `appcast-staging.xml`) — triggers
      on `staging-v*` tags + manual dispatch; signs/notarizes the **Zerro Staging**
      scheme and upserts `ZerroStaging.dmg` + `appcast-staging.xml` to the staging
      `downloads` bucket. Does **not** touch the website or prod appcast.
- [ ] CI workflow: `ZerroTests` + `supabase db lint` + curl tests + type-gen check on PRs.
- [x] Release automation: `auto-release.yml` tags `app-v*` from `apps/desktop/VERSION` on `main` (PR approval + the version bump are the gate). Needs a `RELEASE_PAT` repo secret so the tag push triggers `release-app.yml`.
- [ ] Add `staging` long-lived git branch + branch-protection (PRs required).

Local DX (no Docker):
- [ ] Local DEBUG build points at staging by default (`ZERRO_FUNCTIONS_BASE_URL`
      in the Xcode scheme) — local Supabase/Docker stack retired.
- [ ] Seed a test license / trial into the staging DB so signed-in flows
      (generation, billing) work, since the branch starts empty.

---

## 7. Production vs staging reference

| Piece | Production (`main`) | Staging (branch) |
|---|---|---|
| Supabase backend | `wjxqmurgwyxwkezncxke` (`Zerro`, Pro) | persistent `staging` branch off `Zerro` |
| Functions base URL | hardcoded prod URL | branch URL (env in P1, build setting in P2) |
| App bundle id | `com.cbreeding.Zerro` | `com.cbreeding.Zerro.staging` |
| Sparkle feed | `getzerro.app/appcast.xml` | `appcast-staging.xml` on branch Storage |
| DB/function deploys | auto on merge to `main` | auto on merge to `staging` |
| App build | `release-app.yml` on `app-v*` | `release-staging.yml` on `staging-v*` tag |
| Deeplink scheme | `zerro://` (`DEEPLINK_SCHEME=zerro`) | `zerro-staging://` (`DEEPLINK_SCHEME=zerro-staging`) |
| Provider API keys / LemonSqueezy | live | dev keys / test mode (redirect → `zerro-staging://checkout-complete`) |

---

## 8. Sequence

1. Pause `AI-Agency`; upgrade `SmartScale AI` to **Pro** (you).
2. Connect Supabase GitHub integration; create the `staging` branch (I do this).
3. Wire `config.toml [remotes]` + encrypted branch secrets; verify the branch.
4. App side: configurable URL → `Staging` config + feed → `release-staging.yml`.
5. CI checks + `staging→main` auto-tag release automation.
6. From then on: branch → PR → merge to staging → test → approve to main. Done.

## Decisions

- **`main` = production** + one **persistent `staging` branch** + side-by-side
  **staging app**.
- **AI-Agency:** ✅ pause before upgrading.
- **Deploy workflow:** ✅ **GitHub-integrated** (Supabase integration + GitHub
  Actions) — full automation; supersedes the earlier CLI-managed choice.
- **Local dev:** ✅ runs against the **staging branch, no local Docker** — backend
  changes pushed with one `--project-ref` deploy command; staging doubles as the
  shared dev + test environment.

Still open:
- **Phase 1 first, then Phase 2?** (start testing on a DEBUG build while we build
  the automated staging app) — recommended.
- **Is your friend on Xcode at all?** If never, we skip straight to the signed
  staging app.

> Pausing `AI-Agency` and the Pro upgrade are billing actions you do in the
> dashboard — I can't initiate payment. Once you're on Pro + the GitHub
> integration is connected, I create the `staging` branch and wire the rest.
