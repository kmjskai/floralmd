#!/usr/bin/env python3
"""Fail-closed validation for promoting one immutable FloralMD release."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CALVER_RE = re.compile(r"^[0-9]{4}\.(?:[1-9]|1[0-2])\.(?:0|[1-9][0-9]*)$")
CHECKSUM_RE = re.compile(r"^(?P<digest>[0-9a-f]{64})  (?P<name>[^\r\n]+)\r?\n?$")
SIGNATURE_RE = re.compile(
    r'^sparkle:edSignature="(?P<signature>[A-Za-z0-9+/]+={0,2})" '
    r'length="(?P<length>[1-9][0-9]*)"\r?\n?$'
)


def asset_names(version: str) -> set[str]:
    if not CALVER_RE.fullmatch(version):
        raise ValueError(f"{version!r} is not FloralMD CalVer")
    return {
        f"FloralMD-{version}.dmg",
        f"FloralMD-{version}.zip",
        f"FloralMD-{version}.sha256",
        f"FloralMD-{version}.sparkle-signature.txt",
    }


def load_object(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as file:
        value = json.load(file)
    if not isinstance(value, dict):
        raise ValueError(f"{path} does not contain a JSON object")
    return value


def validate_metadata(
    release: dict[str, object],
    *,
    tag: str,
    version: str,
    required_state: str,
) -> str:
    if tag != f"v{version}":
        raise ValueError(f"release tag must be exactly v{version}")
    if release.get("tag_name") != tag:
        raise ValueError("GitHub Release tag does not match the requested tag")
    if release.get("draft") is not False:
        raise ValueError("GitHub Release must not be a draft")
    if release.get("immutable") is True:
        raise ValueError(
            "GitHub Release immutability prevents in-place promotion"
        )
    prerelease = release.get("prerelease")
    if not isinstance(prerelease, bool):
        raise ValueError("GitHub Release has no boolean prerelease state")
    state = "prerelease" if prerelease else "released"
    if required_state != "either" and state != required_state:
        raise ValueError(
            f"GitHub Release state is {state}, expected {required_state}"
        )
    expected_title = (
        f"FloralMD {version} Preview"
        if state == "prerelease"
        else f"FloralMD {version}"
    )
    if release.get("name") != expected_title:
        raise ValueError(f"GitHub Release title must be {expected_title!r}")

    assets = release.get("assets")
    if not isinstance(assets, list) or not all(
        isinstance(asset, dict) for asset in assets
    ):
        raise ValueError("GitHub Release assets are invalid")
    actual_names = {str(asset.get("name", "")) for asset in assets}
    expected_names = asset_names(version)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        detail = f"missing={missing}, extra={extra}"
        raise ValueError(f"GitHub Release asset set is not exact: {detail}")
    return state


def parse_signature(path: Path) -> tuple[str, int]:
    match = SIGNATURE_RE.fullmatch(path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError("Sparkle signature sidecar has invalid syntax")
    signature = match.group("signature")
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Sparkle signature is not valid base64") from error
    if len(decoded) != 64:
        raise ValueError("Sparkle EdDSA signature must decode to 64 bytes")
    return signature, int(match.group("length"))


def validate_files(
    release: dict[str, object],
    *,
    directory: Path,
    version: str,
) -> tuple[str, int, str]:
    dmg_name = f"FloralMD-{version}.dmg"
    zip_name = f"FloralMD-{version}.zip"
    dmg = directory / dmg_name
    app_zip = directory / zip_name
    checksum = directory / f"FloralMD-{version}.sha256"
    signature_file = directory / f"FloralMD-{version}.sparkle-signature.txt"
    for path in (dmg, app_zip, checksum, signature_file):
        if not path.is_file():
            raise ValueError(f"release asset is missing: {path.name}")

    try:
        with zipfile.ZipFile(app_zip) as archive:
            names = archive.namelist()
            if not any(name.startswith("FloralMD.app/") for name in names):
                raise ValueError("app ZIP does not contain FloralMD.app")
            if any(name.startswith(("/", "../")) or "/../" in name for name in names):
                raise ValueError("app ZIP contains an unsafe path")
    except zipfile.BadZipFile as error:
        raise ValueError("app ZIP is not a valid ZIP archive") from error

    digest = hashlib.sha256()
    with dmg.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_digest = digest.hexdigest()
    checksum_match = CHECKSUM_RE.fullmatch(checksum.read_text(encoding="utf-8"))
    if checksum_match is None:
        raise ValueError("SHA-256 manifest has invalid syntax")
    if checksum_match.group("name") != dmg_name:
        raise ValueError("SHA-256 manifest names a different DMG")
    if checksum_match.group("digest") != actual_digest:
        raise ValueError("DMG bytes do not match the SHA-256 manifest")

    signature, signed_length = parse_signature(signature_file)
    actual_length = dmg.stat().st_size
    if signed_length != actual_length:
        raise ValueError("Sparkle signature length does not match the DMG")

    assets = release["assets"]
    assert isinstance(assets, list)
    dmg_asset = next(
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == dmg_name
    )
    if dmg_asset.get("digest") != f"sha256:{actual_digest}":
        raise ValueError("GitHub asset digest does not match the downloaded DMG")
    zip_digest = hashlib.sha256(app_zip.read_bytes()).hexdigest()
    zip_asset = next(
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == zip_name
    )
    if zip_asset.get("digest") != f"sha256:{zip_digest}":
        raise ValueError("GitHub asset digest does not match the downloaded app ZIP")
    return signature, signed_length, actual_digest


def validate_appcast(
    path: Path,
    *,
    repository: str,
    tag: str,
    version: str,
    build: str,
    signature: str,
    length: int,
) -> None:
    document = ET.parse(path)
    expected_url = (
        f"https://github.com/{repository}/releases/download/{tag}/"
        f"FloralMD-{version}.dmg"
    )
    matches = []
    for enclosure in document.findall("./channel/item/enclosure"):
        if enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString") == version:
            matches.append(enclosure)
    if len(matches) != 1:
        raise ValueError("appcast must contain exactly one item for the version")
    enclosure = matches[0]
    expected = {
        f"{{{SPARKLE_NS}}}version": build,
        f"{{{SPARKLE_NS}}}edSignature": signature,
        "length": str(length),
        "url": expected_url,
    }
    for key, value in expected.items():
        if enclosure.get(key) != value:
            raise ValueError(f"appcast enclosure has the wrong {key} value")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--release", required=True, type=Path)
    metadata.add_argument("--tag", required=True)
    metadata.add_argument("--version", required=True)
    metadata.add_argument(
        "--require-state",
        choices=("prerelease", "released", "either"),
        required=True,
    )

    files = subparsers.add_parser("files")
    files.add_argument("--release", required=True, type=Path)
    files.add_argument("--directory", required=True, type=Path)
    files.add_argument("--version", required=True)
    files.add_argument("--github-env", type=Path)

    appcast = subparsers.add_parser("appcast")
    appcast.add_argument("--appcast", required=True, type=Path)
    appcast.add_argument("--repository", required=True)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build", required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--length", required=True, type=int)

    args = parser.parse_args()
    try:
        if args.command == "metadata":
            state = validate_metadata(
                load_object(args.release),
                tag=args.tag,
                version=args.version,
                required_state=args.require_state,
            )
            print(state)
        elif args.command == "files":
            signature, length, digest = validate_files(
                load_object(args.release),
                directory=args.directory,
                version=args.version,
            )
            if args.github_env is not None:
                with args.github_env.open("a", encoding="utf-8") as file:
                    file.write(f"ED_SIGNATURE={signature}\n")
                    file.write(f"FILE_LENGTH={length}\n")
                    file.write(f"DMG_SHA256={digest}\n")
            print(f"sha256:{digest}")
        else:
            validate_appcast(
                args.appcast,
                repository=args.repository,
                tag=args.tag,
                version=args.version,
                build=args.build,
                signature=args.signature,
                length=args.length,
            )
    except (OSError, ValueError, json.JSONDecodeError, ET.ParseError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
