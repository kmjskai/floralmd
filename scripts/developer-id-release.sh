#!/bin/bash
# Build the one-way Developer ID -> notarized app -> final DMG byte chain.
#
# Secrets are accepted only through environment variables. This script never
# enables shell tracing and never prints certificate, account, or key values.

set -euo pipefail

REQUIRED_SECRETS=(
    MACOS_CERTIFICATE_P12_BASE64
    MACOS_CERTIFICATE_PASSWORD
    APPLE_NOTARY_KEY_P8_BASE64
    APPLE_NOTARY_KEY_ID
    APPLE_NOTARY_ISSUER_ID
    FLORALMD_SPARKLE_ED_PRIVATE_KEY
)

check_secrets() {
    local missing=0
    local name
    for name in "${REQUIRED_SECRETS[@]}"; do
        if [ -z "${!name:-}" ]; then
            echo "Error: required release secret ${name} is missing." >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

if [ "${1:-}" = "--check-secrets" ]; then
    check_secrets
    exit
fi

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <FloralMD.app> <output.dmg>" >&2
    exit 2
fi

check_secrets
APP="$1"
DMG="$2"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
ASSET_NAME="FloralMD-${VERSION}.dmg"
[ "$(basename "$DMG")" = "$ASSET_NAME" ] || {
    echo "Error: output DMG must be named ${ASSET_NAME}." >&2
    exit 1
}

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/floralmd-signing.XXXXXX")"
KEYCHAIN="${WORK}/release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
P12="${WORK}/developer-id.p12"
NOTARY_KEY="${WORK}/AuthKey.p8"

cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 -D >"$P12"
printf '%s' "$APPLE_NOTARY_KEY_P8_BASE64" | base64 -D >"$NOTARY_KEY"
chmod 600 "$P12" "$NOTARY_KEY"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$MACOS_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
security default-keychain -d user -s "$KEYCHAIN"

IDENTITIES="$(
    security find-identity -v -p codesigning "$KEYCHAIN" |
        awk '/Developer ID Application:/{print $2}'
)"
IDENTITY_COUNT="$(printf '%s\n' "$IDENTITIES" | awk 'NF{count++} END{print count+0}')"
[ "$IDENTITY_COUNT" -eq 1 ] || {
    echo "Error: imported archive must contain exactly one Developer ID Application identity." >&2
    exit 1
}
IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk 'NF{print; exit}')"

./scripts/sign-release-code.sh "$APP" "$IDENTITY"
./scripts/verify-release-artifact.sh signed-app "$APP"

notarize() {
    local artifact="$1"
    local label="$2"
    local submission="${WORK}/${label}-submission.json"
    local log="${WORK}/${label}-notary-log.json"
    local submission_id

    xcrun notarytool submit "$artifact" \
        --key "$NOTARY_KEY" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" \
        --wait \
        --output-format json >"$submission"
    submission_id="$(
        python3 scripts/validate-developer-id-release.py \
            --submission "$submission" \
            --log <(printf '{"issues": []}') \
            --print-id
    )"
    xcrun notarytool log "$submission_id" \
        --key "$NOTARY_KEY" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" \
        "$log" >/dev/null
    SUMMARY="$(
        python3 scripts/validate-developer-id-release.py \
            --submission "$submission" \
            --log "$log"
    )"
    echo "${label} notarization: ${SUMMARY}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- ${label} notarization: ${SUMMARY}" >>"$GITHUB_STEP_SUMMARY"
    fi
}

APP_ZIP="${WORK}/FloralMD.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP" app
xcrun stapler staple "$APP" >/dev/null
./scripts/verify-release-artifact.sh notarized-app "$APP"

RELEASE_ZIP="$(dirname "$DMG")/FloralMD-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"

./scripts/create-release-dmg.sh "$APP" "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG" >/dev/null

CHECKSUM="$(dirname "$DMG")/FloralMD-${VERSION}.sha256"
(
    cd "$(dirname "$DMG")"
    shasum -a 256 "$(basename "$DMG")" >"$(basename "$CHECKSUM")"
)
./scripts/verify-release-artifact.sh final-dmg "$DMG" "$CHECKSUM"

SIGN_UPDATE="$(find build/SourcePackages -type f -name sign_update -perm -111 -print -quit)"
GENERATE_KEYS="$(find build/SourcePackages -type f -name generate_keys -perm -111 -print -quit)"
[ -n "$SIGN_UPDATE" ] || {
    echo "Error: Sparkle sign_update was not found." >&2
    exit 1
}
[ -n "$GENERATE_KEYS" ] || {
    echo "Error: Sparkle generate_keys was not found." >&2
    exit 1
}
SPARKLE_KEY_FILE="${WORK}/sparkle-private-key"
printf '%s' "$FLORALMD_SPARKLE_ED_PRIVATE_KEY" >"$SPARKLE_KEY_FILE"
chmod 600 "$SPARKLE_KEY_FILE"
"$GENERATE_KEYS" --account floralmd -f "$SPARKLE_KEY_FILE" >/dev/null 2>&1
DERIVED_PUBLIC_KEY="$("$GENERATE_KEYS" --account floralmd -p)"
EMBEDDED_PUBLIC_KEY="$(
    /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
        "${APP}/Contents/Info.plist"
)"
[ "$DERIVED_PUBLIC_KEY" = "$EMBEDDED_PUBLIC_KEY" ] || {
    echo "Error: Sparkle private key does not match the app's embedded public key." >&2
    exit 1
}
HASH_BEFORE="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIGNATURE_OUTPUT="$(
    printf '%s' "$FLORALMD_SPARKLE_ED_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - "$DMG"
)"
ED_SIGNATURE="$(
    printf '%s\n' "$SIGNATURE_OUTPUT" |
        sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'
)"
FILE_LENGTH="$(
    printf '%s\n' "$SIGNATURE_OUTPUT" |
        sed -n 's/.*length="\([0-9]*\)".*/\1/p'
)"
[ -n "$ED_SIGNATURE" ] && [ -n "$FILE_LENGTH" ] || {
    echo "Error: Sparkle signature output could not be parsed." >&2
    exit 1
}
ACTUAL_LENGTH="$(stat -f %z "$DMG")"
[ "$FILE_LENGTH" = "$ACTUAL_LENGTH" ] || {
    echo "Error: Sparkle signature length does not match the final DMG." >&2
    exit 1
}
printf '%s' "$FLORALMD_SPARKLE_ED_PRIVATE_KEY" |
    "$SIGN_UPDATE" --verify --ed-key-file - "$DMG" "$ED_SIGNATURE" >/dev/null
SIGNATURE_FILE="$(dirname "$DMG")/FloralMD-${VERSION}.sparkle-signature.txt"
printf 'sparkle:edSignature="%s" length="%s"\n' \
    "$ED_SIGNATURE" "$FILE_LENGTH" >"$SIGNATURE_FILE"
HASH_AFTER="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$HASH_BEFORE" = "$HASH_AFTER" ] || {
    echo "Error: final DMG bytes changed after Sparkle signing." >&2
    exit 1
}
./scripts/verify-release-artifact.sh final-dmg "$DMG" "$CHECKSUM"

echo "Developer ID release artifacts are ready."
