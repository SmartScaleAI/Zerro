#!/usr/bin/env bash
#
# verify_release_source.sh — fail-closed check that a production release is
# cut from the production release branch AND that its workflow files match
# GitHub's default branch.
#
# Usage:
#   verify_release_source.sh <commit-sha> <release-branch-ref> <default-branch-ref>
#
#   <release-branch-ref>  the production release branch (origin/main): the
#                         release commit must be CONTAINED in it.
#   <default-branch-ref>  GitHub's default branch for the repository
#                         (origin/<github.event.repository.default_branch>):
#                         .github/workflows at the release commit must be
#                         IDENTICAL to this branch's. The default branch does
#                         not have to contain the release commit; the two refs
#                         may also be the same branch.
#
# Why two refs: GitHub's release API compares a release's target commit
# against the repository's DEFAULT branch, and rejects the workflow's
# GITHUB_TOKEN ("Resource not accessible by integration") when that commit
# modifies workflow files relative to it — GITHUB_TOKEN cannot be granted the
# workflow-write permission that would allow it. The production release branch
# (main) and the default branch are separate concerns, so each is checked
# against its own ref. Without this check the rejection would surface only at
# the publication step, after the full build.
#
# All checks use the local Git history: the caller fetches both refs first;
# this script performs no network access and writes nothing. A missing
# argument, an unknown commit, an unresolvable ref, a commit not contained in
# the release branch, or any workflow-tree difference fails with a non-zero
# exit and a ::error:: line.
#
set -euo pipefail

USAGE='usage: verify_release_source.sh <commit-sha> <release-branch-ref> <default-branch-ref>'
SHA="${1:?$USAGE}"
RELEASE_REF="${2:?$USAGE}"
DEFAULT_REF="${3:?$USAGE}"
WORKFLOWS=':/.github/workflows'   # top-level pathspec, valid from any subdirectory

case "$DEFAULT_REF" in
  */|origin/) echo "::error::default-branch ref '${DEFAULT_REF}' is incomplete — the repository's default branch name is missing (github.event.repository.default_branch was empty?). Refusing to guess."; exit 1 ;;
esac

if ! git cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  echo "::error::release commit ${SHA} is not a commit in this checkout."
  exit 1
fi
if ! git rev-parse --verify --quiet "${RELEASE_REF}^{commit}" >/dev/null; then
  echo "::error::production release branch ref ${RELEASE_REF} is not available in this checkout — fetch it before running this check (refusing to guess)."
  exit 1
fi
if ! git rev-parse --verify --quiet "${DEFAULT_REF}^{commit}" >/dev/null; then
  echo "::error::GitHub default branch ref ${DEFAULT_REF} is not available in this checkout — fetch it before running this check (refusing to guess)."
  exit 1
fi

RELEASE_SHA="$(git rev-parse "${RELEASE_REF}^{commit}")"
DEFAULT_SHA="$(git rev-parse "${DEFAULT_REF}^{commit}")"

if ! git merge-base --is-ancestor "$SHA" "$RELEASE_SHA"; then
  echo "::error::release commit ${SHA} is not contained in the production release branch ${RELEASE_REF} (${RELEASE_SHA}). Production releases are cut only from main: merge the change to main and release from there."
  exit 1
fi

if ! git diff --quiet "$DEFAULT_SHA" "$SHA" -- "$WORKFLOWS"; then
  echo "::error::.github/workflows at release commit ${SHA} differs from GitHub's default branch ${DEFAULT_REF} (${DEFAULT_SHA}). GitHub's release API rejects the workflow's GITHUB_TOKEN when the release's target commit modifies workflow files relative to the repository's default branch (GITHUB_TOKEN cannot be granted workflow-write), so this release would fail at publication after the full build. Land the workflow changes on ${DEFAULT_REF#origin/} first, or release a commit whose workflows match it:"
  git --no-pager diff --stat "$DEFAULT_SHA" "$SHA" -- "$WORKFLOWS" || true
  exit 1
fi

echo "Release commit ${SHA} is contained in the production release branch ${RELEASE_REF} (${RELEASE_SHA}) and its .github/workflows match GitHub's default branch ${DEFAULT_REF} (${DEFAULT_SHA}) — release source OK."
