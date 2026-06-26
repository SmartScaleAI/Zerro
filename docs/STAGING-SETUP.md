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

**Stage 0 — Local (fast inner loop).** `git checkout staging && git checkout -b
feature/x`. Write Swift + migrations + functions. One command (`make dev` /
`justfile`) boots `supabase start` + `functions serve`; a DEBUG build points at
`127.0.0.1`. Generate migrations with `supabase db diff`, not by hand. *Nothing to
deploy — all local.*

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

**Stage 3 — Promote to prod (the one gate).** Open a `staging → main` PR and
approve it (your single human "go"). On merge to `main`: *Automated:*
- Supabase deploys migrations + functions to **production**.
- A release action bumps the version, pushes the `app-v*` tag → your existing
  release workflow → prod appcast → users auto-update.

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
| Prod app build | GitHub Actions (`release-app.yml`, existing) | `app-v*` tag | auto-tagged on `main` merge |
| Prod **release approval** | you | `staging → main` PR | **yes (intentional gate)** |
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
- [ ] `release-staging.yml` (staging app build → `appcast-staging.xml`).
- [ ] CI workflow: `ZerroTests` + `supabase db lint` + curl tests + type-gen check on PRs.
- [ ] Release automation: auto-tag `app-v*` on `staging → main` merge (keep the PR approval as the gate).
- [ ] Add `staging` long-lived git branch + branch-protection (PRs required).

Local DX:
- [ ] `make dev` / `justfile` to boot the local stack + serve in one command.

---

## 7. Production vs staging reference

| Piece | Production (`main`) | Staging (branch) |
|---|---|---|
| Supabase backend | `wjxqmurgwyxwkezncxke` (`Zerro`, Pro) | persistent `staging` branch off `Zerro` |
| Functions base URL | hardcoded prod URL | branch URL (env in P1, build setting in P2) |
| App bundle id | `com.cbreeding.Zerro` | `com.cbreeding.Zerro.staging` |
| Sparkle feed | `getzerro.app/appcast.xml` | `appcast-staging.xml` on branch Storage |
| DB/function deploys | auto on merge to `main` | auto on merge to `staging` |
| App build | `release-app.yml` on `app-v*` | `release-staging.yml` on push to `staging` |
| Provider API keys / LemonSqueezy | live | dev keys / test mode |

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

Still open:
- **Phase 1 first, then Phase 2?** (start testing on a DEBUG build while we build
  the automated staging app) — recommended.
- **Is your friend on Xcode at all?** If never, we skip straight to the signed
  staging app.

> Pausing `AI-Agency` and the Pro upgrade are billing actions you do in the
> dashboard — I can't initiate payment. Once you're on Pro + the GitHub
> integration is connected, I create the `staging` branch and wire the rest.
