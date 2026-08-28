#!/usr/bin/env python3
"""
Tests for staging_channel_publish.py against an in-memory GitHub, plus the
repository contracts around the GitHub-hosted staging channel (workflow,
Staging.xcconfig, and the untouched Production Storage mirror).

Run from apps/desktop:  python3 -m unittest Scripts/test_staging_channel_publish.py -v
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import staging_channel_publish as scp  # noqa: E402

REPO = "SmartScaleAI/Zerro"
SHA = "c" * 40
CHANNEL_URL = "https://github.com/SmartScaleAI/Zerro/releases/download/staging-channel/appcast-staging.xml"


def feed_xml(version: str = "1.0.1", build: int = 1001, *, length: int = 8010001, url: str | None = None, sig: str | None = "SIG==", items: int = 1, enclosures: int = 1) -> bytes:
    url = url or f"https://github.com/{REPO}/releases/download/staging-v{version}/ZerroStaging-{build}.dmg"
    enc = "".join(f'<enclosure url="{url}" length="{length}" type="application/octet-stream"' + (f' sparkle:edSignature="{sig}"' if sig is not None else "") + "/>" for _ in range(enclosures))
    item = f"<item><title>{version}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>{enc}</item>"
    return (f'<?xml version="1.0"?><rss xmlns:sparkle="{scp.SPARKLE_NS}" version="2.0"><channel><title>Zerro Staging</title>{item * items}</channel></rss>').encode()


class FakeGitHub:
    def __init__(self) -> None:
        self.releases: dict[int, dict] = {}
        self.blobs: dict[int, bytes] = {}
        self.next_release = 500
        self.next_asset = 9000
        self.calls: list[str] = []
        self.fail_on: dict[str, int] = {}          # op -> remaining calls before it fails once, BEFORE mutating
        self.raise_after: dict[str, int] = {}      # op -> remaining calls before it mutates and THEN raises once

    # fixtures
    def seed_release(self, tag: str, *, draft: bool = False, prerelease: bool = True, name: str | None = None, assets: dict[str, bytes] | None = None, states: dict[str, str] | None = None) -> dict:
        r = {"id": self.next_release, "tag_name": tag, "target_commitish": SHA, "name": name or tag, "draft": draft, "prerelease": prerelease, "assets": [],
             "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/{self.next_release}/assets{{?name,label}}"}
        self.next_release += 1
        self.releases[r["id"]] = r
        for n, data in (assets or {}).items():
            self._add(r, n, data, (states or {}).get(n, "uploaded"))
        return r

    def _add(self, r: dict, name: str, data: bytes, state: str = "uploaded") -> dict:
        a = {"id": self.next_asset, "name": name, "size": len(data), "state": state}
        self.next_asset += 1
        self.blobs[a["id"]] = data
        r["assets"].append(a)
        return a

    def _maybe_fail(self, op: str) -> None:
        self.calls.append(op)
        if op in self.fail_on:
            self.fail_on[op] -= 1
            if self.fail_on[op] < 0:
                del self.fail_on[op]
                raise scp.ChannelError(f"simulated failure in {op}")

    def _maybe_raise_after(self, op: str) -> None:
        """Called AFTER the mutation was applied: simulates a timeout/error
        response for a request GitHub actually executed."""
        if op in self.raise_after:
            self.raise_after[op] -= 1
            if self.raise_after[op] < 0:
                del self.raise_after[op]
                raise scp.ChannelError(f"simulated post-mutation error in {op}")

    def channel(self) -> dict | None:
        return next((r for r in self.releases.values() if r["tag_name"] == scp.CHANNEL_TAG), None)

    def names(self) -> list[str]:
        return sorted(a["name"] for a in self.channel()["assets"])

    def stable_bytes(self) -> bytes | None:
        a = next((a for a in self.channel()["assets"] if a["name"] == scp.STABLE_ASSET), None)
        return self.blobs[a["id"]] if a else None

    # transport
    def get_release_by_tag(self, tag: str) -> dict | None:
        self._maybe_fail("get_by_tag")
        r = next((r for r in self.releases.values() if r["tag_name"] == tag), None)
        return json.loads(json.dumps(r)) if r else None

    def get_release(self, release_id: int) -> dict:
        self._maybe_fail("get")
        return json.loads(json.dumps(self.releases[release_id]))

    def create_prerelease(self, tag: str, target: str, name: str) -> dict:
        self._maybe_fail("create")
        return json.loads(json.dumps(self.seed_release(tag, name=name)))

    def delete_asset(self, asset_id: int) -> None:
        self._maybe_fail("delete")
        for r in self.releases.values():
            r["assets"] = [a for a in r["assets"] if a["id"] != asset_id]
        self.blobs.pop(asset_id, None)
        self._maybe_raise_after("delete")

    def rename_asset(self, asset_id: int, name: str) -> dict:
        self._maybe_fail(f"rename:{name}")
        for r in self.releases.values():
            for a in r["assets"]:
                if a["id"] == asset_id:
                    a["name"] = name
                    self._maybe_raise_after(f"rename:{name}")
                    return dict(a)
        raise scp.ChannelError("no such asset")

    def upload_asset(self, release: dict, name: str, path: Path) -> dict:
        self._maybe_fail("upload")
        return dict(self._add(self.releases[release["id"]], name, path.read_bytes()))

    def download_asset(self, asset_id: int, dest: Path) -> None:
        self._maybe_fail("download")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(self.blobs[asset_id])


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.gh = FakeGitHub()
        # The versioned prerelease this run just verified (1.0.1 / 1001).
        self.local = feed_xml("1.0.1", 1001)
        self.gh.seed_release("staging-v1.0.1", assets={"ZerroStaging-1001.dmg": b"x" * 8010001, "ZerroStaging.dmg": b"x" * 8010001, "appcast-staging.xml": self.local})
        self.feed = self.tmp / "appcast-staging.xml"
        self.feed.write_bytes(self.local)

    def seed_channel(self, stable: bytes | None, **kw) -> dict:
        assets = {scp.STABLE_ASSET: stable} if stable is not None else {}
        assets.update(kw.pop("extra", {}))
        return self.gh.seed_release(scp.CHANNEL_TAG, name=kw.pop("name", scp.CHANNEL_NAME), assets=assets, **kw)

    def publish(self, *, version: str = "1.0.1", build: int = 1001, tag: str | None = None, bootstrap: bool = False, tag_matches: bool = True, feed: Path | None = None) -> str:
        return scp.publish(self.gh, REPO, tag or f"staging-v{version}", SHA, build, version, feed or self.feed, self.tmp / "dl", bootstrap=bootstrap, tag_matches_commit=tag_matches)

    def seed_previous_release(self, version: str, build: int) -> bytes:
        data = feed_xml(version, build, length=8000000 + build)
        self.gh.seed_release(f"staging-v{version}", assets={f"ZerroStaging-{build}.dmg": b"y" * (8000000 + build), "appcast-staging.xml": data})
        return data


class ChannelResolutionTests(Fixture):
    def test_missing_channel_without_bootstrap_fails(self) -> None:
        with self.assertRaisesRegex(scp.ChannelError, "does not exist"):
            self.publish()
        self.assertIsNone(self.gh.channel())
        self.assertNotIn("create", self.gh.calls)

    def test_bootstrap_creates_exactly_the_permanent_prerelease_and_publishes(self) -> None:
        out = self.publish(bootstrap=True)
        ch = self.gh.channel()
        self.assertEqual((ch["tag_name"], ch["name"], ch["draft"], ch["prerelease"]), (scp.CHANNEL_TAG, scp.CHANNEL_NAME, False, True))
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertEqual(self.gh.stable_bytes(), self.local)
        self.assertIn("bootstrapped", out)
        self.assertEqual(self.gh.calls.count("create"), 1)

    def test_existing_draft_or_non_prerelease_channel_fails(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000), draft=True)
        with self.assertRaisesRegex(scp.ChannelError, "is a draft"):
            self.publish()
        self.gh.releases.clear(); self.setUp()
        self.seed_channel(feed_xml("1.0.0", 1000), prerelease=False)
        with self.assertRaisesRegex(scp.ChannelError, "not a prerelease"):
            self.publish()
        self.gh.releases.clear(); self.setUp()
        self.seed_channel(feed_xml("1.0.0", 1000), name="Something else")
        with self.assertRaisesRegex(scp.ChannelError, "unknown channel state"):
            self.publish()

    def test_bootstrap_flag_does_not_override_an_invalid_existing_channel(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000), draft=True)
        with self.assertRaisesRegex(scp.ChannelError, "is a draft"):
            self.publish(bootstrap=True)


class LiveStateTests(Fixture):
    def test_missing_live_feed_fails_without_bootstrap(self) -> None:
        self.seed_channel(None)
        with self.assertRaisesRegex(scp.ChannelError, "missing live state"):
            self.publish()
        self.assertEqual(self.gh.names(), [])

    def test_malformed_or_empty_live_feed_fails(self) -> None:
        for bad in (b"<rss><channel><item>", feed_xml(items=0), feed_xml(items=2), b""):
            with self.subTest(bad=bad[:20]):
                self.gh.releases.clear(); self.setUp()
                self.seed_channel(bad)
                with self.assertRaises(scp.ChannelError):
                    self.publish()
                self.assertEqual(self.gh.stable_bytes(), bad, "the live asset is left untouched")

    def test_newer_live_build_fails(self) -> None:
        self.seed_previous_release("1.0.2", 1002)
        live = feed_xml("1.0.2", 1002, length=8001002)
        self.seed_channel(live)
        with self.assertRaisesRegex(scp.ChannelError, "move the channel backwards"):
            self.publish()
        self.assertEqual(self.gh.stable_bytes(), live)

    def test_newer_build_replaces_the_live_feed(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old)
        out = self.publish()
        self.assertEqual(self.gh.stable_bytes(), self.local)
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertIn("1.0.1 (build 1001)", out)

    def test_older_build_fails(self) -> None:
        self.seed_previous_release("1.0.0", 1000)
        live = feed_xml("1.0.2", 1002, length=8001002)
        self.seed_channel(live)
        with self.assertRaisesRegex(scp.ChannelError, "backwards"):
            self.publish()

    def test_same_build_retry_requires_matching_tag_commit_and_identical_bytes(self) -> None:
        self.seed_channel(self.local)
        self.assertIn("nothing changed", self.publish(tag_matches=True))
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertFalse(any(c.startswith(("upload", "rename", "delete")) for c in self.gh.calls))
        with self.assertRaisesRegex(scp.ChannelError, "was not proven"):
            self.publish(tag_matches=False)
        # Same build, different bytes (e.g. re-signed) → refused.
        self.gh.releases.clear(); self.setUp()
        self.seed_channel(feed_xml("1.0.1", 1001, sig="OTHER=="))
        with self.assertRaisesRegex(scp.ChannelError, "different feed bytes"):
            self.publish(tag_matches=True)
        # Same build under a different version/tag → refused.
        self.gh.releases.clear(); self.setUp()
        self.gh.seed_release("staging-v1.0.9", assets={"ZerroStaging-1001.dmg": b"z" * 8010001})
        self.seed_channel(feed_xml("1.0.9", 1001))
        with self.assertRaisesRegex(scp.ChannelError, "reused the build number"):
            self.publish(tag_matches=True)

    def test_unexpected_channel_assets_fail(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000), extra={"ZerroStaging.dmg": b"nope"})
        with self.assertRaisesRegex(scp.ChannelError, "unexpected assets"):
            self.publish()


class LocalFeedTests(Fixture):
    def test_local_feed_must_match_this_release_and_its_versioned_prerelease(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000))
        with self.assertRaisesRegex(scp.ChannelError, "expected 1.0.2"):
            self.publish(version="1.0.2", build=1002)
        bad = self.tmp / "bad.xml"
        for data, msg in ((feed_xml("1.0.1", 1001, url=f"https://github.com/{REPO}/releases/download/staging-v1.0.1/ZerroStaging.dmg"), "not an immutable"),
                          (feed_xml("1.0.1", 1001, url=f"https://github.com/{REPO}/releases/latest/download/ZerroStaging-1001.dmg"), "not an immutable GitHub"),
                          (feed_xml("1.0.1", 1001, url="https://wjxq.supabase.co/storage/v1/object/public/downloads/ZerroStaging-1001.dmg"), "not an immutable GitHub"),
                          (feed_xml("1.0.1", 1001, sig=None), "edSignature"),
                          (feed_xml("1.0.1", 1001, length=0), "positive integer length"),
                          (feed_xml("1.0.1", 1001, enclosures=2), "exactly one enclosure"),
                          (feed_xml("1.0.1", 1001, items=2), "exactly one item")):
            with self.subTest(msg=msg):
                bad.write_bytes(data)
                with self.assertRaisesRegex(scp.ChannelError, msg):
                    self.publish(feed=bad)
        # Versioned prerelease asset must exist, be uploaded, and match the length.
        self.gh.releases.clear(); self.setUp()
        self.seed_channel(feed_xml("1.0.0", 1000))
        rel = next(r for r in self.gh.releases.values() if r["tag_name"] == "staging-v1.0.1")
        rel["assets"][0]["size"] = 1
        with self.assertRaisesRegex(scp.ChannelError, "feed records length"):
            self.publish()
        rel["assets"][0]["size"] = 8010001
        rel["assets"][0]["state"] = "starter"
        with self.assertRaisesRegex(scp.ChannelError, "expected exactly 'uploaded'"):
            self.publish()
        rel["assets"][0]["state"] = "uploaded"
        rel["draft"] = True
        with self.assertRaisesRegex(scp.ChannelError, "published prerelease"):
            self.publish()


class SafeSwapTests(Fixture):
    def test_candidate_must_verify_before_the_stable_asset_changes(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old)
        self.gh.fail_on = {"download": 1}   # live download ok (1st), candidate download fails (2nd)
        with self.assertRaisesRegex(scp.ChannelError, "simulated failure in download"):
            self.publish()
        self.assertEqual(self.gh.stable_bytes(), old, "stable untouched when the candidate cannot be verified")
        self.assertNotIn(f"rename:{scp.BACKUP_ASSET}", self.gh.calls)
        # Upload failure likewise leaves the stable feed alone.
        self.gh.releases.clear(); self.setUp(); self.seed_channel(old)
        self.gh.fail_on = {"upload": 0}
        with self.assertRaisesRegex(scp.ChannelError, "simulated failure in upload"):
            self.publish()
        self.assertEqual(self.gh.stable_bytes(), old)

    def test_failure_during_promotion_restores_the_previous_feed(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old)
        self.gh.fail_on = {f"rename:{scp.STABLE_ASSET}": 0}   # stable→backup ok, candidate→stable fails
        with self.assertRaisesRegex(scp.ChannelError, "previous stable feed was restored"):
            self.publish()
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertEqual(self.gh.stable_bytes(), old)
        # Failure while verifying the promoted asset also restores.
        self.gh.releases.clear(); self.setUp(); self.seed_channel(old)
        self.gh.fail_on = {"download": 2}   # live ok, candidate ok, promoted download fails
        with self.assertRaisesRegex(scp.ChannelError, "previous stable feed was restored"):
            self.publish()
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertEqual(self.gh.stable_bytes(), old)

    def _old_stable_id(self) -> int:
        return next(a["id"] for a in self.gh.channel()["assets"] if a["name"] == scp.STABLE_ASSET)

    def assert_restored(self, old: bytes, old_id: int) -> None:
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET], "exactly the stable asset remains")
        stable = next(a for a in self.gh.channel()["assets"] if a["name"] == scp.STABLE_ASSET)
        self.assertEqual(stable["id"], old_id, "the previous asset (by ID) is back under the stable name")
        self.assertEqual(self.gh.stable_bytes(), old)

    def test_every_promotion_failure_point_restores_the_previous_feed(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        scenarios = {
            "first rename fails before mutation": {"fail_on": {f"rename:{scp.BACKUP_ASSET}": 0}},
            "first rename applied remotely but raises": {"raise_after": {f"rename:{scp.BACKUP_ASSET}": 0}},
            "candidate rename fails before mutation": {"fail_on": {f"rename:{scp.STABLE_ASSET}": 0}},
            "candidate rename applied remotely but raises": {"raise_after": {f"rename:{scp.STABLE_ASSET}": 0}},
            "promoted feed verification fails": {"fail_on": {"download": 2}},
        }
        for label, injected in scenarios.items():
            with self.subTest(label=label):
                self.gh.releases.clear(); self.gh.blobs.clear(); self.setUp()
                self.seed_channel(old)
                old_id = self._old_stable_id()
                self.gh.fail_on = dict(injected.get("fail_on", {}))
                self.gh.raise_after = dict(injected.get("raise_after", {}))
                with self.assertRaisesRegex(scp.ChannelError, "previous stable feed was restored as appcast-staging.xml"):
                    self.publish()
                self.assert_restored(old, old_id)

    def test_stable_to_backup_ambiguous_failure_keeps_old_feed_available_under_stable_name(self) -> None:
        # GitHub applied the stable→backup rename but the API call errored.
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old)
        old_id = self._old_stable_id()
        self.gh.raise_after = {f"rename:{scp.BACKUP_ASSET}": 0}
        with self.assertRaisesRegex(scp.ChannelError, "restored as appcast-staging.xml"):
            self.publish()
        self.assert_restored(old, old_id)
        # The reconciliation never assumed the rename was skipped: it observed
        # the asset under the backup name and renamed it back by ID.
        self.assertIn(f"rename:{scp.STABLE_ASSET}", self.gh.calls[self.gh.calls.index(f"rename:{scp.BACKUP_ASSET}"):])

    def test_reconciliation_survives_a_post_mutation_error_on_the_restoring_rename(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old)
        old_id = self._old_stable_id()
        # candidate rename fails before mutation; then the restoring rename
        # (backup→stable) is applied remotely but raises.
        self.gh.fail_on = {f"rename:{scp.STABLE_ASSET}": 0}
        self.gh.raise_after = {f"rename:{scp.STABLE_ASSET}": 0}
        with self.assertRaisesRegex(scp.ChannelError, "restored as appcast-staging.xml"):
            self.publish()
        self.assert_restored(old, old_id)

    def test_success_leaves_exactly_one_stable_asset_and_cleans_leftovers(self) -> None:
        old = feed_xml("1.0.0", 1000, length=8009857)
        self.seed_channel(old, extra={scp.CANDIDATE_ASSET: b"stale candidate", scp.BACKUP_ASSET: b"stale backup"})
        self.publish()
        self.assertEqual(self.gh.names(), [scp.STABLE_ASSET])
        self.assertEqual(self.gh.stable_bytes(), self.local)

    def test_leftover_backup_without_stable_is_unknown_state(self) -> None:
        self.seed_channel(None, extra={scp.BACKUP_ASSET: feed_xml("1.0.0", 1000)})
        with self.assertRaisesRegex(scp.ChannelError, "missing live state"):
            self.publish()
        with self.assertRaisesRegex(scp.ChannelError, "leftover"):
            self.publish(bootstrap=True)


class DownloadedFeedValidatorTests(Fixture):
    def test_downloaded_stable_feed_is_byte_identical_and_passes_both_validators(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000, length=8009857))
        self.publish()
        downloaded = self.tmp / "channel-appcast-staging.xml"
        a = next(a for a in self.gh.channel()["assets"] if a["name"] == scp.STABLE_ASSET)
        self.gh.download_asset(a["id"], downloaded)
        self.assertEqual(downloaded.read_bytes(), self.feed.read_bytes())
        url = f"https://github.com/{REPO}/releases/download/staging-v1.0.1/ZerroStaging-1001.dmg"
        guard = subprocess.run([sys.executable, str(HERE / "appcast_publish_guard.py"), "check", "--feed", str(downloaded), "--expect-build", "1001", "--expect-version", "1.0.1",
                                "--expect-url", url, "--expect-length", "8010001", "--expect-items", "1"], capture_output=True, text=True)
        self.assertEqual(guard.returncode, 0, guard.stderr)
        verify = subprocess.run([sys.executable, str(HERE / "appcast_github_feed.py"), "verify", "--flavor", "staging", "--repo", REPO, "--current-build", "1001",
                                 "--current-tag", "staging-v1.0.1", "--feed", str(downloaded), "--expect-items", "1"], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_cli_round_trip(self) -> None:
        self.seed_channel(feed_xml("1.0.0", 1000, length=8009857))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = scp.main(["--repo", REPO, "publish", "--tag", "staging-v1.0.1", "--target", SHA, "--build", "1001", "--version", "1.0.1",
                             "--feed", str(self.feed), "--download-dir", str(self.tmp / "dl"), "--tag-matches-commit"], lambda repo: self.gh)
        self.assertEqual(code, 0)
        self.assertEqual(self.gh.stable_bytes(), self.local)


ROOT = HERE.parent.parent.parent


class RepositoryContractTests(unittest.TestCase):
    STAGING_HOST = "waripvlpcpwdmacpjiqc"

    def test_staging_workflow_has_no_supabase_dependency(self) -> None:
        wf = (ROOT / ".github/workflows/release-staging.yml").read_text(encoding="utf-8")
        for needle in (self.STAGING_HOST, "STAGING_PROJECT_REF", "STAGING_SERVICE_ROLE_KEY", "publish_storage_release", "supabase.co", "storage/v1"):
            self.assertNotIn(needle, wf, needle)
        self.assertIn("staging_channel_publish.py", wf)
        self.assertIn("bootstrap_staging_channel", wf)
        inputs = wf[wf.index("workflow_dispatch:"):wf.index("permissions:")]
        self.assertIn("type: boolean", inputs)
        self.assertIn("default: false", inputs)
        self.assertIn(f"releases/download/{scp.CHANNEL_TAG}/{scp.STABLE_ASSET}", wf)

    def test_staging_xcconfig_feed_url_resolves_to_the_channel_url(self) -> None:
        cfg = (ROOT / "apps/desktop/Config/Staging.xcconfig").read_text(encoding="utf-8")
        line = next(l for l in cfg.splitlines() if l.startswith("SU_FEED_URL"))
        value = line.split("=", 1)[1].strip().replace("$()", "")
        self.assertEqual(value, CHANNEL_URL)
        self.assertNotIn(self.STAGING_HOST, cfg)
        self.assertNotIn("supabase", cfg)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.cbreeding.Zerro.staging", cfg)
        self.assertIn("DEEPLINK_SCHEME = zerro-staging", cfg)
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) STAGING", cfg)

    def test_production_workflow_and_storage_mirror_are_unchanged(self) -> None:
        prod = (ROOT / ".github/workflows/release-app.yml").read_text(encoding="utf-8")
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY", prod)
        self.assertIn("Publish dmgs + appcast to Supabase Storage", prod)
        self.assertIn("storage_mirror_seed.py check", prod)
        self.assertIn("wjxqmurgwyxwkezncxke.supabase.co", prod)
        self.assertNotIn(self.STAGING_HOST, prod)
        head = subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--", ".github/workflows/release-app.yml", "apps/desktop/Scripts/publish_storage_release.py", "apps/desktop/Config/Production.xcconfig"], check=False)
        self.assertEqual(head.returncode, 0, "release-app.yml, publish_storage_release.py, and Production.xcconfig must be unchanged")


if __name__ == "__main__":
    unittest.main()
