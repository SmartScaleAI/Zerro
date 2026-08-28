#!/usr/bin/env python3
"""
appcast_publish_guard.py — fail-closed checks around publishing a Sparkle feed
to the LIVE download channel. Standard library only.

  guard   Decide whether this run may overwrite the live channel, from the
          feed that is live RIGHT NOW (downloaded by the caller):
            • current build newer than the live newest build → allow;
            • equal → allow only when the marketing version of that live item
              matches AND the caller has proven the release tag resolves to the
              workflow commit (--tag-matches-commit; a same-tag re-run);
            • older → refuse;
            • missing, unreadable, malformed, or empty live feed → refuse.
          Nothing is ever published on a guess about the live state.

  check   Verify a generated (or just-published) feed advertises exactly what
          this run built: an item with the expected build number, marketing
          version, enclosure URL, enclosure length, and a non-empty EdDSA
          signature; that build must be the newest in the feed; and, when
          --expect-items is given, the feed must hold exactly that many items.

The feed is parsed with xml.etree, never with regular expressions. Every
failure exits non-zero with a ::error:: line for the Actions log.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class GuardError(Exception):
    """A refusal. The message is the whole diagnosis."""


@dataclass
class FeedItem:
    build: int
    short_version: str
    url: str | None
    length: str | None
    signature: str | None


def parse_feed(path: str | Path) -> list[FeedItem]:
    p = Path(path)
    if not p.is_file():
        raise GuardError(f"live feed {p} is missing — refusing to publish over an unknown live state")
    try:
        tree = ET.parse(str(p))
    except ET.ParseError as exc:
        raise GuardError(f"feed {p} is not well-formed XML: {exc}") from exc
    except OSError as exc:
        raise GuardError(f"feed {p} is unreadable: {exc}") from exc
    root = tree.getroot()
    if root.tag != "rss":
        raise GuardError(f"feed {p}: root element is <{root.tag}>, expected <rss>")
    channel = root.find("channel")
    if channel is None:
        raise GuardError(f"feed {p}: <rss> has no <channel>")
    items: list[FeedItem] = []
    for element in channel.findall("item"):
        title = element.findtext("title", default="(untitled)").strip()
        enclosure = element.find("enclosure")
        version_text = element.findtext(f"{{{SPARKLE_NS}}}version")
        if version_text is None and enclosure is not None:
            version_text = enclosure.get(f"{{{SPARKLE_NS}}}version")
        if version_text is None or not version_text.strip().isdigit():
            raise GuardError(f"feed {p}: item {title!r} has no integer sparkle:version (got {version_text!r})")
        short = element.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
        if short is None and enclosure is not None:
            short = enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString")
        items.append(
            FeedItem(
                build=int(version_text.strip()),
                short_version=(short or "").strip(),
                url=enclosure.get("url") if enclosure is not None else None,
                length=enclosure.get("length") if enclosure is not None else None,
                signature=enclosure.get(f"{{{SPARKLE_NS}}}edSignature") if enclosure is not None else None,
            )
        )
    if not items:
        raise GuardError(f"feed {p} has no <item> — refusing to treat an empty feed as a known state")
    return items


def guard(args: argparse.Namespace) -> str:
    items = parse_feed(args.live)
    newest = max(items, key=lambda item: item.build)
    current = args.current_build
    if current > newest.build:
        return f"current build {current} is newer than the live newest build {newest.build} ({newest.short_version}) — publishing allowed"
    if current == newest.build:
        if newest.short_version != args.current_version:
            raise GuardError(
                f"the live feed already advertises build {current} as version {newest.short_version!r}, but this run is version {args.current_version!r} — a different release reused the build number; refusing to overwrite it"
            )
        if not args.tag_matches_commit:
            raise GuardError(
                f"the live feed already advertises build {current} ({newest.short_version}); republishing the same build requires the release tag to resolve to this workflow commit, which was not proven"
            )
        return f"current build {current} equals the live newest build and the version + tag match — same-release republish allowed"
    raise GuardError(
        f"current build {current} is OLDER than the live newest build {newest.build} ({newest.short_version}) — publishing would move the live channel backwards; refusing"
    )


def check(args: argparse.Namespace) -> str:
    items = parse_feed(args.feed)
    if args.expect_items is not None and len(items) != args.expect_items:
        raise GuardError(f"feed {args.feed} has {len(items)} item(s), expected exactly {args.expect_items}")
    matches = [item for item in items if item.build == args.expect_build]
    if len(matches) != 1:
        raise GuardError(f"feed {args.feed} has {len(matches)} item(s) for build {args.expect_build}, expected exactly one")
    item = matches[0]
    newest = max(i.build for i in items)
    if newest != args.expect_build:
        raise GuardError(f"build {args.expect_build} is not the newest in {args.feed} (newest is {newest})")
    if item.short_version != args.expect_version:
        raise GuardError(f"build {args.expect_build} advertises version {item.short_version!r}, expected {args.expect_version!r}")
    if item.url != args.expect_url:
        raise GuardError(f"build {args.expect_build} enclosure url is {item.url!r}, expected {args.expect_url!r}")
    if item.length is None or not item.length.isdigit() or int(item.length) != args.expect_length:
        raise GuardError(f"build {args.expect_build} enclosure length is {item.length!r}, expected {args.expect_length}")
    if not item.signature or not item.signature.strip():
        raise GuardError(f"build {args.expect_build} enclosure has no sparkle:edSignature")
    return f"feed {args.feed} advertises build {args.expect_build} ({args.expect_version}) with the expected enclosure, length {args.expect_length}, and a signature"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    g = sub.add_parser("guard", help="may this run overwrite the live channel?")
    g.add_argument("--live", required=True, help="the live feed, downloaded by the caller")
    g.add_argument("--current-build", type=int, required=True)
    g.add_argument("--current-version", required=True)
    g.add_argument("--tag-matches-commit", action="store_true", help="the caller verified the release tag resolves to this workflow commit")
    g.set_defaults(func=guard)

    c = sub.add_parser("check", help="does this feed advertise exactly what was built?")
    c.add_argument("--feed", required=True)
    c.add_argument("--expect-build", type=int, required=True)
    c.add_argument("--expect-version", required=True)
    c.add_argument("--expect-url", required=True)
    c.add_argument("--expect-length", type=int, required=True)
    c.add_argument("--expect-items", type=int, help="require exactly this many items (single-item staging feeds)")
    c.set_defaults(func=check)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        summary = args.func(args)
    except GuardError as exc:
        print(f"::error::appcast_publish_guard {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"appcast_publish_guard {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
