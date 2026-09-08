#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild \
    -project FloralMD.xcodeproj \
    -scheme FloralMD \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath build/TestDerivedData \
    -clonedSourcePackagesDirPath build/SourcePackages \
    CODE_SIGNING_ALLOWED=NO \
    test
