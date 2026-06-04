# Zerro — Full Release Automation (GitHub Actions)

You've already shipped versions by hand, so this is the **fully-automated** setup:
push a version tag and GitHub does everything — build, sign, notarize, publish the
download, and update the appcast on your website. Existing users auto-update.

```
# (in the Zerro app repo)
git tag v1.0.2 && git push --tags     # ← that's the whole release
```

---

## Your two repos and what lives where

| Repo | Purpose | What changes for automation |
|---|---|---|
| **`SmartScaleAI/smartscale-zerro`** (app repo) | The macOS app source | Gets the workflow file, the export options, the secrets, and the version tags. **Almost all setup happens here.** Each release's `.dmg` is stored on this repo's **Releases** page. |
| **`SmartScaleAI/smartscale-website`** (site repo) | The getzerro.app site, auto-deployed by Vercel | Receives **one automated commit per release**: the updated `appcast.xml`. You make **no manual changes** here for releases — the workflow pushes to it. The only setup touching it is granting a token permission (and confirming the appcast's path). |

**Keep them separate — do not merge.** They release on different cadences, binaries
don't belong in the site's git history, and the automation is designed to work across
the two.

```
  Zerro (app repo)                                smartscale-website (site repo)
  ┌────────────────────────────────┐             ┌──────────────────────────────┐
  │  you: git push tag v1.0.2      │             │  appcast.xml  (served at      │
  │      │                         │  workflow   │   getzerro.app/appcast.xml)   │
  │      ▼                         │  commits    │            │                  │
  │  GitHub Actions workflow ──────┼────────────▶│            ▼                  │
  │   build → sign → notarize      │  appcast    │  Vercel auto-deploys          │
  │   → staple → dmg → appcast     │             └──────────────────────────────┘
  │      │                         │
  │      ▼                         │
  │  GitHub Release (dmg asset)    │  ◀── users download the dmg from here
  └────────────────────────────────┘
```

### Why the dmg lives on Zerro's GitHub Releases (not in smartscale-website)

- **Old versions stay downloadable** — each release keeps its own asset URL. (Today you
  overwrite a single `Zerro.dmg`, which breaks anything still referencing the old one.)
- **smartscale-website stays tiny** — binaries don't belong in git; only the small
  `appcast.xml` text file crosses into it.
- **Enables Sparkle delta updates later**, which need old versions kept around.
- **Fewer credentials** — the workflow creates Releases in its own repo (Zerro)
  natively; only the appcast commit needs a cross-repo token.

Your app's `SUFeedURL` (`https://getzerro.app/appcast.xml`) does **not** change — only
where the dmg downloads *from* changes, and that's controlled by the appcast, so
existing users transition seamlessly.

---

## The two security systems (both automated)

| System | Purpose | Key used in CI | Stored as secrets in |
|---|---|---|---|
| **Apple Developer ID + notarization** | macOS opens the app without warnings | Developer ID cert (`.p12`) + App Store Connect API key | **Zerro** repo |
| **Sparkle EdDSA** | Users only install updates genuinely from you | Sparkle private key | **Zerro** repo |

The CI runner is a fresh cloud Mac with none of your keys, so each is stored once as
an encrypted GitHub Actions secret **in the Zerro repo** and loaded at runtime.
One-time setup; never touched per release.

---

## What the workflow does (all in the Zerro repo, except the last step)

Triggered by pushing a tag matching `v*` **to the Zerro repo**:

1. **Checkout** Zerro on a `macos-15` runner (recent enough for the macOS 26.4
   deployment target and Sparkle 2.9.2).
2. **Import the Developer ID cert** from the secret into a temporary keychain
   (destroyed when the job ends).
3. **Derive versions from the tag** — `v1.0.2` → marketing version `1.0.2`; build
   number = commit count (always increasing, which Sparkle requires).
4. **Archive & export** a Developer ID-signed `Zerro.app`.
5. **Verify** signature + hardened runtime (fails fast if misconfigured).
6. **Package** the `.dmg`.
7. **Notarize** via `notarytool --wait` using the App Store Connect API key; on
   failure it prints Apple's log naming the offending file.
8. **Staple** the ticket.
9. **Generate the signed appcast** with `generate_appcast` + the Sparkle private key,
   pointing the download URL at this tag's GitHub Release asset.
10. **Create the GitHub Release on Zerro** and upload the `.dmg`.
11. **Push `appcast.xml` to smartscale-website** (the only cross-repo step) → Vercel
    auto-deploys → `getzerro.app/appcast.xml` is live.

Nothing is published unless every prior step succeeds.

---

## One-time setup — which repo each step touches

Full click-by-click in `SETUP-GITHUB-ACTIONS.md`. Summary:

| Setup step | Repo |
|---|---|
| Commit `.github/workflows/release.yml`, `Scripts/ExportOptions.plist` | **Zerro** |
| Create all 8 secrets | **Zerro** → Settings → Secrets and variables → Actions |
| Create the fine-grained PAT (`SITE_REPO_TOKEN`) | GitHub account settings; scope it to **smartscale-website** with Contents: Read/Write; store it as a secret **in Zerro** |
| Confirm `SITE_APPCAST_PATH` matches where `appcast.xml` lives | look in **smartscale-website** (likely `public/appcast.xml`); set the value in the workflow file **in Zerro** |

Secrets to create **in the Zerro repo**: `DEVELOPER_ID_CERT_P12`,
`DEVELOPER_ID_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `AC_API_KEY_P8`, `AC_API_KEY_ID`,
`AC_API_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`, `SITE_REPO_TOKEN`.

**smartscale-website needs no secrets and no workflow.** It just receives a commit.

> **Back up your Sparkle private key before anything else.** Your public key is baked
> into shipped apps; if you lose the private key you can never sign an update existing
> users will accept. Export from your keychain into a password manager (Part 3 of the
> setup doc).

---

## Per-release flow (after setup)

```bash
# All in the Zerro app repo:
git tag v1.0.2
git push origin v1.0.2

# Watch Zerro → Actions tab. Green check =
#   • dmg published on Zerro → Releases
#   • appcast.xml committed to smartscale-website → Vercel deploys it
#   • users on older builds get offered the update
```

If a release fails, nothing is published. Fix, then re-tag:

```bash
git tag -d v1.0.2 && git push origin :v1.0.2   # remove the bad tag
git tag v1.0.2 && git push origin v1.0.2       # try again
```

---

## Notes specific to Zerro

- **Build number must always increase.** Sparkle compares the integer build number,
  not `1.0.2`. Last shipped build was `2`; the workflow derives builds from commit
  count, which is always higher and always increasing.
- **Deployment target is macOS 26.4** — if a release fails at build time, the runner's
  Xcode may be too old; bump the runner image / Xcode selection in the workflow.
- **Hardened runtime** is required for notarization and already `YES` in Release; the
  workflow re-asserts it.
- **Entitlements stay minimal** (currently audio input); extras can fail notarization.

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
