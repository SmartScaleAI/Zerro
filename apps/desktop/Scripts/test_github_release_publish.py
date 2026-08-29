#!/usr/bin/env python3
"""
Tests for github_release_publish.py against an in-memory GitHub.

Run from apps/desktop:  python3 -m unittest Scripts/test_github_release_publish.py -v

The fake models exactly what the flow depends on: releases with draft state,
tag_name, target_commitish, assets (id/name/size/state/updated_at), asset
upload/delete/download, and `releases/latest` (newest published, non-draft,
non-prerelease release, or whichever was last marked latest). Failure hooks
let a test break the flow at a chosen point and assert what is left behind.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import github_release_publish as pub  # noqa: E402

REPO = "SmartScaleAI/Zerro"
TAG = "app-v1.4.36"
SHA = "a" * 40
OTHER_SHA = "b" * 40


class FakeGitHub:
    def __init__(self) -> None:
        self.releases: dict[int, dict] = {}
        self.blobs: dict[int, bytes] = {}
        self.next_release_id = 100
        self.next_asset_id = 1000
        self.clock = 0
        self.latest_id: int | None = None
        self.fail_upload_named: set[str] = set()
        self.fail_update = False
        self.drop_make_latest = False
        self.calls: list[str] = []

    # -- fixture helpers ---------------------------------------------------
    def seed(self, tag: str, *, draft: bool, target: str = OTHER_SHA, assets: dict[str, bytes] | None = None, latest: bool = False, states: dict[str, str] | None = None) -> dict:
        release = {
            "id": self.next_release_id, "tag_name": tag, "target_commitish": target, "name": tag,
            "draft": draft, "prerelease": False, "assets": [],
            "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/{self.next_release_id}/assets{{?name,label}}",
            "html_url": f"https://github.com/{REPO}/releases/tag/{tag}",
        }
        self.next_release_id += 1
        self.releases[release["id"]] = release
        for name, data in (assets or {}).items():
            self._add_asset(release, name, data, state=(states or {}).get(name, "uploaded"))
        if latest:
            self.latest_id = release["id"]
        return release

    def _add_asset(self, release: dict, name: str, data: bytes, state: str = "uploaded") -> dict:
        self.clock += 1
        asset = {"id": self.next_asset_id, "name": name, "size": len(data), "state": state, "updated_at": f"t{self.clock}"}
        self.next_asset_id += 1
        self.blobs[asset["id"]] = data
        release["assets"].append(asset)
        return asset

    def _copy(self, release: dict) -> dict:
        return json.loads(json.dumps(release))

    # -- GitHub protocol ----------------------------------------------------
    def list_releases(self) -> list[dict]:
        self.calls.append("list")
        return [self._copy(r) for r in self.releases.values()]

    def get_release(self, release_id: int) -> dict:
        self.calls.append(f"get:{release_id}")
        return self._copy(self.releases[release_id])

    def create_draft(self, tag: str, target: str, title: str) -> dict:
        self.calls.append(f"create:{tag}")
        return self._copy(self.seed(tag, draft=True, target=target))

    def update_release(self, release_id: int, fields: dict) -> dict:
        self.calls.append(f"update:{release_id}:{sorted(fields)}")
        if self.fail_update:
            raise pub.PublishError("simulated PATCH failure")
        release = self.releases[release_id]
        for key, value in fields.items():
            if key == "make_latest":
                if value == "true" and not self.drop_make_latest:
                    self.latest_id = release_id
            elif key == "name":
                release["name"] = value
            else:
                release[key] = value
        return self._copy(release)

    def delete_asset(self, asset_id: int) -> None:
        self.calls.append(f"delete-asset:{asset_id}")
        for release in self.releases.values():
            release["assets"] = [a for a in release["assets"] if a["id"] != asset_id]
        self.blobs.pop(asset_id, None)

    def upload_asset(self, release: dict, name: str, path: Path) -> dict:
        self.calls.append(f"upload:{release['id']}:{name}")
        live = self.releases[release["id"]]
        if name in self.fail_upload_named:
            # GitHub leaves a "starter" asset behind when an upload dies.
            self._add_asset(live, name, b"", state="starter")
            raise pub.PublishError(f"simulated upload failure for {name}")
        return self._copy(self._add_asset(live, name, path.read_bytes()))

    def download_asset(self, asset_id: int, dest: Path) -> None:
        self.calls.append(f"download:{asset_id}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(self.blobs[asset_id])

    def latest_release(self) -> dict | None:
        self.calls.append("latest")
        return self._copy(self.releases[self.latest_id]) if self.latest_id is not None else None


class PublishFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.gh = FakeGitHub()
        self.previous = self.gh.seed("app-v1.4.35", draft=False, assets={"Zerro-600.dmg": b"old", "Zerro.dmg": b"old", "appcast.xml": b"<old/>"}, latest=True)
        self.dmg = self.write("dist/Zerro-610.dmg", b"DMG-BYTES-610")
        self.stable = self.write("dist/github/Zerro.dmg", b"DMG-BYTES-610")
        self.feed = self.write("dist/github/appcast.xml", b"<rss>feed</rss>")
        self.assets = [
            pub.ExpectedAsset("Zerro-610.dmg", self.dmg),
            pub.ExpectedAsset("Zerro.dmg", self.stable),
            pub.ExpectedAsset("appcast.xml", self.feed),
        ]

    def write(self, name: str, data: bytes) -> Path:
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def run_full_flow(self) -> tuple[dict, dict]:
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        pub.upload(self.gh, draft["id"], TAG, self.assets[:2])
        pub.upload(self.gh, draft["id"], TAG, self.assets[2:])
        manifest = pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "verify")
        return draft, manifest

    def assert_previous_still_latest(self) -> None:
        self.assertEqual(self.gh.latest_release()["id"], self.previous["id"])

    def names(self, release_id: int) -> list[str]:
        return sorted(a["name"] for a in self.gh.releases[release_id]["assets"])


class PrepareTests(PublishFixture):
    def test_creates_a_draft_pinned_to_this_commit_and_leaves_latest_alone(self) -> None:
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        live = self.gh.releases[draft["id"]]
        self.assertTrue(live["draft"])
        self.assertEqual(live["target_commitish"], SHA)
        self.assertEqual(live["assets"], [])
        self.assert_previous_still_latest()

    def test_reuses_and_repairs_the_single_existing_draft_for_the_tag(self) -> None:
        stale = self.gh.seed(TAG, draft=True, target=OTHER_SHA, assets={"Zerro-610.dmg": b"half", "appcast.xml": b""}, states={"appcast.xml": "starter"})
        unrelated = self.gh.seed("app-v9.9.9", draft=True, assets={"Zerro-999.dmg": b"x"})
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        self.assertEqual(draft["id"], stale["id"], "the existing draft is reused, not duplicated")
        live = self.gh.releases[stale["id"]]
        self.assertEqual(live["assets"], [], "every stale asset (including the starter one) is removed")
        self.assertEqual(live["target_commitish"], SHA)
        self.assertTrue(live["draft"])
        self.assertEqual(self.names(unrelated["id"]), ["Zerro-999.dmg"], "unrelated drafts are untouched")
        self.assertEqual(len([r for r in self.gh.releases.values() if r["tag_name"] == TAG]), 1)
        self.assert_previous_still_latest()

    def test_fails_closed_on_ambiguous_drafts(self) -> None:
        self.gh.seed(TAG, draft=True)
        self.gh.seed(TAG, draft=True)
        with self.assertRaisesRegex(pub.PublishError, "2 draft releases exist"):
            pub.prepare(self.gh, TAG, SHA, "1.4.36")
        self.assertNotIn(f"create:{TAG}", self.gh.calls)

    def test_same_tag_rerun_after_publication_fails_closed(self) -> None:
        shipped = self.gh.seed(TAG, draft=False, target=SHA, assets={"Zerro-610.dmg": b"a", "Zerro.dmg": b"a", "appcast.xml": b"f"}, latest=True)
        with self.assertRaisesRegex(pub.PublishError, "published release already exists"):
            pub.prepare(self.gh, TAG, SHA, "1.4.36")
        self.assertEqual(self.names(shipped["id"]), ["Zerro-610.dmg", "Zerro.dmg", "appcast.xml"], "the live release is not modified")
        self.assertEqual(self.gh.latest_release()["id"], shipped["id"])
        self.assertFalse(any(c.startswith(("delete-asset", "update", "create")) for c in self.gh.calls))


class UploadTests(PublishFixture):
    def test_replaces_a_same_name_asset_without_duplicates(self) -> None:
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        pub.upload(self.gh, draft["id"], TAG, self.assets[:1])
        self.write("dist/Zerro-610.dmg", b"DMG-BYTES-610-rebuilt")
        pub.upload(self.gh, draft["id"], TAG, self.assets[:1])
        live = self.gh.releases[draft["id"]]
        self.assertEqual([a["name"] for a in live["assets"]], ["Zerro-610.dmg"])
        self.assertEqual(live["assets"][0]["size"], len(b"DMG-BYTES-610-rebuilt"))

    def test_refuses_a_release_that_is_no_longer_a_draft(self) -> None:
        shipped = self.gh.seed(TAG, draft=False, target=SHA)
        with self.assertRaisesRegex(pub.PublishError, "already published"):
            pub.upload(self.gh, shipped["id"], TAG, self.assets[:1])
        self.assertEqual(self.gh.releases[shipped["id"]]["assets"], [])

    def test_a_failed_upload_leaves_a_draft_that_a_rerun_repairs(self) -> None:
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        pub.upload(self.gh, draft["id"], TAG, self.assets[:1])
        self.gh.fail_upload_named.add("Zerro.dmg")
        with self.assertRaisesRegex(pub.PublishError, "simulated upload failure"):
            pub.upload(self.gh, draft["id"], TAG, self.assets[1:2])
        live = self.gh.releases[draft["id"]]
        self.assertTrue(live["draft"], "nothing was published")
        self.assert_previous_still_latest()
        self.assertIn("starter", [a["state"] for a in live["assets"]])
        # Same-tag re-run: prepare repairs the same draft, then the flow completes.
        self.gh.fail_upload_named.clear()
        again = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        self.assertEqual(again["id"], draft["id"])
        self.assertEqual(self.gh.releases[draft["id"]]["assets"], [])
        _, manifest = self.run_full_flow()
        self.assertEqual(self.names(draft["id"]), ["Zerro-610.dmg", "Zerro.dmg", "appcast.xml"])
        self.assertEqual(len(self.gh.releases[draft["id"]]["assets"]), 3, "no duplicates after the re-run")
        self.assertEqual(manifest["release_id"], draft["id"])


class VerifyTests(PublishFixture):
    def test_verifies_exactly_the_three_assets_by_size_and_bytes(self) -> None:
        draft, manifest = self.run_full_flow()
        self.assertEqual([a["name"] for a in manifest["assets"]], ["Zerro-610.dmg", "Zerro.dmg", "appcast.xml"])
        self.assertEqual({a["sha256"] for a in manifest["assets"] if a["name"] != "appcast.xml"}, {pub.sha256_of(self.dmg)})
        self.assertTrue((self.tmp / "verify/appcast.xml").read_bytes() == b"<rss>feed</rss>")
        self.assertTrue(self.gh.releases[draft["id"]]["draft"], "verify never publishes")
        self.assert_previous_still_latest()

    def test_rejects_missing_extra_or_altered_assets(self) -> None:
        draft = pub.prepare(self.gh, TAG, SHA, "1.4.36")
        pub.upload(self.gh, draft["id"], TAG, self.assets[:2])
        with self.assertRaisesRegex(pub.PublishError, "must carry exactly"):
            pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v1")
        pub.upload(self.gh, draft["id"], TAG, self.assets[2:])
        live = self.gh.releases[draft["id"]]
        self.gh._add_asset(live, "Zerro-609.dmg", b"stray")
        with self.assertRaisesRegex(pub.PublishError, "must carry exactly"):
            pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v2")
        live["assets"] = [a for a in live["assets"] if a["name"] != "Zerro-609.dmg"]
        # Bytes drift after upload (same size, different content).
        feed_asset = next(a for a in live["assets"] if a["name"] == "appcast.xml")
        self.gh.blobs[feed_asset["id"]] = b"<rss>fee!</rss>"
        with self.assertRaisesRegex(pub.PublishError, "differs from the local artifact"):
            pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v3")
        self.gh.blobs[feed_asset["id"]] = b"<rss>feed</rss>"
        feed_asset["size"] = 1
        with self.assertRaisesRegex(pub.PublishError, "bytes on GitHub"):
            pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v4")
        feed_asset["size"] = len(b"<rss>feed</rss>")
        feed_asset["state"] = "starter"
        with self.assertRaisesRegex(pub.PublishError, "state 'starter'"):
            pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v5")
        feed_asset["state"] = "uploaded"
        with self.assertRaisesRegex(pub.PublishError, "pinned to a different commit"):
            pub.verify(self.gh, draft["id"], TAG, OTHER_SHA, self.assets, self.tmp / "v6")
        self.assertTrue(live["draft"])
        self.assert_previous_still_latest()


class PublishTests(PublishFixture):
    def test_publishes_and_marks_latest_only_after_the_verified_manifest_matches(self) -> None:
        draft, manifest = self.run_full_flow()
        self.assert_previous_still_latest()
        published = pub.publish(self.gh, draft["id"], TAG, SHA, manifest, sleep=lambda _: None)
        self.assertFalse(published["draft"])
        self.assertEqual(self.gh.latest_release()["id"], draft["id"])
        # The PATCH is the last mutation; every read happened before it.
        patch = next(i for i, c in enumerate(self.gh.calls) if c.startswith(f"update:{draft['id']}:['draft', 'make_latest']"))
        self.assertTrue(all(c.startswith(("get", "latest")) for c in self.gh.calls[patch + 1:]))

    def test_refuses_to_publish_without_a_matching_manifest(self) -> None:
        draft, manifest = self.run_full_flow()
        # A change after verification (re-upload → new asset id/updated_at).
        pub.upload(self.gh, draft["id"], TAG, self.assets[2:])
        with self.assertRaisesRegex(pub.PublishError, "changed since verification"):
            pub.publish(self.gh, draft["id"], TAG, SHA, manifest, sleep=lambda _: None)
        self.assertTrue(self.gh.releases[draft["id"]]["draft"])
        self.assert_previous_still_latest()
        # A manifest for a different release / commit.
        fresh = pub.verify(self.gh, draft["id"], TAG, SHA, self.assets, self.tmp / "v")
        with self.assertRaisesRegex(pub.PublishError, "not this run"):
            pub.publish(self.gh, draft["id"], TAG, OTHER_SHA, fresh, sleep=lambda _: None)
        with self.assertRaisesRegex(pub.PublishError, "not this run"):
            pub.publish(self.gh, draft["id"] + 1, TAG, SHA, fresh, sleep=lambda _: None)
        # Only two of the three assets → no manifest can be produced, and a
        # hand-edited one is rejected because the asset counts differ.
        stripped = dict(fresh, assets=fresh["assets"][:2])
        with self.assertRaisesRegex(pub.PublishError, "carries 3 assets, the verified manifest has 2"):
            pub.publish(self.gh, draft["id"], TAG, SHA, stripped, sleep=lambda _: None)
        self.assertTrue(self.gh.releases[draft["id"]]["draft"])
        self.assert_previous_still_latest()
        self.assertFalse(any("make_latest" in c for c in self.gh.calls), "no publication PATCH was ever sent")

    def test_failed_patch_leaves_the_draft_and_previous_latest(self) -> None:
        draft, manifest = self.run_full_flow()
        self.gh.fail_update = True
        with self.assertRaisesRegex(pub.PublishError, "simulated PATCH failure"):
            pub.publish(self.gh, draft["id"], TAG, SHA, manifest, sleep=lambda _: None)
        self.assertTrue(self.gh.releases[draft["id"]]["draft"])
        self.assert_previous_still_latest()

    def test_published_but_not_latest_is_reported_as_a_failure(self) -> None:
        draft, manifest = self.run_full_flow()
        self.gh.drop_make_latest = True
        slept: list[float] = []
        with self.assertRaisesRegex(pub.PublishError, "is NOT releases/latest"):
            pub.publish(self.gh, draft["id"], TAG, SHA, manifest, sleep=slept.append)
        self.assertFalse(self.gh.releases[draft["id"]]["draft"], "the release was published…")
        self.assert_previous_still_latest()  # …but latest never moved, which the script reports
        self.assertEqual(len(slept), pub.LATEST_CONFIRM_ATTEMPTS - 1)


class CliTests(PublishFixture):
    def setUp(self) -> None:
        super().setUp()
        self.quiet = contextlib.ExitStack()
        self.quiet.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.quiet.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.addCleanup(self.quiet.close)

    def test_cli_round_trip_with_injected_client(self) -> None:
        github_env = self.tmp / "github.env"
        factory = lambda repo: self.gh  # noqa: E731
        self.assertEqual(pub.main(["--repo", REPO, "prepare", "--tag", TAG, "--target", SHA, "--title", "1.4.36", "--github-env", str(github_env)], factory), 0)
        release_id = github_env.read_text().strip().split("=", 1)[1]
        self.assertEqual(
            pub.main(["--repo", REPO, "upload", "--release-id", release_id, "--tag", TAG, "--asset", str(self.dmg), "--asset", str(self.stable), "--asset", str(self.feed)], factory), 0
        )
        manifest = self.tmp / "manifest.json"
        self.assertEqual(
            pub.main([
                "--repo", REPO, "verify", "--release-id", release_id, "--tag", TAG, "--target", SHA,
                "--asset", f"Zerro-610.dmg={self.dmg}", "--asset", f"Zerro.dmg={self.stable}", "--asset", f"appcast.xml={self.feed}",
                "--download-dir", str(self.tmp / "dl"), "--manifest", str(manifest),
            ], factory), 0,
        )
        self.assert_previous_still_latest()
        pub.LATEST_CONFIRM_DELAY_SECONDS = 0
        self.assertEqual(pub.main(["--repo", REPO, "publish", "--release-id", release_id, "--tag", TAG, "--target", SHA, "--manifest", str(manifest)], factory), 0)
        self.assertEqual(self.gh.latest_release()["id"], int(release_id))

    def test_cli_publish_fails_without_a_manifest(self) -> None:
        draft, _ = self.run_full_flow()
        code = pub.main(["--repo", REPO, "publish", "--release-id", str(draft["id"]), "--tag", TAG, "--target", SHA, "--manifest", str(self.tmp / "missing.json")], lambda repo: self.gh)
        self.assertEqual(code, 1)
        self.assertTrue(self.gh.releases[draft["id"]]["draft"])
        self.assert_previous_still_latest()


if __name__ == "__main__":
    unittest.main()
