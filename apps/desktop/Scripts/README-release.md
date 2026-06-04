# Releasing Zerro — Phase 1 (local script)

`Scripts/release.sh` builds, signs, notarizes, staples, packages a `.dmg`, and
regenerates the signed Sparkle `appcast.xml` — all on your Mac. It stops before
uploading and prints exactly what to publish + the git tag to push.

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

- `build_number` is what Sparkle compares (`CURRENT_PROJECT_VERSION`). It **must**
  be higher than the last shipped build (currently `2`). The script refuses to go
  backwards.
- `marketing_version` is the cosmetic string (`MARKETING_VERSION`).

What the script does: preflight checks → version bump → archive → export
Developer ID app → verify signature + hardened runtime → build dmg → notarize
(waits, dumps the log on failure) → staple → Gatekeeper check → generate signed
appcast → print publish instructions.

Artifacts land in `dist/` (gitignored): `dist/Zerro.dmg` and `dist/appcast.xml`.

## After the script finishes

1. **Test the update path** on the previously shipped build before going live.
2. **Publish** `Zerro.dmg` and `appcast.xml` to `getzerro.app` (via the site repo /
   Vercel) so these URLs serve the new files:
   - `https://getzerro.app/Zerro.dmg`
   - `https://getzerro.app/appcast.xml`
3. **Commit + tag:**
   ```bash
   git add -A
   git commit -m "Release 1.0.2 (build 3)"
   git tag v1.0.2
   git push && git push --tags
   ```

## Overridable settings (env vars)

| Var | Default | Purpose |
|---|---|---|
| `NOTARY_PROFILE` | `Zerro-Notary` | notarytool keychain profile name |
| `DOWNLOAD_URL_PREFIX` | `https://getzerro.app/` | Prefix for the appcast enclosure URL |
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

## Next: Phase 2 (GitHub Actions)

Once a release goes out cleanly with this script, the same steps lift into a
tag-triggered GitHub Actions workflow on a `macos-latest` runner. That needs the
cert as a base64 `.p12` secret, the ASC API key as secrets, and the Sparkle
private key as a secret. Ask and I'll write it.
