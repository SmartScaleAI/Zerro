#!/usr/bin/env python3
"""
Fixture-based tests for appcast_github_feed.py.

Run from apps/desktop:  python3 -m unittest Scripts/test_appcast_github_feed.py -v

Every fixture is built in code so the rules are exercised against exactly the
shapes generate_appcast emits (sparkle:version as an element, enclosure with
url/length/type/sparkle:edSignature), plus deliberately broken variants.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import appcast_github_feed as feed  # noqa: E402

SPARKLE = feed.SPARKLE_NS
REPO = "SmartScaleAI/smartscale-zerro"
STORAGE = "https://wjxqmurgwyxwkezncxke.supabase.co/storage/v1/object/public/downloads/"


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
            f"<item><title>{it['short']}</title><pubDate>Mon, 27 Jul 2026 05:06:55 +0000</pubDate>"
            f"<link>https://getzerro.app/</link>{version_el}"
            f"<sparkle:shortVersionString>{it['short']}</sparkle:shortVersionString>"
            f"<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>"
            f"<enclosure {' '.join(attrs)}/></item>"
        )
    parts.append("</channel></rss>")
    return "".join(parts)


def prod_item(build: int, short: str, *, url: str | None = None, length: int | None = None, sig: str | None = "SIG=="):
    return {
        "build": build,
        "short": short,
        "url": url if url is not None else f"{STORAGE}Zerro-{build}.dmg",
        "length": 1000 + build if length is None else length,
        "sig": sig,
    }


def gh_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{name}"


def releases_payload(entries: list[tuple[str, str, int | None]], drafts: list[tuple[str, str, int | None]] = ()) -> str:
    """Raw GitHub releases API shape; entries are (tag, asset name, size)."""
    by_tag: dict[str, dict] = {}
    for tag, name, size in entries:
        by_tag.setdefault(tag, {"tag_name": tag, "draft": False, "prerelease": False, "assets": []})
        by_tag[tag]["assets"].append({"name": name, "size": size, "browser_download_url": gh_url(tag, name)})
    for tag, name, size in drafts:
        by_tag.setdefault(tag, {"tag_name": tag, "draft": True, "prerelease": False, "assets": []})
        by_tag[tag]["assets"].append({"name": name, "size": size})
    return json.dumps(list(by_tag.values()))


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

    # A three-item cumulative feed (two historical builds + the current one)
    # with matching release assets, the shape a real production run sees.
    def three_item_setup(self, *, version_as_attribute: bool = False):
        items = [prod_item(530, "1.4.32"), prod_item(527, "1.4.31"), prod_item(521, "1.4.30")]
        feed_path = self.write("dist/appcast.xml", make_feed(items, version_as_attribute=version_as_attribute))
        assets = self.write(
            "releases.json",
            releases_payload([
                ("app-v1.4.32", "Zerro-530.dmg", 1530),
                ("app-v1.4.32", "Zerro.dmg", 1530),
                ("app-v1.4.31", "Zerro-527.dmg", 1527),
                ("app-v1.4.30", "Zerro-521.dmg", 1521),
            ]),
        )
        return feed_path, assets

    def migrate_args(self, feed_path: Path, assets: Path, output: Path, *extra: str) -> list[str]:
        return [
            "migrate", "--flavor", "production", "--repo", REPO,
            "--current-build", "530", "--current-tag", "app-v1.4.32",
            "--input", str(feed_path), "--assets", str(assets), "--output", str(output), *extra,
        ]


class MigrateTests(FeedFixture):
    def test_rewrites_every_historical_item_to_its_immutable_release_url(self) -> None:
        feed_path, assets = self.three_item_setup()
        output = self.tmp / "github/appcast.xml"
        code, out, err = self.run_cli(*self.migrate_args(feed_path, assets, output))
        self.assertEqual(code, 0, err)
        self.assertIn("3 item(s), newest build 530", out)
        tree = ET.parse(output)
        urls = [e.get("url") for e in tree.getroot().iter("enclosure")]
        self.assertEqual(urls, [
            gh_url("app-v1.4.32", "Zerro-530.dmg"),
            gh_url("app-v1.4.31", "Zerro-527.dmg"),
            gh_url("app-v1.4.30", "Zerro-521.dmg"),
        ])
        # Signatures, lengths, and every other element survive untouched.
        for enclosure in tree.getroot().iter("enclosure"):
            self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), "SIG==")
            self.assertTrue(enclosure.get("length").isdigit())
        self.assertEqual(len(tree.getroot().findall("./channel/item/pubDate")), 3)
        text = output.read_text(encoding="utf-8")
        self.assertNotIn("supabase", text)
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', text)
        self.assertTrue(text.startswith("<?xml"))

    def test_accepts_sparkle_version_as_enclosure_attribute(self) -> None:
        feed_path, assets = self.three_item_setup(version_as_attribute=True)
        output = self.tmp / "github/appcast.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output))
        self.assertEqual(code, 0, err)

    def test_current_release_must_be_inserted_and_map_to_the_current_tag(self) -> None:
        items = [prod_item(527, "1.4.31"), prod_item(521, "1.4.30")]  # 530 missing
        feed_path = self.write("dist/appcast.xml", make_feed(items))
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521),
        ]))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("no item for the current build 530", err)

        # Present, but attached to a different tag than this run's.
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases2.json", releases_payload([
            ("app-v1.4.99", "Zerro-530.dmg", 1530),
            ("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521),
        ]))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o2.xml"))
        self.assertEqual(code, 1)
        self.assertIn("expected the current tag 'app-v1.4.32'", err)

    def test_missing_historical_asset_fails_closed(self) -> None:
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31", "Zerro-527.dmg", 1527),
            ("app-v1.4.30", "Zerro.dmg", 1521),  # 1.4.30 only ever got the mutable asset
        ]))
        output = self.tmp / "o.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output))
        self.assertEqual(code, 1)
        self.assertIn("no non-draft GitHub Release carries the asset 'Zerro-521.dmg'", err)
        self.assertFalse(output.exists(), "nothing may be written on failure")

    def test_draft_release_assets_do_not_count(self) -> None:
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload(
            [("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31", "Zerro-527.dmg", 1527)],
            drafts=[("app-v1.4.30", "Zerro-521.dmg", 1521)],
        ))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("Zerro-521.dmg", err)

    def test_current_draft_counts_only_when_explicitly_included(self) -> None:
        # Draft-first publication: this run's release is still a draft when
        # the feed is built, so its assets are visible only through an
        # explicit --include-draft naming exactly the current tag.
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload(
            [("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521)],
            drafts=[("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.32", "Zerro.dmg", 1530)],
        ))
        output = self.tmp / "o.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output))
        self.assertEqual(code, 1)
        self.assertIn("no non-draft GitHub Release carries the asset 'Zerro-530.dmg'", err)
        self.assertFalse(output.exists())

        code, out, err = self.run_cli(*self.migrate_args(feed_path, assets, output, "--include-draft", "app-v1.4.32"))
        self.assertEqual(code, 0, err)
        self.assertIn("3 item(s), newest build 530", out)
        urls = [e.get("url") for e in ET.parse(output).getroot().iter("enclosure")]
        self.assertEqual(urls[0], gh_url("app-v1.4.32", "Zerro-530.dmg"))

        # Naming a different tag does not unlock the current draft.
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o2.xml", "--include-draft", "app-v1.4.99"))
        self.assertEqual(code, 1)
        self.assertIn("Zerro-530.dmg", err)

    def test_other_drafts_stay_ignored_when_the_current_draft_is_included(self) -> None:
        feed_path, _ = self.three_item_setup()
        # A historical build that only ever reached a draft, plus an abandoned
        # unrelated draft carrying the same archive name as a published one.
        assets = self.write("releases.json", releases_payload(
            [("app-v1.4.31", "Zerro-527.dmg", 1527)],
            drafts=[
                ("app-v1.4.32", "Zerro-530.dmg", 1530),
                ("app-v1.4.30", "Zerro-521.dmg", 1521),
                ("app-v1.4.31-retry", "Zerro-527.dmg", 1527),
            ],
        ))
        output = self.tmp / "o.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output, "--include-draft", "app-v1.4.32"))
        self.assertEqual(code, 1)
        self.assertIn("Zerro-521.dmg", err, "the historical draft is still invisible")
        self.assertFalse(output.exists())

        # With 1.4.30 published, the abandoned 1.4.31-retry draft must not turn
        # Zerro-527.dmg into an ambiguous (two-release) asset.
        assets = self.write("releases2.json", releases_payload(
            [("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521)],
            drafts=[("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31-retry", "Zerro-527.dmg", 1527)],
        ))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output, "--include-draft", "app-v1.4.32"))
        self.assertEqual(code, 0, err)
        urls = [e.get("url") for e in ET.parse(output).getroot().iter("enclosure")]
        self.assertEqual(urls[1], gh_url("app-v1.4.31", "Zerro-527.dmg"))

    def test_two_drafts_for_the_current_tag_are_ambiguous(self) -> None:
        feed_path, _ = self.three_item_setup()
        payload = json.loads(releases_payload(
            [("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521)],
        ))
        for _ in range(2):  # two separate draft releases, same tag_name
            payload.append({"tag_name": "app-v1.4.32", "draft": True, "prerelease": False,
                            "assets": [{"name": "Zerro-530.dmg", "size": 1530}]})
        assets = self.write("releases.json", json.dumps(payload))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o.xml", "--include-draft", "app-v1.4.32"))
        self.assertEqual(code, 1)
        self.assertIn("attached to 2 releases", err)

    def test_duplicate_matching_asset_fails_unless_pinned(self) -> None:
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31", "Zerro-527.dmg", 1527),
            ("app-v1.4.30", "Zerro-521.dmg", 1521), ("app-v1.4.29", "Zerro-521.dmg", 1521),  # reused build
        ]))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("attached to 2 releases ['app-v1.4.29', 'app-v1.4.30']", err)

        output = self.tmp / "pinned.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output, "--pin", "Zerro-521.dmg=app-v1.4.30"))
        self.assertEqual(code, 0, err)
        urls = [e.get("url") for e in ET.parse(output).getroot().iter("enclosure")]
        self.assertIn(gh_url("app-v1.4.30", "Zerro-521.dmg"), urls)

        # A pin naming a release that lacks the asset is rejected.
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o3.xml", "--pin", "Zerro-521.dmg=app-v1.4.28"))
        self.assertEqual(code, 1)
        self.assertIn("names a release that does not carry that asset", err)

    def test_mutable_and_latest_urls_are_rejected(self) -> None:
        feed_path, assets = self.three_item_setup()
        # The stable alias as an enclosure.
        items = [prod_item(530, "1.4.32", url=f"{STORAGE}Zerro.dmg"), prod_item(527, "1.4.31"), prod_item(521, "1.4.30")]
        bad = self.write("mutable.xml", make_feed(items))
        code, _, err = self.run_cli(*self.migrate_args(bad, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("mutable stable alias", err)

        # A /releases/latest/ URL in a feed under verification.
        items = [prod_item(530, "1.4.32", url=f"https://github.com/{REPO}/releases/latest/download/Zerro-530.dmg")]
        latest = self.write("latest.xml", make_feed(items))
        code, _, err = self.run_cli("verify", "--flavor", "production", "--repo", REPO, "--current-build", "530", "--current-tag", "app-v1.4.32", "--feed", str(latest))
        self.assertEqual(code, 1)
        self.assertIn("/releases/latest/", err)

    def test_length_mismatch_with_release_asset_fails(self) -> None:
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31", "Zerro-527.dmg", 9999), ("app-v1.4.30", "Zerro-521.dmg", 1521),
        ]))
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("is 9999 bytes but the feed's length is 1527", err)

    def test_missing_signature_or_length_fails(self) -> None:
        _, assets = self.three_item_setup()
        no_sig = self.write("nosig.xml", make_feed([prod_item(530, "1.4.32", sig=None), prod_item(527, "1.4.31"), prod_item(521, "1.4.30")]))
        code, _, err = self.run_cli(*self.migrate_args(no_sig, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("no sparkle:edSignature", err)

        no_len = self.write("nolen.xml", make_feed([prod_item(530, "1.4.32"), prod_item(527, "1.4.31", length=0), prod_item(521, "1.4.30")]))
        code, _, err = self.run_cli(*self.migrate_args(no_len, assets, self.tmp / "o2.xml"))
        self.assertEqual(code, 1)
        self.assertIn("no positive integer length", err)

    def test_malformed_xml_fails(self) -> None:
        _, assets = self.three_item_setup()
        broken = self.write("broken.xml", "<rss><channel><item><enclosure url='x'")
        code, _, err = self.run_cli(*self.migrate_args(broken, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("not well-formed XML", err)

        empty = self.write("empty.xml", f'<rss xmlns:sparkle="{SPARKLE}"><channel><title>Zerro</title></channel></rss>')
        code, _, err = self.run_cli(*self.migrate_args(empty, assets, self.tmp / "o2.xml"))
        self.assertEqual(code, 1)
        self.assertIn("no <item>", err)

    def test_current_build_must_be_the_highest(self) -> None:
        feed_path, _ = self.three_item_setup()
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521),
        ]))
        args = self.migrate_args(feed_path, assets, self.tmp / "o.xml")
        args[args.index("--current-build") + 1] = "527"
        args[args.index("--current-tag") + 1] = "app-v1.4.31"
        code, _, err = self.run_cli(*args)
        self.assertEqual(code, 1)
        self.assertIn("current build 527 is not the newest", err)

    def test_duplicate_builds_and_urls_are_rejected(self) -> None:
        _, assets = self.three_item_setup()
        dup = self.write("dup.xml", make_feed([prod_item(530, "1.4.32"), prod_item(530, "1.4.32-again"), prod_item(521, "1.4.30")]))
        code, _, err = self.run_cli(*self.migrate_args(dup, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("duplicate sparkle:version", err)

    def test_filename_build_must_match_sparkle_version(self) -> None:
        _, assets = self.three_item_setup()
        wrong = self.write("wrong.xml", make_feed([prod_item(530, "1.4.32"), prod_item(527, "1.4.31", url=f"{STORAGE}Zerro-521.dmg")]))
        code, _, err = self.run_cli(*self.migrate_args(wrong, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("carries build 521 but the item's sparkle:version is 527", err)

    def test_non_https_enclosure_is_rejected(self) -> None:
        _, assets = self.three_item_setup()
        http = self.write("http.xml", make_feed([prod_item(530, "1.4.32", url="http://example.com/Zerro-530.dmg")]))
        code, _, err = self.run_cli(*self.migrate_args(http, assets, self.tmp / "o.xml"))
        self.assertEqual(code, 1)
        self.assertIn("must be https", err)


class VerifyTests(FeedFixture):
    def github_feed(self, items: list[dict]) -> Path:
        return self.write("github/appcast.xml", make_feed(items))

    def verify_args(self, feed_path: Path, *extra: str) -> list[str]:
        return ["verify", "--flavor", "production", "--repo", REPO, "--current-build", "530", "--current-tag", "app-v1.4.32", "--feed", str(feed_path), *extra]

    def test_verifies_a_correct_github_feed_against_the_inventory(self) -> None:
        feed_path = self.github_feed([
            prod_item(530, "1.4.32", url=gh_url("app-v1.4.32", "Zerro-530.dmg")),
            prod_item(527, "1.4.31", url=gh_url("app-v1.4.31", "Zerro-527.dmg")),
        ])
        assets = self.write("releases.json", releases_payload([
            ("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.32", "Zerro.dmg", 1530), ("app-v1.4.32", "appcast.xml", 4),
            ("app-v1.4.31", "Zerro-527.dmg", 1527),
        ]))
        code, out, err = self.run_cli(*self.verify_args(feed_path, "--assets", str(assets)))
        self.assertEqual(code, 0, err)
        self.assertIn("2 item(s), newest build 530", out)

    def test_verify_resolves_the_current_draft_only_when_included(self) -> None:
        feed_path, assets = self.three_item_setup()
        output = self.tmp / "github/appcast.xml"
        code, _, err = self.run_cli(*self.migrate_args(feed_path, assets, output))
        self.assertEqual(code, 0, err)
        draft_inventory = self.write("drafts.json", releases_payload(
            [("app-v1.4.31", "Zerro-527.dmg", 1527), ("app-v1.4.30", "Zerro-521.dmg", 1521)],
            drafts=[("app-v1.4.32", "Zerro-530.dmg", 1530), ("app-v1.4.32", "Zerro.dmg", 1530), ("app-v1.4.32", "appcast.xml", 4096)],
        ))
        base = ["verify", "--flavor", "production", "--repo", REPO, "--current-build", "530",
                "--current-tag", "app-v1.4.32", "--feed", str(output), "--assets", str(draft_inventory)]
        code, _, err = self.run_cli(*base)
        self.assertEqual(code, 1)
        self.assertIn("does not resolve to exactly one existing non-draft release asset", err)
        code, out, err = self.run_cli(*base, "--include-draft", "app-v1.4.32")
        self.assertEqual(code, 0, err)
        self.assertIn("3 item(s), newest build 530", out)

    def test_storage_url_left_in_github_feed_is_rejected(self) -> None:
        feed_path = self.github_feed([
            prod_item(530, "1.4.32", url=gh_url("app-v1.4.32", "Zerro-530.dmg")),
            prod_item(527, "1.4.31"),  # still on Storage
        ])
        code, _, err = self.run_cli(*self.verify_args(feed_path))
        self.assertEqual(code, 1)
        self.assertIn("still references 'supabase.co'", err)

    def test_enclosure_must_resolve_to_an_existing_asset(self) -> None:
        feed_path = self.github_feed([prod_item(530, "1.4.32", url=gh_url("app-v1.4.32", "Zerro-530.dmg"))])
        assets = self.write("releases.json", releases_payload([("app-v1.4.32", "Zerro.dmg", 1530)]))
        code, _, err = self.run_cli(*self.verify_args(feed_path, "--assets", str(assets)))
        self.assertEqual(code, 1)
        self.assertIn("does not resolve to exactly one existing non-draft release asset", err)

    def test_foreign_repo_or_wrong_tag_shape_is_rejected(self) -> None:
        other = self.github_feed([prod_item(530, "1.4.32", url="https://github.com/someone/else/releases/download/app-v1.4.32/Zerro-530.dmg")])
        code, _, err = self.run_cli(*self.verify_args(other))
        self.assertEqual(code, 1)
        self.assertIn("is not a release asset of", err)

        staging_tag = self.github_feed([prod_item(530, "1.4.32", url=gh_url("staging-v1.4.32", "Zerro-530.dmg"))])
        code, _, err = self.run_cli(*self.verify_args(staging_tag))
        self.assertEqual(code, 1)
        self.assertIn("not a production release tag", err)

    def test_expect_items_pins_the_item_count(self) -> None:
        feed_path = self.github_feed([
            prod_item(530, "1.4.32", url=gh_url("app-v1.4.32", "Zerro-530.dmg")),
            prod_item(527, "1.4.31", url=gh_url("app-v1.4.31", "Zerro-527.dmg")),
        ])
        code, _, err = self.run_cli(*self.verify_args(feed_path, "--expect-items", "1"))
        self.assertEqual(code, 1)
        self.assertIn("expected exactly 1 item(s), found 2", err)


class StagingRuleTests(FeedFixture):
    def staging_item(self, build: int, name: str) -> dict:
        return {"build": build, "short": "1.4.36", "url": gh_url("staging-v1.4.36", name), "length": 2000, "sig": "SIG=="}

    def verify_args(self, feed_path: Path, *extra: str) -> list[str]:
        return ["verify", "--flavor", "staging", "--repo", REPO, "--current-build", "600", "--current-tag", "staging-v1.4.36", "--feed", str(feed_path), "--expect-items", "1", *extra]

    def test_staging_feed_references_only_the_immutable_staging_archive(self) -> None:
        good = self.write("good.xml", make_feed([self.staging_item(600, "ZerroStaging-600.dmg")]))
        assets = self.write("releases.json", releases_payload([
            ("staging-v1.4.36", "ZerroStaging-600.dmg", 2000), ("staging-v1.4.36", "ZerroStaging.dmg", 2000), ("staging-v1.4.36", "appcast-staging.xml", 3),
        ]))
        code, _, err = self.run_cli(*self.verify_args(good, "--assets", str(assets)))
        self.assertEqual(code, 0, err)

        alias = self.write("alias.xml", make_feed([self.staging_item(600, "ZerroStaging.dmg")]))
        code, _, err = self.run_cli(*self.verify_args(alias))
        self.assertEqual(code, 1)
        self.assertIn("mutable stable alias", err)

        prod_name = self.write("prodname.xml", make_feed([self.staging_item(600, "Zerro-600.dmg")]))
        code, _, err = self.run_cli(*self.verify_args(prod_name))
        self.assertEqual(code, 1)
        self.assertIn("does not match the staging versioned archive rule", err)

    def test_production_flavor_rejects_staging_filenames(self) -> None:
        item = {"build": 600, "short": "1.4.36", "url": gh_url("app-v1.4.36", "ZerroStaging-600.dmg"), "length": 2000, "sig": "SIG=="}
        path = self.write("p.xml", make_feed([item]))
        code, _, err = self.run_cli("verify", "--flavor", "production", "--repo", REPO, "--current-build", "600", "--current-tag", "app-v1.4.36", "--feed", str(path))
        self.assertEqual(code, 1)
        self.assertIn("does not match the production versioned archive rule", err)


class InventoryTests(FeedFixture):
    def test_reads_concatenated_paginated_payloads_and_flat_lists(self) -> None:
        page1 = releases_payload([("app-v1.4.32", "Zerro-530.dmg", 1530)])
        page2 = releases_payload([("app-v1.4.31", "Zerro-527.dmg", 1527)])
        path = self.write("pages.json", page1 + "\n" + page2)
        names = sorted(a.name for a in feed.load_assets(path))
        self.assertEqual(names, ["Zerro-527.dmg", "Zerro-530.dmg"])

        flat = self.write("flat.json", json.dumps([{"tag": "app-v1.4.30", "name": "Zerro-521.dmg", "size": 1}]))
        self.assertEqual([a.tag for a in feed.load_assets(flat)], ["app-v1.4.30"])

        bad = self.write("bad.json", "{not json")
        with self.assertRaises(feed.FeedError):
            feed.load_assets(bad)


if __name__ == "__main__":
    unittest.main()
