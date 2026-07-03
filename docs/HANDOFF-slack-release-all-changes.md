# Handoff — Slack release notification: post ALL changes + flag missing entry

Builds on PR #51 (the existing "Notify Slack of release" step + `changelog_to_slack.py`).
Two changes, both decided with Colin:

1. The Slack message now shows **every** change in the release (internal + user-facing),
   not just the curated What's New notes — so internal team members see everything that
   shipped. The complete list comes from the git commit log; the curated user-facing
   highlights (from `Changelog.swift`) still appear on top when an entry exists.
2. **No build-blocking guard.** When a release has no user-facing `Changelog.swift` entry
   (a legit internal-only release, OR a forgotten entry), the release still succeeds and
   the Slack message shows a visible ⚠️ flag line instead. Do NOT add a pre-build failing
   guard or touch `ci.yml`.

Context for why: `1.4.24` shipped with no user-facing changes (its only app commit was the
Slack CI itself), so it correctly had no What's New entry — and the old step therefore
skipped the Slack post entirely. The fix is to source the full list from commits so the
post always fires, and to surface the missing-entry case rather than swallow it.

`Changelog.swift` and the in-app What's New window are UNCHANGED — still user-facing only.

Scope: production release workflow only (`.github/workflows/release-app.yml`). Leave
`release-staging.yml` alone.

---

## Task 1 — Rewrite `apps/desktop/Scripts/changelog_to_slack.py`

Replace the script with the version below. It has been tested locally against the real
`Changelog.swift` (see Verification). Changes from the current script:
- New `--commits-file` (one commit subject per line) → the "All changes" section.
- New `--compare-url` → a "Full diff" link in the footer + the truncation tail.
- **Always emits a payload now** (the old "print nothing when no entry" contract is gone —
  the post must always fire). When the version has no entry, the What's New section shows a
  `:warning:` flag line.
- Two-section Block Kit: *What's New* (highlights or flag) + *All changes* (commit list).

```python
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
```

Keep it network-free; the webhook URL must never enter Python.

---

## Task 2 — Update the "Notify Slack of release" step in `release-app.yml`

Replace the existing step's `run:` with the version below. What changed:
- Derives the previous app release tag and builds the app-only commit list for this
  release (`git log --no-merges … -- apps/desktop/`).
- Builds a GitHub compare URL for the "Full diff" link.
- Passes `--commits-file` and `--compare-url` to the script.
- Everything else stays: `if: success()`, `working-directory: .`, secret guard in `env`,
  reads `Changelog.swift` by `$GITHUB_SHA`, best-effort POST (warn, never fail the job),
  no `set -x`.

```yaml
      - name: Notify Slack of release
        if: success()
        working-directory: .
        env:
          SLACK_RELEASE_WEBHOOK_URL: ${{ secrets.SLACK_RELEASE_WEBHOOK_URL }}
          VER: ${{ steps.ver.outputs.marketing }}
          BUILD: ${{ steps.ver.outputs.build }}
        run: |
          set -euo pipefail   # never add `set -x` — it would echo the webhook URL
          if [ -z "${SLACK_RELEASE_WEBHOOK_URL:-}" ]; then
            echo "SLACK_RELEASE_WEBHOOK_URL not set — skipping Slack notification."
            exit 0
          fi
          git fetch --tags --quiet origin || true
          # Previous app release = nearest app-v* tag before this commit. `^` skips
          # the tag on THIS commit so we don't diff against ourselves. Empty on the
          # first-ever release.
          PREV_TAG="$(git describe --tags --abbrev=0 --match 'app-v*' "${GITHUB_SHA}^" 2>/dev/null || true)"
          if [ -n "$PREV_TAG" ]; then
            RANGE="${PREV_TAG}..${GITHUB_SHA}"
            COMPARE_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/compare/${PREV_TAG}...${GITHUB_SHA}"
          else
            RANGE="$GITHUB_SHA"
            COMPARE_URL=""
          fi
          # Every app commit in this release (internal + user-facing), one subject per line.
          git log --no-merges --format='%s' $RANGE -- apps/desktop/ > commits.txt || true
          # User-facing highlights (from the released commit's Changelog.swift, by SHA —
          # the runner is on a detached tag) + the full commit list → Block Kit payload.
          git show "$GITHUB_SHA:apps/desktop/Zerro/WhatsNew/Changelog.swift" 2>/dev/null \
            | python3 apps/desktop/Scripts/changelog_to_slack.py \
                --version "$VER" --build "$BUILD" \
                --commits-file commits.txt --compare-url "$COMPARE_URL" > payload.json || true
          if [ ! -s payload.json ]; then
            echo "::warning::Could not build Slack payload for $VER — skipping."
            exit 0
          fi
          code="$(curl -s -o /tmp/slack_resp -w '%{http_code}' -X POST \
            -H 'Content-type: application/json' \
            --data @payload.json "$SLACK_RELEASE_WEBHOOK_URL" || echo 000)"
          if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
            echo "::warning::Slack notification failed (HTTP $code) — release already published."
          else
            echo "Posted release notes for $VER to Slack."
          fi
```

Notes:
- `fetch-depth: 0` on the checkout (already set) means tags + full history are present, so
  `git describe --match 'app-v*'` resolves. The `git fetch --tags` is a cheap safety net.
- `git show "$GITHUB_SHA:…Changelog.swift"` failing (file absent at that commit) is fine —
  `|| true` swallows it, Python gets empty stdin → the ⚠️ flag line, and the commit list
  still populates.
- If you'd rather drop the mechanical version-bump line from "All changes", pipe the log
  through `grep -vE '^chore: [Bb]ump version'` — optional; Colin is fine with the noise.

---

## Task 3 — Docs

Update the Slack note in `docs/DEPLOY-RUNBOOK.md` (added by PR #51) to reflect the new
behavior: the release Slack post now lists **all** app changes for the release (from the
commit log) plus the user-facing What's New highlights when present; a release with no
`Changelog.swift` entry still posts, with a ⚠️ flag line (no build failure — internal-only
releases are expected). The in-app What's New window is unaffected (still user-facing only).

---

## Verification

Reference output confirmed locally (macOS runner has `python3`):

- **Has entry (1.4.22) + commits** → *What's New* shows the 5 decoded bullets (real
  `—`, `'`), *All changes (N)* lists the commit subjects, footer has `Full diff` +
  `Download`.
- **No entry (1.4.24) + commits** → *What's New* = `:warning: No user-facing What's New
  entry for 1.4.24 …`, *All changes (N)* still lists the commits. Post still fires.
- Block order is `header, section, divider, section, context`; `text` fallback present;
  valid JSON.

Repro:
```
CL="$(git show origin/staging:apps/desktop/Zerro/WhatsNew/Changelog.swift)"
printf '%s\n' 'feat: X' 'chore: Bump version to 1.4.24' 'fix: Y' > /tmp/commits.txt
echo "$CL" | python3 apps/desktop/Scripts/changelog_to_slack.py \
  --version 1.4.24 --build 260 --commits-file /tmp/commits.txt \
  --compare-url 'https://github.com/OWNER/REPO/compare/app-v1.4.23...app-v1.4.24' \
  | python3 -m json.tool
```
Also paste the emitted JSON into Slack's Block Kit Builder to eyeball formatting.

## Commit / PR

Branch off `staging`. Commit the script + workflow step + docs. No webhook URL in the repo.
Open the PR against `staging`; note that behavior is live once merged (the
`SLACK_RELEASE_WEBHOOK_URL` secret already exists).

## One-off: backfill the 1.4.24 post (optional)

1.4.24 already shipped with no Slack post. To send it after this merges, run the repro
command above for `--version 1.4.24` with the real commit range
(`git log --no-merges --format='%s' app-v1.4.23..app-v1.4.24 -- apps/desktop/`) and
`curl` the payload to the `_releases` webhook once. (The in-app What's New popup for 1.4.24
can't be recovered — that version's "last seen" marker already advanced on those users'
machines.)
