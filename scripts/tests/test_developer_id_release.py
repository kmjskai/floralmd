from __future__ import annotations

import importlib.util
import base64
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


developer_id = load_script(
    "developer_id_release_validation", "validate-developer-id-release.py"
)
promotion = load_script(
    "release_promotion_validation", "validate-release-promotion.py"
)


class DeveloperIDMetadataTests(unittest.TestCase):
    def test_notary_result_requires_accepted_status_and_clean_log(self) -> None:
        result = developer_id.inspect_notary_result(
            {"status": "Accepted", "id": "submission-id"},
            {"issues": []},
        )
        self.assertEqual(result, ("submission-id", 0, 0))
        result = developer_id.inspect_notary_result(
            {"status": "Accepted", "id": "submission-id"},
            {"issues": None},
        )
        self.assertEqual(result, ("submission-id", 0, 0))
        with self.assertRaisesRegex(ValueError, "not 'Accepted'"):
            developer_id.inspect_notary_result(
                {"status": "Invalid", "id": "submission-id"}, {"issues": []}
            )
        with self.assertRaisesRegex(ValueError, "invalid issues"):
            developer_id.inspect_notary_result(
                {"status": "Accepted", "id": "submission-id"},
                {"issues": "none"},
            )
        with self.assertRaisesRegex(ValueError, "1 error"):
            developer_id.inspect_notary_result(
                {"status": "Accepted", "id": "submission-id"},
                {"issues": [{"severity": "error"}]},
            )
        with self.assertRaisesRegex(ValueError, "1 warning"):
            developer_id.inspect_notary_result(
                {"status": "Accepted", "id": "submission-id"},
                {"issues": [{"severity": "warning"}]},
            )


class PromotionValidationTests(unittest.TestCase):
    version = "2026.7.14"
    tag = "v2026.7.14"

    def make_assets(self, directory: Path) -> tuple[dict[str, object], str, int]:
        dmg_name = f"FloralMD-{self.version}.dmg"
        dmg = directory / dmg_name
        dmg.write_bytes(b"immutable notarized dmg fixture")
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        zip_name = f"FloralMD-{self.version}.zip"
        app_zip = directory / zip_name
        with zipfile.ZipFile(app_zip, "w") as archive:
            archive.writestr("FloralMD.app/Contents/Info.plist", b"fixture")
        zip_digest = hashlib.sha256(app_zip.read_bytes()).hexdigest()
        (directory / f"FloralMD-{self.version}.sha256").write_text(
            f"{digest}  {dmg_name}\n", encoding="utf-8"
        )
        signature = base64.b64encode(b"s" * 64).decode()
        length = dmg.stat().st_size
        (directory / f"FloralMD-{self.version}.sparkle-signature.txt").write_text(
            f'sparkle:edSignature="{signature}" length="{length}"\n',
            encoding="utf-8",
        )
        release = {
            "id": 42,
            "tag_name": self.tag,
            "name": f"FloralMD {self.version} Preview",
            "draft": False,
            "prerelease": True,
            "assets": [
                {"name": dmg_name, "digest": f"sha256:{digest}"},
                {"name": zip_name, "digest": f"sha256:{zip_digest}"},
                {"name": f"FloralMD-{self.version}.sha256", "digest": "sha256:x"},
                {
                    "name": f"FloralMD-{self.version}.sparkle-signature.txt",
                    "digest": "sha256:y",
                },
            ],
        }
        return release, signature, length

    def test_validates_exact_prerelease_assets_and_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            release, signature, length = self.make_assets(directory)
            self.assertEqual(
                promotion.validate_metadata(
                    release,
                    tag=self.tag,
                    version=self.version,
                    required_state="prerelease",
                ),
                "prerelease",
            )
            actual_signature, actual_length, _ = promotion.validate_files(
                release, directory=directory, version=self.version
            )
        self.assertEqual(actual_signature, signature)
        self.assertEqual(actual_length, length)

    def test_rejects_extra_asset_and_wrong_release_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            release, _, _ = self.make_assets(Path(temporary))
            assets = release["assets"]
            assert isinstance(assets, list)
            assets.append({"name": "replacement.dmg", "digest": "sha256:z"})
            with self.assertRaisesRegex(ValueError, "asset set is not exact"):
                promotion.validate_metadata(
                    release,
                    tag=self.tag,
                    version=self.version,
                    required_state="prerelease",
                )
            assets.pop()
            release["prerelease"] = False
            release["name"] = f"FloralMD {self.version}"
            with self.assertRaisesRegex(ValueError, "expected prerelease"):
                promotion.validate_metadata(
                    release,
                    tag=self.tag,
                    version=self.version,
                    required_state="prerelease",
                )

    def test_rejects_github_immutable_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            release, _, _ = self.make_assets(Path(temporary))
            release["immutable"] = True
            with self.assertRaisesRegex(ValueError, "immutability"):
                promotion.validate_metadata(
                    release,
                    tag=self.tag,
                    version=self.version,
                    required_state="prerelease",
                )

    def test_rejects_checksum_length_and_server_digest_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            release, signature, _ = self.make_assets(directory)
            checksum = directory / f"FloralMD-{self.version}.sha256"
            checksum.write_text(
                f"{'0' * 64}  FloralMD-{self.version}.dmg\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "SHA-256 manifest"):
                promotion.validate_files(
                    release, directory=directory, version=self.version
                )

            release, _, length = self.make_assets(directory)
            signature_file = (
                directory / f"FloralMD-{self.version}.sparkle-signature.txt"
            )
            signature_file.write_text(
                f'sparkle:edSignature="{signature}" length="{length + 1}"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "length"):
                promotion.validate_files(
                    release, directory=directory, version=self.version
                )

            release, _, _ = self.make_assets(directory)
            assets = release["assets"]
            assert isinstance(assets, list)
            assets[0]["digest"] = f"sha256:{'f' * 64}"
            with self.assertRaisesRegex(ValueError, "GitHub asset digest"):
                promotion.validate_files(
                    release, directory=directory, version=self.version
                )

    def test_rejects_zip_without_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            release, _, _ = self.make_assets(directory)
            with zipfile.ZipFile(directory / f"FloralMD-{self.version}.zip", "w") as archive:
                archive.writestr("wrong.txt", b"not an app")
            with self.assertRaisesRegex(ValueError, "does not contain FloralMD.app"):
                promotion.validate_files(
                    release, directory=directory, version=self.version
                )

    def test_validates_exact_appcast_enclosure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, signature, length = self.make_assets(directory)
            appcast = directory / "appcast.xml"
            appcast.write_text(
                f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{promotion.SPARKLE_NS}" version="2.0">
  <channel>
    <item>
      <enclosure
        url="https://github.com/yingkaisun-kai/floralmd/releases/download/{self.tag}/FloralMD-{self.version}.dmg"
        sparkle:version="15"
        sparkle:shortVersionString="{self.version}"
        sparkle:edSignature="{signature}"
        length="{length}"
        type="application/x-apple-diskimage"/>
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )
            promotion.validate_appcast(
                appcast,
                repository="yingkaisun-kai/floralmd",
                tag=self.tag,
                version=self.version,
                build="15",
                signature=signature,
                length=length,
            )
            content = appcast.read_text(encoding="utf-8")
            appcast.write_text(
                content.replace('sparkle:version="15"', 'sparkle:version="14"'),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "wrong"):
                promotion.validate_appcast(
                    appcast,
                    repository="yingkaisun-kai/floralmd",
                    tag=self.tag,
                    version=self.version,
                    build="15",
                    signature=signature,
                    length=length,
                )


class ReleaseSecurityFailureTests(unittest.TestCase):
    def run_command(
        self, *args: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            args,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def make_app(
        self,
        directory: Path,
        *,
        runtime: bool,
        get_task_allow: bool = False,
    ) -> Path:
        app = directory / "Fixture.app"
        executable = app / "Contents" / "MacOS" / "fixture"
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)
        info = {
            "CFBundleIdentifier": "invalid.example.fixture",
            "CFBundleExecutable": "fixture",
            "CFBundlePackageType": "APPL",
        }
        with (app / "Contents" / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        command = ["codesign", "--force", "--sign", "-"]
        if runtime:
            command.extend(["--options", "runtime"])
        if get_task_allow:
            entitlements = directory / "entitlements.plist"
            with entitlements.open("wb") as file:
                plistlib.dump({"com.apple.security.get-task-allow": True}, file)
            command.extend(["--entitlements", str(entitlements)])
        command.append(str(app))
        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return app

    def test_missing_secrets_fail_before_release_work(self) -> None:
        env = dict(os.environ)
        for name in (
            "MACOS_CERTIFICATE_P12_BASE64",
            "MACOS_CERTIFICATE_PASSWORD",
            "APPLE_NOTARY_KEY_P8_BASE64",
            "APPLE_NOTARY_KEY_ID",
            "APPLE_NOTARY_ISSUER_ID",
            "FLORALMD_SPARKLE_ED_PRIVATE_KEY",
        ):
            env.pop(name, None)
        result = self.run_command(
            "bash", "scripts/developer-id-release.sh", "--check-secrets", env=env
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required release secret", result.stderr)

    def test_wrong_signing_identity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary), runtime=True)
            result = self.run_command(
                "bash",
                "scripts/sign-release-code.sh",
                str(app),
                "Developer ID Application: definitely-not-present",
            )
        self.assertNotEqual(result.returncode, 0)

    def test_get_task_allow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(
                Path(temporary), runtime=True, get_task_allow=True
            )
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("get-task-allow", result.stderr)

    def test_missing_hardened_runtime_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary), runtime=False)
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hardened runtime", result.stderr)

    def test_unstapled_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "Fixture.dmg"
            artifact.write_bytes(b"not notarized")
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "stapled",
                str(artifact),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stapled", result.stderr)

    def test_checksum_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            dmg = directory / "Fixture.dmg"
            checksum = directory / "Fixture.sha256"
            dmg.write_bytes(b"fixture bytes")
            checksum.write_text(
                f"{'0' * 64}  {dmg.name}\n", encoding="utf-8"
            )
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "checksum",
                str(dmg),
                str(checksum),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)

    def test_valid_signature_metadata_reaches_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "Fixture.app"
            app.mkdir()
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            codesign = fake_bin / "codesign"
            codesign.write_text(
                """#!/bin/bash
case "$1" in
    --verify)
        exit 0
        ;;
    -dvvv)
        printf '%s\\n' \\
            'CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded' \\
            'Timestamp=Jul 29, 2026 at 12:00:00' \\
            'Authority=Developer ID Application: Fixture' >&2
        exit 0
        ;;
    -d)
        exit 0
        ;;
esac
exit 1
""",
                encoding="utf-8",
            )
            codesign.chmod(0o755)
            env = dict(os.environ)
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
                env=env,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


class DeveloperIDWorkflowTests(unittest.TestCase):
    def test_release_secrets_are_isolated_to_protected_job(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        test_job, release_job = workflow.split("\n  release:\n", maxsplit=1)
        self.assertNotIn("secrets.", test_job)
        self.assertIn("environment: production", release_job)
        self.assertIn("secrets.MACOS_CERTIFICATE_P12_BASE64", release_job)
        self.assertIn("permissions:\n      contents: write", release_job)

    def test_final_tag_creates_prerelease_without_updating_stable_feed(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("- 'v*'", workflow)
        self.assertNotIn("preview-v", workflow)
        self.assertIn("--prerelease", workflow)
        self.assertIn('"build/FloralMD-${VERSION}.zip"', workflow)
        self.assertNotIn("update-appcast.py", workflow)
        self.assertNotIn("HEAD:feed", workflow)
        self.assertNotIn("ref: feed", workflow)

    def test_actions_are_pinned_to_full_commit_shas(self) -> None:
        for workflow_name in ("release.yml", "promote-release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            for line in workflow.splitlines():
                if "uses:" not in line:
                    continue
                reference = line.split("@", maxsplit=1)[1].split()[0]
                self.assertRegex(reference, r"^[0-9a-f]{40}$")

    def test_final_dmg_is_not_modified_after_checksum(self) -> None:
        script = (ROOT / "scripts" / "developer-id-release.sh").read_text(
            encoding="utf-8"
        )
        checksum_index = script.index('CHECKSUM="$(dirname "$DMG")')
        self.assertNotIn("codesign --force", script[checksum_index:])
        self.assertNotIn("stapler staple", script[checksum_index:])
        self.assertIn('HASH_BEFORE="$(shasum -a 256 "$DMG"', script)
        self.assertIn('[ "$HASH_BEFORE" = "$HASH_AFTER" ]', script)
        self.assertIn("does not match the app's embedded public key", script)
        self.assertIn('"$SIGN_UPDATE" --verify --ed-key-file -', script)

    def test_promotion_reuses_release_assets_and_is_recoverable(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "promote-release.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("environment: production", workflow)
        self.assertIn('"PROMOTE"', workflow)
        self.assertIn("gh release download", workflow)
        self.assertIn('promotion/FloralMD-${VERSION}.zip', workflow)
        self.assertIn("-F prerelease=false", workflow)
        self.assertIn("update-appcast.py", workflow)
        self.assertNotIn("developer-id-release.sh", workflow)
        self.assertNotIn("gh release upload", workflow)
        self.assertNotIn("gh release create", workflow)
        self.assertNotIn("secrets.", workflow)

    def test_local_release_script_cannot_publish_or_edit_feed(self) -> None:
        script = (ROOT / "scripts" / "release.sh").read_text(encoding="utf-8")
        self.assertNotIn("gh release", script)
        self.assertNotIn("update-appcast.py", script)
        self.assertNotIn("git push", script)


if __name__ == "__main__":
    unittest.main()
