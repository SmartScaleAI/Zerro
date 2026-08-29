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
| `Zerro-<build>.dmg` | The immutable archive and the only enclosure the release's Sparkle feed references, so its recorded `edSignature`/`length` never change. |
| `Zerro.dmg` | A byte-identical stable "download latest" copy. |
| `appcast.xml` | The signed release-line Sparkle feed: this release plus the newest release of every other major version in the line, each on its tag-specific `https://github.com/SmartScaleAI/Zerro/releases/download/app-v<version>/Zerro-<build>.dmg` URL — for 1.0.0 / build 1000, exactly one item on `…/app-v1.0.0/Zerro-1000.dmg`. |

The GitHub release line begins at exactly **version 1.0.0, build 1000, tag
`app-v1.0.0`** (the workflow passes both the start build and start version to
the helper; build 1000 under another version or tag, or 1.0.0 under another
build, fails closed). A release's feed
carries **the newest release from each major version in the line**: a newer
release replaces the older item of its own major, and the final release of an
earlier major stays so that installs on that major keep being offered it (a
license covers every release of one major; `UpdateMajorPolicy` offers only the
installed major). Examples: 1.0.0 → `[1.0.0]`; 1.0.1 → `[1.0.1]`; the final
1.x then 2.0.0 → `[final 1.x, 2.0.0]`; 2.0.1 → `[final 1.x, 2.0.1]`. The first
release of the line composes from its own item alone; every later release
composes from its own item plus the previous release-line feed (the latest
release's `appcast.xml`, bound to that release's tag: the feed's newest item
must be exactly that release) and fails closed if that feed is missing,
invalid, or stale. Every retained prior-major item is verified against its own
release when the feed is composed and again, from freshly fetched data, right
before publication (published, not a prerelease, exactly one
`Zerro-<build>.dmg` in state `uploaded`, size equal to the recorded length).
Nothing before the line is ever read, so pre-line releases and tags are not
needed and can be removed.

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
`apps/web/public` or any routing change away from GitHub Releases. GitHub
is the only publication target: the workflow uploads nothing anywhere else,
and the CI `supabase-removal-guard` job fails a PR that reintroduces the
former Supabase Storage mirror, its scripts, or its service-role secret.

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
2. **Read release metadata** — the marketing version is the checked-in
   `apps/desktop/VERSION` (exactly `X.Y.Z`; the `app-v<X.Y.Z>` tag must name
   it) and the build number is the checked-in `apps/desktop/BUILD_NUMBER` (a
   positive integer bumped by hand, always above the newest published build,
   which Sparkle requires). `Scripts/release_metadata.py` validates both and
   fails the run if the Xcode project's `MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION` differ; dmg name `Zerro-<build>.dmg`.
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
7. **Prepare a draft GitHub Release** for the tag
   (`Scripts/github_release_publish.py prepare`). A published release for the
   tag fails the run (a re-cut is a deliberate manual act); a single existing
   draft is reused and repaired (target/title reset, every stale asset
   deleted); more than one draft is ambiguous and fails.
8. **Upload `Zerro-<build>.dmg` and the byte-identical `Zerro.dmg`** to the
   draft (same-name assets are replaced, never duplicated).
9. **Generate and upload the GitHub `appcast.xml`** to the draft. This
   release's own signed item is generated from the immutable
   `Zerro-<build>.dmg` alone (enclosure
   `releases/download/app-v<version>/Zerro-<build>.dmg`) and validated by
   `Scripts/appcast_publish_guard.py check` and
   `Scripts/appcast_github_feed.py verify`. `Scripts/appcast_release_line.py`
   then composes the release-line feed: for the first release, that item
   alone; for later releases, that item plus the newest item of every other
   major from the previous release-line feed, each retained item re-verified
   against its own release (published, `Zerro-<build>.dmg` present, size
   equal to the recorded length). Missing or invalid previous feeds fail
   closed; no other feed, inventory, or pin is consulted.
10. **Verify the draft** — exactly the three assets, each the local size and
    byte-identical after download, on a draft pinned to this commit; the
    downloaded feed re-passes every feed rule. A verification manifest is
    written.
11. **Publish** — only with that manifest, and only if the draft still
    matches it exactly: `draft=false` + `make_latest=true`, then confirm the
    release is `releases/latest`, then confirm the real tag ref names this
    commit. From here `getzerro.app/appcast.xml` and `getzerro.app/Zerro.dmg`
    resolve this release.
12. **Notify Slack** with the What's New notes (best-effort; skipped without
    the webhook secret).

### What a failure leaves behind

- **Before step 7:** nothing exists anywhere — no release and no draft.
- **Steps 7–10, or step 11 before its publish call:** a *draft* release for
  the tag (invisible to `releases/latest` and to the website's URLs). The
  previous latest release and both website URLs are unchanged. A same-tag
  re-run reuses and repairs that draft.
- **Step 11 after publication (the release did not become latest / the tag
  check failed):** the release is published and complete but the job fails;
  inspect before re-running. A same-tag re-run of the workflow fails closed
  at step 7 because the release is already published.
- **Step 12:** warning only; the release is already live.

### Staging (`release-staging.yml`)

Plain `staging-v<X.Y.Z>` tags build the **Zerro Staging** configuration side
by side with production. Every new staging release increments **both**
`apps/desktop/VERSION` and `apps/desktop/BUILD_NUMBER` — `staging-v1.0.0` /
build 1000, then `staging-v1.0.1` / build 1001, then `staging-v1.0.2` / build
1002, … — so each staging release shows one visible version and gets its own
tag; a tag is never moved or reused. The tag must name exactly the checked-in
`VERSION` of the tagged commit (build-qualified or otherwise decorated tags are
rejected), or the run fails before building; `BUILD_NUMBER` is validated and
checked against the Xcode project the same way. A manual run (Actions tab) is
allowed only from the `staging` branch and computes the tag from `VERSION`.
The workflow creates a versioned GitHub **prerelease** named
`Staging <X.Y.Z> (build <N>)` (`make_latest: false`, so it never becomes the
repository's "latest" release) with `ZerroStaging-<build>.dmg` (the immutable
archive), `ZerroStaging.dmg` (a byte-identical manual-download copy), and a
single-item `appcast-staging.xml` whose only enclosure is that immutable asset
— for 1.0.0 / build 1000, `releases/download/staging-v1.0.0/ZerroStaging-1000.dmg`.

The staging app's update feed is the permanent **`staging-channel`**
prerelease ("Staging Update Channel"), whose single asset
`appcast-staging.xml` is served at
`https://github.com/SmartScaleAI/Zerro/releases/download/staging-channel/appcast-staging.xml`
— the `SU_FEED_URL` in `Config/Staging.xcconfig`. After the versioned
prerelease and its three assets verify, `Scripts/staging_channel_publish.py`
replaces that asset with the release's verified feed, fail-closed: the channel
must be a published prerelease; the live feed is validated first; a newer
build may publish, an equal build only as a proven same-commit re-run with
identical bytes, and the channel never moves backwards; the candidate is
uploaded and verified before the stable asset is renamed aside and replaced,
with the previous feed restored on any failure; the run ends with exactly one
asset, downloaded again and re-validated.
The permanent channel is created only once, by a manual staging-branch run
with the `bootstrap_staging_channel` input set to true (off by default).
Anonymous Sparkle checks against the channel URL work only while the
repository is public. It never touches the website or the production feed.

Operational note: the already-released staging 1.0.0 (build 1000) was built
with a feed URL that is no longer served, so it cannot update itself from
GitHub. The first complete GitHub update test is
1.0.1 → 1.0.2: install 1.0.1 (built with the channel URL), publish 1.0.2, and
confirm the in-app update.

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
  number, not `1.0.2`. The build number is the checked-in
  `apps/desktop/BUILD_NUMBER`, bumped by hand in the change that ships it and
  always above the newest published build for the channel; the feed check
  refuses a build that is not the newest.
- **Deployment target is macOS 26.4** — if a release fails at build time, the
  runner's Xcode may be too old; bump the runner image / Xcode selection in the
  workflow.
- **Hardened runtime** is required for notarization and already `YES` in
  Release; the workflow re-asserts it.
- **Entitlements stay minimal** (currently audio input); extras can fail
  notarization.
- **The release line is self-contained.** A release's feed references only
  releases of the line (itself and the newest of each other major), so
  pre-line releases and tags are not required by the release workflow and can
  be removed independently.

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
