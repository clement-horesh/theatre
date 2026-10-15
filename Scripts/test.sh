#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
bash Scripts/lint.sh
# Default checks never open player windows or access Keychain.
TASK_TEST_OPTIONS=(--skip 'PlayerIntegrationTests|KeychainIntegrationTests')
if [ "${1:-}" = --interactive ]; then
    TASK_TEST_OPTIONS=()
    shift
fi
bash Scripts/setup-vlckit.sh
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
swift build --build-tests --disable-sandbox
BIN_DIR="$(swift build --show-bin-path)"
# The official macOS framework uses an app-relative install name. Give each
# XCTest bundle the same Frameworks layout as the packaged application.
for TEST_BUNDLE in "$BIN_DIR"/*.xctest; do
    [ -d "$TEST_BUNDLE" ] || continue
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    ln -sfn "$TASK_ROOT/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$TEST_BUNDLE/Contents/Frameworks/VLCKit.framework"
done
swift test --skip-build --disable-sandbox "${TASK_TEST_OPTIONS[@]}" "$@"
