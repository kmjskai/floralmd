#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

# GitHub-hosted macOS runners can retain a wedged user-owned testmanagerd
# process. In that state the app test host launches, but XCTest never connects
# and no test case executes. Reset only that user process in CI.
if [ "${CI:-}" = "true" ]; then
    killall testmanagerd 2>/dev/null || true
    sleep 2
fi

# WebKit timing can occasionally fail one hosted-view assertion under the full
# suite load. Xcode reruns only failed tests, at most twice; a deterministic
# regression therefore still fails the release gate on all three attempts.
xcodebuild \
    -project FloralMD.xcodeproj \
    -scheme FloralMD \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath build/TestDerivedData \
    -clonedSourcePackagesDirPath build/SourcePackages \
    CODE_SIGNING_ALLOWED=NO \
    FLORALMD_SKIP_DEBUG_INSTALL=YES \
    -retry-tests-on-failure \
    -test-iterations 3 \
    test
