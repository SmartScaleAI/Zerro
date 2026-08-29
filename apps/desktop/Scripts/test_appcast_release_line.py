#!/usr/bin/env python3
"""
Tests for appcast_release_line.py — the newest release from each major in
the release line that begins at app-v1.0.0 / build 1000.

Run from apps/desktop:  python3 -m unittest Scripts/test_appcast_release_line.py -v
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import appcast_release_line as line  # noqa: E402

SPARKLE = line.SPARKLE_NS
REPO = "SmartScaleAI/Zerro"
STORAGE = "https://wjxqmurgwyxwkezncxke.supabase.co/storage/v1/object/public/downloads/"


def gh_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{name}"


def item(version: str, build: int, *, url: str | None = None, length: int | None = None, sig: str | None = "SIG=="):
    return {"version": version, "build": build, "url": url or gh_url(f"app-v{version}", f"Zerro-{build}.dmg"),
            "length": 8_000_000 + build if length is None else length, "sig": sig}


def make_feed(items: list[dict]) -> str:
    parts = ['<?xml version="1.0" standalone="yes"?>', f'<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>Zerro</title><link>https://getzerro.app/</link>']
    for it in items:
        attrs = [f'url="{it["url"]}"']
        if it["length"] is not None:
            attrs.append(f'length="{it["length"]}"')
        attrs.append('type="application/octet-stream"')
        if it["sig"] is not None:
            attrs.append(f'sparkle:edSignature="{it["sig"]}"')
        parts.append(
            f"<item><title>{it['version']}</title><pubDate>Fri, 28 Aug 2026 00:00:00 +0000</pubDate><link>https://getzerro.app/</link>"
            f"<sparkle:version>{it['build']}</sparkle:version><sparkle:shortVersionString>{it['version']}</sparkle:shortVersionString>"
            f"<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure {' '.join(attrs)}/></item>"
        )
    parts.append("</channel></rss>")
    return "".join(parts)


def feed_versions(path: Path) -> list[tuple[str, int]]:
    root = ET.parse(path).getroot()
    out = []
    for el in root.iter("item"):
        out.append((el.find(f"{{{SPARKLE}}}shortVersionString").text, int(el.find(f"{{{SPARKLE}}}version").text)))
    return out


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.assets = self.tmp / "assets"
        self.assets.mkdir()

    def write(self, name: str, text: str) -> Path:
        p = self.tmp / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p

    def release_json(self, version: str, build: int, size: int, *, draft: bool = False, state: str = "uploaded", name: str | None = None) -> None:
        tag = f"app-v{version}"
        (self.assets / f"{tag}.json").write_text(json.dumps({
            "tag_name": tag, "draft": draft, "prerelease": False,
            "assets": [{"name": name or f"Zerro-{build}.dmg", "size": size, "state": state}, {"name": "Zerro.dmg", "size": size, "state": "uploaded"}, {"name": "appcast.xml", "size": 900, "state": "uploaded"}],
        }))

    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        proc = subprocess.run([sys.executable, str(HERE / "appcast_release_line.py"), *argv], capture_output=True, text=True, check=False)
        return proc.returncode, proc.stdout, proc.stderr

    def compose(self, version: str, build: int, current_items: list[dict] | None = None, previous: list[dict] | None = None, *extra: str,
                line_start: int = 1000, tag: str | None = None, previous_tag: str | None = None) -> tuple[int, str, str, Path]:
        current = self.write(f"current-{build}.xml", make_feed(current_items if current_items is not None else [item(version, build)]))
        out = self.tmp / f"out-{build}.xml"
        args = ["compose", "--repo", REPO, "--line-start-build", str(line_start), "--line-start-version", "1.0.0", "--current-build", str(build),
                "--current-version", version, "--current-tag", tag or f"app-v{version}", "--current-feed", str(current),
                "--release-assets", str(self.assets), "--output", str(out), *extra]
        if previous is not None:
            args += ["--previous-feed", str(self.write(f"previous-{build}.xml", make_feed(previous)))]
            if previous_tag != "":
                newest = max(previous, key=lambda i: i["build"]) if previous else None
                args += ["--previous-tag", previous_tag or (f"app-v{newest['version']}" if newest else "app-v0.0.0")]
        code, so, se = self.run_cli(*args)
        return code, so, se, out


class ReleaseLineCompositionTests(Fixture):
    def test_1_0_0_build_1000_starts_fresh_and_ignores_pre_reset_history(self) -> None:
        code, out, err, path = self.compose("1.0.0", 1000)
        self.assertEqual(code, 0, err)
        self.assertEqual(feed_versions(path), [("1.0.0", 1000)])
        self.assertIn(gh_url("app-v1.0.0", "Zerro-1000.dmg"), path.read_text())
        # No release data exists for anything (empty assets dir): nothing was consulted.
        self.assertEqual(list(self.assets.iterdir()), [])
        # Supplying ANY previous feed for the first release is refused — even a
        # valid-looking pre-reset feed (1.4.31 / build 527) is never read in.
        code, _, err, _ = self.compose("1.0.0", 1000, previous=[item("1.4.31", 527)])
        self.assertEqual(code, 1)
        self.assertIn("first release of the line", err)
        # plan prints nothing to fetch for the first release.
        current = self.write("c.xml", make_feed([item("1.0.0", 1000)]))
        code, out, err = self.run_cli("plan", "--repo", REPO, "--current-build", "1000", "--current-version", "1.0.0", "--current-tag", "app-v1.0.0", "--current-feed", str(current))
        self.assertEqual(code, 0, err)
        self.assertEqual([l for l in out.splitlines() if l.startswith("app-v")], [])

    def test_start_identity_is_exactly_1_0_0_build_1000_app_v1_0_0(self) -> None:
        # Build 1000 under any other version or tag fails closed.
        code, _, err, _ = self.compose("1.0.1", 1000)
        self.assertEqual(code, 1)
        self.assertIn("must be exactly version 1.0.0 on tag app-v1.0.0", err)
        code, _, err, _ = self.compose("1.0.0", 1000, tag="app-v1.0.0-rc.1")
        self.assertEqual(code, 1)
        self.assertIn("must be exactly version 1.0.0 on tag app-v1.0.0", err)
        # Version 1.0.0 under any other starting build fails closed.
        code, _, err, _ = self.compose("1.0.0", 1001)
        self.assertEqual(code, 1)
        self.assertIn("must be build 1000", err)
        code, _, err, _ = self.compose("1.0.0", 999)
        self.assertEqual(code, 1)
        # A later release attempting to start over fails closed.
        code, _, err, _ = self.compose("1.0.1", 1001)
        self.assertEqual(code, 1)
        self.assertIn("requires the previous release-line feed", err)
        # `check` applies the identity to a finished feed as well.
        bad = self.write("bad-start.xml", make_feed([item("1.0.1", 1000)]))
        code, _, err = self.run_cli("check", "--repo", REPO, "--current-build", "1000", "--current-version", "1.0.1", "--feed", str(bad))
        self.assertEqual(code, 1)

    def test_1_0_1_replaces_1_0_0_as_the_sole_1x_item(self) -> None:
        code, _, err, path = self.compose("1.0.1", 1001, previous=[item("1.0.0", 1000)])
        self.assertEqual(code, 0, err)
        self.assertEqual(feed_versions(path), [("1.0.1", 1001)])
        # plan needs nothing fetched: the only previous item is replaced.
        current = self.write("c.xml", make_feed([item("1.0.1", 1001)]))
        prev = self.write("p.xml", make_feed([item("1.0.0", 1000)]))
        code, out, _ = self.run_cli("plan", "--repo", REPO, "--current-build", "1001", "--current-version", "1.0.1", "--current-tag", "app-v1.0.1", "--current-feed", str(current), "--previous-feed", str(prev), "--previous-tag", "app-v1.0.0")
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l.startswith("app-v")], [])

    def test_2_0_0_retains_the_final_1x_alongside_2_0_0(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        code, _, err, path = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 0, err)
        self.assertEqual(feed_versions(path), [("2.0.0", 1100), ("1.0.5", 1005)])
        text = path.read_text()
        self.assertIn(gh_url("app-v1.0.5", "Zerro-1005.dmg"), text)
        self.assertIn(gh_url("app-v2.0.0", "Zerro-1100.dmg"), text)
        self.assertIn('sparkle:edSignature="SIG=="', text)
        # plan names exactly the retained 1.x release to fetch.
        current = self.write("c.xml", make_feed([item("2.0.0", 1100)]))
        prev = self.write("p.xml", make_feed([item("1.0.5", 1005)]))
        code, out, _ = self.run_cli("plan", "--repo", REPO, "--current-build", "1100", "--current-version", "2.0.0", "--current-tag", "app-v2.0.0", "--current-feed", str(current), "--previous-feed", str(prev), "--previous-tag", "app-v1.0.5")
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l.startswith("app-v")], ["app-v1.0.5"])

    def test_previous_feed_is_bound_to_the_latest_release_tag(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        # Latest release is app-v1.0.6, but the feed attached to it still says 1.0.5 → stale/replaced.
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)], previous_tag="app-v1.0.6")
        self.assertEqual(code, 1)
        self.assertIn("stale or replaced feed", err)
        # A feed whose newest item is not the latest release (older major newest) is rejected too.
        code, _, err, _ = self.compose("2.0.1", 1101, previous=[item("2.0.0", 1100), item("1.0.5", 1005)], previous_tag="app-v1.0.5")
        self.assertEqual(code, 1)
        self.assertIn("stale or replaced feed", err)
        # Non-production or pre-line tags are rejected as the previous tag.
        for bad in ("staging-v1.0.5", "app-v1.4.31", "v1.0.5", "app-v01.0.5"):
            with self.subTest(bad=bad):
                code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)], previous_tag=bad)
                self.assertEqual(code, 1)
        # --previous-feed without --previous-tag is refused.
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)], previous_tag="")
        self.assertEqual(code, 1)
        self.assertIn("--previous-tag", err)
        # The correct binding passes.
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)], previous_tag="app-v1.0.5")
        self.assertEqual(code, 0, err)

    def test_pre_publish_reverification_rejects_prerelease_and_missing_asset_state(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        code, _, err, path = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 0, err)
        fresh = self.tmp / "fresh"; fresh.mkdir()
        def refetch(**kw):
            (fresh / "app-v1.0.5.json").write_text(json.dumps({
                "tag_name": "app-v1.0.5", "draft": kw.get("draft", False), "prerelease": kw.get("prerelease", False),
                "assets": [dict({"name": "Zerro-1005.dmg", "size": 8_000_000 + 1005, "state": "uploaded"}, **kw.get("asset", {}))],
            }))
            return self.run_cli("verify-retained", "--repo", REPO, "--current-build", "1100", "--current-version", "2.0.0", "--feed", str(path), "--release-assets", str(fresh))
        code, out, err = refetch()
        self.assertEqual(code, 0, err)
        self.assertIn("app-v1.0.5, Zerro-1005.dmg 8001005 bytes", out)
        code, _, err = refetch(prerelease=True)
        self.assertEqual(code, 1); self.assertIn("is a prerelease", err)
        code, _, err = refetch(draft=True)
        self.assertEqual(code, 1); self.assertIn("is a draft", err)
        code, _, err = refetch(asset={"state": None})
        self.assertEqual(code, 1); self.assertIn("expected exactly 'uploaded'", err)
        code, _, err = refetch(asset={"state": "starter"})
        self.assertEqual(code, 1)
        code, _, err = refetch(asset={"size": 1})
        self.assertEqual(code, 1); self.assertIn("feed records length", err)
        # list-retained names exactly the prior-major release.
        code, out, _ = self.run_cli("list-retained", "--repo", REPO, "--current-build", "1100", "--current-version", "2.0.0", "--feed", str(path))
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l.startswith("app-v")], ["app-v1.0.5"])
        # A missing asset state at compose time is rejected as well.
        (self.assets / "app-v1.0.5.json").write_text(json.dumps({"tag_name": "app-v1.0.5", "draft": False, "prerelease": False, "assets": [{"name": "Zerro-1005.dmg", "size": 8_000_000 + 1005}]}))
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1); self.assertIn("expected exactly 'uploaded'", err)

    def test_2_0_1_retains_the_final_1x_and_replaces_2_0_0(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        code, _, err, path = self.compose("2.0.1", 1101, previous=[item("2.0.0", 1100), item("1.0.5", 1005)])
        self.assertEqual(code, 0, err)
        self.assertEqual(feed_versions(path), [("2.0.1", 1101), ("1.0.5", 1005)])
        # The composed feed passes `check` and the other validators' rules.
        code, out, err = self.run_cli("check", "--repo", REPO, "--current-build", "1101", "--current-version", "2.0.1", "--feed", str(path))
        self.assertEqual(code, 0, err)
        self.assertIn("2.0.1 (build 1101, major 2), 1.0.5 (build 1005, major 1)", out)

    def test_a_1x_installation_still_selects_the_final_1x_after_2_0(self) -> None:
        # Mirrors UpdateMajorPolicy: only items of the installed major are
        # offered, the highest build among them wins.
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        _, _, _, path = self.compose("2.0.1", 1101, previous=[item("2.0.0", 1100), item("1.0.5", 1005)])
        items = feed_versions(path)
        def best_for(installed_major: int):
            allowed = [(v, b) for v, b in items if int(v.split(".")[0]) == installed_major]
            return max(allowed, key=lambda x: x[1]) if allowed else None
        self.assertEqual(best_for(1), ("1.0.5", 1005))
        self.assertEqual(best_for(2), ("2.0.1", 1101))
        self.assertIsNone(best_for(3))


class ReleaseLineFailClosedTests(Fixture):
    def test_pre_reset_builds_in_the_previous_feed_are_rejected(self) -> None:
        code, _, err, _ = self.compose("1.0.1", 1001, previous=[item("1.4.31", 527)])
        self.assertEqual(code, 1)
        self.assertIn("predates the release line", err)
        code, _, err, _ = self.compose("1.0.1", 1001, previous=[item("1.0.0", 1000), item("1.4.31", 527)])
        self.assertEqual(code, 1)

    def test_later_release_without_a_previous_feed_fails_closed(self) -> None:
        code, _, err, _ = self.compose("1.0.1", 1001)
        self.assertEqual(code, 1)
        self.assertIn("requires the previous release-line feed", err)

    def test_missing_or_mismatched_retained_asset_fails_closed(self) -> None:
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1, "no release data for app-v1.0.5")
        self.assertIn("release data for app-v1.0.5 is missing", err)
        self.release_json("1.0.5", 1005, 8_000_000 + 1005 + 1)
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("bytes but the feed records length", err)
        self.release_json("1.0.5", 1005, 8_000_000 + 1005, draft=True)
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("is a draft", err)
        self.release_json("1.0.5", 1005, 8_000_000 + 1005, name="Zerro-1004.dmg")
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("does not carry exactly one Zerro-1005.dmg", err)
        self.release_json("1.0.5", 1005, 8_000_000 + 1005, state="starter")
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("state 'starter'", err)

    def test_malformed_versions_mutable_aliases_and_storage_urls_are_rejected(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        bad_version = self.write("bv.xml", make_feed([item("1.0.5", 1005)]).replace("<sparkle:shortVersionString>1.0.5<", "<sparkle:shortVersionString>1.0<"))
        code, _, err = self.run_cli("compose", "--repo", REPO, "--current-build", "1100", "--current-version", "2.0.0", "--current-tag", "app-v2.0.0",
                                    "--current-feed", str(self.write("c.xml", make_feed([item("2.0.0", 1100)]))), "--previous-feed", str(bad_version),
                                    "--previous-tag", "app-v1.0.5", "--release-assets", str(self.assets), "--output", str(self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("exact X.Y.Z", err)
        for bad in (item("1.0.5", 1005, url=gh_url("app-v1.0.5", "Zerro.dmg")),
                    item("1.0.5", 1005, url=f"https://github.com/{REPO}/releases/latest/download/Zerro-1005.dmg"),
                    item("1.0.5", 1005, url=f"{STORAGE}Zerro-1005.dmg"),
                    item("1.0.5", 1005, url=gh_url("app-v1.0.4", "Zerro-1005.dmg")),
                    item("1.0.5", 1005, sig=None),
                    dict(item("1.0.5", 1005), length=None),
                    item("1.0.5", 1005, url="https://github.com/someone/else/releases/download/app-v1.0.5/Zerro-1005.dmg")):
            with self.subTest(url=bad["url"], sig=bad["sig"], length=bad["length"]):
                code, _, err, _ = self.compose("2.0.0", 1100, previous=[bad])
                self.assertEqual(code, 1)
        # The current feed is held to the same rules.
        code, _, err, _ = self.compose("2.0.0", 1100, current_items=[item("2.0.0", 1100, url=gh_url("app-v2.0.0", "Zerro.dmg"))], previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("mutable alias", err)
        code, _, err, _ = self.compose("2.0.0", 1100, current_items=[item("2.0.0", 1100), item("1.0.5", 1005)], previous=[item("1.0.5", 1005)])
        self.assertEqual(code, 1)
        self.assertIn("exactly one item", err)

    def test_non_monotonic_or_multi_item_per_major_previous_feeds_are_rejected(self) -> None:
        self.release_json("1.0.5", 1005, 8_000_000 + 1005)
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005), item("1.0.4", 1004)])
        self.assertEqual(code, 1)
        self.assertIn("more than one item for a major version", err)
        code, _, err, _ = self.compose("1.0.6", 1006, previous=[item("1.0.7", 1007)], previous_tag="app-v1.0.7")
        self.assertEqual(code, 1)
        self.assertIn("is not older than the current build", err)
        code, _, err, _ = self.compose("2.0.0", 1100, previous=[item("1.0.5", 1005), item("1.0.5", 1005)])
        self.assertEqual(code, 1)

    def test_check_rejects_feeds_that_break_the_line_rules(self) -> None:
        two_ones = self.write("t.xml", make_feed([item("1.0.1", 1001), item("1.0.0", 1000)]))
        code, _, err = self.run_cli("check", "--repo", REPO, "--current-build", "1001", "--current-version", "1.0.1", "--feed", str(two_ones))
        self.assertEqual(code, 1)
        self.assertIn("more than one item for a major version", err)
        old = self.write("o.xml", make_feed([item("1.0.1", 1001), item("1.4.31", 527)]))
        code, _, err = self.run_cli("check", "--repo", REPO, "--current-build", "1001", "--current-version", "1.0.1", "--feed", str(old))
        self.assertEqual(code, 1)
        self.assertIn("predates the release line", err)
        stale = self.write("s.xml", make_feed([item("1.0.1", 1001)]))
        code, _, err = self.run_cli("check", "--repo", REPO, "--current-build", "1002", "--current-version", "1.0.2", "--feed", str(stale))
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
