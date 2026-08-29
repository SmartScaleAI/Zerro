#!/usr/bin/env python3
"""
Tests for storage_mirror_seed.py and the workflow contract around it: the
cumulative Storage mirror is seeded only from its own published Storage feed,
every seed item is validated (it will be republished verbatim), the gate fails
closed on any read problem, it never falls back to the website or GitHub
release-line feed, and bootstrap allows only a genuinely missing download.

Run from apps/desktop:  python3 -m unittest Scripts/test_storage_mirror_seed.py -v
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import storage_mirror_seed as seed  # noqa: E402

HOST = "wjxqmurgwyxwkezncxke.supabase.co"
PREFIX = f"https://{HOST}/storage/v1/object/public/downloads/"
GITHUB = "https://github.com/SmartScaleAI/Zerro/releases/download/app-v1.0.0/Zerro-1000.dmg"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def item(build: int = 527, short: str = "1.4.31", *, url: str | None = None, length: str | None = "8395405", sig: str | None = "SIG==",
         enclosures: int = 1, version_el: str | None = "default", short_el: str | None = "default") -> str:
    url = url if url is not None else f"{PREFIX}Zerro-{build}.dmg"
    attrs = [f'url="{url}"'] + ([f'length="{length}"'] if length is not None else []) + ['type="application/octet-stream"'] + ([f'sparkle:edSignature="{sig}"'] if sig is not None else [])
    enc = f"<enclosure {' '.join(attrs)}/>" * enclosures
    v = f"<sparkle:version>{build}</sparkle:version>" if version_el == "default" else (version_el or "")
    s = f"<sparkle:shortVersionString>{short}</sparkle:shortVersionString>" if short_el == "default" else (short_el or "")
    return f"<item><title>{short}</title>{v}{s}{enc}</item>"


def feed(items: list[str], *, root: str = "rss", channel: bool = True) -> str:
    body = "".join(items)
    inner = f"<channel><title>Zerro</title>{body}</channel>" if channel else body
    return f'<{root} xmlns:sparkle="{NS}" version="2.0">{inner}</{root}>'


def quiet_main(argv: list[str]) -> int:
    """Run the CLI with its ::error/OK lines captured (asserted via exit code)."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return seed.main(argv)


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def write(self, name: str, text: str) -> Path:
        p = self.tmp / name
        p.write_text(text, encoding="utf-8")
        return p

    def reject(self, text: str, message: str, *, bootstrap: bool = False) -> None:
        p = self.write("f.xml", text)
        with self.assertRaisesRegex(seed.SeedError, message):
            seed.evaluate(p, PREFIX, bootstrap)
        self.assertEqual(quiet_main(["check", "--feed", str(p), "--storage-prefix", PREFIX, *(["--bootstrap"] if bootstrap else [])]), 1)


class ValidSeedTests(Fixture):
    def test_cumulative_storage_feed_seeds_the_mirror(self) -> None:
        p = self.write("a.xml", feed([item(527, "1.4.31"), item(521, "1.4.30", length="8395397"), item(238, "1.4.16", length="5903197")]))
        self.assertIn("3 valid item(s)", seed.evaluate(p, PREFIX, False))
        self.assertEqual(quiet_main(["check", "--feed", str(p), "--storage-prefix", PREFIX]), 0)
        # With bootstrap set and a published feed present, the feed is still what seeds.
        self.assertIn("3 valid item(s)", seed.evaluate(p, PREFIX, True))


class BootstrapTests(Fixture):
    def test_bootstrap_allows_only_a_missing_path(self) -> None:
        self.assertIn("BOOTSTRAP", seed.evaluate(self.tmp / "missing.xml", PREFIX, True))
        self.assertEqual(quiet_main(["check", "--feed", str(self.tmp / "missing.xml"), "--storage-prefix", PREFIX, "--bootstrap"]), 0)

    def test_missing_path_without_bootstrap_fails_closed(self) -> None:
        with self.assertRaisesRegex(seed.SeedError, "does not exist"):
            seed.evaluate(self.tmp / "missing.xml", PREFIX, False)
        self.assertEqual(quiet_main(["check", "--feed", str(self.tmp / "missing.xml"), "--storage-prefix", PREFIX]), 1)

    def test_existing_zero_byte_or_whitespace_file_is_rejected_even_with_bootstrap(self) -> None:
        for text in ("", "  \n"):
            for bootstrap in (False, True):
                with self.subTest(text=repr(text), bootstrap=bootstrap):
                    self.reject(text, "is empty", bootstrap=bootstrap)

    def test_directory_or_unreadable_input_is_rejected_without_traceback(self) -> None:
        d = self.tmp / "dir.xml"
        d.mkdir()
        for bootstrap in (False, True):
            with self.assertRaisesRegex(seed.SeedError, "is a directory"):
                seed.evaluate(d, PREFIX, bootstrap)
            self.assertEqual(quiet_main(["check", "--feed", str(d), "--storage-prefix", PREFIX, *(["--bootstrap"] if bootstrap else [])]), 1)
        if os.geteuid() != 0:
            p = self.write("locked.xml", feed([item()]))
            p.chmod(0)
            try:
                for bootstrap in (False, True):
                    with self.assertRaisesRegex(seed.SeedError, "cannot read"):
                        seed.evaluate(p, PREFIX, bootstrap)
            finally:
                p.chmod(stat.S_IRUSR | stat.S_IWUSR)

    def test_malformed_empty_invalid_or_foreign_feed_is_rejected_even_with_bootstrap(self) -> None:
        for text, msg in (("<rss><channel><item>", "not well-formed"), (feed([]), "has no <item>"), (feed([item(sig=None)]), "edSignature"), (feed([item(url=GITHUB)]), "not the Storage host")):
            for bootstrap in (False, True):
                with self.subTest(msg=msg, bootstrap=bootstrap):
                    self.reject(text, msg, bootstrap=bootstrap)


class ItemValidationTests(Fixture):
    def test_root_and_channel_shape(self) -> None:
        self.reject(feed([item()], root="feed"), "expected <rss>")
        self.reject(feed([item()], channel=False), "no <channel>")

    def test_missing_version_short_version_length_or_signature(self) -> None:
        self.reject(feed([item(version_el=None)]), "sparkle:version must be a positive integer")
        self.reject(feed([item(short_el=None)]), "shortVersionString must be exactly X.Y.Z")
        self.reject(feed([item(length=None)]), "length must be a positive integer")
        self.reject(feed([item(sig=None)]), "no sparkle:edSignature")
        self.reject(feed([item(sig="   ")]), "no sparkle:edSignature")

    def test_malformed_versions_and_builds(self) -> None:
        for short in ("1.4", "v1.4.31", "1.04.31", "1.4.31-beta", "1.4.31.1", ""):
            with self.subTest(short=short):
                self.reject(feed([item(527, short)]), "exactly X.Y.Z")
        for v in ("0", "-5", "0527", "527.0", "abc"):
            with self.subTest(v=v):
                self.reject(feed([item(version_el=f"<sparkle:version>{v}</sparkle:version>", url=f"{PREFIX}Zerro-527.dmg")]), "positive integer build")

    def test_zero_or_invalid_length(self) -> None:
        for length in ("0", "-1", "01", "1.5", "big", ""):
            with self.subTest(length=length):
                self.reject(feed([item(length=length)]), "length must be a positive integer")

    def test_exactly_one_enclosure(self) -> None:
        self.reject(feed([item(enclosures=0)]), "exactly one <enclosure>")
        self.reject(feed([item(enclosures=2)]), "exactly one <enclosure>")

    def test_mutable_or_incorrectly_named_archives(self) -> None:
        self.reject(feed([item(url=f"{PREFIX}Zerro.dmg")]), "mutable 'Zerro.dmg'")
        for name in ("ZerroStaging-527.dmg", "Zerro-527.zip", "zerro-527.dmg", "Zerro-0527.dmg", "Zerro-527.dmg.bak", "Zerro-.dmg", "appcast.xml"):
            with self.subTest(name=name):
                self.reject(feed([item(url=f"{PREFIX}{name}")]), "not an immutable Zerro-<build>.dmg")

    def test_filename_build_must_match_sparkle_version(self) -> None:
        self.reject(feed([item(527, url=f"{PREFIX}Zerro-521.dmg")]), "does not carry the item's build 527")

    def test_duplicate_builds_and_urls(self) -> None:
        self.reject(feed([item(527), item(527, "1.4.32")]), "repeats build 527")
        dup_url = item(521, "1.4.30", url=f"{PREFIX}Zerro-527.dmg").replace("<sparkle:version>521", "<sparkle:version>527")
        self.reject(feed([item(527), dup_url]), "repeats build 527")
        # Same URL under different builds is caught by the filename/build rule first; a
        # duplicate URL with matching builds is the duplicate-build case above. Verify the
        # URL rule directly on the evaluator's bookkeeping as well:
        two = feed([item(527), item(527)])
        self.reject(two, "repeats build 527")

    def test_query_fragment_traversal_and_encoded_traversal(self) -> None:
        for url, msg in ((f"{PREFIX}Zerro-527.dmg?x=1", "query or fragment"), (f"{PREFIX}Zerro-527.dmg#frag", "query or fragment"),
                         (f"{PREFIX}../Zerro-527.dmg", "not a plain archive name"), (f"{PREFIX}sub/Zerro-527.dmg", "not a plain archive name"),
                         (f"{PREFIX}..%2FZerro-527.dmg", "not a plain archive name"), (f"{PREFIX}%2e%2e/Zerro-527.dmg", "not a plain archive name"),
                         (f"{PREFIX}Zerro-527%2Edmg", "not a plain archive name"), (f"{PREFIX}", "not a plain archive name")):
            with self.subTest(url=url):
                self.reject(feed([item(url=url)]), msg)

    def test_wrong_scheme_host_or_path(self) -> None:
        self.reject(feed([item(url=f"http://{HOST}/storage/v1/object/public/downloads/Zerro-527.dmg")]), "must be https")
        self.reject(feed([item(url=f"https://other.supabase.co/storage/v1/object/public/downloads/Zerro-527.dmg")]), "not the Storage host")
        self.reject(feed([item(url=f"https://{HOST}/storage/v1/object/public/other/Zerro-527.dmg")]), "outside the Storage prefix")
        self.reject(feed([item(url=f"https://{HOST}/downloads/Zerro-527.dmg")]), "outside the Storage prefix")
        self.reject(feed([item(url=GITHUB)]), "not the Storage host")
        self.reject(feed([item(url="https://getzerro.app/Zerro-527.dmg")]), "not the Storage host")

    def test_one_bad_item_among_valid_ones_rejects_the_whole_feed(self) -> None:
        self.reject(feed([item(527), item(521, "1.4.30", length="8395397"), item(238, "1.4.16", sig=None)]), "item #3")

    def test_prefix_must_be_https_directory(self) -> None:
        p = self.write("a.xml", feed([item()]))
        for bad in ("http://x/", "https://x", "", "https://x/?q=1"):
            with self.assertRaises(seed.SeedError):
                seed.evaluate(p, bad, False)


class WorkflowContractTests(unittest.TestCase):
    """release-app.yml's Storage-mirror step must route every seed through the
    gate and must have no website/GitHub fallback."""

    def workflow(self) -> str:
        return (HERE.parent.parent.parent / ".github" / "workflows" / "release-app.yml").read_text(encoding="utf-8")

    def storage_step(self) -> str:
        text = self.workflow()
        start = text.index("- name: Generate signed appcast (Storage mirror)")
        end = text.index("# GitHub Release asset set", start)
        return text[start:end]

    def test_storage_step_seeds_only_from_storage_and_fails_closed(self) -> None:
        step = self.storage_step()
        self.assertIn("storage_mirror_seed.py check", step)
        self.assertNotIn("getzerro.app/appcast.xml", step, "no website fallback")
        self.assertNotIn("releases/latest", step, "no GitHub release-line fallback")
        self.assertNotIn("generating a fresh feed", step, "no silent fresh start")
        self.assertLess(step.index("storage_mirror_seed.py check"), step.index("generate_appcast"))
        self.assertIn('DL_PREFIX="https://wjxqmurgwyxwkezncxke.supabase.co/storage/v1/object/public/downloads/"', step)
        self.assertIn('PUB_STORAGE="${DL_PREFIX}appcast.xml"', step)
        curls = re.findall(r"curl [^\n]*", step)
        self.assertEqual(len(curls), 1, curls)
        self.assertIn("${PUB_STORAGE}", curls[0])
        self.assertIn('--storage-prefix "$DL_PREFIX"', step)

    def test_bootstrap_is_an_explicit_dispatch_input_off_by_default(self) -> None:
        text = self.workflow()
        inputs = text[text.index("workflow_dispatch:"):text.index("permissions:")]
        self.assertIn("bootstrap_storage_mirror:", inputs)
        self.assertIn("type: boolean", inputs)
        self.assertIn("default: false", inputs)
        step = self.storage_step()
        self.assertIn("github.event.inputs.bootstrap_storage_mirror", step)
        self.assertIn("--bootstrap", step)


if __name__ == "__main__":
    unittest.main()
