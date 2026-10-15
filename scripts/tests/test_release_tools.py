from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


release_version = load_script("release_version", "validate-release-version.py")
update_appcast = load_script("update_appcast", "update-appcast.py")
changelog_tools = load_script("changelog_tools", "changelog_tools.py")
changelog_html = load_script("changelog_html", "changelog-to-html.py")


class ChangelogTests(unittest.TestCase):
    def test_current_release_is_bilingual_and_renderable(self) -> None:
        lines = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8").splitlines(True)
        notes = changelog_tools.release_notes("2026.10.1", lines)
        self.assertTrue(notes.startswith("### 中文\n"))
        self.assertLess(notes.index("### 中文"), notes.index("### English"))
        html = changelog_html.to_html(
            changelog_tools.trim_section(
                changelog_tools.extract_section("2026.10.1", lines)
            )
        )
        self.assertIn("<h3>中文</h3>", html)
        self.assertIn("<h3>English</h3>", html)

    def test_missing_language_block_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            changelog_tools.ChangelogFormatError, "exactly one '### English'"
        ):
            changelog_tools.validate_section(
                "2026.9.0", ["### 中文", "", "#### 变更", "- 内容"]
            )


class ReleaseVersionTests(unittest.TestCase):
    def test_current_version_is_the_successor_to_failed_2026_9_1_candidate(self) -> None:
        release_version.validate_release(
            version="2026.9.2",
            tag="v2026.9.2",
            build="22",
            previous_version="2026.9.1",
            previous_build="21",
        )

    def test_macos14_release_follows_the_failed_build_candidate(self) -> None:
        release_version.validate_release(
            version="2026.10.1",
            tag="v2026.10.1",
            build="24",
            previous_version="2026.10.0",
            previous_build="23",
        )

    def test_rejects_skipped_patch_and_reused_build(self) -> None:
        with self.assertRaisesRegex(ValueError, "not the next"):
            release_version.validate_successor("2026.8.1", "2026.9.1")
        with self.assertRaisesRegex(ValueError, "greater than previous"):
            release_version.validate_release(
                version="2026.9.0",
                tag="v2026.9.0",
                build="19",
                previous_version="2026.8.1",
                previous_build="19",
            )

    def test_project_contains_the_release_version_and_build(self) -> None:
        project = (ROOT / "FloralMD.xcodeproj" / "project.pbxproj").read_text(
            encoding="utf-8"
        )
        versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
        builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project))
        self.assertIn("2026.10.1", versions)
        self.assertNotIn("2026.9.2", versions)
        self.assertIn("24", builds)
        self.assertNotIn("22", builds)


class AppcastTests(unittest.TestCase):
    def test_calver_item_uses_short_version_and_build(self) -> None:
        args = type(
            "Args",
            (),
            {
                "version": "2026.9.0",
                "build": "20",
                "url": "https://example.invalid/FloralMD-2026.9.0.dmg",
                "signature": "test-signature",
                "length": 123,
                "pub_date": "Tue, 08 Sep 2026 00:00:00 +0000",
                "description_file": None,
            },
        )()
        item = update_appcast.make_item(args)
        self.assertIn('sparkle:shortVersionString="2026.9.0"', item)
        self.assertIn('sparkle:version="20"', item)


class RepositoryContractTests(unittest.TestCase):
    def test_public_identity_and_sparkle_are_release_only(self) -> None:
        project = (ROOT / "FloralMD.xcodeproj" / "project.pbxproj").read_text(
            encoding="utf-8"
        )
        source = (ROOT / "FloralMD" / "FloralMDApp.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("com.yingkaisun.floralmd;", project)
        self.assertIn("com.yingkaisun.floralmd.dev;", project)
        self.assertIn("FLORALMD_PRODUCTION", project)
        self.assertIn("SPUStandardUpdaterController", source)
        self.assertIn("#if FLORALMD_PRODUCTION", source)

    def test_builder_requires_universal_release_quicklook_and_sparkle(self) -> None:
        script = (SCRIPTS / "build-app.sh").read_text(encoding="utf-8")
        self.assertIn('ARCHS="arm64 x86_64"', script)
        self.assertIn("com.yingkaisun.floralmd.quicklook", script)
        self.assertIn("Sparkle.framework", script)
        self.assertIn("inactive Harness/DSH resources leaked", script)

    def test_workflows_use_xcode_scripts_and_preserve_two_stage_release(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        promote = (ROOT / ".github" / "workflows" / "promote-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("./scripts/test.sh", ci)
        self.assertNotIn("./scripts/test.sh", release)
        self.assertIn("python3 -m unittest discover -s scripts/tests", ci)
        self.assertIn("./scripts/build-app.sh --variant production", ci)
        self.assertIn("./scripts/build-app.sh --variant production", release)
        self.assertIn("--prerelease", release)
        self.assertIn("update-appcast.py", promote)
        self.assertIn("./scripts/release-metadata.sh version", release)

    def test_full_test_script_resets_only_the_user_xctest_daemon_in_ci_mode(self) -> None:
        script = (SCRIPTS / "test.sh").read_text(encoding="utf-8")
        self.assertIn('if [ "${CI:-}" = "true" ]', script)
        self.assertIn("killall testmanagerd", script)
        self.assertIn("-retry-tests-on-failure", script)
        self.assertIn("-test-iterations 3", script)
        self.assertIn("FLORALMD_SKIP_DEBUG_INSTALL=YES", script)


if __name__ == "__main__":
    unittest.main()
