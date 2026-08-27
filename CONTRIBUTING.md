# Contributing to Zerro

Thanks for your interest in contributing. This document covers how to
report issues, set up the repository, and submit changes.

## Reporting bugs and requesting features

- **Bugs:** open a [bug report](https://github.com/SmartScaleAI/Zerro/issues/new?template=bug_report.yml)
  with your Zerro version, macOS version, and reproduction steps.
- **Features:** open a [feature request](https://github.com/SmartScaleAI/Zerro/issues/new?template=feature_request.yml)
  describing the problem before the solution.
- **Security vulnerabilities:** never open a public issue. Follow
  [SECURITY.md](SECURITY.md) instead.

### Privacy in issues and pull requests

Zerro records the screen and microphone, so it is easy to leak private
data by accident. Before attaching anything to a public issue or PR:

- Redact prompts, screenshots, and recordings that show private
  information (names, emails, messages, documents, other apps).
- Never paste API keys, provider credentials, or license keys, even
  expired ones.
- Scrub logs of tokens, keys, file paths that identify you, and anything
  else you would not publish.

## Setting up the repository

The root [README](README.md) is the authoritative guide to the repo
layout and builds. In short:

- **macOS app:** `open apps/desktop/Zerro.xcodeproj` and build the Zerro
  scheme with a current Xcode.
- **Website:** `cd apps/web && npm install && npm run dev`.
- **`supabase/`** is archived legacy backend material kept for
  reference; it is not required to build or run Zerro.

## Branches and pull requests

- Target the `staging` branch with your pull request.
- Keep each PR focused on one change; do not mix unrelated refactors
  into a fix.
- Fill in the pull request template, including the privacy/security
  impact section.
- Maintainers review PRs as time permits; small, well-described PRs are
  reviewed fastest.

## Tests

Run the checks relevant to what you touched, and add tests for new
behavior:

- **macOS app:** run the `ZerroTests` test suite in Xcode.
- **Website (`apps/web`):** `npm run lint`, `npm run typecheck`, and
  `npm test`.

CI on the pull request must be green before merge.

## Developer Certificate of Origin (sign-off)

This project uses the [Developer Certificate of Origin 1.1](DCO)
(from <https://developercertificate.org/>). This project does not
currently require a Contributor License Agreement.

Every commit in a pull request must be signed off, which certifies the
DCO for that contribution:

```bash
git commit -s
```

This appends a `Signed-off-by: Your Name <your@email>` trailer to the
commit message. Use a real name and a reachable email address.

## Licensing of contributions

- Contributions are accepted under the project license,
  **GPL-3.0-or-later** (see [LICENSE](LICENSE)).
- **You retain the copyright** to your contributions; you license them to
  the project and everyone else under GPL-3.0-or-later. Nothing is
  assigned or transferred to SmartScale Solutions LLC.
- Submitting code does not grant you any rights to the Zerro trademarks
  or branding, and does not transfer any trademark rights to anyone. See
  [TRADEMARKS.md](TRADEMARKS.md).
- SmartScale Solutions LLC maintains the official Zerro releases and
  branding and decides what ships in official builds.
