#!/usr/bin/env python3
"""
appcast_github_feed.py — build and verify a Sparkle appcast whose every
enclosure is an immutable, tag-specific GitHub Release asset URL.

Two commands, standard library only (the release runners have python3 and
nothing else needs to be installed):

  migrate  Take the cumulative feed generate_appcast produced (enclosures on
           the current download host), map every item's versioned archive
           name to exactly one existing, non-draft GitHub Release asset, and
           rewrite the enclosure URL to
           https://github.com/<owner>/<repo>/releases/download/<tag>/<name>.
           Nothing else in the item changes: the recorded length and EdDSA
           signature are preserved because the archive bytes are unchanged.
           The result is verified before it is written.

  verify   Check a feed (typically the one downloaded back from the release)
           against the same rules and, when an asset inventory is given,
           against the actual release assets.

The feed is parsed and rewritten with xml.etree, never with regular
expressions, so element structure, namespaces, and attributes other than the
enclosure URL survive byte-for-byte in meaning.

Every rule fails closed: a historical item that maps to zero or more than one
asset, a mutable or "latest" URL, a non-HTTPS URL, a leftover Supabase URL, a
missing length or signature, a duplicate item, a build that is not the newest,
or malformed XML all abort with a non-zero exit and a ::error:: line for the
Actions log. Nothing secret is ever read or printed by this script.

Asset inventory format (--assets): the raw GitHub REST payload from
`gh api --paginate repos/<owner>/<repo>/releases` (one or more concatenated
JSON arrays of releases), or a pre-flattened JSON array of
{"tag", "name", "size"} objects. Draft releases are ignored, with one
explicit exception: --include-draft TAG counts the assets of draft releases
whose tag_name is exactly TAG. The production workflow publishes draft-first
(the current run's release stays a draft until its three assets verify), so
it passes its own tag here; every other draft — historical, abandoned, or
unrelated — stays invisible.

Duplicate historical assets (the same versioned archive attached to two
releases) can be resolved only by an explicit, reviewed --pin NAME=TAG whose
tag really carries that asset; without a pin the migration fails.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urlsplit

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

GITHUB_HOST = "github.com"
FORBIDDEN_HOST_FRAGMENTS = ("supabase.co", "supabase.in")


@dataclass(frozen=True)
class Flavor:
    name: str
    asset_re: re.Pattern
    mutable_names: frozenset
    tag_re: re.Pattern


FLAVORS = {
    "production": Flavor(
        name="production",
        asset_re=re.compile(r"^Zerro-(\d+)\.dmg$"),
        mutable_names=frozenset({"Zerro.dmg"}),
        tag_re=re.compile(r"^app-v\d+\.\d+\.\d+$"),
    ),
    "staging": Flavor(
        name="staging",
        asset_re=re.compile(r"^ZerroStaging-(\d+)\.dmg$"),
        mutable_names=frozenset({"ZerroStaging.dmg", "Zerro.dmg"}),
        # Plain staging-v<X.Y.Z> tags only (staging-v1.0.0, staging-v1.0.1, …):
        # every staging release carries its own version and build number.
        tag_re=re.compile(r"^staging-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$"),
    ),
}


class FeedError(Exception):
    """A rule violation. The message is the whole diagnosis."""


@dataclass
class Asset:
    tag: str
    name: str
    size: int | None


@dataclass
class Item:
    element: ET.Element
    enclosure: ET.Element
    build: int
    title: str


# --------------------------------------------------------------------------
# Inventory


def _json_documents(text: str) -> Iterable[object]:
    """Yield every top-level JSON value in `text` (gh --paginate concatenates
    one array per page with no separator)."""
    decoder = json.JSONDecoder()
    index = 0
    length = len(text)
    while True:
        while index < length and text[index].isspace():
            index += 1
        if index >= length:
            return
        value, index = decoder.raw_decode(text, index)
        yield value


def load_assets(path: str | Path, include_draft_tags: Iterable[str] = ()) -> list[Asset]:
    """Read the inventory. Draft releases are skipped unless their tag_name
    is in `include_draft_tags` (the current run's explicitly named draft)."""
    allowed_drafts = frozenset(include_draft_tags)
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise FeedError(f"cannot read asset inventory {path}: {exc}") from exc
    assets: list[Asset] = []
    try:
        documents = list(_json_documents(text))
    except json.JSONDecodeError as exc:
        raise FeedError(f"asset inventory {path} is not valid JSON: {exc}") from exc
    for document in documents:
        if isinstance(document, dict):
            document = [document]
        if not isinstance(document, list):
            raise FeedError(f"asset inventory {path}: expected a JSON array")
        for entry in document:
            if not isinstance(entry, dict):
                raise FeedError(f"asset inventory {path}: expected objects")
            if "assets" in entry:  # raw GitHub release payload
                tag = entry.get("tag_name")
                if entry.get("draft") and tag not in allowed_drafts:
                    continue
                if not tag:
                    raise FeedError("asset inventory: release without tag_name")
                for asset in entry.get("assets") or []:
                    assets.append(Asset(tag=tag, name=asset["name"], size=asset.get("size")))
            else:  # pre-flattened
                if entry.get("draft") and entry.get("tag") not in allowed_drafts:
                    continue
                assets.append(Asset(tag=entry["tag"], name=entry["name"], size=entry.get("size")))
    return assets


def index_assets(assets: Iterable[Asset]) -> dict[str, list[Asset]]:
    by_name: dict[str, list[Asset]] = {}
    for asset in assets:
        by_name.setdefault(asset.name, []).append(asset)
    return by_name


# --------------------------------------------------------------------------
# Feed parsing


def parse_feed(path: str | Path) -> tuple[ET.ElementTree, list[Item]]:
    try:
        tree = ET.parse(str(path))
    except ET.ParseError as exc:
        raise FeedError(f"{path} is not well-formed XML: {exc}") from exc
    except OSError as exc:
        raise FeedError(f"cannot read feed {path}: {exc}") from exc
    root = tree.getroot()
    if root.tag != "rss":
        raise FeedError(f"{path}: root element is <{root.tag}>, expected <rss>")
    channel = root.find("channel")
    if channel is None:
        raise FeedError(f"{path}: <rss> has no <channel>")
    elements = channel.findall("item")
    if not elements:
        raise FeedError(f"{path}: the feed has no <item> — refusing an empty feed")
    items: list[Item] = []
    for element in elements:
        title_el = element.find("title")
        title = (title_el.text or "").strip() if title_el is not None else "(untitled)"
        enclosure = element.find("enclosure")
        if enclosure is None:
            raise FeedError(f"item {title!r} has no <enclosure>")
        version_el = element.find(f"{{{SPARKLE_NS}}}version")
        raw_version = None
        if version_el is not None and version_el.text:
            raw_version = version_el.text.strip()
        else:
            raw_version = enclosure.get(f"{{{SPARKLE_NS}}}version")
        if raw_version is None or not raw_version.isdigit():
            raise FeedError(f"item {title!r} has no integer sparkle:version (got {raw_version!r})")
        items.append(Item(element=element, enclosure=enclosure, build=int(raw_version), title=title))
    return tree, items


# --------------------------------------------------------------------------
# Rules


def enclosure_filename(url: str, title: str) -> str:
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise FeedError(f"item {title!r}: enclosure URL must be https, got {url!r}")
    if not parts.netloc:
        raise FeedError(f"item {title!r}: enclosure URL has no host: {url!r}")
    if parts.query or parts.fragment:
        raise FeedError(f"item {title!r}: enclosure URL must not carry a query or fragment: {url!r}")
    name = parts.path.rsplit("/", 1)[-1]
    if not name:
        raise FeedError(f"item {title!r}: enclosure URL has no file name: {url!r}")
    return name


def check_archive_name(name: str, build: int, flavor: Flavor, title: str) -> None:
    if name in flavor.mutable_names:
        raise FeedError(
            f"item {title!r}: enclosure {name!r} is the mutable stable alias — Sparkle must only ever be pointed at the immutable versioned archive"
        )
    match = flavor.asset_re.match(name)
    if not match:
        raise FeedError(
            f"item {title!r}: enclosure {name!r} does not match the {flavor.name} versioned archive rule {flavor.asset_re.pattern}"
        )
    if int(match.group(1)) != build:
        raise FeedError(
            f"item {title!r}: enclosure {name!r} carries build {match.group(1)} but the item's sparkle:version is {build}"
        )


def check_signature_and_length(item: Item) -> int:
    length = item.enclosure.get("length")
    if length is None or not length.isdigit() or int(length) <= 0:
        raise FeedError(f"item {item.title!r}: enclosure has no positive integer length (got {length!r})")
    signature = item.enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if not signature or not signature.strip():
        raise FeedError(f"item {item.title!r}: enclosure has no sparkle:edSignature")
    return int(length)


def check_no_forbidden_hosts(tree: ET.ElementTree) -> None:
    serialized = ET.tostring(tree.getroot(), encoding="unicode")
    for fragment in FORBIDDEN_HOST_FRAGMENTS:
        if fragment in serialized:
            raise FeedError(f"the GitHub-hosted feed still references {fragment!r} — every URL must be a GitHub Release asset")


def check_uniqueness_and_newest(items: list[Item], current_build: int | None) -> None:
    builds = [item.build for item in items]
    if len(set(builds)) != len(builds):
        dupes = sorted({b for b in builds if builds.count(b) > 1})
        raise FeedError(f"duplicate sparkle:version values in the feed: {dupes}")
    urls = [item.enclosure.get("url") for item in items]
    if len(set(urls)) != len(urls):
        raise FeedError("duplicate enclosure URLs in the feed")
    if current_build is not None:
        newest = max(builds)
        if current_build not in builds:
            raise FeedError(f"the feed has no item for the current build {current_build}")
        if newest != current_build:
            raise FeedError(
                f"the current build {current_build} is not the newest in the feed (max sparkle:version is {newest}) — the tag is probably on an old or duplicate commit"
            )


def github_release_url(repo: str, tag: str, name: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{name}"


def parse_github_release_url(url: str, repo: str, flavor: Flavor, title: str) -> tuple[str, str]:
    """Return (tag, name) for an immutable release-asset URL of `repo`, or raise."""
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.netloc != GITHUB_HOST:
        raise FeedError(f"item {title!r}: {url!r} is not an https://github.com URL")
    if parts.query or parts.fragment:
        raise FeedError(f"item {title!r}: release-asset URL must not carry a query or fragment: {url!r}")
    prefix = f"/{repo}/releases/download/"
    if "/releases/latest/" in parts.path:
        raise FeedError(f"item {title!r}: {url!r} is a mutable /releases/latest/ URL")
    if not parts.path.startswith(prefix):
        raise FeedError(f"item {title!r}: {url!r} is not a release asset of {repo}")
    remainder = parts.path[len(prefix):]
    segments = remainder.split("/")
    if len(segments) != 2 or not all(segments):
        raise FeedError(f"item {title!r}: {url!r} is not of the form .../releases/download/<tag>/<asset>")
    tag, name = segments
    if not flavor.tag_re.match(tag):
        raise FeedError(f"item {title!r}: tag {tag!r} is not a {flavor.name} release tag ({flavor.tag_re.pattern})")
    return tag, name


# --------------------------------------------------------------------------
# Commands


def resolve_asset(name: str, by_name: dict[str, list[Asset]], pins: dict[str, str], title: str) -> Asset:
    candidates = by_name.get(name, [])
    if not candidates:
        raise FeedError(
            f"item {title!r}: no non-draft GitHub Release carries the asset {name!r} — attach the original archive to its release (or stop advertising this build) before migrating"
        )
    pinned = pins.get(name)
    if pinned is not None:
        matches = [asset for asset in candidates if asset.tag == pinned]
        if len(matches) != 1:
            raise FeedError(
                f"item {title!r}: --pin {name}={pinned} names a release that does not carry that asset (releases with it: {sorted(a.tag for a in candidates)})"
            )
        return matches[0]
    if len(candidates) > 1:
        raise FeedError(
            f"item {title!r}: asset {name!r} is attached to {len(candidates)} releases {sorted(a.tag for a in candidates)} — resolve with an explicit --pin {name}=<tag>"
        )
    return candidates[0]


def migrate(args: argparse.Namespace) -> str:
    flavor = FLAVORS[args.flavor]
    pins = parse_pins(args.pin)
    by_name = index_assets(load_assets(args.assets, args.include_draft or ()))
    tree, items = parse_feed(args.input)
    for item in items:
        url = item.enclosure.get("url")
        if not url:
            raise FeedError(f"item {item.title!r}: enclosure has no url")
        name = enclosure_filename(url, item.title)
        check_archive_name(name, item.build, flavor, item.title)
        length = check_signature_and_length(item)
        asset = resolve_asset(name, by_name, pins, item.title)
        if asset.size is not None and asset.size != length:
            raise FeedError(
                f"item {item.title!r}: release asset {name!r} on {asset.tag} is {asset.size} bytes but the feed's length is {length} — the bytes differ, so the recorded signature would not match"
            )
        if item.build == args.current_build and asset.tag != args.current_tag:
            raise FeedError(
                f"the current build {args.current_build} maps to release {asset.tag!r}, expected the current tag {args.current_tag!r}"
            )
        item.enclosure.set("url", github_release_url(args.repo, asset.tag, name))
    check_uniqueness_and_newest(items, args.current_build)
    summary = verify_tree(tree, items, args.repo, flavor, by_name, args.current_build, args.current_tag)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tree.write(str(output), encoding="utf-8", xml_declaration=True)
    return summary


def verify_tree(
    tree: ET.ElementTree,
    items: list[Item],
    repo: str,
    flavor: Flavor,
    by_name: dict[str, list[Asset]] | None,
    current_build: int | None,
    current_tag: str | None,
) -> str:
    check_no_forbidden_hosts(tree)
    for item in items:
        url = item.enclosure.get("url")
        if not url:
            raise FeedError(f"item {item.title!r}: enclosure has no url")
        tag, name = parse_github_release_url(url, repo, flavor, item.title)
        if name != enclosure_filename(url, item.title):
            raise FeedError(f"item {item.title!r}: inconsistent asset name in {url!r}")
        check_archive_name(name, item.build, flavor, item.title)
        length = check_signature_and_length(item)
        if item.build == current_build and current_tag is not None and tag != current_tag:
            raise FeedError(f"the current build {current_build} is published under {tag!r}, expected {current_tag!r}")
        if by_name is not None:
            matches = [asset for asset in by_name.get(name, []) if asset.tag == tag]
            if len(matches) != 1:
                raise FeedError(
                    f"item {item.title!r}: {url} does not resolve to exactly one existing non-draft release asset (found {len(matches)})"
                )
            size = matches[0].size
            if size is not None and size != length:
                raise FeedError(
                    f"item {item.title!r}: release asset {name!r} is {size} bytes but the feed says {length}"
                )
    check_uniqueness_and_newest(items, current_build)
    newest = max(item.build for item in items)
    return f"{len(items)} item(s), newest build {newest}, every enclosure an immutable {repo} release asset"


def verify(args: argparse.Namespace) -> str:
    flavor = FLAVORS[args.flavor]
    by_name = index_assets(load_assets(args.assets, args.include_draft or ())) if args.assets else None
    tree, items = parse_feed(args.feed)
    if args.expect_items is not None and len(items) != args.expect_items:
        raise FeedError(f"expected exactly {args.expect_items} item(s), found {len(items)}")
    return verify_tree(tree, items, args.repo, flavor, by_name, args.current_build, args.current_tag)


def parse_pins(values: list[str] | None) -> dict[str, str]:
    pins: dict[str, str] = {}
    for value in values or []:
        if "=" not in value:
            raise FeedError(f"--pin must be NAME=TAG, got {value!r}")
        name, tag = value.split("=", 1)
        if not name or not tag:
            raise FeedError(f"--pin must be NAME=TAG, got {value!r}")
        if name in pins and pins[name] != tag:
            raise FeedError(f"conflicting --pin values for {name!r}")
        pins[name] = tag
    return pins


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--flavor", choices=sorted(FLAVORS), required=True)
        p.add_argument("--repo", required=True, help="OWNER/REPO (use $GITHUB_REPOSITORY)")
        p.add_argument("--current-build", type=int, required=True, help="the build number produced by this run")
        p.add_argument("--current-tag", required=True, help="the release tag for this run")
        p.add_argument(
            "--include-draft",
            action="append",
            metavar="TAG",
            help="count the assets of DRAFT releases whose tag_name is exactly TAG (the current run's draft-first release); all other drafts stay ignored",
        )

    m = sub.add_parser("migrate", help="rewrite enclosures to immutable GitHub Release asset URLs")
    common(m)
    m.add_argument("--input", required=True, help="the cumulative feed generate_appcast produced")
    m.add_argument("--assets", required=True, help="JSON asset inventory (gh api --paginate repos/…/releases)")
    m.add_argument("--output", required=True)
    m.add_argument("--pin", action="append", metavar="NAME=TAG", help="resolve a duplicated historical asset to one reviewed release tag")
    m.set_defaults(func=migrate)

    v = sub.add_parser("verify", help="verify a GitHub-hosted feed")
    common(v)
    v.add_argument("--feed", required=True)
    v.add_argument("--assets", help="JSON asset inventory; when given, every enclosure must resolve to an existing asset")
    v.add_argument("--expect-items", type=int, help="require exactly this many items (staging feeds are single-item)")
    v.set_defaults(func=verify)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        summary = args.func(args)
    except FeedError as exc:
        print(f"::error::appcast_github_feed {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"appcast_github_feed {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
