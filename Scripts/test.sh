#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
bash Scripts/lint.sh
# Default checks never open player windows or access Keychain.
if [ "${1:-}" = --interactive ]; then
    shift
else
    set -- --skip 'PlayerIntegrationTests|KeychainIntegrationTests' "$@"
fi
bash Scripts/setup-vlckit.sh
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
swift Scripts/verify-update.swift Resources/Info.plist updates/appcast.xml
swift build --build-tests --disable-keychain --disable-netrc --disable-sandbox
BIN_DIR="$(swift build --disable-keychain --disable-netrc --show-bin-path)"
# The official macOS framework uses an app-relative install name. Give each
# XCTest bundle the same Frameworks layout as the packaged application.
for TEST_BUNDLE in "$BIN_DIR"/*.xctest; do
    [ -d "$TEST_BUNDLE" ] || continue
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    ln -sfn "$TASK_ROOT/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$TEST_BUNDLE/Contents/Frameworks/VLCKit.framework"
    ln -sfn "$TASK_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$TEST_BUNDLE/Contents/Frameworks/Sparkle.framework"
done
swift test --skip-build --disable-keychain --disable-netrc --disable-sandbox "$@"
