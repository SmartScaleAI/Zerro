# Zerro

Zerro is an open-source, bring-your-own-key (BYOK) AI assistant for macOS.
This monorepo contains the macOS app and the website at
[getzerro.app](https://getzerro.app).

## What Zerro does

You talk to Zerro while showing it your screen, and it turns what it saw
and heard into results. Zerro is BYOK: you supply your own API keys from
supported AI providers (Anthropic, OpenAI, and Google), and Zerro uses
your accounts to do the work.

## Repository layout

```
apps/
  desktop/   macOS app (Swift / Xcode). Open apps/desktop/Zerro.xcodeproj
  web/       Website at getzerro.app (Next.js). Deployed by Vercel
docs/        Cross-cutting docs
.github/     CI and release automation
```

## Building from source

Anyone may build and run Zerro from this source code under the GPL, free
of charge. No purchase is required to use, modify, or redistribute the
source code.

### macOS app

```bash
open apps/desktop/Zerro.xcodeproj
```

Build the Zerro scheme with a current Xcode. A self-built app is not
signed or notarized by SmartScale Solutions LLC and does not receive
official updates. Building for your own use requires no changes; if you
distribute builds to others, see [TRADEMARKS.md](TRADEMARKS.md).

### Website

```bash
cd apps/web
npm install
npm run dev
```

## Official builds

SmartScale Solutions LLC publishes the official signed and notarized
Zerro build:

- **$39 one-time.** A purchase covers all Zerro 1.x.x releases. A future
  Zerro 2.0 may require a new major-version purchase.
- **14-day trial**, no payment card required.
- **Two active Macs** per license. Lost-device activation resets are
  handled through [support@getzerro.app](mailto:support@getzerro.app).

The purchase pays for the official signed and notarized distribution,
updates, and support. It is never a legal requirement for using or
compiling the GPL-licensed source; self-built versions are always
permitted.

## Releases and updates

Official builds are produced from this repository, and GitHub hosts the
source code, the release downloads, and the Sparkle update feeds:

- [getzerro.app](https://getzerro.app) is the official download location
  for the signed and notarized build; it redirects `getzerro.app/Zerro.dmg`
  and `getzerro.app/appcast.xml` to the assets of the latest
  [GitHub Release](https://github.com/SmartScaleAI/Zerro/releases).
  Installed official builds check for updates through Sparkle.
- Pushing a production tag (`app-v<version>`) makes GitHub Actions build,
  sign, notarize, and staple the official DMG and publish it, together with
  its signed `appcast.xml`, as a GitHub Release.
- Staging builds are published as GitHub prereleases
  (`staging-v<version>`) whose update feed is the permanent
  `staging-channel` prerelease. They are not production releases.
- No DMG or appcast is stored in the repository.

## License

The source code in this repository is free software, licensed under the
**GNU General Public License, version 3 or (at your option) any later
version** (SPDX: `GPL-3.0-or-later`). See [LICENSE](LICENSE) for the full
license text.

Copyright © 2026 SmartScale Solutions LLC.

Third-party components and assets remain subject to their respective
licenses and terms; the Zerro GPL license does not replace those terms.
The licenses of the third-party components the app uses are reproduced
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Trademarks

"Zerro", the Zerro logos and icons, official branding, the getzerro.app
identity, the official bundle identifiers (including
`com.cbreeding.Zerro`), the `zerro://` URL scheme, and the official
signing and update identities are trademarks and brand assets of
SmartScale Solutions LLC. They are not covered by the GPL license for the
code, and the trademark policy does not limit your GPL rights to use,
modify, and build the code.

Private builds for your own use need no rebranding. Builds you
distribute to others must use their own name, icons, bundle identifiers,
URL scheme, signing identity, and update feed. Truthful references such
as "a fork of Zerro" are always fine. See [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Contributions are welcome under GPL-3.0-or-later with [DCO](DCO)
sign-off (`git commit -s`); this project does not currently require a
Contributor License Agreement. See [CONTRIBUTING.md](CONTRIBUTING.md)
for setup, branch, test, and privacy expectations, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards.

## Security

Report vulnerabilities privately via
[GitHub private vulnerability reporting](https://github.com/SmartScaleAI/Zerro/security/advisories/new)
or, as a fallback, [support@getzerro.app](mailto:support@getzerro.app).
Do not open public issues for security problems, and never include real
API keys, license keys, or recordings in a report. See
[SECURITY.md](SECURITY.md).
