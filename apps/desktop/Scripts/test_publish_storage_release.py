#!/usr/bin/env python3
"""
Deterministic tests for publish_storage_release.py, driven through a fake
Storage bucket that records every operation and can be told to fail.

Run from apps/desktop:  python3 -m unittest Scripts/test_publish_storage_release.py -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import publish_storage_release as psr  # noqa: E402

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
BASE = "https://storage.example.test/storage/v1"
PUB = f"{BASE}/object/public/downloads/"


def feed_for(build: int, short: str, name: str, length: int, sig: str = "SIG==") -> bytes:
    return (
        f'<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>Zerro Staging</title>'
        f"<item><title>{short}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{short}</sparkle:shortVersionString>"
        f'<enclosure url="{PUB}{name}" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/></item>'
        "</channel></rss>"
    ).encode()


class FakeStorage:
    """An in-memory public bucket. `objects` is the live state; `log` records
    every call in order; `fail_put` makes uploads of those names fail; `stale`
    makes reads of those names keep returning the pre-existing bytes (a CDN
    that never catches up)."""

    def __init__(self, objects: dict[str, bytes] | None = None):
        self.objects = dict(objects or {})
        self.log: list[tuple] = []
        self.fail_put: set[str] = set()
        self.stale: dict[str, bytes] = {}

    def public_url(self, name: str) -> str:
        return PUB + name

    def get(self, name: str, cache_buster: str) -> bytes | None:
        self.log.append(("get", name))
        if name in self.stale:
            return self.stale[name]
        return self.objects.get(name)

    def put(self, name: str, data: bytes, content_type: str, upsert: bool, cache_control: str | None = None) -> None:
        self.log.append(("put", name, upsert, content_type, cache_control))
        if name in self.fail_put:
            raise psr.StorageError(f"upload of {name} failed with HTTP 500 (injected)")
        if name in self.objects and not upsert:
            raise psr.StorageError(f"upload of {name} failed with HTTP 400: resource already exists")
        self.objects[name] = data


NEW_DMG = b"D" * 5000
OLD_DMG = b"O" * 4000
NO_SLEEP = lambda seconds: None  # noqa: E731


def run_publish(storage: FakeStorage, *, appcast: bytes | None = None, alias: str | None = "ZerroStaging.dmg", dmg: bytes = NEW_DMG, build: int = 570, version: str = "1.4.47", attempts: int = 3):
    return psr.publish(
        storage,
        immutable_name=f"ZerroStaging-{build}.dmg",
        dmg_bytes=dmg,
        appcast_name="appcast-staging.xml",
        appcast_bytes=appcast if appcast is not None else feed_for(build, version, f"ZerroStaging-{build}.dmg", len(dmg)),
        alias_name=alias,
        expect_build=build,
        expect_version=version,
        expect_items=1,
        cache_buster="test",
        attempts=attempts,
        sleep=NO_SLEEP,
        log=lambda _: None,
    )


class OrderingTests(unittest.TestCase):
    def test_fresh_publish_uses_the_safe_order_and_writes_the_alias_last(self) -> None:
        storage = FakeStorage()
        run_publish(storage)
        ops = [(op[0], op[1]) for op in storage.log]
        self.assertEqual(ops, [
            ("get", "ZerroStaging-570.dmg"),          # existence check
            ("put", "ZerroStaging-570.dmg"),          # immutable upload, no upsert
            ("get", "ZerroStaging-570.dmg"),          # read back + compare
            ("put", "appcast-staging.xml"),           # feed only after the archive verified
            ("get", "appcast-staging.xml"),           # read back + compare
            ("put", "ZerroStaging.dmg"),              # alias last
            ("get", "ZerroStaging.dmg"),
        ])
        immutable_put = next(op for op in storage.log if op[0] == "put" and op[1] == "ZerroStaging-570.dmg")
        self.assertFalse(immutable_put[2], "the immutable archive is uploaded WITHOUT upsert")
        feed_put = next(op for op in storage.log if op[0] == "put" and op[1] == "appcast-staging.xml")
        self.assertTrue(feed_put[2]); self.assertEqual(feed_put[4], "no-cache")
        self.assertEqual(storage.objects["ZerroStaging-570.dmg"], NEW_DMG)
        self.assertEqual(storage.objects["ZerroStaging.dmg"], NEW_DMG)

    def test_the_feed_must_reference_the_immutable_url_before_any_write(self) -> None:
        storage = FakeStorage()
        mutable_feed = feed_for(570, "1.4.47", "ZerroStaging.dmg", len(NEW_DMG))
        with self.assertRaises(psr.StorageError) as ctx:
            run_publish(storage, appcast=mutable_feed)
        self.assertIn("enclosure url is", str(ctx.exception))
        self.assertEqual(storage.log, [], "nothing may be read or written when the feed points at the mutable alias")
        self.assertEqual(storage.objects, {})

    def test_feed_describing_a_different_build_or_length_is_refused_before_any_write(self) -> None:
        storage = FakeStorage()
        with self.assertRaises(psr.StorageError):
            run_publish(storage, appcast=feed_for(569, "1.4.46", "ZerroStaging-569.dmg", len(NEW_DMG)))
        with self.assertRaises(psr.StorageError):
            run_publish(storage, appcast=feed_for(570, "1.4.47", "ZerroStaging-570.dmg", len(NEW_DMG) + 1))
        self.assertEqual(storage.log, [])


class ImmutableArchiveTests(unittest.TestCase):
    def test_existing_identical_object_is_reused_without_rewriting(self) -> None:
        storage = FakeStorage({"ZerroStaging-570.dmg": NEW_DMG})
        run_publish(storage)
        puts = [op[1] for op in storage.log if op[0] == "put"]
        self.assertEqual(puts, ["appcast-staging.xml", "ZerroStaging.dmg"], "the immutable archive is not re-uploaded")

    def test_existing_object_with_different_bytes_is_rejected_before_any_write(self) -> None:
        storage = FakeStorage({"ZerroStaging-570.dmg": b"X" * 5000, "appcast-staging.xml": b"<old/>", "ZerroStaging.dmg": OLD_DMG})
        before = dict(storage.objects)
        with self.assertRaises(psr.StorageError) as ctx:
            run_publish(storage)
        self.assertIn("DIFFERENT bytes", str(ctx.exception))
        self.assertIn("new build number", str(ctx.exception))
        self.assertEqual([op for op in storage.log if op[0] == "put"], [], "no upload of any kind after the rejection")
        self.assertEqual(storage.objects, before)

    def test_immutable_readback_mismatch_stops_before_the_feed(self) -> None:
        storage = FakeStorage()
        storage.stale["ZerroStaging-570.dmg"] = None  # the existence check sees "missing"…
        # …but reads after the upload keep returning something else.
        original_get = storage.get

        def flaky_get(name, cb):
            result = original_get(name, cb)
            if name == "ZerroStaging-570.dmg" and any(op[0] == "put" for op in storage.log):
                return b"corrupt"
            return result

        storage.get = flaky_get
        with self.assertRaises(psr.StorageError) as ctx:
            run_publish(storage, attempts=2)
        self.assertIn("not byte-identical", str(ctx.exception))
        self.assertNotIn(("put", "appcast-staging.xml", True, psr.XML_CONTENT_TYPE, "no-cache"), storage.log)


class FeedFailureTests(unittest.TestCase):
    def previous_live_state(self) -> FakeStorage:
        old_feed = feed_for(569, "1.4.46", "ZerroStaging-569.dmg", len(OLD_DMG))
        return FakeStorage({"ZerroStaging-569.dmg": OLD_DMG, "appcast-staging.xml": old_feed, "ZerroStaging.dmg": OLD_DMG})

    def test_feed_upload_failure_leaves_the_previous_feed_and_archive_pair_intact(self) -> None:
        storage = self.previous_live_state()
        storage.fail_put.add("appcast-staging.xml")
        old_feed = storage.objects["appcast-staging.xml"]
        with self.assertRaises(psr.StorageError):
            run_publish(storage)
        # The previously live pair is untouched and still consistent.
        self.assertEqual(storage.objects["appcast-staging.xml"], old_feed)
        self.assertEqual(storage.objects["ZerroStaging-569.dmg"], OLD_DMG)
        self.assertEqual(storage.objects["ZerroStaging.dmg"], OLD_DMG, "the alias is written only after the feed, so it is untouched too")
        # The new immutable archive may exist (harmless: nothing references it yet).
        self.assertEqual(storage.objects["ZerroStaging-570.dmg"], NEW_DMG)
        self.assertNotIn(("put", "ZerroStaging.dmg", True, psr.DMG_CONTENT_TYPE, None), storage.log)

    def test_feed_readback_mismatch_fails_and_never_touches_the_alias(self) -> None:
        storage = self.previous_live_state()
        storage.stale["appcast-staging.xml"] = storage.objects["appcast-staging.xml"]  # CDN never catches up
        with self.assertRaises(psr.StorageError) as ctx:
            run_publish(storage, attempts=2)
        self.assertIn("appcast-staging.xml is not byte-identical", str(ctx.exception))
        self.assertEqual(storage.objects["ZerroStaging.dmg"], OLD_DMG)

    def test_alias_failure_cannot_affect_the_already_live_feed(self) -> None:
        storage = self.previous_live_state()
        storage.fail_put.add("ZerroStaging.dmg")
        with self.assertRaises(psr.StorageError):
            run_publish(storage)
        new_feed = feed_for(570, "1.4.47", "ZerroStaging-570.dmg", len(NEW_DMG))
        self.assertEqual(storage.objects["appcast-staging.xml"], new_feed, "the new feed is live…")
        self.assertEqual(storage.objects["ZerroStaging-570.dmg"], NEW_DMG, "…and its archive exists with the right bytes")
        self.assertEqual(storage.objects["ZerroStaging.dmg"], OLD_DMG)


class HttpClassificationTests(unittest.TestCase):
    def test_missing_object_is_only_a_genuine_not_found(self) -> None:
        self.assertTrue(psr.is_missing_response(404, b""))
        self.assertTrue(psr.is_missing_response(400, b'{"statusCode":"404","error":"not_found","message":"Object not found"}'))
        self.assertFalse(psr.is_missing_response(400, b'{"statusCode":"400","error":"InvalidRequest","message":"bad"}'))
        self.assertFalse(psr.is_missing_response(401, b"Unauthorized"))
        self.assertFalse(psr.is_missing_response(500, b""))
        self.assertFalse(psr.is_missing_response(400, b"not json"))

    def test_public_url_shape(self) -> None:
        client = psr.HttpStorage(BASE, "downloads", "token")
        self.assertEqual(client.public_url("ZerroStaging-570.dmg"), PUB + "ZerroStaging-570.dmg")


if __name__ == "__main__":
    unittest.main()
