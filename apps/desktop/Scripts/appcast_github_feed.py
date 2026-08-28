#!/usr/bin/env python3
"""
appcast_github_feed.py — verify a Sparkle appcast whose every enclosure is an
immutable, tag-specific GitHub Release asset URL.

A GitHub release's feed advertises that release and — for production — the
newest release of each other major version in the release line (see
appcast_release_line.py); every enclosure is an immutable archive URL,
https://github.com/<owner>/<repo>/releases/download/<tag>/<archive>.
Nothing here reads a release inventory or a live feed: a feed is verified from
its own contents.

One command, standard library only (the release runners have python3 and
nothing else needs to be installed):

  verify   Check a feed (typically the one downloaded back from the release)
           against the rules below.

Every rule fails closed with a ::error:: line and a non-zero exit:

  • the feed is well-formed RSS with at least one <item>, and with
    --expect-items exactly the requested number of items. Staging passes
    --expect-items 1 because staging feeds are single-item; production
    release-line feeds may carry the current release plus the newest
    retained release from each other major, so production does not
    always pass this option;
  • every enclosure is an https://github.com URL of --repo of the form
    /releases/download/<tag>/<archive> — no query, no fragment, never a
    mutable /releases/latest/ URL, never a Supabase Storage host;
  • <tag> has the flavor's shape (production app-v<X.Y.Z>, staging
    staging-v<X.Y.Z>, components without leading zeros) and <archive> is the
    flavor's immutable versioned name (Zerro-<build>.dmg /
    ZerroStaging-<build>.dmg) whose build equals the item's sparkle:version —
    never the mutable Zerro.dmg / ZerroStaging.dmg alias;
  • every enclosure carries a positive integer length and a sparkle:edSignature;
  • builds and URLs are unique, the current build is present and is the newest,
    and it is published under the current tag.

Byte length, expected URL, and expected version for the current build are
checked by Scripts/appcast_publish_guard.py check, which the workflows run
alongside this tool.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
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
        tag_re=re.compile(r"^app-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$"),
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
class Item:
    element: ET.Element
    enclosure: ET.Element
    build: int
    title: str


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
# Command


def verify_tree(
    tree: ET.ElementTree,
    items: list[Item],
    repo: str,
    flavor: Flavor,
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
        check_signature_and_length(item)
        if item.build == current_build and current_tag is not None and tag != current_tag:
            raise FeedError(f"the current build {current_build} is published under {tag!r}, expected {current_tag!r}")
    check_uniqueness_and_newest(items, current_build)
    newest = max(item.build for item in items)
    return f"{len(items)} item(s), newest build {newest}, every enclosure an immutable {repo} release asset"


def verify(args: argparse.Namespace) -> str:
    flavor = FLAVORS[args.flavor]
    tree, items = parse_feed(args.feed)
    if args.expect_items is not None and len(items) != args.expect_items:
        raise FeedError(f"expected exactly {args.expect_items} item(s), found {len(items)}")
    return verify_tree(tree, items, args.repo, flavor, args.current_build, args.current_tag)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    v = sub.add_parser("verify", help="verify a GitHub-hosted feed")
    v.add_argument("--flavor", choices=sorted(FLAVORS), required=True)
    v.add_argument("--repo", required=True, help="OWNER/REPO (use $GITHUB_REPOSITORY)")
    v.add_argument("--current-build", type=int, required=True, help="the build number produced by this run")
    v.add_argument("--current-tag", required=True, help="the release tag for this run")
    v.add_argument("--feed", required=True)
    v.add_argument(
        "--expect-items",
        type=int,
        help="require exactly this many items (staging passes 1: staging feeds are single-item; production release-line "
             "feeds may carry the current release plus the newest retained release from each other major, so production "
             "does not always pass this option)",
    )
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
