#!/usr/bin/env python3
"""Pre-release gate: fail when the version being released has no What's New entry.

The in-app What's New window auto-pops only when Changelog.swift has an entry
whose `version:` exactly matches the released CFBundleShortVersionString
(WhatsNewPolicy's `hasEntry` guard). Versions 1.4.24-1.4.28 shipped without an
entry, so the pop silently stopped firing and the About history went stale;
this check turns that silent skip into a release-blocking error.

Detection reuses changelog_to_slack.highlights_for() (the same parser the Slack
release post uses), so the gate and the notification can never disagree about
whether an entry exists.

Wired in:
  * .github/workflows/auto-release.yml  - blocks BEFORE the app-v* tag is pushed
  * .github/workflows/release-app.yml   - blocks before the Xcode build (covers
    hand-pushed tags and workflow_dispatch)
  * Scripts/cut-release.sh / release.sh - local preflight

Intentional internal-only releases (allowed by the runbook) skip the gate by:
  * putting "[no-changelog]" anywhere in the release PR title / commit message
    (passed via --commit-message), or
  * setting ZERRO_ALLOW_NO_CHANGELOG=1 in the environment (local scripts).

Exit codes: 0 = entry present (or intentionally skipped); 1 = missing entry,
entry without highlights, or unreadable input.
"""
import argparse
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from changelog_to_slack import highlights_for  # noqa: E402

SKIP_MARKER = "[no-changelog]"


def fail(message: str, hint: str) -> int:
    # In GitHub Actions, surface the one-line summary as an error annotation.
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print("::error::%s" % message)
    print("error: %s" % message, file=sys.stderr)
    print(hint, file=sys.stderr)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version",
                    help="marketing version to check (default: read --version-file)")
    ap.add_argument("--version-file", default=str(SCRIPT_DIR.parent / "VERSION"),
                    help="file holding the marketing version (default: apps/desktop/VERSION)")
    ap.add_argument("--changelog",
                    default=str(SCRIPT_DIR.parent / "Zerro" / "WhatsNew" / "Changelog.swift"),
                    help="path to Changelog.swift")
    ap.add_argument("--commit-message", default="",
                    help="release commit/PR message; a %s marker in it skips the check"
                         % SKIP_MARKER)
    args = ap.parse_args()

    if os.environ.get("ZERRO_ALLOW_NO_CHANGELOG") == "1":
        print("check_changelog_entry: skipped (ZERRO_ALLOW_NO_CHANGELOG=1 set; "
              "intentional internal-only release).")
        return 0
    if SKIP_MARKER in args.commit_message:
        print("check_changelog_entry: skipped (%s marker in the release message; "
              "intentional internal-only release)." % SKIP_MARKER)
        return 0

    version = (args.version or "").strip()
    if not version:
        try:
            version = Path(args.version_file).read_text(encoding="utf-8").strip()
        except OSError as e:
            return fail("could not read version file %s (%s)" % (args.version_file, e),
                        "Pass --version explicitly or fix --version-file.")
    if not version:
        return fail("no version to check (empty VERSION file and no --version).",
                    "Pass --version explicitly or fix --version-file.")

    changelog = Path(args.changelog)
    try:
        src = changelog.read_text(encoding="utf-8")
    except OSError as e:
        return fail("could not read %s (%s)" % (changelog, e),
                    "Pass --changelog explicitly.")

    highlights = highlights_for(version, src)
    if highlights:
        print("check_changelog_entry: OK - %s has a What's New entry with %d highlight(s)."
              % (version, len(highlights)))
        return 0

    if highlights == []:
        problem = ("Changelog.swift has an entry for %s but zero ChangelogHighlight "
                   "bullets in it" % version)
    else:
        problem = "Changelog.swift has no entry for version %s" % version
    return fail(
        "%s. The in-app What's New pop would silently skip this release." % problem,
        "Add a ChangelogEntry for %s at the TOP of apps/desktop/Zerro/WhatsNew/"
        "Changelog.swift in the same PR that bumps apps/desktop/VERSION\n"
        "(see apps/desktop/Scripts/RELEASE-AUTOMATION.md). For an intentional internal-only release, "
        "put %s in the release PR title / commit message,\n"
        "or set ZERRO_ALLOW_NO_CHANGELOG=1 for the local scripts." % (version, SKIP_MARKER))


if __name__ == "__main__":
    sys.exit(main())
