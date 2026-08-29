#!/usr/bin/env python3
"""
appcast_release_line.py — compose the production GitHub appcast as the newest
release from each major version in the release line.

The GitHub release line begins at exactly one release identity — version
1.0.0, build 1000, tag app-v1.0.0 (the line-start version and build, both
passed explicitly). The feed a release carries advertises:

  • this release, and
  • the newest release of every OTHER major version that the line has
    already published,

so a 1.x install is still offered the final 1.x release after 2.0 ships
(UpdateMajorPolicy offers only the installed major), while a 2.x install is
offered the newest 2.x. Examples: 1.0.0 → [1.0.0]; 1.0.1 → [1.0.1];
2.0.0 → [final 1.x, 2.0.0]; 2.0.1 → [final 1.x, 2.0.1].

Sources, and what is never read:

  • The FIRST release of the line is exactly version 1.0.0 / build 1000 /
    tag app-v1.0.0 and is composed from its own freshly generated single-item
    feed alone. No earlier tag, release, asset, or appcast is read. Build
    1000 under any other version or tag, or version 1.0.0 under any other
    build, fails closed.
  • Every LATER release composes from exactly two inputs: its own fresh
    single-item feed and the previous release-line feed — the appcast.xml
    asset of the line's latest release, downloaded by the workflow, which also
    passes that release's tag (--previous-tag). The previous feed must be a
    valid release-line feed — every item on an immutable GitHub asset URL of
    this repository, every build at or above the line start and below the
    current build, one item per major, tag == app-v<version> — AND its
    highest-build item must be exactly the release the tag names, or the run
    fails closed (a stale or replaced feed attached to the latest release is
    rejected). There is no fallback to any other feed, no repository-wide
    inventory, and no pin variable.
  • Every retained item is checked against its own release (the workflow
    fetches releases/tags/<tag> for exactly the retained tags): the release
    must exist, be published (draft == false, prerelease == false), and carry
    exactly one Zerro-<build>.dmg in state "uploaded" with a size equal to
    the item's recorded length. The check runs when the feed is composed and
    again, from freshly fetched release data, right before the draft is
    published (verify-retained). The current item's asset is verified by the
    draft-first publication flow (byte-identical upload, then download).

Commands (standard library only):

  plan             Validate the previous feed for the current release and
                   print the tags whose releases the workflow must fetch (one
                   per line): the retained items' tags. Prints nothing for the
                   first release.
  compose          Build the release-line feed for this release and write it.
  check            Verify an existing feed obeys the release-line rules (used
                   on the feed downloaded back from the draft release).
  list-retained    Print the tags of a feed's retained (non-current) items.
  verify-retained  Re-verify every retained item of a feed against freshly
                   fetched release data.

All failures are ::error:: lines with a non-zero exit. Nothing secret is read.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

DEFAULT_LINE_START_BUILD = 1000
DEFAULT_LINE_START_VERSION = "1.0.0"
PRODUCTION_TAG_RE = re.compile(r"^app-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$")
VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
ASSET_RE = re.compile(r"^Zerro-(\d+)\.dmg$")
MUTABLE_NAMES = frozenset({"Zerro.dmg"})
FORBIDDEN_HOST_FRAGMENTS = ("supabase.co", "supabase.in")


class LineError(Exception):
    """A fail-closed condition. The message is the whole diagnosis."""


@dataclass
class Item:
    element: ET.Element
    build: int
    version: str
    major: int
    tag: str
    name: str
    url: str
    length: int


# --------------------------------------------------------------------------
# Parsing + per-item rules


def _text(element: ET.Element, tag: str) -> str | None:
    child = element.find(tag)
    return child.text.strip() if child is not None and child.text else None


def parse_feed(path: Path, repo: str, label: str) -> tuple[ET.ElementTree, list[Item]]:
    try:
        tree = ET.parse(str(path))
    except ET.ParseError as exc:
        raise LineError(f"{label} feed {path} is not well-formed XML: {exc}") from exc
    except OSError as exc:
        raise LineError(f"cannot read {label} feed {path}: {exc}") from exc
    serialized = ET.tostring(tree.getroot(), encoding="unicode")
    for fragment in FORBIDDEN_HOST_FRAGMENTS:
        if fragment in serialized:
            raise LineError(f"{label} feed {path} references {fragment!r} — only GitHub Release assets are allowed")
    root = tree.getroot()
    channel = root.find("channel") if root.tag == "rss" else None
    if channel is None:
        raise LineError(f"{label} feed {path}: expected <rss><channel>")
    elements = channel.findall("item")
    if not elements:
        raise LineError(f"{label} feed {path} has no <item>")
    items: list[Item] = []
    for element in elements:
        title = _text(element, "title") or "(untitled)"
        enclosure = element.find("enclosure")
        if enclosure is None:
            raise LineError(f"{label} feed: item {title!r} has no <enclosure>")
        raw_build = _text(element, f"{{{SPARKLE_NS}}}version") or enclosure.get(f"{{{SPARKLE_NS}}}version")
        if raw_build is None or not raw_build.isdigit():
            raise LineError(f"{label} feed: item {title!r} has no integer sparkle:version (got {raw_build!r})")
        version = _text(element, f"{{{SPARKLE_NS}}}shortVersionString") or enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString")
        if version is None or not VERSION_RE.match(version):
            raise LineError(f"{label} feed: item {title!r} has no exact X.Y.Z sparkle:shortVersionString (got {version!r})")
        url = enclosure.get("url") or ""
        tag, name = parse_release_url(url, repo, title, label)
        if name in MUTABLE_NAMES:
            raise LineError(f"{label} feed: item {title!r} references the mutable alias {name!r}")
        match = ASSET_RE.match(name)
        if not match:
            raise LineError(f"{label} feed: item {title!r} enclosure {name!r} is not an immutable Zerro-<build>.dmg")
        build = int(raw_build)
        if int(match.group(1)) != build:
            raise LineError(f"{label} feed: item {title!r} enclosure {name!r} does not carry build {build}")
        if tag != f"app-v{version}":
            raise LineError(f"{label} feed: item {title!r} is version {version} but its enclosure is on tag {tag!r} (expected app-v{version})")
        raw_length = enclosure.get("length")
        if raw_length is None or not raw_length.isdigit() or int(raw_length) <= 0:
            raise LineError(f"{label} feed: item {title!r} has no positive integer length (got {raw_length!r})")
        signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
        if not signature or not signature.strip():
            raise LineError(f"{label} feed: item {title!r} has no sparkle:edSignature")
        items.append(Item(element=element, build=build, version=version, major=int(version.split(".")[0]), tag=tag, name=name, url=url, length=int(raw_length)))
    return tree, items


def parse_release_url(url: str, repo: str, title: str, label: str) -> tuple[str, str]:
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.netloc != "github.com":
        raise LineError(f"{label} feed: item {title!r} enclosure {url!r} is not an https://github.com URL")
    if parts.query or parts.fragment:
        raise LineError(f"{label} feed: item {title!r} enclosure must not carry a query or fragment: {url!r}")
    if "/releases/latest/" in parts.path:
        raise LineError(f"{label} feed: item {title!r} enclosure {url!r} is a mutable /releases/latest/ URL")
    prefix = f"/{repo}/releases/download/"
    if not parts.path.startswith(prefix):
        raise LineError(f"{label} feed: item {title!r} enclosure {url!r} is not a release asset of {repo}")
    segments = parts.path[len(prefix):].split("/")
    if len(segments) != 2 or not all(segments):
        raise LineError(f"{label} feed: item {title!r} enclosure {url!r} is not .../releases/download/<tag>/<asset>")
    return segments[0], segments[1]


# --------------------------------------------------------------------------
# Release-line rules


def check_line_rules(items: list[Item], line_start: int, current_build: int | None, current_version: str | None, label: str, *, allow_current: bool) -> None:
    """Every build inside the line, at most one item per major, unique builds,
    and (when given) the current release present and newest."""
    builds = [i.build for i in items]
    if len(set(builds)) != len(builds):
        raise LineError(f"{label} feed has duplicate builds {sorted(b for b in builds if builds.count(b) > 1)}")
    for item in items:
        if item.build < line_start:
            raise LineError(
                f"{label} feed item {item.version} (build {item.build}) predates the release line, which starts at build {line_start} — pre-line releases are never carried forward"
            )
        if current_build is not None and not allow_current and item.build >= current_build:
            raise LineError(f"{label} feed item {item.version} (build {item.build}) is not older than the current build {current_build}")
    majors = [i.major for i in items]
    if len(set(majors)) != len(majors):
        raise LineError(f"{label} feed carries more than one item for a major version ({sorted(majors)}) — it is not a release-line feed")
    if allow_current and current_build is not None:
        current = [i for i in items if i.build == current_build]
        if len(current) != 1:
            raise LineError(f"{label} feed must carry exactly one item for the current build {current_build}")
        if current_version is not None and current[0].version != current_version:
            raise LineError(f"{label} feed advertises build {current_build} as {current[0].version}, expected {current_version}")
        if max(builds) != current_build:
            raise LineError(f"{label} feed's newest build is {max(builds)}, but the current build is {current_build}")


def check_start_identity(line_start_build: int, line_start_version: str, current_build: int, current_version: str, current_tag: str) -> bool:
    """True when this release IS the line's first release. The first release
    is exactly one identity; a build-1000 release under another version/tag
    or a 1.0.0 release under another build fails closed."""
    if not VERSION_RE.match(line_start_version):
        raise LineError(f"line-start version {line_start_version!r} is not exactly X.Y.Z")
    start_tag = f"app-v{line_start_version}"
    if current_build == line_start_build:
        if current_version != line_start_version or current_tag != start_tag:
            raise LineError(
                f"build {current_build} is the release line's first build and must be exactly version {line_start_version} on tag {start_tag}; "
                f"got version {current_version} on tag {current_tag!r}"
            )
        return True
    if current_version == line_start_version or current_tag == start_tag:
        raise LineError(
            f"version {line_start_version} (tag {start_tag}) is the release line's first release and must be build {line_start_build}; got build {current_build}"
        )
    return False


def load_previous(path: Path | None, repo: str, line_start: int, current_build: int, current_version: str, is_first: bool, previous_tag: str | None) -> list[Item]:
    """The previous release-line feed, validated for the current release and
    bound to the release it was downloaded from."""
    if is_first:
        if path is not None or previous_tag is not None:
            raise LineError(
                f"build {current_build} is the first release of the line and composes from its own feed alone — no previous feed or tag may be supplied"
            )
        return []
    if path is None:
        raise LineError(
            f"build {current_build} is a later release of the line (line start {line_start}) and requires the previous release-line feed; none was supplied — refusing to start over or fall back to any other feed"
        )
    if previous_tag is None:
        raise LineError("--previous-tag (the latest release the previous feed was downloaded from) is required with --previous-feed")
    match = PRODUCTION_TAG_RE.match(previous_tag)
    if not match:
        raise LineError(f"previous tag {previous_tag!r} is not a production release tag (app-v<X.Y.Z>)")
    _, items = parse_feed(path, repo, "previous release-line")
    check_line_rules(items, line_start, current_build, current_version, "previous release-line", allow_current=False)
    newest = max(items, key=lambda i: i.build)
    if newest.tag != previous_tag or newest.version != match.group(1):
        raise LineError(
            f"the previous feed was downloaded from release {previous_tag}, but its newest item is {newest.version} (build {newest.build}) on tag {newest.tag!r} — "
            f"a stale or replaced feed is attached to the latest release; refusing to build on it"
        )
    return items


def load_current(path: Path, repo: str, line_start: int, current_build: int, current_version: str, current_tag: str) -> tuple[ET.ElementTree, Item]:
    tree, items = parse_feed(path, repo, "current release")
    if len(items) != 1:
        raise LineError(f"current release feed {path} must contain exactly one item, found {len(items)}")
    item = items[0]
    if item.build != current_build or item.version != current_version:
        raise LineError(f"current release feed advertises {item.version} (build {item.build}), expected {current_version} (build {current_build})")
    if item.tag != current_tag:
        raise LineError(f"current release feed enclosure is on tag {item.tag!r}, expected {current_tag!r}")
    if item.build < line_start:
        raise LineError(f"current build {current_build} is below the release-line start {line_start}")
    return tree, item


def retained_items(previous: list[Item], current: Item) -> list[Item]:
    """Newest-first: the current release plus the newest item of every other major."""
    kept = [i for i in previous if i.major != current.major]
    return sorted([current, *kept], key=lambda i: i.build, reverse=True)


def verify_retained_assets(items: list[Item], assets_dir: Path, current_build: int) -> list[Item]:
    """Each retained (non-current) item must resolve to its own published,
    non-prerelease release carrying exactly one Zerro-<build>.dmg in state
    "uploaded" whose size equals the feed's recorded length."""
    retained = [i for i in items if i.build != current_build]
    for item in retained:
        path = assets_dir / f"{item.tag}.json"
        try:
            release = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise LineError(f"retained item {item.version}: release data for {item.tag} is missing or unreadable ({path}): {exc}") from exc
        if release.get("tag_name") != item.tag:
            raise LineError(f"retained item {item.version}: release data names tag {release.get('tag_name')!r}, expected {item.tag}")
        if release.get("draft") is not False:
            raise LineError(f"retained item {item.version}: release {item.tag} is a draft (or its draft state is unknown)")
        if release.get("prerelease") is not False:
            raise LineError(f"retained item {item.version}: release {item.tag} is a prerelease (or its prerelease state is unknown) — only published releases may be retained")
        assets = [a for a in release.get("assets") or [] if a.get("name") == item.name]
        if len(assets) != 1:
            raise LineError(f"retained item {item.version}: release {item.tag} does not carry exactly one {item.name} (found {len(assets)})")
        if assets[0].get("state") != "uploaded":
            raise LineError(f"retained item {item.version}: asset {item.name} on {item.tag} is in state {assets[0].get('state')!r}, expected exactly 'uploaded'")
        if assets[0].get("size") != item.length:
            raise LineError(
                f"retained item {item.version}: asset {item.name} on {item.tag} is {assets[0].get('size')} bytes but the feed records length {item.length} — the recorded signature would not match"
            )
    return retained


def compose_tree(current_tree: ET.ElementTree, items: list[Item]) -> ET.ElementTree:
    root = copy.deepcopy(current_tree.getroot())
    channel = root.find("channel")
    for element in channel.findall("item"):
        channel.remove(element)
    for item in items:
        channel.append(copy.deepcopy(item.element))
    return ET.ElementTree(root)


# --------------------------------------------------------------------------
# CLI


def _load_inputs(args: argparse.Namespace):
    is_first = check_start_identity(args.line_start_build, args.line_start_version, args.current_build, args.current_version, args.current_tag)
    current_tree, current = load_current(Path(args.current_feed), args.repo, args.line_start_build, args.current_build, args.current_version, args.current_tag)
    previous = load_previous(
        Path(args.previous_feed) if args.previous_feed else None, args.repo, args.line_start_build,
        args.current_build, args.current_version, is_first, args.previous_tag,
    )
    return current_tree, current, previous


def cmd_plan(args: argparse.Namespace) -> str:
    _, current, previous = _load_inputs(args)
    kept = [i for i in retained_items(previous, current) if i is not current]
    for item in kept:
        print(item.tag)
    return f"{len(kept)} retained release(s) to fetch" + (": " + ", ".join(i.tag for i in kept) if kept else " (nothing retained)")


def cmd_compose(args: argparse.Namespace) -> str:
    current_tree, current, previous = _load_inputs(args)
    items = retained_items(previous, current)
    if previous:
        if not args.release_assets:
            raise LineError("--release-assets DIR is required whenever a previous feed is composed in")
        verify_retained_assets(items, Path(args.release_assets), current.build)
    tree = compose_tree(current_tree, items)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tree.write(str(output), encoding="utf-8", xml_declaration=True)
    # Re-read what was written and apply every rule to it.
    _, written = parse_feed(output, args.repo, "composed")
    check_line_rules(written, args.line_start_build, args.current_build, args.current_version, "composed", allow_current=True)
    return "release-line feed: " + ", ".join(f"{i.version} (build {i.build}, major {i.major})" for i in written)


def cmd_check(args: argparse.Namespace) -> str:
    _, items = parse_feed(Path(args.feed), args.repo, "release-line")
    check_line_rules(items, args.line_start_build, args.current_build, args.current_version, "release-line", allow_current=True)
    current = next(i for i in items if i.build == args.current_build)
    check_start_identity(args.line_start_build, args.line_start_version, current.build, current.version, current.tag)
    return "release-line feed OK: " + ", ".join(f"{i.version} (build {i.build}, major {i.major})" for i in items)


def cmd_list_retained(args: argparse.Namespace) -> str:
    _, items = parse_feed(Path(args.feed), args.repo, "release-line")
    check_line_rules(items, args.line_start_build, args.current_build, args.current_version, "release-line", allow_current=True)
    retained = [i for i in items if i.build != args.current_build]
    for item in retained:
        print(item.tag)
    return f"{len(retained)} retained release(s)"


def cmd_verify_retained(args: argparse.Namespace) -> str:
    _, items = parse_feed(Path(args.feed), args.repo, "release-line")
    check_line_rules(items, args.line_start_build, args.current_build, args.current_version, "release-line", allow_current=True)
    retained = verify_retained_assets(items, Path(args.release_assets), args.current_build)
    return "retained releases re-verified: " + (", ".join(f"{i.version} ({i.tag}, {i.name} {i.length} bytes)" for i in retained) or "none")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", required=True, help="OWNER/REPO (use $GITHUB_REPOSITORY)")
        p.add_argument("--line-start-build", type=int, default=DEFAULT_LINE_START_BUILD, help="first build of the release line")
        p.add_argument("--line-start-version", default=DEFAULT_LINE_START_VERSION, help="first version of the release line (its tag is app-v<version>)")
        p.add_argument("--current-build", type=int, required=True)
        p.add_argument("--current-version", required=True)

    for name, func in (("plan", cmd_plan), ("compose", cmd_compose)):
        p = sub.add_parser(name)
        common(p)
        p.add_argument("--current-tag", required=True)
        p.add_argument("--current-feed", required=True, help="the fresh single-item feed generate_appcast produced for this release")
        p.add_argument("--previous-feed", help="the previous release-line feed (required after the first release; forbidden for it)")
        p.add_argument("--previous-tag", help="the latest release the previous feed was downloaded from (required with --previous-feed)")
        if name == "compose":
            p.add_argument("--release-assets", help="directory of <tag>.json release payloads for every retained tag")
            p.add_argument("--output", required=True)
        p.set_defaults(func=func)
    for name, func in (("check", cmd_check), ("list-retained", cmd_list_retained), ("verify-retained", cmd_verify_retained)):
        c = sub.add_parser(name)
        common(c)
        c.add_argument("--feed", required=True)
        if name == "verify-retained":
            c.add_argument("--release-assets", required=True, help="directory of freshly fetched <tag>.json release payloads")
        c.set_defaults(func=func)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        summary = args.func(args)
    except LineError as exc:
        print(f"::error::appcast_release_line {args.command}: {exc}", file=sys.stderr)
        return 1
    print(f"appcast_release_line {args.command}: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
