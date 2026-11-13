#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination=${IOS_DESTINATION:-generic/platform=iOS}
xcodebuild -resolvePackageDependencies -project BL616Camera.xcodeproj -scheme BL616Camera
xcodebuild -project BL616Camera.xcodeproj -scheme BL616Camera \
    -destination "$destination" -derivedDataPath "${TMPDIR:-/tmp}/BL616CameraDerivedData" \
    CODE_SIGNING_ALLOWED=NO build
