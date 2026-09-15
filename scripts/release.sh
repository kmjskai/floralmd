#!/bin/bash
# Modified from Edmund by Yingkai Sun for FloralMD.
# Validate a FloralMD release candidate locally without publishing anything.
#
# GitHub Actions is the only formal builder and publisher. This helper never
# reads release secrets, creates a DMG, changes a tag/Release, or edits feed.

set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "usage: $0" >&2
    exit 2
fi

VERSION="$(./scripts/release-metadata.sh version)"
BUILD="$(./scripts/release-metadata.sh build)"
VALIDATE_ARGS=(
    --version "$VERSION"
    --tag "v${VERSION}"
    --build "$BUILD"
)
if git cat-file -e HEAD^:Info.plist 2>/dev/null; then
    PREVIOUS_VERSION="$(
        git show HEAD^:Info.plist |
            plutil -extract CFBundleShortVersionString raw -o - -
    )"
    PREVIOUS_BUILD="$(
        git show HEAD^:Info.plist |
            plutil -extract CFBundleVersion raw -o - -
    )"
    VALIDATE_ARGS+=(
        --previous-version "$PREVIOUS_VERSION"
        --previous-build "$PREVIOUS_BUILD"
    )
fi

python3 scripts/validate-release-version.py "${VALIDATE_ARGS[@]}"
python3 scripts/extract-release-notes.py "$VERSION" >/dev/null
python3 -m unittest discover -s scripts/tests
./scripts/test.sh
./scripts/build-app.sh --variant production

echo "Validated local FloralMD ${VERSION} (${BUILD}) candidate."
echo "No tag, GitHub Release, notarization, or Sparkle feed was changed."
