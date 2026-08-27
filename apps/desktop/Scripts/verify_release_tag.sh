#!/usr/bin/env bash
#
# verify_release_tag.sh — fail-closed check that a release tag names the
# commit the workflow actually built.
#
# Usage:
#   verify_release_tag.sh <tag> <expected-commit-sha> <preflight|postrelease> <event-name>
# Env: GH_TOKEN (or GITHUB_TOKEN) and GITHUB_REPOSITORY. Needs `gh` and `jq`,
# both present on GitHub-hosted runners.
#
# The check reads the REAL Git ref (repos/…/git/ref/tags/<tag>, an exact
# match) and peels annotated tag objects down to the commit they name; it never
# trusts the release's `target_commitish` metadata, which only records what the
# release was created against. Only a genuine HTTP 404 from that endpoint means
# "no such tag"; any other failure (bad credentials, rate limit, network) is
# treated as unknown and fails the run, because a release must never proceed on
# a guess.
#
#   preflight    Before the expensive build. An existing tag must resolve to
#                the checked-out commit. A missing tag is allowed only for a
#                workflow_dispatch run, where the release step creates it
#                pinned to this commit via target_commitish.
#   postrelease  After the release step. The tag must exist and resolve to
#                the checked-out commit.
#
set -euo pipefail

TAG="${1:?usage: verify_release_tag.sh <tag> <expected-commit-sha> <preflight|postrelease> <event-name>}"
EXPECTED="${2:?expected commit sha}"
MODE="${3:?preflight|postrelease}"
EVENT="${4:-}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# Resolve a tag to the commit it ultimately names. Prints the commit sha.
# Exit 0 = resolved; 44 = the tag does not exist (genuine 404); anything else
# = could not determine, which the caller must treat as a failure.
resolve_tag_commit() {
  local tag="$1" out type sha hops=0
  if ! out="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${tag}" 2>&1)"; then
    if grep -q "(HTTP 404)" <<< "$out"; then
      return 44
    fi
    echo "::error::could not query tag ${tag} (not a 404, refusing to guess): ${out}" >&2
    return 1
  fi
  type="$(jq -r '.object.type' <<< "$out")"
  sha="$(jq -r '.object.sha' <<< "$out")"
  # An annotated tag ref points at a tag OBJECT; peel until a commit appears.
  while [ "$type" = "tag" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 5 ]; then
      echo "::error::tag ${tag} nests more than 5 tag objects" >&2
      return 1
    fi
    if ! out="$(gh api "repos/${GITHUB_REPOSITORY}/git/tags/${sha}" 2>&1)"; then
      echo "::error::could not peel annotated tag ${tag} (object ${sha}): ${out}" >&2
      return 1
    fi
    type="$(jq -r '.object.type' <<< "$out")"
    sha="$(jq -r '.object.sha' <<< "$out")"
  done
  if [ "$type" != "commit" ]; then
    echo "::error::tag ${tag} resolves to a ${type} object, not a commit" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

set +e
ACTUAL="$(resolve_tag_commit "$TAG")"
STATUS=$?
set -e

case "$MODE" in
  preflight)
    if [ "$STATUS" -eq 44 ]; then
      if [ "$EVENT" = "workflow_dispatch" ]; then
        echo "Tag ${TAG} does not exist yet; the release step will create it at ${EXPECTED} (workflow_dispatch)."
        exit 0
      fi
      echo "::error::tag ${TAG} does not exist, yet this is a '${EVENT}' run — refusing to build a release for a tag that is not there."
      exit 1
    fi
    [ "$STATUS" -eq 0 ] || exit 1
    ;;
  postrelease)
    if [ "$STATUS" -eq 44 ]; then
      echo "::error::tag ${TAG} does not exist after the release step."
      exit 1
    fi
    [ "$STATUS" -eq 0 ] || exit 1
    ;;
  *)
    echo "::error::unknown mode '${MODE}' (expected preflight or postrelease)" >&2
    exit 2
    ;;
esac

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "::error::tag ${TAG} resolves to ${ACTUAL}, but this workflow built ${EXPECTED} — the release would advertise assets built from a different commit than its tag names. Refusing to continue (${MODE})."
  exit 1
fi
echo "Tag ${TAG} resolves to ${ACTUAL}, which is the checked-out commit (${MODE} OK)."
