#!/usr/bin/env python3
"""
Tests for release_metadata.py: the checked-in VERSION / BUILD_NUMBER files,
the plain staging-v<X.Y.Z> tag format, and the Xcode project drift check.

Run from apps/desktop:  python3 -m unittest Scripts/test_release_metadata.py -v

The last test class runs against the REAL repository files, so it fails the
moment apps/desktop/VERSION, apps/desktop/BUILD_NUMBER, and the Zerro
target's MARKETING_VERSION / CURRENT_PROJECT_VERSION in Zerro.xcodeproj stop
agreeing.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import release_metadata as rm  # noqa: E402


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def write(self, name: str, text: str) -> Path:
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path


class VersionFileTests(Fixture):
    def test_reads_exact_semver_and_tolerates_trailing_newline(self) -> None:
        self.assertEqual(rm.read_version(self.write("VERSION", "1.0.0\n")), "1.0.0")
        self.assertEqual(rm.read_version(self.write("V2", "12.34.56")), "12.34.56")

    def test_rejects_non_xyz_versions(self) -> None:
        for bad in ("1.0", "v1.0.0", "1.0.0-beta", "1.0.0.1", "01.0.0", "", "1.0.0\n2.0.0\n", "1000"):
            with self.subTest(bad=bad):
                with self.assertRaises(rm.MetadataError):
                    rm.read_version(self.write("VERSION", bad))

    def test_missing_file_fails_closed(self) -> None:
        with self.assertRaises(rm.MetadataError):
            rm.read_version(self.tmp / "nope")


class ExactFileContentTests(Fixture):
    """The files must be exactly the value plus an optional final newline."""

    def test_version_file_accepts_only_exact_contents(self) -> None:
        for good in ("1.0.0\n", "1.0.0"):
            with self.subTest(good=good):
                self.assertEqual(rm.read_version(self.write("VERSION", good)), "1.0.0")
        for bad in (" 1.0.0\n", "1.0.0 \n", "\t1.0.0\n", "1.0.0\t\n", " 1.0.0 \n", "1.0.0\n\n", "\n1.0.0\n",
                    "1.0.0\n1.0.1\n", "1.0.0\n\n1.0.1\n", "1.0.0\r\n", "1.0.0 ", " 1.0.0", "1.0.0\n ", "\n", " \n"):
            with self.subTest(bad=bad):
                with self.assertRaises(rm.MetadataError):
                    rm.read_version(self.write("VERSION", bad))

    def test_build_number_file_accepts_only_exact_contents(self) -> None:
        for good in ("1000\n", "1000"):
            with self.subTest(good=good):
                self.assertEqual(rm.read_build_number(self.write("BUILD_NUMBER", good)), 1000)
        for bad in (" 1000\n", "1000 \n", "\t1000\n", "1000\t\n", " 1000 \n", "1000\n\n", "\n1000\n",
                    "1000\n1001\n", "1000\n\n1001\n", "1000\r\n", "1000 ", " 1000", "1000\n ", "\n", " \n"):
            with self.subTest(bad=bad):
                with self.assertRaises(rm.MetadataError):
                    rm.read_build_number(self.write("BUILD_NUMBER", bad))

    def test_command_line_validation_is_unchanged_by_the_file_rules(self) -> None:
        # `validate` takes values, not files: the same X.Y.Z / positive-integer
        # rules apply, and a trailing newline in an argument is still rejected.
        self.assertEqual(rm.validate_version("1.0.0"), "1.0.0")
        self.assertEqual(rm.validate_build_number("1000"), 1000)
        for bad in ("1.0.0\n", " 1.0.0", "1.0.0 "):
            with self.assertRaises(rm.MetadataError):
                rm.validate_version(bad)
        for bad in ("1000\n", " 1000", "1000 "):
            with self.assertRaises(rm.MetadataError):
                rm.validate_build_number(bad)


class BuildNumberFileTests(Fixture):
    def test_reads_positive_integer(self) -> None:
        self.assertEqual(rm.read_build_number(self.write("BUILD_NUMBER", "1000\n")), 1000)
        self.assertEqual(rm.read_build_number(self.write("B2", "1")), 1)

    def test_rejects_non_positive_or_non_integer(self) -> None:
        for bad in ("0", "-5", "01000", "1000.0", "1e3", "abc", "", "1000\n1001\n", " "):
            with self.subTest(bad=bad):
                with self.assertRaises(rm.MetadataError):
                    rm.read_build_number(self.write("BUILD_NUMBER", bad))


class StagingTagTests(Fixture):
    def test_builds_the_plain_staging_tag(self) -> None:
        self.assertEqual(rm.staging_tag("1.0.0"), "staging-v1.0.0")
        self.assertEqual(rm.staging_tag("1.0.1"), "staging-v1.0.1")
        self.assertEqual(rm.production_tag("1.0.0"), "app-v1.0.0")

    def test_parses_plain_staging_tags(self) -> None:
        self.assertEqual(rm.parse_staging_tag("staging-v1.0.0"), "1.0.0")
        self.assertEqual(rm.parse_staging_tag("staging-v1.0.1"), "1.0.1")
        self.assertEqual(rm.parse_staging_tag("staging-v1.4.48"), "1.4.48")
        self.assertEqual(rm.parse_staging_tag("staging-v2.10.3"), "2.10.3")

    def test_build_qualified_tags_are_rejected(self) -> None:
        for bad in ("staging-v1.0.0-build.1000", "staging-v1.0.1-build.1001", "staging-v1.0.0-build."):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(rm.MetadataError, "build-qualified"):
                    rm.parse_staging_tag(bad)

    def test_malformed_tags_are_rejected(self) -> None:
        for bad in ("staging-1.0.0", "vstaging-v1.0.0", "staging-v1.0", "staging-v1", "staging-v01.0.0", "staging-v1.00.0",
                    "staging-v1.0.0-rc.1", "staging-v1.0.0-beta", "staging-v1.0.0.1", "app-v1.0.0", "", "staging-v1.0.0\n", " staging-v1.0.0"):
            with self.subTest(bad=bad):
                with self.assertRaises(rm.MetadataError):
                    rm.parse_staging_tag(bad)

    def test_cli_require_match_pins_tag_version_to_checked_in_version(self) -> None:
        quiet = contextlib.ExitStack()
        quiet.enter_context(contextlib.redirect_stdout(io.StringIO()))
        quiet.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.addCleanup(quiet.close)
        v = self.write("VERSION", "1.0.0\n")
        b = self.write("BUILD_NUMBER", "1000\n")
        base = ["--version-file", str(v), "--build-file", str(b)]
        self.assertEqual(rm.main([*base, "parse-staging-tag", "staging-v1.0.0", "--require-match"]), 0)
        for wrong in ("staging-v1.0.1", "staging-v0.9.9", "staging-v1.0.0-build.1000"):
            with self.subTest(wrong=wrong):
                self.assertEqual(rm.main([*base, "parse-staging-tag", wrong, "--require-match"]), 1)
        self.assertEqual(rm.main([*base, "parse-staging-tag", "staging-v1.0.1"]), 0, "without --require-match any plain tag parses")
        self.assertEqual(rm.main([*base, "staging-tag"]), 0)
        self.assertEqual(rm.main([*base, "read"]), 0)

    def test_next_release_bumps_both_files(self) -> None:
        # staging-v1.0.0 / 1000 → staging-v1.0.1 / 1001: each release is a new
        # version AND a new build, and the tag follows VERSION alone.
        v = self.write("VERSION", "1.0.1\n")
        b = self.write("BUILD_NUMBER", "1001\n")
        self.assertEqual(rm.staging_tag(rm.read_version(v)), "staging-v1.0.1")
        self.assertEqual(rm.read_build_number(b), 1001)


PBXPROJ_TEMPLATE = """// !$*UTF8*$!
{{
\tobjects = {{
\t\tAAAA00000000000000000001 /* Zerro */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = CCCC00000000000000000001 /* Build configuration list for PBXNativeTarget "Zerro" */;
\t\t}};
\t\tBBBB00000000000000000001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCURRENT_PROJECT_VERSION = {debug_build};
\t\t\t\tMARKETING_VERSION = {debug_marketing};
\t\t\t\tPRODUCT_NAME = Zerro;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\tBBBB00000000000000000002 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCURRENT_PROJECT_VERSION = {release_build};
\t\t\t\tMARKETING_VERSION = {release_marketing};
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\tDDDD00000000000000000001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCURRENT_PROJECT_VERSION = 7;
\t\t\t\tMARKETING_VERSION = 9.9.9;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\tCCCC00000000000000000001 /* Build configuration list for PBXNativeTarget "Zerro" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tBBBB00000000000000000001 /* Debug */,
\t\t\t\tBBBB00000000000000000002 /* Release */,
\t\t\t);
\t\t}};
\t\tCCCC00000000000000000002 /* Build configuration list for PBXNativeTarget "OtherTarget" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tDDDD00000000000000000001 /* Debug */,
\t\t\t);
\t\t}};
\t}};
}}
"""


class ProjectDriftTests(Fixture):
    def project(self, **kw) -> Path:
        values = dict(debug_build=1000, debug_marketing="1.0.0", release_build=1000, release_marketing="1.0.0")
        values.update(kw)
        return self.write("project.pbxproj", PBXPROJ_TEMPLATE.format(**values))

    def test_matching_project_passes_and_only_checks_the_app_target(self) -> None:
        # The unrelated target carries different values and must be ignored.
        self.assertEqual(rm.check_project("1.0.0", 1000, self.project()), ["Debug", "Release"])

    def test_any_configuration_drift_fails_and_names_the_setting(self) -> None:
        with self.assertRaisesRegex(rm.MetadataError, r"Zerro/Release: CURRENT_PROJECT_VERSION = '999'"):
            rm.check_project("1.0.0", 1000, self.project(release_build=999))
        with self.assertRaisesRegex(rm.MetadataError, r"Zerro/Debug: MARKETING_VERSION = '1.0.1'"):
            rm.check_project("1.0.0", 1000, self.project(debug_marketing="1.0.1"))
        with self.assertRaisesRegex(rm.MetadataError, r"CURRENT_PROJECT_VERSION = None"):
            # Release configuration with the build setting removed entirely.
            text = PBXPROJ_TEMPLATE.format(debug_build=1000, debug_marketing="1.0.0", release_build=1000, release_marketing="1.0.0")
            needle = "\t\t\t\tCURRENT_PROJECT_VERSION = 1000;\n\t\t\t\tMARKETING_VERSION = 1.0.0;\n\t\t\t};\n\t\t\tname = Release"
            assert text.count(needle) == 1
            stripped = text.replace(needle, "\t\t\t\tMARKETING_VERSION = 1.0.0;\n\t\t\t};\n\t\t\tname = Release")
            rm.check_project("1.0.0", 1000, self.write("p.pbxproj", stripped))

    def test_missing_target_fails_closed(self) -> None:
        with self.assertRaises(rm.MetadataError):
            rm.check_project("1.0.0", 1000, self.project(), target_name="Nope")


class ValidateCommandTests(Fixture):
    """The shared rule set every entry point (workflows, cut-release.sh, release.sh) uses."""

    VALID_VERSIONS = ("1.0.0", "0.0.1", "10.20.30", "2.0.0")
    INVALID_VERSIONS = ("v1.0.0", "1.0.0-beta", "1.0", "1", "01.0.0", "1.00.0", "1.0.0.0", "1.0.0 ", "", "1.0.0\n")
    VALID_BUILDS = ("1", "1000", "1001", "99999")
    INVALID_BUILDS = ("0", "-1", "+1", "1000.0", "1e3", "01000", "1000 ", "", "abc", "1_000")

    def run_validate(self, *args: str) -> tuple[int, str]:
        import contextlib, io
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = rm.main(["validate", *args])
        return code, out.getvalue() + err.getvalue()

    def test_valid_values_pass(self) -> None:
        for v in self.VALID_VERSIONS:
            self.assertEqual(self.run_validate("--marketing", v)[0], 0, v)
        for b in self.VALID_BUILDS:
            self.assertEqual(self.run_validate("--build", b)[0], 0, b)
        self.assertEqual(self.run_validate("--marketing", "1.0.0", "--build", "1000")[0], 0)

    def test_invalid_versions_fail(self) -> None:
        for v in self.INVALID_VERSIONS:
            with self.subTest(v=v):
                code, text = self.run_validate("--marketing", v)
                self.assertEqual(code, 1)
                self.assertIn("not exactly X.Y.Z", text)

    def test_invalid_builds_fail(self) -> None:
        for b in self.INVALID_BUILDS:
            with self.subTest(b=b):
                code, text = self.run_validate("--build", b)
                self.assertEqual(code, 1)
                self.assertIn("not a positive integer", text)

    def test_one_bad_value_fails_the_pair_and_nothing_is_required_by_default(self) -> None:
        self.assertEqual(self.run_validate("--marketing", "1.0.0", "--build", "0")[0], 1)
        self.assertEqual(self.run_validate("--marketing", "1.0", "--build", "1000")[0], 1)
        self.assertEqual(self.run_validate()[0], 1)


class ShellEntryPointTests(unittest.TestCase):
    """cut-release.sh and release.sh must reject bad values before doing anything.

    Only INVALID inputs are ever passed to the real scripts: they exit at the
    shared validation, before any Git, Xcode, or remote command. A valid
    release path is never executed against the working repository here;
    ValidateCommandTests proves valid values pass the same rule set.
    """

    def run_script(self, script: str, *args: str) -> tuple[int, str]:
        import subprocess
        proc = subprocess.run(["bash", str(HERE / script), *args], capture_output=True, text=True, check=False,
                              cwd=str(HERE.parent), env={**os.environ, "TERM": "dumb"})
        return proc.returncode, proc.stdout + proc.stderr

    def test_cut_release_rejects_invalid_versions_before_touching_anything(self) -> None:
        before = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, cwd=str(HERE.parent)).stdout
        for v in ("1.0", "v1.0.0", "1.0.0-rc1", "01.0.0"):
            with self.subTest(v=v):
                code, text = self.run_script("cut-release.sh", v)
                self.assertNotEqual(code, 0)
                self.assertIn("not exactly X.Y.Z", text)
        after = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, cwd=str(HERE.parent)).stdout
        self.assertEqual(before, after, "a rejected version must not modify the working tree")

    def test_release_sh_rejects_invalid_values_before_any_preflight(self) -> None:
        for args in (("1.0", "1000"), ("1.0.0", "0"), ("1.0.0", "01000"), ("v1.0.0", "1000"), ("1.0.0", "1000.0"), ("1.0.0", "-5")):
            with self.subTest(args=args):
                code, text = self.run_script("release.sh", *args)
                self.assertNotEqual(code, 0)
                self.assertIn("release_metadata validate", text)
                self.assertNotIn("Preflight checks", text, "validation must fail before the preflight stage")


class ChangelogResetTests(unittest.TestCase):
    """The shipped What's New list is exactly the released 1.x versions, newest first."""

    def test_shipped_changelog_contains_exactly_the_released_versions(self) -> None:
        src = (HERE.parent / "Zerro" / "WhatsNew" / "Changelog.swift").read_text(encoding="utf-8")
        versions = re.findall(r'version:\s*"([^"]+)"', src)
        self.assertEqual(versions, ["1.0.2", "1.0.1", "1.0.0"])
        # One highlight per staging verification release; the 1.0.0 reset keeps its four.
        entries = src.split("ChangelogEntry(")[1:]
        self.assertEqual([e.count("ChangelogHighlight(") for e in entries], [1, 1, 4])
        self.assertNotIn("releaseDate", src, "the unused date helper is gone")
        self.assertEqual(rm.read_version(), versions[0], "the newest entry matches the checked-in VERSION")


class RepositoryMetadataTests(unittest.TestCase):
    """Guards the real checked-in files against silent drift."""

    def test_checked_in_files_are_valid(self) -> None:
        marketing = rm.read_version()
        build = rm.read_build_number()
        self.assertRegex(marketing, rm.VERSION_RE)
        self.assertGreater(build, 0)

    def test_xcode_project_matches_the_checked_in_metadata(self) -> None:
        names = rm.check_project(rm.read_version(), rm.read_build_number())
        self.assertEqual(sorted(names), ["Debug", "Release", "Staging"], "every Zerro app configuration is covered")

    def test_changelog_has_an_entry_for_the_checked_in_version(self) -> None:
        import subprocess
        proc = subprocess.run([sys.executable, str(HERE / "check_changelog_entry.py")], capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
