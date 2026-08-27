#!/usr/bin/env python3
"""
Deterministic tests for appcast_publish_guard.py.

Run from apps/desktop:  python3 -m unittest Scripts/test_appcast_publish_guard.py -v
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
STORAGE = "https://waripvlpcpwdmacpjiqc.supabase.co/storage/v1/object/public/downloads/"


def feed(items: list[dict]) -> str:
    parts = [f'<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>Zerro</title>']
    for it in items:
        attrs = [f'url="{it["url"]}"']
        if it.get("length") is not None:
            attrs.append(f'length="{it["length"]}"')
        attrs.append('type="application/octet-stream"')
        if it.get("sig") is not None:
            attrs.append(f'sparkle:edSignature="{it["sig"]}"')
        parts.append(
            f"<item><title>{it['short']}</title><sparkle:version>{it['build']}</sparkle:version>"
            f"<sparkle:shortVersionString>{it['short']}</sparkle:shortVersionString>"
            f"<enclosure {' '.join(attrs)}/></item>"
        )
    parts.append("</channel></rss>")
    return "".join(parts)


def item(build: int, short: str, *, url: str = STORAGE + "ZerroStaging.dmg", length: int | None = 8000000, sig: str | None = "SIG=="):
    return {"build": build, "short": short, "url": url, "length": length, "sig": sig}


class GuardFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def write(self, name: str, text: str) -> Path:
        path = self.tmp / name
        path.write_text(text, encoding="utf-8")
        return path

    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        proc = subprocess.run([sys.executable, str(HERE / "appcast_publish_guard.py"), *argv], capture_output=True, text=True, check=False)
        return proc.returncode, proc.stdout, proc.stderr

    def guard(self, live: Path, build: int, version: str, *extra: str) -> tuple[int, str, str]:
        return self.run_cli("guard", "--live", str(live), "--current-build", str(build), "--current-version", version, *extra)


class GuardTests(GuardFixture):
    def test_newer_build_is_allowed(self) -> None:
        live = self.write("live.xml", feed([item(568, "1.4.45")]))
        code, out, _ = self.guard(live, 569, "1.4.46")
        self.assertEqual(code, 0)
        self.assertIn("newer than the live newest build 568", out)

    def test_older_build_is_refused(self) -> None:
        live = self.write("live.xml", feed([item(569, "1.4.46")]))
        code, _, err = self.guard(live, 568, "1.4.45")
        self.assertEqual(code, 1)
        self.assertIn("OLDER than the live newest build 569", err)

    def test_equal_build_matching_version_with_verified_tag_is_allowed(self) -> None:
        live = self.write("live.xml", feed([item(569, "1.4.46")]))
        code, out, _ = self.guard(live, 569, "1.4.46", "--tag-matches-commit")
        self.assertEqual(code, 0)
        self.assertIn("same-release republish allowed", out)

    def test_equal_build_without_verified_tag_is_refused(self) -> None:
        live = self.write("live.xml", feed([item(569, "1.4.46")]))
        code, _, err = self.guard(live, 569, "1.4.46")
        self.assertEqual(code, 1)
        self.assertIn("requires the release tag to resolve to this workflow commit", err)

    def test_equal_build_conflicting_version_is_refused_even_with_tag(self) -> None:
        live = self.write("live.xml", feed([item(569, "1.4.46")]))
        code, _, err = self.guard(live, 569, "1.4.47", "--tag-matches-commit")
        self.assertEqual(code, 1)
        self.assertIn("a different release reused the build number", err)

    def test_cumulative_feed_uses_the_newest_item(self) -> None:
        live = self.write("live.xml", feed([item(527, "1.4.31", url=STORAGE + "Zerro-527.dmg"), item(521, "1.4.30", url=STORAGE + "Zerro-521.dmg")]))
        self.assertEqual(self.guard(live, 530, "1.4.32")[0], 0)
        self.assertEqual(self.guard(live, 524, "1.4.99")[0], 1)
        self.assertEqual(self.guard(live, 527, "1.4.31", "--tag-matches-commit")[0], 0)

    def test_missing_live_feed_fails_closed(self) -> None:
        code, _, err = self.guard(self.tmp / "absent.xml", 570, "1.4.47")
        self.assertEqual(code, 1)
        self.assertIn("is missing", err)

    def test_malformed_live_feed_fails_closed(self) -> None:
        live = self.write("broken.xml", "<rss><channel><item><enclosure url='x'")
        code, _, err = self.guard(live, 570, "1.4.47")
        self.assertEqual(code, 1)
        self.assertIn("not well-formed XML", err)

    def test_empty_or_non_feed_document_fails_closed(self) -> None:
        empty = self.write("empty.xml", f'<rss xmlns:sparkle="{SPARKLE}"><channel><title>Zerro</title></channel></rss>')
        code, _, err = self.guard(empty, 570, "1.4.47")
        self.assertEqual(code, 1)
        self.assertIn("has no <item>", err)
        html = self.write("html.xml", "<html><body>Not Found</body></html>")
        code, _, err = self.guard(html, 570, "1.4.47")
        self.assertEqual(code, 1)
        self.assertIn("expected <rss>", err)

    def test_item_without_integer_version_fails_closed(self) -> None:
        live = self.write("bad.xml", feed([item(568, "1.4.45")]).replace("<sparkle:version>568</sparkle:version>", "<sparkle:version>x</sparkle:version>"))
        code, _, err = self.guard(live, 570, "1.4.47")
        self.assertEqual(code, 1)
        self.assertIn("no integer sparkle:version", err)


class CheckTests(GuardFixture):
    def check(self, path: Path, *extra: str) -> tuple[int, str, str]:
        return self.run_cli("check", "--feed", str(path), "--expect-build", "570", "--expect-version", "1.4.47", "--expect-url", STORAGE + "ZerroStaging.dmg", "--expect-length", "8000000", *extra)

    def test_generated_single_item_feed_passes(self) -> None:
        path = self.write("gen.xml", feed([item(570, "1.4.47")]))
        code, out, err = self.check(path, "--expect-items", "1")
        self.assertEqual(code, 0, err)
        self.assertIn("advertises build 570 (1.4.47)", out)

    def test_cumulative_feed_passes_when_current_is_newest(self) -> None:
        path = self.write("gen.xml", feed([item(570, "1.4.47", url=STORAGE + "Zerro-570.dmg"), item(527, "1.4.31", url=STORAGE + "Zerro-527.dmg")]))
        code, _, err = self.run_cli("check", "--feed", str(path), "--expect-build", "570", "--expect-version", "1.4.47", "--expect-url", STORAGE + "Zerro-570.dmg", "--expect-length", "8000000")
        self.assertEqual(code, 0, err)

    def test_wrong_length_signature_url_version_count_or_not_newest_fail(self) -> None:
        cases = {
            "length": (feed([item(570, "1.4.47", length=1)]), "enclosure length is '1'"),
            "signature": (feed([item(570, "1.4.47", sig=None)]), "no sparkle:edSignature"),
            "url": (feed([item(570, "1.4.47", url=STORAGE + "ZerroStaging-570.dmg")]), "enclosure url is"),
            "version": (feed([item(570, "1.4.46")]), "advertises version '1.4.46'"),
            "count": (feed([item(570, "1.4.47"), item(569, "1.4.46")]), "expected exactly 1"),
            "absent": (feed([item(569, "1.4.46")]), "0 item(s) for build 570"),
            "not-newest": (feed([item(570, "1.4.47"), item(571, "1.4.48")]), "not the newest"),
        }
        for name, (text, expected) in cases.items():
            path = self.write(f"{name}.xml", text)
            extra = ("--expect-items", "1") if name in ("count",) else ()
            code, _, err = self.check(path, *extra)
            self.assertEqual(code, 1, name)
            self.assertIn(expected, err, name)


if __name__ == "__main__":
    unittest.main()
