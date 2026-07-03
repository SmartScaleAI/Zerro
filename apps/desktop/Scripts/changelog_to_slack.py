#!/usr/bin/env python3
"""Extract a version's What's New notes from Changelog.swift and emit a Slack
Block Kit payload on stdout.

Reads Changelog.swift on stdin; takes --version and --build. Prints NOTHING
and exits 0 when the version has no entry — the caller (the "Notify Slack of
release" step in .github/workflows/release-app.yml) treats empty output as
"skip the post". The notes are the SAME ones the in-app What's New window
shows: Changelog.swift is the single source of truth, parsed here at release
time so no second copy exists.

This script never touches the network and must never read the webhook URL —
the workflow owns the POST so the secret never enters Python.
"""
import argparse
import json
import re
import sys


def decode_swift(s: str) -> str:
    """Decode the Swift string escapes Changelog.swift uses (\\u{2014} em-dash,
    \\u{2019} apostrophe, \\u{2192} arrow, curly quotes, \\u{2325} option key,
    \\u{2009} thin space, plus \\" and \\\\) into real characters."""
    s = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return s.replace('\\"', '"').replace("\\\\", "\\")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    args = ap.parse_args()
    src = sys.stdin.read()

    # Split into per-entry chunks (each entry starts with `ChangelogEntry(`),
    # then pick the chunk whose `version:` matches exactly. Versions are
    # unique (pinned by WhatsNewPolicyTests.testEntriesAreUniquePerVersion).
    chunks = src.split("ChangelogEntry(")
    target = next(
        (c for c in chunks if re.search(r'version:\s*"%s"' % re.escape(args.version), c)),
        None,
    )
    if target is None:
        return 0  # no entry → caller skips the post

    highlights = [
        decode_swift(m.group(1))
        for m in re.finditer(r'ChangelogHighlight\(\s*"((?:[^"\\]|\\.)*)"', target)
    ]

    bullets = "\n".join("•  " + h for h in highlights) if highlights else "_Released._"
    if len(bullets) > 2900:  # Slack section mrkdwn cap is 3000
        bullets = bullets[:2900] + "…"

    payload = {
        "text": "Zerro %s released" % args.version,  # notification fallback
        "blocks": [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": "\U0001F680 Zerro %s" % args.version,
                    "emoji": True,
                },
            },
            {"type": "section", "text": {"type": "mrkdwn", "text": bullets}},
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": "build %s · <https://getzerro.app|Download>" % args.build,
                    }
                ],
            },
        ],
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
