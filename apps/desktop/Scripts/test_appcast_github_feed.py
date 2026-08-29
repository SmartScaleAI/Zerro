#!/usr/bin/env python3
"""
Fixture-based tests for appcast_github_feed.py.

Run from apps/desktop:  python3 -m unittest Scripts/test_appcast_github_feed.py -v

Every fixture is built in code so the rules are exercised against exactly the
shapes generate_appcast emits (sparkle:version as an element, enclosure with
url/length/type/sparkle:edSignature), plus deliberately broken variants. The
production feed is the current release plus the newest retained release from
every other major version (see appcast_release_line.py); the line starts at
app-v1.0.0 / build 1000, whose feed is that single release. Staging feeds are
single-item. No release inventory or pin is ever consulted.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import appcast_github_feed as feed  # noqa: E402

SPARKLE = feed.SPARKLE_NS
REPO = "SmartScaleAI/Zerro"
# A retired Storage-host URL shape (example host): every validator must reject it.
STORAGE = "https://example.supabase.co/storage/v1/object/public/downloads/"


def make_feed(items: list[dict], *, version_as_attribute: bool = False) -> str:
    """Render a Sparkle feed. Each item: build, short, url, length, sig
    (any of the last three may be None to omit the attribute)."""
    parts = [
        '<?xml version="1.0" standalone="yes"?>',
        f'<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>Zerro</title>',
    ]
    for it in items:
        attrs = [f'url="{it["url"]}"'] if it.get("url") is not None else []
        if it.get("length") is not None:
            attrs.append(f'length="{it["length"]}"')
        attrs.append('type="application/octet-stream"')
        if it.get("sig") is not None:
            attrs.append(f'sparkle:edSignature="{it["sig"]}"')
        if version_as_attribute:
            attrs.append(f'sparkle:version="{it["build"]}"')
            version_el = ""
        else:
            version_el = f"<sparkle:version>{it['build']}</sparkle:version>"
        parts.append(
            f"<item><title>{it['short']}</title><pubDate>Fri, 28 Aug 2026 00:00:00 +0000</pubDate>"
            f"<link>https://getzerro.app/</link>{version_el}"
            f"<sparkle:shortVersionString>{it['short']}</sparkle:shortVersionString>"
            f"<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>"
            f"<enclosure {' '.join(attrs)}/></item>"
        )
    parts.append("</channel></rss>")
    return "".join(parts)


def gh_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{name}"


PROD_URL_1000 = "https://github.com/SmartScaleAI/Zerro/releases/download/app-v1.0.0/Zerro-1000.dmg"
DMG_LENGTH_1000 = 8009857


def prod_item(build: int = 1000, short: str = "1.0.0", *, url: str | None = None, length: int | None = DMG_LENGTH_1000, sig: str | None = "SIG=="):
    tag = f"app-v{short}"
    return {"build": build, "short": short, "url": url if url is not None else gh_url(tag, f"Zerro-{build}.dmg"), "length": length, "sig": sig}


class FeedFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def write(self, name: str, text: str) -> Path:
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        proc = subprocess.run(
            [sys.executable, str(HERE / "appcast_github_feed.py"), *argv],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def run_guard(self, *argv: str) -> tuple[int, str, str]:
        proc = subprocess.run(
            [sys.executable, str(HERE / "appcast_publish_guard.py"), *argv],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def verify(self, feed_path: Path, *extra: str, build: str = "1000", tag: str = "app-v1.0.0", flavor: str = "production") -> tuple[int, str, str]:
        return self.run_cli(
            "verify", "--flavor", flavor, "--repo", REPO, "--current-build", build, "--current-tag", tag,
            "--feed", str(feed_path), *extra,
        )

    def guard(self, feed_path: Path, *, build: str = "1000", version: str = "1.0.0", url: str = PROD_URL_1000, length: str = str(DMG_LENGTH_1000)) -> tuple[int, str, str]:
        return self.run_guard(
            "check", "--feed", str(feed_path), "--expect-build", build, "--expect-version", version,
            "--expect-url", url, "--expect-length", length, "--expect-items", "1",
        )


class FreshProductionFeedTests(FeedFixture):
    """The production GitHub feed for 1.0.0 / build 1000 — the first release of
    the line — is exactly one item; later feeds add the newest retained
    release from each other major (covered by test_appcast_release_line.py)."""

    def test_single_item_1_0_0_feed_passes_both_validators(self) -> None:
        feed_path = self.write("appcast.xml", make_feed([prod_item()]))
        code, out, err = self.verify(feed_path, "--expect-items", "1")
        self.assertEqual(code, 0, err)
        self.assertIn("1 item(s), newest build 1000", out)
        self.assertIn("Zerro-1000.dmg", feed_path.read_text())
        self.assertEqual(gh_url("app-v1.0.0", "Zerro-1000.dmg"), PROD_URL_1000)
        code, out, err = self.guard(feed_path)
        self.assertEqual(code, 0, err)

    def test_the_next_release_is_also_a_single_item_feed(self) -> None:
        feed_path = self.write("next.xml", make_feed([prod_item(1001, "1.0.1", length=8100000)]))
        code, out, err = self.verify(feed_path, "--expect-items", "1", build="1001", tag="app-v1.0.1")
        self.assertEqual(code, 0, err)
        self.assertIn("newest build 1001", out)
        code, _, err = self.guard(feed_path, build="1001", version="1.0.1", url=gh_url("app-v1.0.1", "Zerro-1001.dmg"), length="8100000")
        self.assertEqual(code, 0, err)

    def test_accepts_sparkle_version_as_enclosure_attribute(self) -> None:
        feed_path = self.write("attr.xml", make_feed([prod_item()], version_as_attribute=True))
        code, _, err = self.verify(feed_path, "--expect-items", "1")
        self.assertEqual(code, 0, err)

    def test_no_inventory_pins_or_migration_are_accepted_or_needed(self) -> None:
        # The tool has no migrate command and no inventory/pin options: a
        # release feed is verified from its own contents alone.
        feed_path = self.write("appcast.xml", make_feed([prod_item()]))
        code, _, err = self.run_cli("migrate", "--flavor", "production", "--repo", REPO)
        self.assertNotEqual(code, 0)
        self.assertIn("invalid choice: 'migrate'", err)
        for extra in (("--assets", "x.json"), ("--pin", "Zerro-242.dmg=app-v1.4.18"), ("--include-draft", "app-v1.0.0")):
            with self.subTest(extra=extra):
                code, _, err = self.verify(feed_path, *extra)
                self.assertNotEqual(code, 0)
                self.assertIn("unrecognized arguments", err)
        self.assertFalse(hasattr(feed, "migrate"))
        self.assertFalse(hasattr(feed, "load_assets"))
        self.assertFalse(hasattr(feed, "parse_pins"))

    def test_a_historical_item_in_the_fresh_feed_is_rejected(self) -> None:
        two = self.write("two.xml", make_feed([prod_item(), prod_item(527, "1.4.31", length=8395405)]))
        code, _, err = self.verify(two, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("expected exactly 1 item(s), found 2", err)
        code, _, err = self.guard(two)
        self.assertEqual(code, 1)

    def test_mutable_alias_and_latest_urls_are_rejected(self) -> None:
        alias = self.write("alias.xml", make_feed([prod_item(url=gh_url("app-v1.0.0", "Zerro.dmg"))]))
        code, _, err = self.verify(alias, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("mutable stable alias", err)
        latest = self.write("latest.xml", make_feed([prod_item(url=f"https://github.com/{REPO}/releases/latest/download/Zerro-1000.dmg")]))
        code, _, err = self.verify(latest, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("mutable /releases/latest/ URL", err)

    def test_missing_signature_or_length_is_rejected(self) -> None:
        no_sig = self.write("nosig.xml", make_feed([prod_item(sig=None)]))
        code, _, err = self.verify(no_sig, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("no sparkle:edSignature", err)
        no_len = self.write("nolen.xml", make_feed([prod_item(length=None)]))
        code, _, err = self.verify(no_len, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("no positive integer length", err)

    def test_incorrect_length_build_version_or_asset_name_is_rejected(self) -> None:
        feed_path = self.write("appcast.xml", make_feed([prod_item()]))
        code, _, err = self.guard(feed_path, length="1")
        self.assertEqual(code, 1, "length must equal the released dmg's byte size")
        code, _, err = self.guard(feed_path, build="999")
        self.assertEqual(code, 1)
        code, _, err = self.guard(feed_path, version="1.0.1")
        self.assertEqual(code, 1)
        code, _, err = self.guard(feed_path, url=gh_url("app-v1.0.0", "Zerro-999.dmg"))
        self.assertEqual(code, 1)
        # Wrong asset name for the item's build.
        wrong_name = self.write("name.xml", make_feed([prod_item(url=gh_url("app-v1.0.0", "Zerro-999.dmg"))]))
        code, _, err = self.verify(wrong_name, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("carries build 999 but the item's sparkle:version is 1000", err)
        # Wrong build for the run (feed says 1000, run says 1001).
        code, _, err = self.verify(feed_path, "--expect-items", "1", build="1001", tag="app-v1.0.1")
        self.assertEqual(code, 1)
        self.assertIn("no item for the current build 1001", err)
        # Right build, but published under a different tag than this run's.
        code, _, err = self.verify(feed_path, "--expect-items", "1", tag="app-v1.0.1")
        self.assertEqual(code, 1)
        self.assertIn("published under 'app-v1.0.0', expected 'app-v1.0.1'", err)
        # Staging archive name in a production feed.
        staging_name = self.write("stg.xml", make_feed([prod_item(url=gh_url("app-v1.0.0", "ZerroStaging-1000.dmg"))]))
        code, _, err = self.verify(staging_name, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("does not match the production versioned archive rule", err)

    def test_storage_foreign_repo_and_wrong_tag_shapes_are_rejected(self) -> None:
        storage = self.write("storage.xml", make_feed([prod_item(url=f"{STORAGE}Zerro-1000.dmg")]))
        code, _, err = self.verify(storage, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("still references 'supabase.co'", err)
        other = self.write("other.xml", make_feed([prod_item(url="https://github.com/someone/else/releases/download/app-v1.0.0/Zerro-1000.dmg")]))
        code, _, err = self.verify(other, "--expect-items", "1")
        self.assertEqual(code, 1)
        self.assertIn("is not a release asset of", err)
        for tag in ("staging-v1.0.0", "app-v01.0.0", "app-v1.0", "v1.0.0", "app-v1.0.0-rc.1"):
            with self.subTest(tag=tag):
                bad = self.write("tag.xml", make_feed([prod_item(url=gh_url(tag, "Zerro-1000.dmg"))]))
                code, _, err = self.verify(bad, "--expect-items", "1")
                self.assertEqual(code, 1)
                self.assertIn("not a production release tag", err)
        http = self.write("http.xml", make_feed([prod_item(url="http://github.com/SmartScaleAI/Zerro/releases/download/app-v1.0.0/Zerro-1000.dmg")]))
        code, _, err = self.verify(http, "--expect-items", "1")
        self.assertEqual(code, 1)
        query = self.write("query.xml", make_feed([prod_item(url=PROD_URL_1000 + "?x=1")]))
        code, _, err = self.verify(query, "--expect-items", "1")
        self.assertEqual(code, 1)

    def test_malformed_xml_and_empty_feeds_are_rejected(self) -> None:
        broken = self.write("broken.xml", "<rss><channel><item>")
        code, _, err = self.verify(broken)
        self.assertEqual(code, 1)
        self.assertIn("not well-formed XML", err)
        empty = self.write("empty.xml", make_feed([]))
        code, _, err = self.verify(empty)
        self.assertEqual(code, 1)
        self.assertIn("has no <item>", err)

    def test_duplicate_builds_and_urls_and_stale_newest_are_rejected(self) -> None:
        dup = self.write("dup.xml", make_feed([prod_item(), prod_item()]))
        code, _, err = self.verify(dup)
        self.assertEqual(code, 1)
        self.assertIn("duplicate sparkle:version", err)
        stale = self.write("stale.xml", make_feed([prod_item(), prod_item(1001, "1.0.1")]))
        code, _, err = self.verify(stale)
        self.assertEqual(code, 1)
        self.assertIn("is not the newest in the feed", err)


class StagingRuleTests(FeedFixture):
    def test_staging_feed_references_only_the_immutable_staging_archive(self) -> None:
        good = self.write("staging.xml", make_feed([
            {"build": 1000, "short": "1.0.0", "url": gh_url("staging-v1.0.0", "ZerroStaging-1000.dmg"), "length": DMG_LENGTH_1000, "sig": "SIG=="},
        ]))
        code, out, err = self.verify(good, "--expect-items", "1", tag="staging-v1.0.0", flavor="staging")
        self.assertEqual(code, 0, err)
        self.assertIn("1 item(s), newest build 1000", out)
        alias = self.write("alias.xml", make_feed([
            {"build": 1000, "short": "1.0.0", "url": gh_url("staging-v1.0.0", "ZerroStaging.dmg"), "length": DMG_LENGTH_1000, "sig": "SIG=="},
        ]))
        code, _, err = self.verify(alias, "--expect-items", "1", tag="staging-v1.0.0", flavor="staging")
        self.assertEqual(code, 1)
        self.assertIn("mutable stable alias", err)

    def test_plain_staging_tags_yield_a_single_item_feed_on_the_tag_asset(self) -> None:
        for tag, build, short in (("staging-v1.0.0", 1000, "1.0.0"), ("staging-v1.0.1", 1001, "1.0.1"), ("staging-v1.4.48", 571, "1.4.48"),
                                  ("staging-v0.0.1", 1, "0.0.1"), ("staging-v10.20.30", 102030, "10.20.30")):
            with self.subTest(tag=tag):
                url = gh_url(tag, f"ZerroStaging-{build}.dmg")
                self.assertEqual(url, f"https://github.com/{REPO}/releases/download/{tag}/ZerroStaging-{build}.dmg")
                feed_path = self.write(f"{tag}.xml", make_feed([{"build": build, "short": short, "url": url, "length": 8000 + build, "sig": "SIG=="}]))
                code, out, err = self.verify(feed_path, "--expect-items", "1", build=str(build), tag=tag, flavor="staging")
                self.assertEqual(code, 0, err)
                self.assertIn(f"1 item(s), newest build {build}", out)
        two = self.write("two.xml", make_feed([
            {"build": 1000, "short": "1.0.0", "url": gh_url("staging-v1.0.0", "ZerroStaging-1000.dmg"), "length": 9000, "sig": "SIG=="},
            {"build": 571, "short": "1.4.48", "url": gh_url("staging-v1.4.48", "ZerroStaging-571.dmg"), "length": 8571, "sig": "SIG=="},
        ]))
        code, _, err = self.verify(two, "--expect-items", "1", tag="staging-v1.0.0", flavor="staging")
        self.assertEqual(code, 1)
        self.assertIn("expected exactly 1 item(s), found 2", err)

    def test_build_qualified_and_malformed_staging_tags_are_rejected(self) -> None:
        for tag in ("staging-v1.0.0-build.1000", "staging-v1.0.0-build.", "staging-v1.0.0-rc.1", "staging-1.0.0", "staging-v1.0",
                    "staging-v01.0.0", "staging-v1.00.0", "staging-v1.0.00"):
            with self.subTest(tag=tag):
                feed_path = self.write("bad.xml", make_feed([
                    {"build": 1000, "short": "1.0.0", "url": gh_url(tag, "ZerroStaging-1000.dmg"), "length": 9000, "sig": "SIG=="},
                ]))
                code, _, err = self.verify(feed_path, tag=tag, flavor="staging")
                self.assertEqual(code, 1)
                self.assertIn("not a staging release tag", err)

    def test_production_flavor_rejects_staging_filenames_and_vice_versa(self) -> None:
        feed_path = self.write("x.xml", make_feed([{"build": 1000, "short": "1.0.0", "url": gh_url("app-v1.0.0", "ZerroStaging-1000.dmg"), "length": 9000, "sig": "SIG=="}]))
        code, _, err = self.verify(feed_path)
        self.assertEqual(code, 1)
        self.assertIn("does not match the production versioned archive rule", err)
        feed_path = self.write("y.xml", make_feed([{"build": 1000, "short": "1.0.0", "url": gh_url("staging-v1.0.0", "Zerro-1000.dmg"), "length": 9000, "sig": "SIG=="}]))
        code, _, err = self.verify(feed_path, tag="staging-v1.0.0", flavor="staging")
        self.assertEqual(code, 1)
        self.assertIn("does not match the staging versioned archive rule", err)


if __name__ == "__main__":
    unittest.main()
