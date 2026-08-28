#!/usr/bin/env python3
"""
staging_channel_publish.py — publish a verified staging appcast to the
permanent `staging-channel` GitHub prerelease, fail-closed.

The staging update channel is one permanent GitHub prerelease:

  tag      staging-channel            (never moved by this script)
  name     Staging Update Channel
  state    published, prerelease, never the repository's latest release
  asset    appcast-staging.xml        (the ONLY asset when a run finishes)
  URL      https://github.com/<owner>/<repo>/releases/download/staging-channel/appcast-staging.xml

The feed it carries is the one-item feed of the newest staging release; its
enclosure is the immutable archive on that release's own versioned
prerelease:
  https://github.com/<owner>/<repo>/releases/download/staging-v<X.Y.Z>/ZerroStaging-<build>.dmg

Rules (every failure is a ::error:: line and a non-zero exit, and leaves a
valid stable feed in place whenever one existed):

  • Channel resolution. The channel must already exist as a published
    (draft == false) prerelease with the exact name. A missing channel is
    created ONLY when --bootstrap is passed (the workflow passes it only from
    an explicit manual staging-branch dispatch with bootstrap_staging_channel
    = true); without it a missing channel fails closed. A draft or a
    non-prerelease channel fails closed.
  • Local feed. The feed being published must be exactly one item for this
    build and version whose enclosure is this release's immutable archive on
    tag --tag, with a positive length and a signature; that versioned
    prerelease must exist, be published, and carry ZerroStaging-<build>.dmg
    in state "uploaded" with a size equal to the length.
  • Live state. With a stable feed present it is downloaded and validated
    the same way. A NEWER build may publish. An EQUAL build may publish only
    when --tag-matches-commit was proven by the caller, the live item is on
    the same tag and version, and the live bytes are identical to the local
    feed (a same-tag re-run; nothing changes). An older build, a malformed
    or empty live feed, a live build newer than this one, or any asset the
    channel is not expected to carry, fails closed. A channel without a
    stable feed is accepted only under --bootstrap.
  • Safe swap. The candidate is uploaded under a temporary name, downloaded
    back, required byte-identical, and validated BEFORE the stable asset is
    touched. The stable asset is then renamed to a backup name, the
    candidate is renamed to the stable name, the stable asset is downloaded
    and required byte-identical again, and only then is the backup deleted.
    A failure at any point after the stable asset was renamed restores it
    from the backup. Leftover candidate/backup assets from an earlier failed
    run are cleaned up (a leftover backup is removed only after the current
    stable feed validated). The run ends with exactly one asset.

The GitHub transport is injectable (test_staging_channel_publish.py drives
the flow against an in-memory GitHub). Nothing secret is read or printed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from github_release_publish import GhCli as _GhCli, PublishError  # noqa: E402

CHANNEL_TAG = "staging-channel"
CHANNEL_NAME = "Staging Update Channel"
STABLE_ASSET = "appcast-staging.xml"
CANDIDATE_ASSET = "appcast-staging.candidate.xml"
BACKUP_ASSET = "appcast-staging.previous.xml"
KNOWN_ASSETS = frozenset({STABLE_ASSET, CANDIDATE_ASSET, BACKUP_ASSET})

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
STAGING_TAG_RE = re.compile(r"^staging-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$")
ARCHIVE_RE = re.compile(r"^ZerroStaging-([1-9]\d*)\.dmg$")


class ChannelError(Exception):
    """A fail-closed condition. The message is the whole diagnosis."""


class GitHub(Protocol):
    def get_release_by_tag(self, tag: str) -> dict | None: ...
    def get_release(self, release_id: int) -> dict: ...
    def create_prerelease(self, tag: str, target: str, name: str) -> dict: ...
    def delete_asset(self, asset_id: int) -> None: ...
    def rename_asset(self, asset_id: int, name: str) -> dict: ...
    def upload_asset(self, release: dict, name: str, path: Path) -> dict: ...
    def download_asset(self, asset_id: int, dest: Path) -> None: ...


class GhCli(_GhCli):
    """`gh api` transport (authenticated). Extends the release publisher's client."""

    def get_release_by_tag(self, tag: str) -> dict | None:
        try:
            return json.loads(self._api(f"repos/{self.repo}/releases/tags/{tag}"))
        except PublishError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise ChannelError(str(exc)) from exc

    def create_prerelease(self, tag: str, target: str, name: str) -> dict:
        body = {"tag_name": tag, "target_commitish": target, "name": name, "draft": False, "prerelease": True, "make_latest": "false"}
        return json.loads(
            self._api("--method", "POST", "-H", "Content-Type: application/json", f"repos/{self.repo}/releases",
                      "--input", "-", input_bytes=json.dumps(body).encode())
        )

    def rename_asset(self, asset_id: int, name: str) -> dict:
        return json.loads(
            self._api("--method", "PATCH", "-H", "Content-Type: application/json", f"repos/{self.repo}/releases/assets/{asset_id}",
                      "--input", "-", input_bytes=json.dumps({"name": name}).encode())
        )


# --------------------------------------------------------------------------
# Feed parsing


@dataclass(frozen=True)
class FeedItem:
    build: int
    version: str
    tag: str
    name: str
    url: str
    length: int


def parse_staging_feed(data: bytes, repo: str, label: str) -> FeedItem:
    """Parse a one-item staging feed and return its item, or raise."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise ChannelError(f"{label} feed is not well-formed XML: {exc}") from exc
    channel = root.find("channel") if root.tag == "rss" else None
    items = channel.findall("item") if channel is not None else []
    if len(items) != 1:
        raise ChannelError(f"{label} feed must contain exactly one item (found {len(items)})")
    item = items[0]
    version_el = item.find(f"{{{SPARKLE_NS}}}version")
    raw_build = version_el.text.strip() if version_el is not None and version_el.text else None
    if raw_build is None or not raw_build.isdigit() or int(raw_build) <= 0:
        raise ChannelError(f"{label} feed item has no positive integer sparkle:version (got {raw_build!r})")
    short_el = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
    version = short_el.text.strip() if short_el is not None and short_el.text else None
    if not version or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ChannelError(f"{label} feed item has no exact X.Y.Z sparkle:shortVersionString (got {version!r})")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ChannelError(f"{label} feed item must have exactly one enclosure (found {len(enclosures)})")
    enc = enclosures[0]
    length = enc.get("length")
    if length is None or not length.isdigit() or int(length) <= 0:
        raise ChannelError(f"{label} feed enclosure has no positive integer length (got {length!r})")
    signature = enc.get(f"{{{SPARKLE_NS}}}edSignature")
    if not signature or not signature.strip():
        raise ChannelError(f"{label} feed enclosure has no sparkle:edSignature")
    url = enc.get("url") or ""
    parts = urlsplit(url)
    prefix = f"/{repo}/releases/download/"
    if parts.scheme != "https" or parts.netloc != "github.com" or parts.query or parts.fragment or not parts.path.startswith(prefix):
        raise ChannelError(f"{label} feed enclosure {url!r} is not an immutable GitHub release asset of {repo}")
    segments = parts.path[len(prefix):].split("/")
    if len(segments) != 2 or not all(segments):
        raise ChannelError(f"{label} feed enclosure {url!r} is not .../releases/download/<tag>/<asset>")
    tag, name = segments
    tag_match = STAGING_TAG_RE.fullmatch(tag)
    if not tag_match:
        raise ChannelError(f"{label} feed enclosure tag {tag!r} is not a staging-v<X.Y.Z> release tag")
    if tag_match.group(1) != version:
        raise ChannelError(f"{label} feed item is version {version} but its enclosure is on tag {tag!r}")
    name_match = ARCHIVE_RE.fullmatch(name)
    if not name_match:
        raise ChannelError(f"{label} feed enclosure {name!r} is not an immutable ZerroStaging-<build>.dmg archive")
    if int(name_match.group(1)) != int(raw_build):
        raise ChannelError(f"{label} feed enclosure {name!r} does not carry build {raw_build}")
    return FeedItem(build=int(raw_build), version=version, tag=tag, name=name, url=url, length=int(length))


# --------------------------------------------------------------------------
# Steps


def resolve_channel(github: GitHub, target: str, bootstrap: bool) -> tuple[dict, bool]:
    """Return (channel release, created_now)."""
    release = github.get_release_by_tag(CHANNEL_TAG)
    if release is None:
        if not bootstrap:
            raise ChannelError(
                f"the permanent {CHANNEL_TAG} prerelease does not exist. It is created only by an explicit manual staging-branch run with "
                "bootstrap_staging_channel=true (first time only); refusing to create it implicitly."
            )
        release = github.create_prerelease(CHANNEL_TAG, target, CHANNEL_NAME)
        created = True
    else:
        created = False
    if release.get("tag_name") != CHANNEL_TAG:
        raise ChannelError(f"channel release names tag {release.get('tag_name')!r}, expected {CHANNEL_TAG!r}")
    if release.get("draft") is not False:
        raise ChannelError(f"the {CHANNEL_TAG} release is a draft (or its draft state is unknown) — the channel must be published")
    if release.get("prerelease") is not True:
        raise ChannelError(f"the {CHANNEL_TAG} release is not a prerelease — the channel must never be eligible to become the repository's latest release")
    if release.get("name") != CHANNEL_NAME:
        raise ChannelError(f"the {CHANNEL_TAG} release is named {release.get('name')!r}, expected {CHANNEL_NAME!r} — unknown channel state")
    return release, created


def verify_versioned_prerelease(github: GitHub, item: FeedItem) -> None:
    release = github.get_release_by_tag(item.tag)
    if release is None:
        raise ChannelError(f"the versioned prerelease {item.tag} the feed points at does not exist")
    if release.get("draft") is not False or release.get("prerelease") is not True:
        raise ChannelError(f"the versioned release {item.tag} must be a published prerelease (draft={release.get('draft')}, prerelease={release.get('prerelease')})")
    assets = [a for a in release.get("assets") or [] if a.get("name") == item.name]
    if len(assets) != 1:
        raise ChannelError(f"release {item.tag} does not carry exactly one {item.name} (found {len(assets)})")
    if assets[0].get("state") != "uploaded":
        raise ChannelError(f"asset {item.name} on {item.tag} is in state {assets[0].get('state')!r}, expected exactly 'uploaded'")
    if assets[0].get("size") != item.length:
        raise ChannelError(f"asset {item.name} on {item.tag} is {assets[0].get('size')} bytes but the feed records length {item.length}")


def asset_named(release: dict, name: str) -> dict | None:
    matches = [a for a in release.get("assets") or [] if a.get("name") == name]
    if len(matches) > 1:
        raise ChannelError(f"channel carries {len(matches)} assets named {name!r} — unknown live state")
    return matches[0] if matches else None


def check_live(github: GitHub, channel: dict, local_bytes: bytes, local: FeedItem, repo: str, download_dir: Path, *, bootstrap: bool, tag_matches_commit: bool) -> tuple[dict | None, bool]:
    """Validate the live stable feed against the local one. Returns
    (stable asset or None, identical) — identical=True means the live feed is
    already byte-identical to the local one (nothing to change)."""
    unknown = sorted({a.get("name") for a in channel.get("assets") or []} - KNOWN_ASSETS)
    if unknown:
        raise ChannelError(f"the channel carries unexpected assets {unknown} — unknown live state; refusing to publish")
    stable = asset_named(channel, STABLE_ASSET)
    if stable is None:
        if bootstrap:
            return None, False
        raise ChannelError(f"the channel has no {STABLE_ASSET} — missing live state; only a bootstrap run may publish into an empty channel")
    if stable.get("state") != "uploaded":
        raise ChannelError(f"the live {STABLE_ASSET} is in state {stable.get('state')!r} — unknown live state")
    dest = download_dir / "live-appcast-staging.xml"
    github.download_asset(stable["id"], dest)
    live_bytes = dest.read_bytes()
    live = parse_staging_feed(live_bytes, repo, "live channel")
    if local.build < live.build:
        raise ChannelError(f"the channel already advertises build {live.build} ({live.version}); this run is build {local.build} — publishing would move the channel backwards")
    if local.build > live.build:
        return stable, False
    # Equal build: only a proven same-tag/same-commit re-run with identical bytes.
    if not tag_matches_commit:
        raise ChannelError(f"the channel already advertises build {local.build}; republishing the same build requires the release tag to resolve to this workflow commit, which was not proven")
    if live.tag != local.tag or live.version != local.version:
        raise ChannelError(f"the channel already advertises build {local.build} as {live.version} on {live.tag}, but this run is {local.version} on {local.tag} — a different release reused the build number; refusing")
    if live_bytes != local_bytes:
        raise ChannelError(f"the channel already advertises build {local.build} on {local.tag} but with different feed bytes — refusing to overwrite an equal build with a different feed")
    return stable, True


def _asset_by_id(release: dict, asset_id: int) -> dict | None:
    return next((a for a in release.get("assets") or [] if a.get("id") == asset_id), None)


def _rename_reconciled(github: GitHub, release_id: int, asset_id: int, name: str) -> None:
    """Rename an asset; if the call errors, re-fetch and accept the rename
    when it was applied remotely anyway (a timeout after the mutation)."""
    try:
        github.rename_asset(asset_id, name)
    except Exception as exc:
        current = _asset_by_id(github.get_release(release_id), asset_id)
        if current is None or current.get("name") != name:
            raise
    current = _asset_by_id(github.get_release(release_id), asset_id)
    if current is None or current.get("name") != name:
        raise ChannelError(f"asset {asset_id} is not named {name!r} after the rename")


def _restore_previous(github: GitHub, release_id: int, old_stable_id: int | None, candidate_id: int) -> str:
    """Reconcile the channel by asset ID after a failed promotion: remove the
    candidate under whatever name it carries and make sure the previous
    stable asset (by ID) is named appcast-staging.xml again."""
    if old_stable_id is None:
        try:
            channel = github.get_release(release_id)
            if _asset_by_id(channel, candidate_id) is not None:
                github.delete_asset(candidate_id)
        except Exception as cleanup_exc:  # pragma: no cover - reported, not masked
            return f"no previous stable feed existed; candidate cleanup failed ({cleanup_exc})"
        return "no previous stable feed existed"
    try:
        channel = github.get_release(release_id)
        if _asset_by_id(channel, old_stable_id) is None:
            return f"RESTORE FAILED: the previous stable asset (id {old_stable_id}) is no longer on the channel"
        if _asset_by_id(channel, candidate_id) is not None:
            try:
                github.delete_asset(candidate_id)
            except Exception:
                if _asset_by_id(github.get_release(release_id), candidate_id) is not None:
                    raise
        _rename_reconciled(github, release_id, old_stable_id, STABLE_ASSET)
        channel = github.get_release(release_id)
        stable = asset_named(channel, STABLE_ASSET)
        if stable is None or stable.get("id") != old_stable_id:
            return f"RESTORE FAILED: {STABLE_ASSET} is not the previous asset after reconciliation"
        return "the previous stable feed was restored as appcast-staging.xml"
    except Exception as restore_exc:
        current = None
        try:
            current = _asset_by_id(github.get_release(release_id), old_stable_id)
        except Exception:
            pass
        where = f"currently named {current.get('name')!r}" if current else "state unknown"
        return f"RESTORE FAILED ({restore_exc}); the previous feed is asset id {old_stable_id}, {where}"


def swap_in(github: GitHub, channel: dict, local_path: Path, local_bytes: bytes, local: FeedItem, repo: str, download_dir: Path, stable: dict | None) -> dict:
    """Upload, verify, and promote the candidate; restore on failure."""
    release_id = channel["id"]
    for leftover in (CANDIDATE_ASSET,):
        old = asset_named(channel, leftover)
        if old is not None:
            github.delete_asset(old["id"])
    backup = asset_named(channel, BACKUP_ASSET)
    if backup is not None:
        # A backup can only exist alongside a validated stable feed (the live
        # check above already validated it); otherwise it is unknown state.
        if stable is None:
            raise ChannelError(f"the channel carries a leftover {BACKUP_ASSET} but no {STABLE_ASSET} — unknown live state; restore it by hand")
        github.delete_asset(backup["id"])
    channel = github.get_release(release_id)
    github.upload_asset(channel, CANDIDATE_ASSET, local_path)
    channel = github.get_release(release_id)
    candidate = asset_named(channel, CANDIDATE_ASSET)
    if candidate is None or candidate.get("state") != "uploaded" or candidate.get("size") != len(local_bytes):
        raise ChannelError("the candidate feed did not upload cleanly (missing, not 'uploaded', or wrong size); the stable feed was not touched")
    dest = download_dir / "candidate-appcast-staging.xml"
    github.download_asset(candidate["id"], dest)
    if dest.read_bytes() != local_bytes:
        raise ChannelError("the uploaded candidate feed is not byte-identical to the verified local feed; the stable feed was not touched")
    parse_staging_feed(dest.read_bytes(), repo, "candidate")
    # Promote: stable → backup, candidate → stable. BOTH renames run inside the
    # recovery boundary. A failed API call is never assumed to mean the
    # mutation was not applied: after any error the release is re-fetched and
    # reconciled by asset ID (names are what may have changed).
    old_stable_id = stable["id"] if stable is not None else None
    candidate_id = candidate["id"]
    try:
        # Any error here — even one raised after GitHub applied the rename —
        # is treated as a failed promotion: the except branch re-fetches the
        # release and restores the previous feed by asset ID.
        if old_stable_id is not None:
            github.rename_asset(old_stable_id, BACKUP_ASSET)
        github.rename_asset(candidate_id, STABLE_ASSET)
        channel = github.get_release(release_id)
        new_stable = asset_named(channel, STABLE_ASSET)
        if new_stable is None or new_stable.get("id") != candidate_id:
            raise ChannelError("the promoted stable asset is not the verified candidate")
        verify_dest = download_dir / "promoted-appcast-staging.xml"
        github.download_asset(new_stable["id"], verify_dest)
        if verify_dest.read_bytes() != local_bytes:
            raise ChannelError("the promoted stable feed is not byte-identical to the verified local feed")
        parse_staging_feed(verify_dest.read_bytes(), repo, "promoted stable")
    except Exception as exc:  # reconcile from the real remote state, then fail
        restored = _restore_previous(github, release_id, old_stable_id, candidate_id)
        raise ChannelError(f"promotion failed: {exc} — {restored}") from exc
    backup_id = old_stable_id
    if backup_id is not None:
        github.delete_asset(backup_id)
    channel = github.get_release(release_id)
    names = sorted(a.get("name") for a in channel.get("assets") or [])
    if names != [STABLE_ASSET]:
        raise ChannelError(f"the channel must end with exactly [{STABLE_ASSET}]; it has {names}")
    return channel


def publish(github: GitHub, repo: str, tag: str, target: str, build: int, version: str, feed_path: Path, download_dir: Path, *, bootstrap: bool, tag_matches_commit: bool) -> str:
    local_bytes = feed_path.read_bytes()
    local = parse_staging_feed(local_bytes, repo, "local")
    if local.build != build or local.version != version or local.tag != tag:
        raise ChannelError(f"local feed advertises {local.version} (build {local.build}) on {local.tag}, expected {version} (build {build}) on {tag}")
    verify_versioned_prerelease(github, local)
    channel, created = resolve_channel(github, target, bootstrap)
    download_dir.mkdir(parents=True, exist_ok=True)
    if created:
        stable, identical = None, False
    else:
        stable, identical = check_live(github, channel, local_bytes, local, repo, download_dir, bootstrap=bootstrap, tag_matches_commit=tag_matches_commit)
    if identical:
        names = sorted(a.get("name") for a in channel.get("assets") or [])
        if names != [STABLE_ASSET]:
            channel = swap_in(github, channel, feed_path, local_bytes, local, repo, download_dir, stable)
        return f"channel already carries this exact feed (build {build}, {version}, {tag}); nothing changed"
    swap_in(github, channel, feed_path, local_bytes, local, repo, download_dir, stable)
    return f"channel {CHANNEL_TAG} now serves {STABLE_ASSET} for {version} (build {build}) → {local.url}" + (" (channel bootstrapped)" if created else "")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="OWNER/REPO (use $GITHUB_REPOSITORY)")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("publish", help="publish the verified staging feed to the staging-channel prerelease")
    p.add_argument("--tag", required=True, help="this release's versioned staging tag (staging-v<X.Y.Z>)")
    p.add_argument("--target", required=True, help="commit the channel is pinned to if it is bootstrapped (use $GITHUB_SHA)")
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--feed", required=True, help="the verified local appcast-staging.xml (downloaded back from the versioned prerelease)")
    p.add_argument("--download-dir", required=True)
    p.add_argument("--bootstrap", action="store_true", help="create the permanent channel if missing (manual first-time run only)")
    p.add_argument("--tag-matches-commit", action="store_true", help="the caller proved the release tag resolves to this workflow commit")
    return parser


def main(argv: list[str] | None = None, github_factory: Callable[[str], GitHub] = GhCli) -> int:
    args = build_parser().parse_args(argv)
    try:
        summary = publish(
            github_factory(args.repo), args.repo, args.tag, args.target, args.build, args.version, Path(args.feed), Path(args.download_dir),
            bootstrap=args.bootstrap, tag_matches_commit=args.tag_matches_commit,
        )
    except (ChannelError, PublishError) as exc:
        print(f"::error::staging_channel_publish {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"staging_channel_publish {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
