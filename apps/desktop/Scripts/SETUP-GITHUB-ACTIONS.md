# One-Time Setup — GitHub Actions Release Automation

Do this once. Afterwards every release is `git tag vX.Y.Z && git push --tags` (in the
**Zerro** app repo).

**Repo map — where everything happens:**

- **`SmartScaleAI/smartscale-zerro`** (app repo) → the workflow file, ALL 8 secrets, version
  tags. Every part below happens here unless it says otherwise.
- **`SmartScaleAI/smartscale-website`** (site repo) → you change **nothing** in it. It is
  only *referenced*: the cross-repo token (Part 4) is scoped to it, and you *look* at
  it once (Part 0) to confirm where `appcast.xml` lives. The workflow will commit to
  it automatically on each release.

Budget ~45 minutes the first time.

> **Before anything: back up your Sparkle private key (Part 3 shows how).** If you
> lose it you can never sign an update your existing users will accept.

---

## Part 0 — Confirm the workflow's config  *(edit in: Zerro · look at: smartscale-website)*

Open `.github/workflows/release.yml` **in the Zerro repo** and check the `env:` block:

```yaml
  SITE_REPO: SmartScaleAI/smartscale-website        # ✓ already set to your site repo
  SITE_APPCAST_PATH: public/appcast.xml         # ← confirm this one
```

To confirm `SITE_APPCAST_PATH`: open the **smartscale-website** repo and find where the
current `appcast.xml` file sits (the path that Vercel serves at
`https://getzerro.app/appcast.xml`). For most Vercel projects (Next.js, Vite, plain
static) that's `public/appcast.xml`. If yours differs (e.g. `static/appcast.xml` or
root `appcast.xml`), set the value accordingly — the edit itself is made in the
workflow file **in Zerro**.

The rest (`SCHEME`, `BUNDLE_ID`, `TEAM_ID`) already match the project.

---

## Part 1 — Developer ID certificate (`.p12`) → 3 secrets  *(on: your Mac · secrets in: Zerro)*

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
5. In **Zerro** → **Settings → Secrets and variables → Actions → New repository
   secret**, create:
   - `DEVELOPER_ID_CERT_P12` → paste the base64 blob
   - `DEVELOPER_ID_CERT_PASSWORD` → the password from step 3
   - `KEYCHAIN_PASSWORD` → any random string (locks the runner's temp keychain)
6. Delete `DeveloperID.p12` from disk.

---

## Part 2 — App Store Connect API key (`.p8`) → 3 secrets  *(on: appstoreconnect.apple.com · secrets in: Zerro)*

Lets the runner notarize without your Apple ID password.

1. Go to **App Store Connect → Users and Access → Integrations → App Store Connect
   API** (https://appstoreconnect.apple.com/access/integrations/api).
2. Create a key with the **Developer** role.
3. **Download the `.p8`** — Apple allows the download **once**. Save it safely.
4. Note the **Key ID** (beside the key) and **Issuer ID** (top of page).
5. In **Zerro** → secrets, create:
   - `AC_API_KEY_P8` → full contents of the `.p8`:
     ```bash
     pbcopy < AuthKey_XXXXXXXXXX.p8
     ```
     (Include the `-----BEGIN PRIVATE KEY-----` lines.)
   - `AC_API_KEY_ID` → the Key ID
   - `AC_API_ISSUER_ID` → the Issuer ID
6. Keep the `.p8` in your password manager.

---

## Part 3 — Sparkle private key → 1 secret  *(on: your Mac · secret in: Zerro)*

The EdDSA key that signs updates. It's in your login keychain (its public half is
already in the app's Info.plist).

1. Get the Sparkle CLI tools: download `Sparkle-2.9.2.tar.xz` from
   https://github.com/sparkle-project/Sparkle/releases and unpack. Tools are in `bin/`.
2. Export your existing private key:
   ```bash
   ./bin/generate_keys -x sparkle_private_key.txt
   ```
   (Exports the existing key from the keychain; it does not create a new one.)
3. In **Zerro** → secrets, create:
   - `SPARKLE_PRIVATE_KEY` → contents of `sparkle_private_key.txt`
4. **Store `sparkle_private_key.txt` in your password manager** (this is the backup),
   then delete the file from disk.

> Sanity check: this key must match the `SUPublicEDKey` in the app's Info.plist
> (`IV0J9TIWJpe/dL5A/8NvDhfmsjZatlrJA1NPnmX2xiE=`). A later "signature mismatch" on a
> test client means the wrong key was exported.

---

## Part 4 — Cross-repo token → 1 secret  *(create in: GitHub account settings · scope to: smartscale-website · store in: Zerro)*

The workflow commits `appcast.xml` into **smartscale-website**, a different repo, so it
needs explicit permission. This is the only setup item involving the site repo.

1. GitHub → avatar → **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. Configure:
   - **Resource owner:** **SmartScaleAI** (the org — NOT your personal account; the
     dropdown lists both. If SmartScaleAI isn't in the dropdown, the org needs to
     allow fine-grained PATs: org **Settings → Third-party Access → Personal access
     tokens** → allow access via fine-grained tokens.)
   - **Repository access:** Only select repositories → **smartscale-website**
   - **Permissions:** Repository permissions → **Contents: Read and write**
   - **Expiration:** your call (e.g. 1 year; set a rotation reminder)
3. Generate and copy the token. (If the org requires PAT *approval*, an org owner —
   you — must approve it under org Settings → Personal access tokens → Pending
   requests before it works.)
4. In **Zerro** → secrets, create:
   - `SITE_REPO_TOKEN` → the token

Note the asymmetry: the token is *scoped to* smartscale-website but *stored in* Zerro,
because it's Zerro's workflow that uses it. **smartscale-website itself gets no secrets and
no workflow.**

---

## Part 5 — Commit the automation files  *(in: Zerro)*

Make sure these are committed and pushed to Zerro's main branch:

- `.github/workflows/release.yml`
- `Scripts/ExportOptions.plist`  (already in the repo)

The Sparkle CLI tools are downloaded fresh by the workflow at runtime — nothing to
commit for that.

---

## Final checklist

**In Zerro → Settings → Secrets and variables → Actions** (8 secrets):

- [ ] `DEVELOPER_ID_CERT_P12`
- [ ] `DEVELOPER_ID_CERT_PASSWORD`
- [ ] `KEYCHAIN_PASSWORD`
- [ ] `AC_API_KEY_P8`
- [ ] `AC_API_KEY_ID`
- [ ] `AC_API_ISSUER_ID`
- [ ] `SPARKLE_PRIVATE_KEY`
- [ ] `SITE_REPO_TOKEN`

**In Zerro's workflow file:** `SITE_REPO` = `SmartScaleAI/smartscale-website` ✓ and
`SITE_APPCAST_PATH` confirmed against where the file actually lives in smartscale-website.

**In smartscale-website:** nothing to do. ✓

---

## Your first automated release  *(in: Zerro)*

1. Commit and push the workflow + Scripts to main.
2. Tag and push:
   ```bash
   git tag v1.0.2
   git push origin v1.0.2
   ```
3. Watch **Zerro → Actions** tab. Green check means:
   - the dmg is on **Zerro → Releases** (that tag's assets), and
   - **smartscale-website** received an automated `appcast.xml` commit → Vercel deployed →
     `getzerro.app/appcast.xml` is live.
4. **Test once:** on a Mac with an older build installed, open Zerro → Check for
   Updates… → confirm it finds, verifies, downloads, installs.

### If a release fails

Nothing is published unless the whole job succeeds (publish steps run last). Read the
failing step's log in Zerro → Actions. Common first-run issues:

- **Notarization rejected** — the workflow prints Apple's log naming the exact file.
  Usually a missing entitlement or unsigned nested binary.
- **No signing identity found** — `DEVELOPER_ID_CERT_P12` base64 or its password is
  wrong.
- **Push to site repo denied** — `SITE_REPO_TOKEN` lacks Contents: write on
  smartscale-website, or it expired.

Retry the same version by deleting and re-pushing the tag (in Zerro):
```bash
git tag -d v1.0.2 && git push origin :v1.0.2
git tag v1.0.2 && git push origin v1.0.2
```

---

## Leftovers from the earlier manual phase

`Scripts/release.sh` and `Scripts/README-release.md` (in Zerro) were the manual/local
path. Keep as a fallback or delete — your call. `RELEASE-AUTOMATION.md` is the
overview of this automated setup.
