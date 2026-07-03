# Handoff — Slack notification on app release (from What's New notes)

Goal: when a production app release publishes, post a Slack message with that version's
release notes — the SAME notes shown in the in-app What's New window. Source of truth is
`apps/desktop/Zerro/WhatsNew/Changelog.swift`; do not create a second copy of the notes.

Scope: PRODUCTION releases only (`.github/workflows/release-app.yml`, triggered by
`app-v*` tags). Do NOT touch `release-staging.yml`.

Notes source approach (decided): parse `Changelog.swift` at release time. No app-code
changes, no JSON refactor.

---

## Prerequisites (the human does these — do NOT attempt them)

These are manual and already assigned to Colin; the workflow must degrade gracefully if
the secret isn't set yet (see Task 2's guard), so it's safe to merge before they're done:

1. Create a Slack **Incoming Webhook** (api.slack.com/apps → new app "Zerro Releases" →
   Incoming Webhooks → Add to Workspace → pick the `#releases` channel) and copy the URL.
2. Add it as a **GitHub Actions repository secret** named `SLACK_RELEASE_WEBHOOK_URL`.
   (This is separate from the feedback function's `SLACK_WEBHOOK_URL`, which lives in
   Supabase secrets — different system, different channel.)

---

## Task 1 — Parser script

Add `apps/desktop/Scripts/changelog_to_slack.py`. It reads `Changelog.swift` text on
**stdin**, takes `--version` and `--build`, and prints a Slack Block Kit JSON payload to
**stdout**. If there's no entry for `--version`, it prints NOTHING and exits 0 (the
workflow treats empty output as "skip").

Requirements:
- Find the `ChangelogEntry(` block whose `version:` equals `--version` exactly.
- Within that block, extract each `ChangelogHighlight("…"` first string-literal argument.
- Decode Swift escapes so Slack shows real characters, not `\u{…}`:
  - `\u{XXXX}` → the Unicode code point (the file uses `\u{2014}` em-dash, `\u{2019}`
    apostrophe, `\u{2192}` →, `\u{201C}`/`\u{201D}` curly quotes, `\u{2325}` ⌥,
    `\u{2009}` thin space — all must decode),
  - `\"` → `"`, `\\` → `\`.
- Build the payload (below) and print it. No network calls here, and NEVER read or print
  the webhook URL from this script — the workflow owns the POST so the secret never
  enters Python.
- If the matched entry has zero highlights, still emit a minimal payload (header +
  download context, section text `_Released._`).

Reference implementation (adjust as needed, keep the contract):

```python
#!/usr/bin/env python3
"""Extract a version's What's New notes from Changelog.swift and emit a Slack
Block Kit payload on stdout. Reads Changelog.swift on stdin. Prints nothing and
exits 0 when the version has no entry (caller then skips the post)."""
import argparse, json, re, sys

def decode_swift(s: str) -> str:
    s = re.sub(r'\\u\{([0-9A-Fa-f]+)\}', lambda m: chr(int(m.group(1), 16)), s)
    return s.replace('\\"', '"').replace('\\\\', '\\')

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    args = ap.parse_args()
    src = sys.stdin.read()

    # Split into per-entry chunks (each entry starts with `ChangelogEntry(`),
    # then pick the chunk whose `version:` matches exactly.
    chunks = src.split("ChangelogEntry(")
    target = next(
        (c for c in chunks if re.search(r'version:\s*"%s"' % re.escape(args.version), c)),
        None,
    )
    if target is None:
        return 0  # no entry → caller skips

    highlights = [
        decode_swift(m.group(1))
        for m in re.finditer(r'ChangelogHighlight\(\s*"((?:[^"\\]|\\.)*)"', target)
    ]

    bullets = "\n".join("•  " + h for h in highlights) if highlights else "_Released._"
    if len(bullets) > 2900:                         # Slack section mrkdwn cap is 3000
        bullets = bullets[:2900] + "…"

    payload = {
        "text": "Zerro %s released" % args.version,   # notification fallback
        "blocks": [
            {"type": "header",
             "text": {"type": "plain_text", "text": "\U0001F680 Zerro %s" % args.version,
                      "emoji": True}},
            {"type": "section", "text": {"type": "mrkdwn", "text": bullets}},
            {"type": "context", "elements": [
                {"type": "mrkdwn",
                 "text": "build %s · <https://getzerro.app|Download>" % args.build}]},
        ],
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

---

## Task 2 — Workflow step in `release-app.yml`

Add ONE step as the LAST step of the `release` job, so it fires only after a clean
release. Key constraints:

- `if: success()` — never post for a failed release.
- `working-directory: .` — the job's default working-directory is `apps/desktop`; this
  step runs git + the script from the repo root, so override it.
- Read the changelog **by commit SHA**, not the working tree: the "Publish appcast"
  step earlier runs `git switch main`, so the runner is no longer on the tag tree by the
  end. `git show "$GITHUB_SHA:apps/desktop/Zerro/WhatsNew/Changelog.swift"` always reads
  the exact released commit's changelog (works for both tag pushes and manual
  `workflow_dispatch`).
- **Secret guard**: skip cleanly if `SLACK_RELEASE_WEBHOOK_URL` is unset (so the workflow
  is safe before Colin adds the secret, and on forks). Put the secret in `env`, not in the
  step `if`.
- **Best-effort**: the release is already published by this point — a Slack failure must
  NOT fail the job. Log `::warning::` on non-2xx / unreachable and exit 0.
- **Secret hygiene**: no `set -x`, never echo the URL (mirror the feedback edge function's
  contract).

```yaml
      # ----------------------------------------------------------------------
      # Post the release notes to Slack — the SAME notes shown in the in-app
      # What's New window (parsed from Changelog.swift). Best-effort: the
      # release is already live, so a Slack hiccup only warns.
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
          git show "$GITHUB_SHA:apps/desktop/Zerro/WhatsNew/Changelog.swift" \
            | python3 apps/desktop/Scripts/changelog_to_slack.py \
                --version "$VER" --build "$BUILD" > payload.json || true
          if [ ! -s payload.json ]; then
            echo "::warning::No Changelog.swift entry for $VER — skipping Slack post."
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

---

## Task 3 — Docs

In `docs/DEPLOY-RUNBOOK.md`, near the existing "add a Changelog.swift entry every release"
note, add: production releases now post the release notes to Slack, sourced from that same
`Changelog.swift` entry; requires the `SLACK_RELEASE_WEBHOOK_URL` GitHub Actions secret;
if the entry is missing the post is skipped with a warning (the release still succeeds).
Optionally cross-note it in `apps/desktop/Scripts/README-release.md` if that's where
release-secret setup is documented.

---

## Verification

- **Local parser test** (no secret, no network):
  ```
  git show HEAD:apps/desktop/Zerro/WhatsNew/Changelog.swift \
    | python3 apps/desktop/Scripts/changelog_to_slack.py --version 1.4.22 --build 250 \
    | python3 -m json.tool
  ```
  Confirm: bullets present, em-dashes/→/⌥/curly quotes render as real characters (no
  `\u{…}`), header is "🚀 Zerro 1.4.22".
- Run the same for a version with NO entry (e.g. `--version 9.9.9`) → prints nothing,
  exits 0.
- Optional end-to-end: paste the emitted `payload.json` into Slack's Block Kit Builder
  (app.slack.com/block-kit-builder) to eyeball formatting, or `curl` it to a throwaway
  test webhook.
- YAML sanity: the new step parses (the workflow still loads) and doesn't disturb existing
  steps.

## Commit / PR

Branch off `staging` (or wherever release-workflow changes normally land — check how
`release-app.yml` was last modified). Commit the script + workflow step + docs. Do NOT
commit any webhook URL. Open the PR; note in the description that
`SLACK_RELEASE_WEBHOOK_URL` must be set as a repo secret for the post to fire.
