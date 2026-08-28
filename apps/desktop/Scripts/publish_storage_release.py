#!/usr/bin/env python3
"""
publish_storage_release.py — publish a release to the live Supabase Storage
download channel in an order that can never leave the Sparkle feed pointing at
bytes that no longer match it. Standard library only.

The feed must only ever reference an IMMUTABLE, build-specific archive
(ZerroStaging-<build>.dmg / Zerro-<build>.dmg). Because such an object is
never rewritten with different bytes, a feed that was live before this run
keeps referencing exactly the bytes it was signed against no matter where this
run fails. The order is therefore:

  0. Refuse before touching anything unless the feed to publish references the
     immutable object's public URL and advertises this build, version, the
     archive's real byte length, and a signature.
  1. Immutable archive: if the object already exists (a same-build re-run) it
     must be byte-identical to the local notarized archive — then it is reused
     untouched; different bytes fail closed (bump the build number). If it is
     missing it is uploaded WITHOUT upsert, then read straight back and must
     match.
  2. Feed: uploaded (upsert, Cache-Control: no-cache) only after step 1
     verified, then read straight back and must match byte-for-byte.
  3. Optional mutable alias (a manual "latest" download such as
     ZerroStaging.dmg): written LAST, after the feed is live and consistent.
     Sparkle never reads it, so its state has no bearing on feed integrity.

Every read-back is cache-busted (a CDN copy must never stand in for the live
object) and retried briefly for propagation. Any HTTP failure other than a
genuine "object not found" on the existence check aborts the run. Nothing
secret is ever printed; the bearer token is read from an environment variable
named on the command line.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appcast_publish_guard as feed_guard  # noqa: E402

DMG_CONTENT_TYPE = "application/x-apple-diskimage"
XML_CONTENT_TYPE = "application/xml"


class StorageError(Exception):
    """A refusal or a transport failure. The message is the whole diagnosis."""


def is_missing_response(status: int, body: bytes) -> bool:
    """Supabase Storage reports a missing public object as 404, or (older
    gateways) as 400 with a not_found body. Anything else is NOT "missing"."""
    if status == 404:
        return True
    if status == 400:
        try:
            payload = json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            return False
        return payload.get("error") == "not_found" or payload.get("statusCode") == "404" or "not found" in str(payload.get("message", "")).lower()
    return False


class HttpStorage:
    """Thin client for one public Supabase Storage bucket."""

    def __init__(self, base: str, bucket: str, token: str, timeout: float = 120.0):
        self.base = base.rstrip("/")
        self.bucket = bucket
        self._token = token
        self.timeout = timeout

    def public_url(self, name: str) -> str:
        return f"{self.base}/object/public/{self.bucket}/{name}"

    def get(self, name: str, cache_buster: str) -> bytes | None:
        url = f"{self.public_url(name)}?cb={cache_buster}"
        request = urllib.request.Request(url, method="GET", headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read() if hasattr(exc, "read") else b""
            if is_missing_response(exc.code, body):
                return None
            raise StorageError(f"GET {name} failed with HTTP {exc.code}: {body[:200]!r}") from exc
        except urllib.error.URLError as exc:
            raise StorageError(f"GET {name} failed: {exc.reason}") from exc

    def put(self, name: str, data: bytes, content_type: str, upsert: bool, cache_control: str | None = None) -> None:
        headers = {"Authorization": f"Bearer {self._token}", "Content-Type": content_type}
        if upsert:
            headers["x-upsert"] = "true"
        if cache_control:
            headers["Cache-Control"] = cache_control
        request = urllib.request.Request(f"{self.base}/object/{self.bucket}/{name}", data=data, method="POST", headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read() if hasattr(exc, "read") else b""
            raise StorageError(f"upload of {name} failed with HTTP {exc.code}: {body[:200]!r}") from exc
        except urllib.error.URLError as exc:
            raise StorageError(f"upload of {name} failed: {exc.reason}") from exc


def check_feed_bytes(feed_bytes: bytes, *, expect_build: int, expect_version: str, expect_url: str, expect_length: int, expect_items: int | None) -> str:
    with tempfile.NamedTemporaryFile(suffix=".xml", delete=False) as handle:
        handle.write(feed_bytes)
        path = handle.name
    try:
        namespace = argparse.Namespace(
            feed=path,
            expect_build=expect_build,
            expect_version=expect_version,
            expect_url=expect_url,
            expect_length=expect_length,
            expect_items=expect_items,
        )
        try:
            return feed_guard.check(namespace)
        except feed_guard.GuardError as exc:
            raise StorageError(str(exc)) from exc
    finally:
        os.unlink(path)


def read_back(storage, name: str, expected: bytes, cache_buster: str, attempts: int, sleep: Callable[[float], None], log: Callable[[str], None]) -> None:
    for attempt in range(1, attempts + 1):
        got = storage.get(name, f"{cache_buster}-{name}-{attempt}")
        if got == expected:
            log(f"read back {name}: byte-identical to the local artifact (attempt {attempt}).")
            return
        if attempt < attempts:
            log(f"read back {name}: not settled yet (attempt {attempt}); retrying in 10s…")
            sleep(10)
    raise StorageError(f"the live {name} is not byte-identical to what this run published (or to the local artifact) after {attempts} attempts")


def publish(
    storage,
    *,
    immutable_name: str,
    dmg_bytes: bytes,
    appcast_name: str,
    appcast_bytes: bytes,
    alias_name: str | None,
    expect_build: int,
    expect_version: str,
    expect_items: int | None,
    cache_buster: str,
    attempts: int = 6,
    sleep: Callable[[float], None] = time.sleep,
    log: Callable[[str], None] = print,
) -> str:
    immutable_url = storage.public_url(immutable_name)
    if immutable_name in {alias_name, appcast_name}:
        raise StorageError("the immutable archive name must differ from the alias and feed names")

    # 0. The feed must reference the immutable object — never a mutable alias —
    #    and describe exactly this build. Checked before any write.
    log(check_feed_bytes(appcast_bytes, expect_build=expect_build, expect_version=expect_version, expect_url=immutable_url, expect_length=len(dmg_bytes), expect_items=expect_items))

    # 1. Immutable archive: reuse if identical, refuse if different, upload if missing.
    existing = storage.get(immutable_name, f"{cache_buster}-{immutable_name}-exists")
    if existing is not None:
        if existing != dmg_bytes:
            raise StorageError(
                f"{immutable_name} already exists in the bucket with DIFFERENT bytes ({len(existing)} vs {len(dmg_bytes)} local). An immutable archive is never rewritten — cut a new build number instead."
            )
        log(f"{immutable_name} already exists and is byte-identical to the notarized archive — reusing it.")
    else:
        storage.put(immutable_name, dmg_bytes, DMG_CONTENT_TYPE, upsert=False)
        log(f"uploaded {immutable_name} ({len(dmg_bytes)} bytes, no upsert).")
        read_back(storage, immutable_name, dmg_bytes, cache_buster, attempts, sleep, log)

    # 2. Feed, only now.
    storage.put(appcast_name, appcast_bytes, XML_CONTENT_TYPE, upsert=True, cache_control="no-cache")
    log(f"uploaded {appcast_name} ({len(appcast_bytes)} bytes).")
    read_back(storage, appcast_name, appcast_bytes, cache_buster, attempts, sleep, log)
    log(check_feed_bytes(appcast_bytes, expect_build=expect_build, expect_version=expect_version, expect_url=immutable_url, expect_length=len(dmg_bytes), expect_items=expect_items))

    # 3. Mutable alias last; Sparkle never reads it.
    if alias_name:
        storage.put(alias_name, dmg_bytes, DMG_CONTENT_TYPE, upsert=True)
        log(f"uploaded the manual-download alias {alias_name} (not referenced by the feed).")
        read_back(storage, alias_name, dmg_bytes, cache_buster, attempts, sleep, log)

    return f"live channel updated: {appcast_name} → {immutable_url}" + (f"; alias {alias_name} refreshed" if alias_name else "")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="https://<project>.supabase.co/storage/v1")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--token-env", required=True, help="name of the environment variable holding the service token")
    parser.add_argument("--immutable-name", required=True, help="build-specific archive object name, e.g. ZerroStaging-570.dmg")
    parser.add_argument("--dmg", required=True, help="local notarized archive")
    parser.add_argument("--appcast-name", required=True)
    parser.add_argument("--appcast", required=True, help="local generated feed (enclosure = the immutable object's public URL)")
    parser.add_argument("--alias-name", help="optional mutable manual-download alias, written last")
    parser.add_argument("--expect-build", type=int, required=True)
    parser.add_argument("--expect-version", required=True)
    parser.add_argument("--expect-items", type=int)
    parser.add_argument("--cache-buster", required=True, help="unique per run, e.g. $GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT")
    parser.add_argument("--attempts", type=int, default=6)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    token = os.environ.get(args.token_env, "")
    if not token:
        print(f"::error::publish_storage_release: environment variable {args.token_env} is empty", file=sys.stderr)
        return 1
    try:
        summary = publish(
            HttpStorage(args.base, args.bucket, token),
            immutable_name=args.immutable_name,
            dmg_bytes=Path(args.dmg).read_bytes(),
            appcast_name=args.appcast_name,
            appcast_bytes=Path(args.appcast).read_bytes(),
            alias_name=args.alias_name,
            expect_build=args.expect_build,
            expect_version=args.expect_version,
            expect_items=args.expect_items,
            cache_buster=args.cache_buster,
            attempts=args.attempts,
        )
    except StorageError as exc:
        print(f"::error::publish_storage_release: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"::error::publish_storage_release: {exc}", file=sys.stderr)
        return 1
    print(f"publish_storage_release: OK — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
