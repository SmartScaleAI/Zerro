#!/usr/bin/env python3
"""
github_release_publish.py — draft-first, fail-closed publication of a
production GitHub Release.

getzerro.app/appcast.xml and getzerro.app/Zerro.dmg redirect to
https://github.com/<owner>/<repo>/releases/latest/download/<asset>, so the
moment a release becomes the repository's "latest" it is what every installed
app and download link resolves. A release must therefore never be published
or marked latest until it carries all three verified assets. This script
keeps the release a DRAFT — invisible to `releases/latest` — until the very
last step, and every step before that one fails closed:

  prepare   Resolve this run's draft. A published (non-draft) release for the
            tag means the tag already shipped: fail closed (a re-cut is a
            deliberate manual act: delete the release, and the tag on a tag
            push, then re-run). Exactly one existing draft for the tag is
            reused and REPAIRED — its target commit and title are reset and
            every asset it carries (including half-uploaded "starter" assets
            from a failed run) is deleted, so a same-tag re-run can never end
            up with duplicate or stale assets. No draft → create one. More
            than one draft for the tag is ambiguous: fail closed.
  upload    Upload assets to the draft. An existing asset of the same name is
            deleted first, and the upload is confirmed against the release
            (exactly one asset of that name, state "uploaded", the local
            size). Refuses to touch a release that is no longer a draft.
  verify    The draft must carry EXACTLY the expected assets, each with the
            expected size, each downloaded back and byte-identical (sha256) to
            the local file; its tag_name and target commit must be this run's.
            Writes a manifest (asset ids, sizes, hashes, updated_at) that is
            the only ticket `publish` accepts.
  publish   Re-fetch the release and require it to still be a draft that
            matches the manifest exactly (same asset ids/sizes/updated_at, no
            extras). Only then PATCH draft=false + make_latest=true, and then
            confirm the release is published and IS `releases/latest`.

Failure guarantees. Any failure in prepare/upload/verify, or in publish before
its PATCH, leaves the release a draft: the previous latest release, and so the
website's update URLs, are unchanged. If the PATCH succeeds but the
confirmation fails, the release is published but this script still exits
non-zero so the workflow stops.

All GitHub access goes through `gh api` (GH_TOKEN). Nothing secret is read or
printed. The GitHub client is injectable so the flow is unit-tested against an
in-memory GitHub (test_github_release_publish.py).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Protocol

MANIFEST_VERSION = 1
LATEST_CONFIRM_ATTEMPTS = 6
LATEST_CONFIRM_DELAY_SECONDS = 10


class PublishError(Exception):
    """A fail-closed condition. The message is the whole diagnosis."""


# --------------------------------------------------------------------------
# GitHub client


class GitHub(Protocol):
    def list_releases(self) -> list[dict]: ...
    def get_release(self, release_id: int) -> dict: ...
    def create_draft(self, tag: str, target: str, title: str) -> dict: ...
    def update_release(self, release_id: int, fields: dict) -> dict: ...
    def delete_asset(self, asset_id: int) -> None: ...
    def upload_asset(self, release: dict, name: str, path: Path) -> dict: ...
    def download_asset(self, asset_id: int, dest: Path) -> None: ...
    def latest_release(self) -> dict | None: ...


def _json_documents(text: str) -> Iterable[object]:
    """Yield every top-level JSON value (gh --paginate concatenates pages)."""
    decoder = json.JSONDecoder()
    index, length = 0, len(text)
    while True:
        while index < length and text[index].isspace():
            index += 1
        if index >= length:
            return
        value, index = decoder.raw_decode(text, index)
        yield value


class GhCli:
    """`gh api`-backed client. Every call is authenticated; failures raise."""

    def __init__(self, repo: str) -> None:
        self.repo = repo

    def _api(self, *args: str, input_bytes: bytes | None = None, stdout=None) -> str:
        proc = subprocess.run(
            ["gh", "api", *args],
            input=input_bytes,
            capture_output=stdout is None,
            stdout=stdout,
            check=False,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or b"").decode("utf-8", "replace").strip() if stdout is None else ""
            raise PublishError(f"gh api {' '.join(args)} failed (exit {proc.returncode}) {detail}".rstrip())
        return proc.stdout.decode("utf-8") if stdout is None else ""

    def list_releases(self) -> list[dict]:
        text = self._api("--paginate", f"repos/{self.repo}/releases?per_page=100")
        releases: list[dict] = []
        for document in _json_documents(text):
            if isinstance(document, list):
                releases.extend(document)
            else:
                releases.append(document)
        return releases

    def get_release(self, release_id: int) -> dict:
        return json.loads(self._api(f"repos/{self.repo}/releases/{release_id}"))

    def create_draft(self, tag: str, target: str, title: str) -> dict:
        body = {"tag_name": tag, "target_commitish": target, "name": title, "draft": True, "prerelease": False}
        return json.loads(
            self._api(
                "--method", "POST", "-H", "Content-Type: application/json", f"repos/{self.repo}/releases",
                "--input", "-", input_bytes=json.dumps(body).encode(),
            )
        )

    def update_release(self, release_id: int, fields: dict) -> dict:
        return json.loads(
            self._api(
                "--method", "PATCH", "-H", "Content-Type: application/json", f"repos/{self.repo}/releases/{release_id}",
                "--input", "-", input_bytes=json.dumps(fields).encode(),
            )
        )

    def delete_asset(self, asset_id: int) -> None:
        self._api("--method", "DELETE", f"repos/{self.repo}/releases/assets/{asset_id}")

    def upload_asset(self, release: dict, name: str, path: Path) -> dict:
        upload_url = str(release.get("upload_url") or "").split("{", 1)[0]
        if not upload_url.startswith("https://"):
            raise PublishError(f"release {release.get('id')} has no usable upload_url")
        return json.loads(
            self._api(
                "--method", "POST", "-H", "Content-Type: application/octet-stream",
                f"{upload_url}?name={name}", "--input", str(path),
            )
        )

    def download_asset(self, asset_id: int, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as handle:
            self._api("-H", "Accept: application/octet-stream", f"repos/{self.repo}/releases/assets/{asset_id}", stdout=handle)

    def latest_release(self) -> dict | None:
        try:
            return json.loads(self._api(f"repos/{self.repo}/releases/latest"))
        except PublishError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise


# --------------------------------------------------------------------------
# Helpers


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe(release: dict) -> str:
    return f"release {release.get('id')} ({release.get('tag_name')!r}, draft={release.get('draft')})"


def require_draft(release: dict, tag: str) -> None:
    if release.get("tag_name") != tag:
        raise PublishError(f"{describe(release)} is not for tag {tag!r}")
    if not release.get("draft"):
        raise PublishError(f"{describe(release)} is already published — refusing to modify a live release")


@dataclass(frozen=True)
class ExpectedAsset:
    name: str
    path: Path


def parse_expected(values: list[str]) -> list[ExpectedAsset]:
    expected: list[ExpectedAsset] = []
    for value in values:
        if "=" in value:
            name, path = value.split("=", 1)
        else:
            name, path = os.path.basename(value), value
        if not name or not path:
            raise PublishError(f"--asset must be NAME=PATH or PATH, got {value!r}")
        if not Path(path).is_file():
            raise PublishError(f"asset file {path} does not exist")
        expected.append(ExpectedAsset(name=name, path=Path(path)))
    names = [asset.name for asset in expected]
    if len(set(names)) != len(names):
        raise PublishError(f"duplicate asset names in --asset: {names}")
    if not expected:
        raise PublishError("at least one --asset is required")
    return expected


# --------------------------------------------------------------------------
# Steps


def prepare(github: GitHub, tag: str, target: str, title: str) -> dict:
    """Return the single draft release this run may publish under `tag`."""
    releases = github.list_releases()
    published = [r for r in releases if r.get("tag_name") == tag and not r.get("draft")]
    if published:
        raise PublishError(
            f"a published release already exists for {tag!r} (id {published[0].get('id')}). Refusing to re-publish over a live release: "
            f"to re-cut this version, delete that release (and the tag, on a tag push) deliberately and re-run."
        )
    drafts = [r for r in releases if r.get("tag_name") == tag and r.get("draft")]
    if len(drafts) > 1:
        raise PublishError(
            f"{len(drafts)} draft releases exist for {tag!r} (ids {[r.get('id') for r in drafts]}) — ambiguous; delete the stale drafts and re-run."
        )
    if drafts:
        draft = drafts[0]
        for asset in draft.get("assets") or []:
            github.delete_asset(asset["id"])
        draft = github.update_release(draft["id"], {"target_commitish": target, "name": title, "draft": True, "prerelease": False})
        require_draft(draft, tag)
        if draft.get("assets"):
            raise PublishError(f"{describe(draft)} still carries assets after repair: {[a.get('name') for a in draft['assets']]}")
        return draft
    draft = github.create_draft(tag, target, title)
    require_draft(draft, tag)
    return draft


def upload(github: GitHub, release_id: int, tag: str, assets: list[ExpectedAsset]) -> dict:
    release = github.get_release(release_id)
    require_draft(release, tag)
    for expected in assets:
        for existing in release.get("assets") or []:
            if existing.get("name") == expected.name:
                github.delete_asset(existing["id"])
        github.upload_asset(release, expected.name, expected.path)
        release = github.get_release(release_id)
        require_draft(release, tag)
        matches = [a for a in release.get("assets") or [] if a.get("name") == expected.name]
        if len(matches) != 1:
            raise PublishError(f"{describe(release)} carries {len(matches)} assets named {expected.name!r} after upload, expected exactly one")
        asset = matches[0]
        local_size = expected.path.stat().st_size
        if asset.get("state") != "uploaded":
            raise PublishError(f"asset {expected.name!r} is in state {asset.get('state')!r}, expected 'uploaded'")
        if asset.get("size") != local_size:
            raise PublishError(f"asset {expected.name!r} is {asset.get('size')} bytes on GitHub but {local_size} locally")
    return release


def verify(github: GitHub, release_id: int, tag: str, target: str, assets: list[ExpectedAsset], download_dir: Path) -> dict:
    """Verify the draft and return the manifest `publish` requires."""
    release = github.get_release(release_id)
    require_draft(release, tag)
    if release.get("target_commitish") != target:
        raise PublishError(
            f"{describe(release)} targets {release.get('target_commitish')!r}, but this workflow built {target} — the release would be pinned to a different commit"
        )
    remote = release.get("assets") or []
    expected_names = sorted(a.name for a in assets)
    actual_names = sorted(a.get("name") for a in remote)
    if actual_names != expected_names:
        raise PublishError(f"{describe(release)} must carry exactly {expected_names}; it has {actual_names}")
    manifest_assets = []
    download_dir.mkdir(parents=True, exist_ok=True)
    for expected in assets:
        asset = next(a for a in remote if a.get("name") == expected.name)
        local_size = expected.path.stat().st_size
        if asset.get("state") != "uploaded":
            raise PublishError(f"asset {expected.name!r} is in state {asset.get('state')!r}, expected 'uploaded'")
        if asset.get("size") != local_size:
            raise PublishError(f"asset {expected.name!r} is {asset.get('size')} bytes on GitHub but {local_size} locally")
        dest = download_dir / expected.name
        github.download_asset(asset["id"], dest)
        local_hash, remote_hash = sha256_of(expected.path), sha256_of(dest)
        if local_hash != remote_hash:
            raise PublishError(f"downloaded {expected.name!r} differs from the local artifact (sha256 {remote_hash} vs {local_hash})")
        manifest_assets.append(
            {"id": asset["id"], "name": expected.name, "size": local_size, "sha256": local_hash, "updated_at": asset.get("updated_at")}
        )
    return {
        "version": MANIFEST_VERSION,
        "release_id": release["id"],
        "tag": tag,
        "target": target,
        "assets": sorted(manifest_assets, key=lambda a: a["name"]),
    }


def publish(
    github: GitHub,
    release_id: int,
    tag: str,
    target: str,
    manifest: dict,
    sleep: Callable[[float], None] = time.sleep,
) -> dict:
    """Publish the verified draft as the latest release. Fails closed before
    the PATCH on any drift from the manifest; fails (after the PATCH) if the
    release did not become `releases/latest`."""
    if manifest.get("version") != MANIFEST_VERSION:
        raise PublishError("manifest is not from this script version")
    if manifest.get("release_id") != release_id or manifest.get("tag") != tag or manifest.get("target") != target:
        raise PublishError(f"manifest is for release {manifest.get('release_id')} / {manifest.get('tag')!r} / {manifest.get('target')!r}, not this run")
    release = github.get_release(release_id)
    require_draft(release, tag)
    if release.get("target_commitish") != target:
        raise PublishError(f"{describe(release)} targets {release.get('target_commitish')!r}, expected {target}")
    remote = sorted(release.get("assets") or [], key=lambda a: a.get("name") or "")
    expected = manifest.get("assets") or []
    if len(remote) != len(expected):
        raise PublishError(f"{describe(release)} carries {len(remote)} assets, the verified manifest has {len(expected)} — re-run verify")
    for got, want in zip(remote, expected):
        for key in ("id", "name", "size", "updated_at"):
            if got.get(key) != want.get(key):
                raise PublishError(
                    f"asset {want.get('name')!r} changed since verification ({key}: {got.get(key)!r} vs verified {want.get(key)!r}) — refusing to publish unverified content"
                )
        if got.get("state") != "uploaded":
            raise PublishError(f"asset {want.get('name')!r} is in state {got.get('state')!r}")
    published = github.update_release(release_id, {"draft": False, "make_latest": "true"})
    if published.get("draft"):
        raise PublishError(f"{describe(published)} is still a draft after publication")
    if published.get("tag_name") != tag:
        raise PublishError(f"published release carries tag {published.get('tag_name')!r}, expected {tag!r}")
    for attempt in range(1, LATEST_CONFIRM_ATTEMPTS + 1):
        latest = github.latest_release()
        if latest and latest.get("id") == release_id:
            return published
        if attempt < LATEST_CONFIRM_ATTEMPTS:
            sleep(LATEST_CONFIRM_DELAY_SECONDS)
    raise PublishError(
        f"release {release_id} ({tag}) is published but is NOT releases/latest (latest is {latest.get('id') if latest else None}); the website's update URLs still resolve the previous release"
    )


# --------------------------------------------------------------------------
# CLI


def cmd_prepare(github: GitHub, args: argparse.Namespace) -> str:
    draft = prepare(github, args.tag, args.target, args.title)
    if args.github_env:
        with open(args.github_env, "a", encoding="utf-8") as handle:
            handle.write(f"RELEASE_ID={draft['id']}\n")
    return f"draft {describe(draft)} ready (no assets); RELEASE_ID={draft['id']}"


def cmd_upload(github: GitHub, args: argparse.Namespace) -> str:
    assets = parse_expected(args.asset)
    release = upload(github, args.release_id, args.tag, assets)
    return f"uploaded {[a.name for a in assets]} to {describe(release)}"


def cmd_verify(github: GitHub, args: argparse.Namespace) -> str:
    assets = parse_expected(args.asset)
    manifest = verify(github, args.release_id, args.tag, args.target, assets, Path(args.download_dir))
    Path(args.manifest).parent.mkdir(parents=True, exist_ok=True)
    Path(args.manifest).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return f"draft release {args.release_id} verified: exactly {[a.name for a in assets]}, byte-identical to the local artifacts; manifest written to {args.manifest}"


def cmd_publish(github: GitHub, args: argparse.Namespace) -> str:
    try:
        manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PublishError(f"cannot read the verification manifest {args.manifest}: {exc}") from exc
    published = publish(github, args.release_id, args.tag, args.target, manifest)
    return f"{describe(published)} published and confirmed as releases/latest ({published.get('html_url')})"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="OWNER/REPO (use $GITHUB_REPOSITORY)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("prepare", help="create or repair this run's draft release")
    p.add_argument("--tag", required=True)
    p.add_argument("--target", required=True, help="the commit the release must be pinned to (use $GITHUB_SHA)")
    p.add_argument("--title", required=True)
    p.add_argument("--github-env", help="append RELEASE_ID=<id> to this file (use $GITHUB_ENV)")
    p.set_defaults(func=cmd_prepare)

    u = sub.add_parser("upload", help="upload assets to the draft (replacing same-name assets)")
    u.add_argument("--release-id", type=int, required=True)
    u.add_argument("--tag", required=True)
    u.add_argument("--asset", action="append", required=True, metavar="[NAME=]PATH")
    u.set_defaults(func=cmd_upload)

    v = sub.add_parser("verify", help="verify the draft carries exactly the expected, byte-identical assets")
    v.add_argument("--release-id", type=int, required=True)
    v.add_argument("--tag", required=True)
    v.add_argument("--target", required=True)
    v.add_argument("--asset", action="append", required=True, metavar="NAME=PATH")
    v.add_argument("--download-dir", required=True)
    v.add_argument("--manifest", required=True, help="where to write the verification manifest publish requires")
    v.set_defaults(func=cmd_verify)

    b = sub.add_parser("publish", help="publish the verified draft and make it the latest release")
    b.add_argument("--release-id", type=int, required=True)
    b.add_argument("--tag", required=True)
    b.add_argument("--target", required=True)
    b.add_argument("--manifest", required=True)
    b.set_defaults(func=cmd_publish)
    return parser


def main(argv: list[str] | None = None, github_factory: Callable[[str], GitHub] = GhCli) -> int:
    args = build_parser().parse_args(argv)
    try:
        summary = args.func(github_factory(args.repo), args)
    except PublishError as exc:
        print(f"::error::github_release_publish {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"github_release_publish {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
