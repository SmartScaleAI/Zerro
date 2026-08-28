# Zerro — Release Automation (GitHub Actions)

Releases are fully automated: a version bump (or a pushed tag) makes GitHub
Actions build, sign, notarize, staple, package the dmg, sign the Sparkle feed,
and publish. Existing users auto-update.

```
# Standard path: bump apps/desktop/VERSION in the staging → main promotion PR;
# auto-release.yml tags app-v<version> on merge and release-app.yml builds it.
#
# Manual fallback (from main):
./apps/desktop/Scripts/cut-release.sh 1.0.2        # or by hand:
git tag app-v1.0.2 && git push origin app-v1.0.2   # only app-v* tags trigger a release
```

---

## Where the artifacts live

**GitHub Releases on `SmartScaleAI/Zerro` are the canonical public
source for every official artifact.** Each production release (`app-v<version>`)
carries exactly three assets:

| Asset | Purpose |
|---|---|
| `Zerro-<build>.dmg` | The immutable archive. It is the only enclosure the Sparkle feed references, so every past release's recorded `edSignature`/`length` stays valid and old builds remain downloadable. |
| `Zerro.dmg` | A byte-identical stable "download latest" copy. |
| `appcast.xml` | The cumulative, signed Sparkle feed. Every release appends its `<item>` and preserves all prior ones; each enclosure is a tag-specific `https://github.com/SmartScaleAI/Zerro/releases/download/app-v<version>/Zerro-<build>.dmg` URL. |

The website (`apps/web`, deployed by Vercel) owns the two stable public URLs
and redirects each to the matching asset on the latest release
(`releases/latest/download/<asset>`), so neither URL ever changes:

- `https://getzerro.app/appcast.xml` — the `SUFeedURL` baked into installed
  apps → `…/releases/latest/download/appcast.xml`
- `https://getzerro.app/Zerro.dmg` — the marketing download link →
  `…/releases/latest/download/Zerro.dmg`

The routing contract is `apps/web/lib/release-routes.ts`; `next.config.ts`
installs it, `apps/web/lib/release-routes.test.ts` verifies it, and the CI
`release-routing-guard` job rejects any static `appcast.xml`/`Zerro.dmg` under
`apps/web/public` or any routing change away from GitHub Releases.

**Storage compatibility mirror.** After the GitHub Release is published, the
workflow also upserts the same dmg and feed into the public Supabase Storage
`downloads` bucket (`Zerro-<build>.dmg`, `Zerro.dmg`, `appcast.xml`) for
clients that read the Storage objects directly. The mirror is guarded so its
objects can never move backwards. It is not what the website routes to.

### Why one repo, and why the dmg lives on GitHub Releases

- **Old versions stay downloadable** — every release keeps its own permanent
  `Zerro-<build>.dmg`; the stable `Zerro.dmg` is marketing-only and never
  referenced by the feed, so overwriting it can't strand anyone.
- **Binaries don't belong in git** — the site and the app share this monorepo,
  but no dmg or appcast is ever committed; CI enforces it.
- **Fewer credentials** — the workflow creates the release in its own repo
  with the job's `GITHUB_TOKEN`; no cross-repo token exists.
- **Enables Sparkle delta updates later**, which need old versions kept around.

The app's `SUFeedURL` (`https://getzerro.app/appcast.xml`) never changes — only
where the dmg downloads *from* is controlled by the appcast, so existing users
transition seamlessly.

---

## The two security systems (both automated)

| System | Purpose | Key used in CI | Stored as |
|---|---|---|---|
| **Apple Developer ID + notarization** | macOS opens the app without warnings | Developer ID cert (`.p12`) + App Store Connect API key | GitHub Actions secrets |
| **Sparkle EdDSA** | Users only install updates genuinely from you | Sparkle private key | GitHub Actions secret |

The CI runner is a fresh cloud Mac with none of your keys, so each is stored
once as an encrypted GitHub Actions secret and loaded at runtime. One-time
setup (`SETUP-GITHUB-ACTIONS.md`); never touched per release.

---

## What `release-app.yml` does

Triggered by a pushed tag matching `app-v*` (or a manual run with a version):

1. **Checkout** on a `macos-26` runner (Xcode 26.4.x, required for the
   macOS 26.4 deployment target and Sparkle 2.9.2).
2. **Derive versions** — `app-v1.0.2` → marketing version `1.0.2`; build
   number = commit count (always increasing, which Sparkle requires); dmg
   name `Zerro-<build>.dmg`.
3. **Preflight gates** — the release tag must resolve to the checked-out
   commit; the commit must be contained in `origin/main` (the production
   release branch) and its `.github/workflows` must be identical to GitHub's
   default branch (`github.event.repository.default_branch`, which need not
   be `main` or contain the commit — GitHub's release API rejects the workflow
   token for a commit whose workflow files differ from the default branch,
   and `GITHUB_TOKEN` cannot be granted workflow-write);
   and `Changelog.swift` must carry a What's New entry for the version (or the
   commit carries `[no-changelog]`).
4. **Import the Developer ID cert** into a temporary keychain (destroyed when
   the job ends) and **fetch the pinned Sparkle tools** (checksum-verified).
5. **Archive & export** a Developer ID-signed `Zerro.app` as an official
   build, then **verify** the official marker, the version, the signature, and
   the hardened runtime.
6. **Package** the dmg, **notarize** via `notarytool --wait`, and **staple**.
7. **Generate the cumulative signed appcast** with `generate_appcast` and the
   Sparkle private key, seeded from the currently published feed so every
   prior item is preserved, and check it (versioned enclosure present, newest
   build, no mutable URL).
8. **Prepare a draft GitHub Release** for the tag
   (`Scripts/github_release_publish.py prepare`). A published release for the
   tag fails the run (a re-cut is a deliberate manual act); a single existing
   draft is reused and repaired (target/title reset, every stale asset
   deleted); more than one draft is ambiguous and fails.
9. **Upload `Zerro-<build>.dmg` and the byte-identical `Zerro.dmg`** to the
   draft (same-name assets are replaced, never duplicated).
10. **Build and upload the GitHub-hosted `appcast.xml`** to the draft — the
    same feed with every enclosure rewritten to its immutable release-asset
    URL, validated by `Scripts/appcast_github_feed.py` (every historical item
    must map to exactly one published release asset; the only draft counted
    is this run's own; signatures and lengths are preserved verbatim).
11. **Verify the draft** — exactly the three assets, each the local size and
    byte-identical after download, on a draft pinned to this commit; the
    downloaded feed re-passes every feed rule. A verification manifest is
    written.
12. **Publish** — only with that manifest, and only if the draft still
    matches it exactly: `draft=false` + `make_latest=true`, then confirm the
    release is `releases/latest`, then confirm the real tag ref names this
    commit. From here `getzerro.app/appcast.xml` and `getzerro.app/Zerro.dmg`
    resolve this release.
13. **Storage compatibility mirror** — after a monotonic guard against the
    live objects, upsert the dmgs and feed into Supabase Storage and verify
    them.
14. **Notify Slack** with the What's New notes (best-effort; skipped without
    the webhook secret).

### What a failure leaves behind

- **Before step 8:** nothing exists anywhere — no release, no draft, no
  Storage change.
- **Steps 8–11, or step 12 before its publish call:** a *draft* release for
  the tag (invisible to `releases/latest` and to the website's URLs). The
  previous latest release and both website URLs are unchanged. A same-tag
  re-run reuses and repairs that draft.
- **Step 12 after publication (the release did not become latest / the tag
  check failed):** the release is published and complete but the job fails;
  inspect before re-running.
- **Step 13 (Storage compatibility mirror):** the workflow fails, but the
  GitHub Release is already complete, verified, published, and latest — it is
  not invalidated. Only the mirror's Storage objects need repair (re-run the
  failed uploads by hand). A same-tag re-run of the workflow fails closed at
  step 8 because the release is already published.
- **Step 14:** warning only; the release is already live.

### Staging (`release-staging.yml`)

`staging-v*` tags build the **Zerro Staging** configuration side by side with
production. The workflow creates a GitHub **prerelease** (`make_latest: false`,
so it never becomes the repository's "latest" release) with
`ZerroStaging-<build>.dmg`, `ZerroStaging.dmg`, and `appcast-staging.xml`, then
publishes the immutable dmg and feed to the staging Supabase project's Storage
bucket, which is the staging app's feed. It never touches the website or the
production feed.

---

## Per-release flow (after setup)

```bash
# Standard: bump apps/desktop/VERSION in the staging → main promotion PR.
# auto-release.yml tags app-v<version> on merge; release-app.yml builds it.

# Manual fallback (from main):
git tag app-v1.0.2
git push origin app-v1.0.2

# Watch the Actions tab. Green check =
#   • GitHub Release app-v1.0.2 carries Zerro-<build>.dmg, Zerro.dmg, appcast.xml
#   • getzerro.app/appcast.xml and getzerro.app/Zerro.dmg resolve to those assets
#   • the Storage compatibility mirror was updated to match
#   • users on older builds get offered the update
```

If a release fails before publication (see "What a failure leaves behind"),
only a draft exists. Fix the cause, then either re-run the workflow for the
same tag (it repairs the draft) or re-tag:

```bash
git tag -d app-v1.0.2 && git push origin :app-v1.0.2   # remove the bad tag
git tag app-v1.0.2 && git push origin app-v1.0.2       # try again
```

If it fails *after* publication, the GitHub Release is live; delete it (and
the tag) deliberately before re-cutting the same version.

---

## Notes specific to Zerro

- **Build number must always increase.** Sparkle compares the integer build
  number, not `1.0.2`. The workflow derives builds from commit count, which is
  always higher and always increasing, and the feed check refuses a build that
  is not the newest.
- **Deployment target is macOS 26.4** — if a release fails at build time, the
  runner's Xcode may be too old; bump the runner image / Xcode selection in the
  workflow.
- **Hardened runtime** is required for notarization and already `YES` in
  Release; the workflow re-asserts it.
- **Entitlements stay minimal** (currently audio input); extras can fail
  notarization.
- **A build attached to two releases** (a re-cut) is resolved for the
  GitHub-hosted feed only by the `APPCAST_ASSET_PINS` repository variable
  (`Zerro-<build>.dmg=app-v<version> …`), reviewed by the owner.

---

## Sources

- Sparkle — Publishing an update: https://sparkle-project.org/documentation/publishing/
- Automating Xcode Sparkle releases with GitHub Actions:
  https://medium.com/@alex.pera/automating-xcode-sparkle-releases-with-github-actions-bd14f3ca92aa
- Automatic code-signing & notarization with GitHub Actions:
  https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/
- GitHub: installing Apple certificates on macOS runners:
  https://docs.github.com/en/actions/deployment/deploying-xcode-applications/installing-an-apple-certificate-on-macos-runners-for-xcode-development
- Notarize with notarytool:
  https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
