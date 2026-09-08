#!/bin/bash
# Build an isolated local app or the unsigned universal production candidate.

set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT=debug
if [ "${1:-}" = "--variant" ] && [ "${2:-}" = "production" ] && [ "$#" -eq 2 ]; then
    VARIANT=production
elif [ "$#" -ne 0 ]; then
    echo "usage: $0 [--variant production]" >&2
    exit 2
fi

DERIVED_DATA="build/DerivedData"
SOURCE_PACKAGES="build/SourcePackages"
mkdir -p build

if [ "$VARIANT" = production ]; then
    CONFIGURATION=Release
    SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/FloralMD.app"
    OUTPUT_APP="build/FloralMD.app"
    EXPECTED_ID="com.yingkaisun.floralmd"
    EXPECTED_NAME="FloralMD"
    EXTRA_SETTINGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
else
    CONFIGURATION=Debug
    SOURCE_APP="${DERIVED_DATA}/Build/Products/Debug/FloralMD-Dev.app"
    OUTPUT_APP="build/FloralMD-Debug.app"
    EXPECTED_ID="com.yingkaisun.floralmd.dev"
    EXPECTED_NAME="FloralMD Dev"
    EXTRA_SETTINGS=()
fi

xcodebuild \
    -project FloralMD.xcodeproj \
    -scheme FloralMD \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    CODE_SIGNING_ALLOWED=NO \
    "${EXTRA_SETTINGS[@]}" \
    build

rm -rf "$OUTPUT_APP"
ditto "$SOURCE_APP" "$OUTPUT_APP"
cp LICENSE NOTICE "$OUTPUT_APP/Contents/Resources/"

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

[ "$(read_plist "$OUTPUT_APP" CFBundleIdentifier)" = "$EXPECTED_ID" ] || {
    echo "Error: wrong app bundle identifier." >&2; exit 1;
}
[ "$(read_plist "$OUTPUT_APP" CFBundleDisplayName)" = "$EXPECTED_NAME" ] || {
    echo "Error: wrong app display name." >&2; exit 1;
}

QUICK_LOOK="$OUTPUT_APP/Contents/PlugIns/FloralMDQuickLook.appex"
[ -d "$QUICK_LOOK" ] || { echo "Error: Quick Look extension is missing." >&2; exit 1; }

if [ "$VARIANT" = production ]; then
    [ "$(read_plist "$QUICK_LOOK" CFBundleIdentifier)" = "com.yingkaisun.floralmd.quicklook" ] || {
        echo "Error: wrong Quick Look bundle identifier." >&2; exit 1;
    }
    [ "$(read_plist "$OUTPUT_APP" SUFeedURL)" = \
      "https://raw.githubusercontent.com/yingkaisun-kai/floralmd/feed/appcast.xml" ] || {
        echo "Error: production bundle has the wrong Sparkle feed URL." >&2; exit 1;
    }
    [ -d "$OUTPUT_APP/Contents/Frameworks/Sparkle.framework" ] || {
        echo "Error: production bundle does not embed Sparkle." >&2; exit 1;
    }
    ARCHITECTURES="$(lipo -archs "$OUTPUT_APP/Contents/MacOS/FloralMD")"
    grep -qw arm64 <<<"$ARCHITECTURES" && grep -qw x86_64 <<<"$ARCHITECTURES" || {
        echo "Error: production binary is not universal." >&2; exit 1;
    }
fi

if find "$OUTPUT_APP/Contents" -iname '*harness*' -o -iname '*dsh*' | grep -q .; then
    echo "Error: inactive Harness/DSH resources leaked into the public app." >&2
    exit 1
fi

echo "Built ${OUTPUT_APP} ($(read_plist "$OUTPUT_APP" CFBundleShortVersionString), build $(read_plist "$OUTPUT_APP" CFBundleVersion))."
