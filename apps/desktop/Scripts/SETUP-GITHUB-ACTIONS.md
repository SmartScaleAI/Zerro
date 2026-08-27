# One-Time Setup — GitHub Actions Release Automation

Do this once. Afterwards every release is an `apps/desktop/VERSION` bump in the
staging → main promotion PR (`auto-release.yml` tags `app-v<version>` on merge
and `release-app.yml` builds it) — or, as a manual fallback,
`git tag app-vX.Y.Z && git push origin app-vX.Y.Z`.

Everything lives in **this** repository (`SmartScaleAI/smartscale-zerro`): the
workflows under `.github/workflows/`, the secrets, the version tags, and the
GitHub Releases that publish the artifacts. The getzerro.app site is `apps/web`
in the same repo; it redirects `getzerro.app/appcast.xml` and
`getzerro.app/Zerro.dmg` to the latest release's assets, so no site repository,
site token, or appcast commit exists. See `RELEASE-AUTOMATION.md` for the
overview of what the workflow does.

Budget ~45 minutes the first time.

> **Before anything: back up your Sparkle private key (Part 3 shows how).** If you
> lose it you can never sign an update your existing users will accept.

---

## Part 0 — Confirm the workflow's config

Open `.github/workflows/release-app.yml` and check the `env:` block:

```yaml
  SCHEME: Zerro
  CONFIGURATION: Release
  APP_NAME: Zerro
  BUNDLE_ID: com.cbreeding.Zerro
  TEAM_ID: H6NWCRRAHV
  SPARKLE_VERSION: "2.9.2"   # must match the app's pinned Sparkle
```

These already match the project. The public URLs the site serves are pinned in
`apps/web/lib/release-routes.ts` and need no per-release change.

---

## Part 1 — Developer ID certificate (`.p12`) → 3 secrets  *(on: your Mac)*

Your Apple signing identity. Already in your Mac's keychain (you've shipped before).

1. Open **Keychain Access** → **login** keychain → **My Certificates**.
2. Find **Developer ID Application: … (H6NWCRRAHV)**. Expand the disclosure triangle —
   confirm a private key sits underneath.
3. Right-click the certificate → **Export…** → save as `DeveloperID.p12`, set a
   password — remember it.
4. Base64-encode for storage:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy     # now in your clipboard
   ```
5. In the repo → **Settings → Secrets and variables → Actions → New repository
   secret**, create:
   - `DEVELOPER_ID_CERT_P12` → paste the base64 blob
   - `DEVELOPER_ID_CERT_PASSWORD` → the password from step 3
   - `KEYCHAIN_PASSWORD` → any random string (locks the runner's temp keychain)
6. Delete `DeveloperID.p12` from disk.

---

## Part 2 — App Store Connect API key (`.p8`) → 3 secrets  *(on: appstoreconnect.apple.com)*

Lets the runner notarize without your Apple ID password.

1. Go to **App Store Connect → Users and Access → Integrations → App Store Connect
   API** (https://appstoreconnect.apple.com/access/integrations/api).
2. Create a key with the **Developer** role.
3. **Download the `.p8`** — Apple allows the download **once**. Save it safely.
4. Note the **Key ID** (beside the key) and **Issuer ID** (top of page).
5. In the repo → secrets, create:
   - `AC_API_KEY_P8` → full contents of the `.p8`:
     ```bash
     pbcopy < AuthKey_XXXXXXXXXX.p8
     ```
     (Include the `-----BEGIN PRIVATE KEY-----` lines.)
   - `AC_API_KEY_ID` → the Key ID
   - `AC_API_ISSUER_ID` → the Issuer ID
6. Keep the `.p8` in your password manager.

---

## Part 3 — Sparkle private key → 1 secret  *(on: your Mac)*

The EdDSA key that signs updates. It's in your login keychain (its public half is
already in the app's Info.plist).

1. Get the Sparkle CLI tools: download `Sparkle-2.9.2.tar.xz` from
   https://github.com/sparkle-project/Sparkle/releases and unpack. Tools are in `bin/`.
2. Export your existing private key:
   ```bash
   ./bin/generate_keys -x sparkle_private_key.txt
   ```
   (Exports the existing key from the keychain; it does not create a new one.)
3. In the repo → secrets, create:
   - `SPARKLE_PRIVATE_KEY` → contents of `sparkle_private_key.txt`
4. **Store `sparkle_private_key.txt` in your password manager** (this is the backup),
   then delete the file from disk.

> Sanity check: this key must match the `SUPublicEDKey` in the app's Info.plist
> (`IV0J9TIWJpe/dL5A/8NvDhfmsjZatlrJA1NPnmX2xiE=`). A later "signature mismatch" on a
> test client means the wrong key was exported.

---

## Part 4 — Release tag token → 1 secret  *(create in: GitHub account settings)*

`auto-release.yml` pushes the `app-v<version>` tag when a `VERSION` bump merges
to `main`. A tag pushed with the workflow's own `GITHUB_TOKEN` would not trigger
`release-app.yml` (GitHub suppresses workflow runs from token-pushed refs), so
the push uses a personal access token.

1. GitHub → avatar → **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. Configure:
   - **Resource owner:** **SmartScaleAI** (the org — not your personal account).
   - **Repository access:** Only select repositories → **smartscale-zerro**
   - **Permissions:** Repository permissions → **Contents: Read and write**
   - **Expiration:** your call (e.g. 1 year; set a rotation reminder)
3. Generate and copy the token (approve it under the org's pending PAT requests
   if the org requires approval).
4. In the repo → secrets, create:
   - `RELEASE_PAT` → the token

Manual `git tag app-vX.Y.Z && git push origin app-vX.Y.Z` from your own machine
needs no token beyond your normal push access.

---

## Part 5 — Storage compatibility-mirror secrets → 2 secrets  *(in: Supabase dashboard)*

After the GitHub Release is published, the release workflows also mirror the
dmg and feed to Supabase Storage for clients that read the Storage objects
directly (see `RELEASE-AUTOMATION.md`). The uploads authenticate with each
project's service-role key:

- `SUPABASE_SERVICE_ROLE_KEY` → production project, used by `release-app.yml`
- `STAGING_SERVICE_ROLE_KEY` → staging project, used by `release-staging.yml`

Both come from the project's **Settings → API** page. They are full-access keys:
never echo them, and rotate them if they are ever exposed.

---

## Part 6 — Optional secrets and variables

The release succeeds without these; each step skips or degrades cleanly when
its value is unset.

- `SLACK_RELEASE_WEBHOOK_URL` (secret) — Slack Incoming Webhook for the
  `#releases` channel; the release workflow's final step posts the version's
  What's New notes there.
- `POSTHOG_CLI_API_KEY` (secret) — lets the archive step's dSYM-upload build
  phase send symbol files to PostHog.
- `APPCAST_ASSET_PINS` (repository **variable**, not a secret) — only needed
  when the same `Zerro-<build>.dmg` is attached to two releases (a re-cut).
  Space-separated `Zerro-<build>.dmg=app-v<version>` entries tell the
  GitHub-hosted feed which release each ambiguous asset belongs to; the
  workflow fails closed until the pin exists.

---

## Part 7 — Commit the automation files

Make sure these are on `main`:

- `.github/workflows/release-app.yml`, `release-staging.yml`, `auto-release.yml`
- `apps/desktop/Scripts/ExportOptions.plist`
- `apps/desktop/Scripts/github_release_publish.py`, `appcast_github_feed.py`,
  `appcast_publish_guard.py`, `publish_storage_release.py`,
  `verify_release_tag.sh`, `verify_release_source.sh`

The Sparkle CLI tools are downloaded (and checksum-verified) by the workflow at
runtime — nothing to commit for that.

---

## Final checklist

**Settings → Secrets and variables → Actions:**

Required for a production release:

- [ ] `DEVELOPER_ID_CERT_P12`
- [ ] `DEVELOPER_ID_CERT_PASSWORD`
- [ ] `KEYCHAIN_PASSWORD`
- [ ] `AC_API_KEY_P8`
- [ ] `AC_API_KEY_ID`
- [ ] `AC_API_ISSUER_ID`
- [ ] `SPARKLE_PRIVATE_KEY`
- [ ] `RELEASE_PAT` (auto-release tagging)
- [ ] `SUPABASE_SERVICE_ROLE_KEY` (Storage compatibility mirror)

Staging releases additionally need:

- [ ] `STAGING_SERVICE_ROLE_KEY`

Optional:

- [ ] `SLACK_RELEASE_WEBHOOK_URL`
- [ ] `POSTHOG_CLI_API_KEY`
- [ ] `APPCAST_ASSET_PINS` (variable; only for a re-cut build)

---

## Your first automated release

1. Bump `apps/desktop/VERSION` in the staging → main promotion PR and merge it
   (or, manually from `main`: `git tag app-v1.0.2 && git push origin app-v1.0.2`).
2. Watch the **Actions** tab. Green check means:
   - GitHub Release `app-v1.0.2` carries `Zerro-<build>.dmg`, `Zerro.dmg`, and
     `appcast.xml`, and
   - `getzerro.app/appcast.xml` and `getzerro.app/Zerro.dmg` resolve to those
     assets (the site redirects to `releases/latest/download/…`).
3. **Test once:** on a Mac with an older build installed, open Zerro → Check for
   Updates… → confirm it finds, verifies, downloads, installs.

### If a release fails

The release is built and uploaded to a *draft* GitHub Release, which is
invisible to `releases/latest` and to the website's URLs; it is published and
marked latest only after all three assets verify. A failure before that point
leaves only the draft (a same-tag re-run repairs it); a failure in the Storage
compatibility mirror afterwards fails the job without invalidating the
already-published release. See "What a failure leaves behind" in `RELEASE-AUTOMATION.md`. Read
the failing step's log in the Actions tab. Common first-run issues:

- **Notarization rejected** — the workflow prints Apple's log naming the exact file.
  Usually a missing entitlement or unsigned nested binary.
- **No signing identity found** — `DEVELOPER_ID_CERT_P12` base64 or its password is
  wrong.
- **Tag does not target this commit** — the `app-v*` tag already exists at a
  different commit; delete and re-push it (below).
- **Feed check failed** — the built build is not the newest in the cumulative
  feed (the tag is on an old or duplicate commit), or a re-cut build needs an
  `APPCAST_ASSET_PINS` entry.

Retry an unpublished version by re-running the workflow (it repairs the draft)
or by deleting and re-pushing the tag:
```bash
git tag -d app-v1.0.2 && git push origin :app-v1.0.2
git tag app-v1.0.2 && git push origin app-v1.0.2
```
If the release was already published, delete it deliberately first.

---

## Local release diagnostic

`Scripts/release.sh` (documented in `Scripts/README-release.md`) builds, signs,
and notarizes on your Mac so the signing chain can be debugged by hand. It never
publishes anything; official releases come only from the automated workflow.
