# Zerro local release diagnostic (`release.sh`)

`Scripts/release.sh` builds, signs, notarizes, staples, packages a `.dmg`, and
regenerates the signed Sparkle `appcast.xml` — all on your Mac — so the signing
and notarization chain can be debugged by hand. It stops before uploading:
official publication happens through the automated release workflow (see the
end of this document).

## One-time setup

You only do this section once.

### 1. Developer ID certificate in your keychain

You already sign with a **Developer ID Application** identity (the project is
configured for it). Confirm it's there:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If it's missing on this machine, export it from the Mac that has it
(Keychain Access → export the cert *and* its private key as a `.p12`) and import:

```bash
security import DeveloperID.p12 -k ~/Library/Keychains/login.keychain-db
```

### 2. App Store Connect API key (for notarization)

At App Store Connect → **Users and Access → Integrations → App Store Connect API**,
create a key with the **Developer** role. Download the `.p8` — **Apple lets you
download it only once.** Note the **Key ID** and the **Issuer ID** shown there.

Store the credentials in a notarytool keychain profile (the script expects a
profile named `Zerro-Notary`):

```bash
xcrun notarytool store-credentials "Zerro-Notary" \
    --key /path/to/AuthKey_XXXXXXXXXX.p8 \
    --key-id <KEY_ID> \
    --issuer <ISSUER_ID>
```

Keep the `.p8` itself in your password manager. Never commit it.

### 3. Sparkle command-line tools

`generate_appcast` and `sign_update` ship in the Sparkle **release archive**, not
the Swift package. Download the latest Sparkle release tarball
(https://github.com/sparkle-project/Sparkle/releases — match your integrated
version, 2.9.x) and place its `bin/` here:

```
Scripts/sparkle/bin/generate_appcast
Scripts/sparkle/bin/sign_update
Scripts/sparkle/bin/generate_keys
```

Committing a pinned copy keeps releases reproducible. (Or set `SPARKLE_BIN` to
wherever you keep them.)

### 4. Back up your Sparkle EdDSA private key (do not skip)

Your app's public key is already in `Info.plist`, so the private key is in your
login keychain. If you lose it you can never sign an update existing users accept.
Export and store it securely:

```bash
Scripts/sparkle/bin/generate_keys -x sparkle_private_key.txt
# move sparkle_private_key.txt into 1Password, then delete the file
```

## Cutting a release

```bash
./Scripts/release.sh <marketing_version> <build_number>
# example: bump human version to 1.0.2, Sparkle build number to 3
./Scripts/release.sh 1.0.2 3
```

- `build_number` is what Sparkle compares (`CURRENT_PROJECT_VERSION`). It must be
  a **positive integer** — digits only, no `0`, no sign, no decimals, no leading
  zeros — and it **must** exceed the latest published build (see the newest
  `Zerro-<build>.dmg` on the GitHub Releases page). The script refuses to go
  backwards.
- `marketing_version` is the cosmetic string (`MARKETING_VERSION`). It must be
  **exactly `X.Y.Z`** — three dot-separated integers with no prefix (`v`), no
  suffix (`-beta`), no missing component (`1.0`), and no leading zeros.
- Both values are validated by `Scripts/release_metadata.py validate` before the
  script touches anything; the same rules govern the checked-in files.
- The checked-in `apps/desktop/VERSION` and `apps/desktop/BUILD_NUMBER` are
  what the automated workflows ship (read through
  `Scripts/release_metadata.py`, which also checks that the Xcode project
  carries the same values). Pass the same numbers here; the script warns when
  they differ.

What the script does: preflight checks → version bump → archive → export
Developer ID app → verify signature + hardened runtime → build dmg → notarize
(waits, dumps the log on failure) → staple → Gatekeeper check → generate signed
appcast → print publish instructions.

Artifacts land in `dist/` (gitignored): `dist/Zerro.dmg` and `dist/appcast.xml`.

## After the script finishes

The local artifacts are for **testing the signing and update chain only**. The
official artifacts are the assets of the GitHub Release that
`.github/workflows/release-app.yml` creates (`Zerro-<build>.dmg`, `Zerro.dmg`,
and the signed release-line `appcast.xml` — this release plus the newest
release of each other major); `https://getzerro.app/Zerro.dmg`
and `https://getzerro.app/appcast.xml` redirect to those assets on the latest
release. Nothing built here should be uploaded anywhere public: the CI feed
references the release's immutable per-build GitHub URL, and a hand-published
feed or a mutable enclosure would break that contract.

1. **Test the update path** on the previously shipped build against a local or
   staging host (Sparkle only needs the feed URL to serve `dist/appcast.xml`).
2. **Ship through CI** when satisfied: bump `apps/desktop/VERSION` in the
   staging → main promotion PR (or run `Scripts/cut-release.sh <version>` from
   `main`). The `app-v<version>` tag triggers the release workflow.
3. If you commit the local version bump for bookkeeping, tag it `v1.0.2`, **not**
   `app-v1.0.2` — only `app-v*` tags trigger the CI release.

## Overridable settings (env vars)

| Var | Default | Purpose |
|---|---|---|
| `NOTARY_PROFILE` | `Zerro-Notary` | notarytool keychain profile name |
| `DOWNLOAD_URL_PREFIX` | `https://getzerro.app/` | Prefix for the appcast enclosure URL (local testing only; the CI feed uses immutable GitHub Release asset URLs) |
| `APPCAST_LINK` | `https://getzerro.app/` | "Find out more" link in the appcast |
| `SPARKLE_BIN` | `Scripts/sparkle/bin` | Where the Sparkle CLI tools live |

## Common notarization failures (and fixes)

- **"The binary is not signed with a valid Developer ID certificate"** — a nested
  binary/framework wasn't signed. Xcode usually handles this; if not, the
  Developer ID identity may be missing.
- **"The executable does not have the hardened runtime enabled"** — the Release
  config must have `ENABLE_HARDENED_RUNTIME = YES` (it does). The script also
  asserts this after export.
- **Entitlement rejected** — only declare entitlements you actually use. Zerro's
  entitlements currently declare audio input; add others (e.g. screen recording
  usage) as needed and keep them minimal.

When in doubt, read the notary log the script prints on failure — it names the
exact offending file.

## The automated release workflow

Official releases are cut by `.github/workflows/release-app.yml`, triggered by
`app-v*` tags (created by `auto-release.yml` on an `apps/desktop/VERSION` bump,
or manually via `Scripts/cut-release.sh`). See `RELEASE-AUTOMATION.md`. This
local script is a diagnostic for the signing/notarization chain only.
