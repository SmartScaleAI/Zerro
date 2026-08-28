#!/usr/bin/env python3
"""
release_metadata.py — the single source of truth for Zerro's release metadata.

Two checked-in files under apps/desktop are authoritative:

  VERSION       the marketing version, exactly X.Y.Z (CFBundleShortVersionString)
  BUILD_NUMBER  the integer build Sparkle compares, a positive integer
                (CFBundleVersion / CURRENT_PROJECT_VERSION)

Both release workflows (release-app.yml, release-staging.yml) read them
through this script and pass the values to xcodebuild as MARKETING_VERSION and
CURRENT_PROJECT_VERSION; nothing derives a build number from Git history. The
build number is bumped by hand in the same change that ships it and must
always exceed the newest published build for its channel (Sparkle refuses to
offer an update otherwise).

Commands (standard library only; every rule fails closed with a ::error::
line and a non-zero exit):

  read                  Validate both files and print `marketing=X.Y.Z` and
                        `build=N` (one per line), suitable for `$GITHUB_OUTPUT`.
  check-project         Every Zerro app-target build configuration in
                        Zerro.xcodeproj/project.pbxproj must carry exactly
                        MARKETING_VERSION = <VERSION> and
                        CURRENT_PROJECT_VERSION = <BUILD_NUMBER>, so a local
                        build reports the same version CI ships and the files
                        cannot drift from the project silently.
  staging-tag           Print the staging tag for the checked-in VERSION:
                        staging-v<X.Y.Z> (e.g. staging-v1.0.0).
  parse-staging-tag TAG Parse a plain staging tag (exactly staging-v<X.Y.Z>)
                        and print `marketing=`. Build-qualified tags such as
                        staging-v1.0.0-build.1000, prefixes, suffixes,
                        incomplete versions, and leading zeros are rejected.
                        With --require-match, the tag's version must equal the
                        checked-in VERSION exactly. Every new staging release
                        increments BOTH VERSION and BUILD_NUMBER
                        (staging-v1.0.0 / 1000, then staging-v1.0.1 / 1001,
                        …): one visible version per staging release, and a
                        tag is never moved or reused. BUILD_NUMBER is validated
                        independently by `read` and `check-project`.
  production-tag        Print the production tag for the checked-in VERSION:
                        app-v<X.Y.Z>.
  validate              Validate values given on the command line with the
                        same rules as the files: --marketing must be exactly
                        X.Y.Z (no prefix, no suffix, no missing component, no
                        leading zeros) and --build must be a positive integer
                        (no 0, no sign, no decimals, no leading zeros).
                        Scripts/cut-release.sh and Scripts/release.sh call this
                        before they touch anything, so every entry point
                        enforces one rule set.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DESKTOP_DIR = Path(__file__).resolve().parent.parent
VERSION_FILE = DESKTOP_DIR / "VERSION"
BUILD_NUMBER_FILE = DESKTOP_DIR / "BUILD_NUMBER"
PBXPROJ = DESKTOP_DIR / "Zerro.xcodeproj" / "project.pbxproj"
APP_TARGET = "Zerro"

VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
BUILD_RE = re.compile(r"^[1-9]\d*$")
STAGING_TAG_RE = re.compile(r"^staging-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$")
BUILD_QUALIFIED_STAGING_TAG_RE = re.compile(r"^staging-v\d+\.\d+\.\d+-build\.\d*$")


class MetadataError(Exception):
    """A fail-closed condition. The message is the whole diagnosis."""


def _read(path: Path, label: str) -> str:
    """Return the file's single value. The file must contain exactly that
    value, optionally followed by one conventional final newline: no leading
    or trailing spaces or tabs, no extra blank lines, no second value line, no
    carriage returns, nothing else."""
    try:
        # Decoded from bytes so \r\n is NOT translated — a CRLF file is rejected below.
        text = path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise MetadataError(f"cannot read {label} file {path}: {exc}") from exc
    body = text[:-1] if text.endswith("\n") else text
    if body == "":
        raise MetadataError(f"{label} file {path} is empty")
    if "\n" in body or "\r" in body:
        raise MetadataError(f"{label} file {path} must contain exactly one line (a single value plus an optional final newline)")
    if any(ch.isspace() for ch in body):
        raise MetadataError(f"{label} file {path} contains whitespace around or inside the value {body!r} — the file must be exactly the value plus an optional final newline")
    return body


def validate_version(value: str, label: str = "VERSION") -> str:
    """Return `value` if it is exactly X.Y.Z; raise otherwise."""
    if not VERSION_RE.fullmatch(value):
        raise MetadataError(
            f"{label} {value!r} is not exactly X.Y.Z (three dot-separated integers, no prefix, no suffix, no leading zeros)"
        )
    return value


def validate_build_number(value: str, label: str = "BUILD_NUMBER") -> int:
    """Return `value` as an int if it is a positive integer; raise otherwise."""
    if not BUILD_RE.fullmatch(value):
        raise MetadataError(f"{label} {value!r} is not a positive integer (digits only, no 0, no sign, no decimals, no leading zeros)")
    return int(value)


def read_version(path: Path = VERSION_FILE) -> str:
    return validate_version(_read(path, "VERSION"))


def read_build_number(path: Path = BUILD_NUMBER_FILE) -> int:
    return validate_build_number(_read(path, "BUILD_NUMBER"))


def staging_tag(marketing: str) -> str:
    return f"staging-v{marketing}"


def production_tag(marketing: str) -> str:
    return f"app-v{marketing}"


def parse_staging_tag(tag: str) -> str:
    """Return the marketing version named by a plain staging tag, or raise."""
    match = STAGING_TAG_RE.fullmatch(tag)
    if match:
        return match.group(1)
    if BUILD_QUALIFIED_STAGING_TAG_RE.fullmatch(tag):
        raise MetadataError(
            f"{tag!r} is a build-qualified tag; staging tags are exactly staging-v<X.Y.Z> (e.g. staging-v1.0.0) — "
            f"a new staging release bumps BOTH VERSION and BUILD_NUMBER and gets its own plain tag"
        )
    raise MetadataError(f"{tag!r} is not a staging tag (expected exactly staging-v<X.Y.Z>: no prefix, no suffix, no leading zeros)")


# --------------------------------------------------------------------------
# Xcode project drift check


def _target_configuration_ids(pbxproj: str, target_name: str) -> list[str]:
    """Return the XCBuildConfiguration ids listed by the target's configuration list."""
    target = re.search(
        r"buildConfigurationList = ([0-9A-F]+) /\* Build configuration list for PBXNativeTarget \"" + re.escape(target_name) + r"\" \*/",
        pbxproj,
    )
    if not target:
        raise MetadataError(f"project.pbxproj has no build configuration list for target {target_name!r}")
    list_id = target.group(1)
    block = re.search(re.escape(list_id) + r" /\* Build configuration list for PBXNativeTarget \"" + re.escape(target_name)
                      + r"\" \*/ = \{.*?buildConfigurations = \((.*?)\);", pbxproj, re.S)
    if not block:
        raise MetadataError(f"cannot read configuration list {list_id} for target {target_name!r}")
    ids = re.findall(r"([0-9A-F]{24}) /\* ([^*]+) \*/", block.group(1))
    if not ids:
        raise MetadataError(f"target {target_name!r} lists no build configurations")
    return [f"{cid} /* {name} */" for cid, name in ids]


def _configuration_settings(pbxproj: str, config_ref: str) -> dict[str, str]:
    cid, name = config_ref.split(" ", 1)
    block = re.search(re.escape(cid) + r" " + re.escape(name) + r" = \{(.*?)\n\t\t\};", pbxproj, re.S)
    if not block:
        raise MetadataError(f"cannot read build configuration {config_ref}")
    settings: dict[str, str] = {}
    for key, value in re.findall(r"^\t\t\t\t([A-Z_][A-Z0-9_]*) = (.*?);$", block.group(1), re.M):
        settings[key] = value.strip().strip('"')
    return settings


def check_project(marketing: str, build: int, pbxproj_path: Path = PBXPROJ, target_name: str = APP_TARGET) -> list[str]:
    """Return the names of the target's configurations, all of which matched."""
    try:
        pbxproj = pbxproj_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise MetadataError(f"cannot read {pbxproj_path}: {exc}") from exc
    checked: list[str] = []
    problems: list[str] = []
    for ref in _target_configuration_ids(pbxproj, target_name):
        name = ref.split("/* ", 1)[1].rstrip(" */")
        settings = _configuration_settings(pbxproj, ref)
        got_marketing = settings.get("MARKETING_VERSION")
        got_build = settings.get("CURRENT_PROJECT_VERSION")
        if got_marketing != marketing:
            problems.append(f"{target_name}/{name}: MARKETING_VERSION = {got_marketing!r}, VERSION file says {marketing!r}")
        if got_build != str(build):
            problems.append(f"{target_name}/{name}: CURRENT_PROJECT_VERSION = {got_build!r}, BUILD_NUMBER file says {build!r}")
        checked.append(name)
    if problems:
        raise MetadataError(
            "Zerro.xcodeproj is out of sync with apps/desktop/VERSION / BUILD_NUMBER — update the project so every "
            "Zerro configuration matches:\n  " + "\n  ".join(problems)
        )
    return checked


# --------------------------------------------------------------------------
# CLI


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version-file", default=str(VERSION_FILE))
    parser.add_argument("--build-file", default=str(BUILD_NUMBER_FILE))
    parser.add_argument("--pbxproj", default=str(PBXPROJ))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("read")
    sub.add_parser("check-project")
    sub.add_parser("staging-tag")
    sub.add_parser("production-tag")
    p = sub.add_parser("parse-staging-tag")
    p.add_argument("tag")
    p.add_argument("--require-match", action="store_true", help="the tag's version must equal the checked-in VERSION exactly")
    v = sub.add_parser("validate", help="validate a marketing version and/or build number given on the command line")
    v.add_argument("--marketing", metavar="X.Y.Z")
    v.add_argument("--build", metavar="N")
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            if args.marketing is None and args.build is None:
                raise MetadataError("validate needs --marketing and/or --build")
            if args.marketing is not None:
                validate_version(args.marketing, "marketing version")
            if args.build is not None:
                validate_build_number(args.build, "build number")
            print("release_metadata validate: OK")
            return 0
        if args.command == "parse-staging-tag":
            marketing = parse_staging_tag(args.tag)
            if args.require_match:
                want_marketing = read_version(Path(args.version_file))
                if marketing != want_marketing:
                    raise MetadataError(
                        f"tag {args.tag!r} names version {marketing}, but apps/desktop/VERSION at this commit is {want_marketing} — "
                        f"the tag must be created from the commit that carries the version it names"
                    )
            print(f"marketing={marketing}")
            return 0
        marketing, build = read_version(Path(args.version_file)), read_build_number(Path(args.build_file))
        if args.command == "read":
            print(f"marketing={marketing}")
            print(f"build={build}")
        elif args.command == "check-project":
            names = check_project(marketing, build, Path(args.pbxproj))
            print(f"release_metadata check-project: OK — {APP_TARGET} configurations {names} carry MARKETING_VERSION={marketing}, CURRENT_PROJECT_VERSION={build}")
        elif args.command == "staging-tag":
            print(staging_tag(marketing))
        elif args.command == "production-tag":
            print(production_tag(marketing))
        return 0
    except MetadataError as exc:
        print(f"::error::release_metadata {args.command}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
