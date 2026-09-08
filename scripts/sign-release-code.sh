#!/bin/bash
# Sign FloralMD's nested code inside-out for Developer ID distribution.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <FloralMD.app> <Developer ID Application identity>" >&2
    exit 2
fi

APP="$1"
IDENTITY="$2"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
QUICK_LOOK="${APP}/Contents/PlugIns/FloralMDQuickLook.appex"

if ! security find-identity -v -p codesigning |
    awk -v identity="$IDENTITY" 'index($0, identity) { found = 1 } END { exit !found }'; then
    echo "Error: requested Developer ID Application identity is not available." >&2
    exit 1
fi

[ -d "$APP" ] || { echo "Error: app bundle does not exist." >&2; exit 1; }
[ -d "$SPARKLE" ] || { echo "Error: Sparkle.framework is missing." >&2; exit 1; }
[ -d "$QUICK_LOOK" ] || { echo "Error: Quick Look extension is missing." >&2; exit 1; }

sign_runtime() {
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
}

# Sparkle's alternate-workflow contract requires signing helpers before their
# containing bundles. Do not use --deep: Downloader.xpc retains its entitlement,
# while unrelated code must not inherit it.
SPARKLE_VERSION="${SPARKLE}/Versions/B"
INSTALLER="${SPARKLE_VERSION}/XPCServices/Installer.xpc"
DOWNLOADER="${SPARKLE_VERSION}/XPCServices/Downloader.xpc"
AUTOUPDATE="${SPARKLE_VERSION}/Autoupdate"
UPDATER="${SPARKLE_VERSION}/Updater.app"

for required_code in "$INSTALLER" "$DOWNLOADER" "$AUTOUPDATE" "$UPDATER"; do
    [ -e "$required_code" ] || {
        echo "Error: expected Sparkle nested code is missing." >&2
        exit 1
    }
done

sign_runtime "$INSTALLER"
sign_runtime --preserve-metadata=entitlements "$DOWNLOADER"
sign_runtime "$AUTOUPDATE"
sign_runtime "$UPDATER"
sign_runtime "$SPARKLE"

sign_runtime \
    --entitlements FloralMDQuickLook/FloralMDQuickLook.entitlements \
    "$QUICK_LOOK"
sign_runtime "$APP"
