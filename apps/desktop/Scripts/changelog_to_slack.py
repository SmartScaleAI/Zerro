#!/usr/bin/env python3
"""Build a Slack Block Kit payload for a release.

Two sections:
  * "What's New" — user-facing highlights from Changelog.swift (stdin). When the
    released version has no entry, a visible flag line is shown instead (internal-
    only release, or a forgotten entry — either way the team sees it).
  * "All changes" — every app commit in this release (--commits-file), so internal
    members see everything shipped, user-facing or not.

Always prints a payload (the notification never silently skips). Never reads the
webhook URL — the workflow owns the POST.
"""
import argparse, json, re, sys

SECTION_CAP = 2800  # Slack section mrkdwn hard cap is 3000; leave headroom.

def decode_swift(s: str) -> str:
    s = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return s.replace('\\"', '"').replace("\\\\", "\\")

def highlights_for(version: str, src: str):
    chunks = src.split("ChangelogEntry(")
    target = next((c for c in chunks
                   if re.search(r'version:\s*"%s"' % re.escape(version), c)), None)
    if target is None:
        return None  # no entry for this version
    return [decode_swift(m.group(1)) for m in
            re.finditer(r'ChangelogHighlight\(\s*"((?:[^"\\]|\\.)*)"', target)]

def capped(lines, compare_url):
    out, total = [], 0
    for ln in lines:
        if total + len(ln) + 1 > SECTION_CAP:
            tail = "…and %d more" % (len(lines) - len(out))
            if compare_url:
                tail += " — <%s|full diff>" % compare_url
            out.append(tail)
            break
        out.append(ln); total += len(ln) + 1
    return "\n".join(out)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--commits-file")
    ap.add_argument("--compare-url", default="")
    args = ap.parse_args()

    src = sys.stdin.read()
    hl = highlights_for(args.version, src)
    if hl:
        whats_new = "\n".join("•  " + h for h in hl)
    elif hl == []:
        whats_new = "_Entry present but no highlights._"
    else:
        whats_new = (":warning:  No user-facing What's New entry for %s "
                     "(internal-only release, or the entry was forgotten)." % args.version)

    commits = []
    if args.commits_file:
        with open(args.commits_file, encoding="utf-8") as f:
            commits = [l.strip() for l in f if l.strip()]
    all_changes = capped(["•  " + c for c in commits], args.compare_url) if commits \
        else "_No app commits in this release range._"

    ctx = "build %s" % args.build
    if args.compare_url:
        ctx += " · <%s|Full diff>" % args.compare_url
    ctx += " · <https://getzerro.app|Download>"

    payload = {
        "text": "Zerro %s released" % args.version,
        "blocks": [
            {"type": "header", "text": {"type": "plain_text",
                "text": "\U0001F680 Zerro %s" % args.version, "emoji": True}},
            {"type": "section", "text": {"type": "mrkdwn",
                "text": "*What's New*\n%s" % whats_new}},
            {"type": "divider"},
            {"type": "section", "text": {"type": "mrkdwn",
                "text": "*All changes (%d)*\n%s" % (len(commits), all_changes)}},
            {"type": "context", "elements": [{"type": "mrkdwn", "text": ctx}]},
        ],
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0

if __name__ == "__main__":
    sys.exit(main())
