#!/bin/bash
# Print one FloralMD Release build setting: version or build.

set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    version) SETTING=MARKETING_VERSION ;;
    build) SETTING=CURRENT_PROJECT_VERSION ;;
    *) echo "usage: $0 version|build" >&2; exit 2 ;;
esac

xcodebuild \
    -project FloralMD.xcodeproj \
    -scheme FloralMD \
    -configuration Release \
    -showBuildSettings 2>/dev/null |
    awk -F ' = ' -v setting="$SETTING" '$1 ~ ("[[:space:]]" setting "$") { print $2; exit }'
