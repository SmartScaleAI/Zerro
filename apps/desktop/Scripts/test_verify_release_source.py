#!/usr/bin/env python3
"""
Tests for verify_release_source.sh against throwaway Git repositories.

Run from apps/desktop:  python3 -m unittest Scripts/test_verify_release_source.py -v

Each test builds a small history with remote-tracking refs (no network, no
remote) and runs the script from a subdirectory, the way the release workflow
does (working-directory: apps/desktop). Two refs are always involved: the
production release branch (origin/main), which must CONTAIN the release
commit, and GitHub's default branch (origin/<default>), whose
.github/workflows the release commit must MATCH.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "verify_release_source.sh"

GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
}

WF = ".github/workflows/release-app.yml"


class Repo:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.git("init", "-q", "-b", "main")
        (root / "apps/desktop").mkdir(parents=True)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=GIT_ENV, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, files: dict[str, str]) -> str:
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def set_remote_branch(self, name: str, sha: str) -> None:
        self.git("update-ref", f"refs/remotes/origin/{name}", sha)

    def check(self, *args: str) -> tuple[int, str]:
        proc = subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=self.root / "apps/desktop", env=GIT_ENV, capture_output=True, text=True, check=False,
        )
        return proc.returncode, proc.stdout + proc.stderr


class ReleaseSourceTests(unittest.TestCase):
    """History used by most tests:

        base ──── release (main)                 workflows v1
          └────── staging_tip (default branch)   workflows v1 + unrelated app change

    `staging` (GitHub's default branch) does NOT contain `release`.
    """

    def setUp(self) -> None:
        self.repo = Repo(Path(tempfile.mkdtemp()))
        self.base = self.repo.commit("workflows v1", {WF: "v1\n", "apps/desktop/VERSION": "1.0.0\n"})
        self.release = self.repo.commit("release bump on main", {"apps/desktop/VERSION": "1.0.1\n"})
        self.repo.git("checkout", "-q", "-b", "staging", self.base)
        self.staging_tip = self.repo.commit("staging app work", {"apps/desktop/VERSION": "2.0.0-dev\n", "README.md": "x\n"})
        self.repo.git("checkout", "-q", "main")
        self.repo.set_remote_branch("main", self.release)
        self.repo.set_remote_branch("staging", self.staging_tip)

    def test_on_main_and_workflows_match_a_separate_default_branch(self) -> None:
        code, out = self.repo.check(self.release, "origin/main", "origin/staging")
        self.assertEqual(code, 0, out)
        self.assertIn("contained in the production release branch origin/main", out)
        self.assertIn("match GitHub's default branch origin/staging", out)

    def test_default_branch_need_not_contain_the_release_commit(self) -> None:
        # origin/staging does not contain `release`; only the workflow trees matter.
        self.assertNotEqual(self.repo.git("merge-base", self.release, self.staging_tip), self.release)
        code, out = self.repo.check(self.release, "origin/main", "origin/staging")
        self.assertEqual(code, 0, out)

    def test_on_main_but_workflows_differ_from_default_branch_fails(self) -> None:
        self.repo.git("checkout", "-q", "staging")
        changed = self.repo.commit("staging workflow v2", {WF: "v2\n"})
        self.repo.git("checkout", "-q", "main")
        self.repo.set_remote_branch("staging", changed)
        code, out = self.repo.check(self.release, "origin/main", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("differs from GitHub's default branch origin/staging", out)
        self.assertIn("GITHUB_TOKEN", out)
        self.assertIn("release-app.yml", out, "the differing file is named")
        self.assertIn("::error::", out)

    def test_release_commit_that_edits_workflows_fails_even_when_on_main(self) -> None:
        wf_release = self.repo.commit("main workflow edit", {WF: "v1-main-only\n"})
        self.repo.set_remote_branch("main", wf_release)
        code, out = self.repo.check(wf_release, "origin/main", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("differs from GitHub's default branch", out)

    def test_default_branch_equal_to_main_passes(self) -> None:
        code, out = self.repo.check(self.release, "origin/main", "origin/main")
        self.assertEqual(code, 0, out)

    def test_not_on_main_fails_even_if_workflows_match_default(self) -> None:
        self.repo.git("checkout", "-q", "-b", "feature", self.base)
        head = self.repo.commit("feature work", {"apps/desktop/VERSION": "1.0.9\n"})
        self.repo.git("checkout", "-q", "main")
        code, out = self.repo.check(head, "origin/main", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("is not contained in the production release branch origin/main", out)
        # Being on the DEFAULT branch is not enough either.
        code, out = self.repo.check(self.staging_tip, "origin/main", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("is not contained in the production release branch origin/main", out)

    def test_unknown_commit_fails(self) -> None:
        code, out = self.repo.check("0" * 40, "origin/main", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("is not a commit", out)

    def test_missing_or_unknown_default_branch_ref_fails(self) -> None:
        code, out = self.repo.check(self.release, "origin/main")  # argument missing
        self.assertNotEqual(code, 0)
        self.assertIn("usage:", out)
        code, out = self.repo.check(self.release, "origin/main", "origin/")  # empty branch name
        self.assertEqual(code, 1)
        self.assertIn("default branch name is missing", out)
        code, out = self.repo.check(self.release, "origin/main", "origin/nonexistent")
        self.assertEqual(code, 1)
        self.assertIn("GitHub default branch ref origin/nonexistent is not available", out)

    def test_unknown_release_branch_ref_fails(self) -> None:
        code, out = self.repo.check(self.release, "origin/nonexistent", "origin/staging")
        self.assertEqual(code, 1)
        self.assertIn("production release branch ref origin/nonexistent is not available", out)


if __name__ == "__main__":
    unittest.main()
