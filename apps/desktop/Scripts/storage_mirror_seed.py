#!/usr/bin/env python3
"""
storage_mirror_seed.py — decide, fail-closed, what may seed the cumulative
Supabase Storage compatibility-mirror appcast.

The Storage mirror promises to keep its full cumulative history. The release
workflow therefore regenerates it by MERGING the new release into the feed
that is currently published in Storage — and only that feed. The website feed
and the GitHub release-line feed carry just the newest release of each major,
so seeding from either would silently truncate the mirror. And because every
seed item is republished verbatim, an invalid historical item would be
republished too: this gate validates every item, not just the feed's shape.

  check --feed PATH --storage-prefix URL [--bootstrap]

    The feed must be well-formed <rss><channel> with at least one <item>, and
    EVERY item must carry:
      • an exact X.Y.Z sparkle:shortVersionString (no leading zeros),
      • a positive integer sparkle:version (the build),
      • exactly one <enclosure> with a positive integer length and a
        non-empty sparkle:edSignature,
      • an enclosure URL that is https, on the exact Storage host and path
        prefix, without query or fragment, whose file name is exactly
        Zerro-<build>.dmg for that item's build — never the mutable Zerro.dmg,
        never a traversal (plain or percent-encoded), never any other name.
    Builds and enclosure URLs must be unique across the feed.
    Anything else — a missing or unreadable download, a directory, an empty
    object, a malformed document, an invalid item, a feed whose enclosures
    live on github.com or any other host — fails closed BEFORE any Storage
    object is touched. Filesystem errors are reported the same way, never as
    a traceback.

    --bootstrap is the explicit, documented opt-in for a true first-time
    mirror with no published feed yet: it allows a feed PATH THAT DOES NOT
    EXIST (the download produced nothing) and nothing else — an existing
    file, even a zero-byte one, must still be a valid Storage feed. It is off
    by default and is passed only from a manual workflow_dispatch run that
    sets bootstrap_storage_mirror=true.

Exit 0 prints how the mirror will be seeded; exit 1 prints a ::error:: line.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
BUILD_RE = re.compile(r"^[1-9]\d*$")
ARCHIVE_RE = re.compile(r"^Zerro-([1-9]\d*)\.dmg$")
MUTABLE_NAMES = frozenset({"Zerro.dmg"})


class SeedError(Exception):
    pass


def _text(element: ET.Element, tag: str) -> str | None:
    child = element.find(tag)
    if child is None or child.text is None:
        return None
    return child.text.strip()


def validate_item(index: int, item: ET.Element, prefix: str, host: str, path_prefix: str) -> tuple[int, str]:
    """Return (build, url) for a valid mirror item, or raise."""
    label = f"item #{index}"
    title = _text(item, "title")
    if title:
        label += f" ({title!r})"
    short = _text(item, f"{{{SPARKLE_NS}}}shortVersionString")
    if short is None or not VERSION_RE.match(short):
        raise SeedError(f"{label}: sparkle:shortVersionString must be exactly X.Y.Z with no leading zeros (got {short!r})")
    raw_build = _text(item, f"{{{SPARKLE_NS}}}version")
    if raw_build is None or not BUILD_RE.match(raw_build):
        raise SeedError(f"{label}: sparkle:version must be a positive integer build (got {raw_build!r})")
    build = int(raw_build)
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise SeedError(f"{label}: must have exactly one <enclosure> (found {len(enclosures)})")
    enclosure = enclosures[0]
    length = enclosure.get("length")
    if length is None or not BUILD_RE.match(length):
        raise SeedError(f"{label}: enclosure length must be a positive integer (got {length!r})")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if signature is None or not signature.strip():
        raise SeedError(f"{label}: enclosure has no sparkle:edSignature")
    url = enclosure.get("url")
    if not url:
        raise SeedError(f"{label}: enclosure has no url")
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise SeedError(f"{label}: enclosure URL must be https (got {url!r})")
    if parts.netloc != host:
        raise SeedError(f"{label}: enclosure is on host {parts.netloc!r}, not the Storage host {host!r} ({url!r}) — the website and GitHub release-line feeds must never seed the cumulative mirror")
    if parts.query or parts.fragment:
        raise SeedError(f"{label}: enclosure URL must not carry a query or fragment ({url!r})")
    if not parts.path.startswith(path_prefix):
        raise SeedError(f"{label}: enclosure path {parts.path!r} is outside the Storage prefix {path_prefix!r}")
    name = parts.path[len(path_prefix):]
    if "/" in name or "%" in name or name in ("", ".", ".."):
        raise SeedError(f"{label}: enclosure file name {name!r} is not a plain archive name directly under the Storage prefix")
    if name in MUTABLE_NAMES:
        raise SeedError(f"{label}: enclosure references the mutable {name!r} alias — only immutable Zerro-<build>.dmg archives may be republished")
    match = ARCHIVE_RE.match(name)
    if not match:
        raise SeedError(f"{label}: enclosure file name {name!r} is not an immutable Zerro-<build>.dmg archive")
    if int(match.group(1)) != build:
        raise SeedError(f"{label}: enclosure {name!r} does not carry the item's build {build}")
    return build, url


def evaluate(feed: Path, storage_prefix: str, bootstrap: bool) -> str:
    parts = urlsplit(storage_prefix)
    if parts.scheme != "https" or not parts.netloc or not storage_prefix.endswith("/") or parts.query or parts.fragment:
        raise SeedError(f"--storage-prefix must be an https URL ending in '/', got {storage_prefix!r}")
    host, path_prefix = parts.netloc, parts.path
    if not feed.exists():
        if bootstrap:
            return (
                "BOOTSTRAP: no published Storage appcast was downloaded; the mirror starts from this release alone "
                "(explicit bootstrap_storage_mirror opt-in)"
            )
        raise SeedError(
            f"the published Storage appcast could not be read ({feed} does not exist). The cumulative mirror is seeded ONLY from its "
            "own published feed — never from the website or the GitHub release-line feed — so this run stops before touching Storage. "
            "Retry once Storage is reachable; a genuine first-time mirror requires a manual run with bootstrap_storage_mirror=true."
        )
    try:
        if feed.is_dir():
            raise SeedError(f"{feed} is a directory, not the downloaded Storage appcast")
        data = feed.read_bytes()
    except OSError as exc:
        raise SeedError(f"cannot read the downloaded Storage appcast {feed}: {exc}") from exc
    if not data.strip():
        raise SeedError(f"the downloaded Storage appcast {feed} is empty; refusing to seed the cumulative mirror from it (bootstrap allows only a missing download, never an empty one)")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise SeedError(f"the downloaded Storage appcast {feed} is not well-formed XML ({exc}); refusing to seed the mirror from it") from exc
    if root.tag != "rss":
        raise SeedError(f"the downloaded Storage appcast root is <{root.tag}>, expected <rss>")
    channel = root.find("channel")
    if channel is None:
        raise SeedError("the downloaded Storage appcast has no <channel>")
    items = channel.findall("item")
    if not items:
        raise SeedError(f"the downloaded Storage appcast {feed} has no <item>; refusing to seed the cumulative mirror from an empty feed")
    seen_builds: dict[int, int] = {}
    seen_urls: dict[str, int] = {}
    for index, item in enumerate(items, start=1):
        build, url = validate_item(index, item, storage_prefix, host, path_prefix)
        if build in seen_builds:
            raise SeedError(f"item #{index} repeats build {build} (also item #{seen_builds[build]})")
        if url in seen_urls:
            raise SeedError(f"item #{index} repeats enclosure URL {url!r} (also item #{seen_urls[url]})")
        seen_builds[build] = index
        seen_urls[url] = index
    return f"seeding the cumulative mirror from its published Storage appcast ({len(items)} valid item(s), all on {host}{path_prefix})"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("check")
    c.add_argument("--feed", required=True, help="the downloaded Storage appcast (absent when the fetch failed)")
    c.add_argument("--storage-prefix", required=True, help="public Storage URL prefix every mirror enclosure must start with")
    c.add_argument("--bootstrap", action="store_true", help="explicit first-time opt-in: allow a MISSING download (never an existing invalid file)")
    args = parser.parse_args(argv)
    try:
        summary = evaluate(Path(args.feed), args.storage_prefix, args.bootstrap)
    except SeedError as exc:
        print(f"::error::storage_mirror_seed {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"storage_mirror_seed {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
