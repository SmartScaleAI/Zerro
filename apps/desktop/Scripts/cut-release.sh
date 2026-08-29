#!/usr/bin/env bash
#
# cut-release.sh — trigger a CI release for Zerro by hand.
#
# Bumps the project's MARKETING_VERSION, commits it, tags the commit `app-v<version>`,
# and pushes both the commit and the tag. Pushing the tag triggers
# .github/workflows/release-app.yml, which builds, signs, notarizes, packages
# the .dmg, and publishes it with the signed Sparkle appcast as GitHub Release
# assets (getzerro.app/Zerro.dmg and getzerro.app/appcast.xml redirect to the
# latest release). Only `app-v*` tags trigger that workflow — a bare `v*` tag
# releases nothing.
#
# The STANDARD release path doesn't need this script: bump apps/desktop/VERSION
# in the staging → main promotion PR and .github/workflows/auto-release.yml
# creates the app-v* tag on merge. This script is the manual fallback for
# cutting a release directly from main. (Scripts/release.sh is the local
# release diagnostic: it builds and notarizes on your Mac for debugging the
# signing chain and never publishes.)
#
# The BUILD number is NOT set here: it is the checked-in apps/desktop/BUILD_NUMBER
# (bumped by hand, always above the newest published build), which CI reads
# together with apps/desktop/VERSION through Scripts/release_metadata.py. This
# script writes VERSION, keeps the Xcode project's MARKETING_VERSION in sync,
# and refuses to tag if the project and the two files disagree.
#
# Usage:
#   ./Scripts/cut-release.sh 1.0.3
#
# <marketing-version> must be exactly X.Y.Z — three dot-separated integers with
# no prefix, no suffix, no missing component, and no leading zeros — the same
# rule Scripts/release_metadata.py applies to apps/desktop/VERSION. Validation
# runs before any file is modified, committed, or tagged.
#
set -Eeuo pipefail

usage() { echo "usage: $0 <marketing-version>   e.g. $0 1.0.3   (exactly X.Y.Z)" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || usage

# Run from the repo root regardless of where the script is invoked.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# One rule set for every entry point: the same validation the release workflows
# apply to apps/desktop/VERSION. Fails here, before anything is touched.
python3 "$ROOT/Scripts/release_metadata.py" validate --marketing "$VERSION"

# release-app.yml triggers only on app-v* tags — a bare v* tag is a no-op.
TAG="app-v$VERSION"

# Pre-release gate: the version being cut must have a What's New entry in
# Changelog.swift, or the in-app pop silently skips this release (see
# docs/DEPLOY-RUNBOOK.md step 6). CI enforces the same check; failing here is
# just faster. Intentional internal-only release: ZERRO_ALLOW_NO_CHANGELOG=1.
python3 "$ROOT/Scripts/check_changelog_entry.py" --version "$VERSION"

# Must be on main.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: releases must be cut from 'main' (currently on '$BRANCH')" >&2
  exit 1
fi

# Working tree must be clean so unrelated changes don't get swept into the release commit.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree is dirty — commit or stash changes first" >&2
  git status --short >&2
  exit 1
fi

# Tag must not already exist (locally or on the remote).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi

# Stay current with the remote so the tag lands on the real tip of main.
git pull --ff-only origin main

echo "==> Bumping marketing version to $VERSION"
printf '%s\n' "$VERSION" > "$ROOT/VERSION"
( cd "$ROOT" && xcrun agvtool new-marketing-version "$VERSION" >/dev/null )
# VERSION, BUILD_NUMBER, and the Xcode project must agree before anything is tagged.
python3 "$ROOT/Scripts/release_metadata.py" check-project

# agvtool leaves nothing to commit if the version is unchanged.
if git diff --quiet; then
  echo "note: marketing version already $VERSION — tagging current HEAD"
else
  git commit -am "Release $VERSION"
fi

echo "==> Tagging $TAG"
git tag "$TAG"

echo "==> Pushing main + $TAG"
git push origin main
git push origin "$TAG"

echo "✅ Released $VERSION. CI (release-app.yml) is now building & deploying — watch the Actions tab."
