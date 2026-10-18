#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_FRAMEWORK="$TASK_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [ ! -d "$TASK_FRAMEWORK/Sparkle.framework" ]; then
    swift package --disable-keychain --disable-netrc resolve
fi
TASK_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Theatre-Updater.XXXXXX")"
trap 'rm -rf "$TASK_TEST_ROOT"' EXIT
TASK_FIXTURES="$TASK_ROOT/Tests/UpdaterSmoke"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
xcrun clang -fobjc-arc -F "$TASK_FRAMEWORK" -c "$TASK_FIXTURES/Driver.m" -o "$TASK_TEST_ROOT/Driver.o"
xcrun swiftc -parse-as-library -F "$TASK_FRAMEWORK" -framework Sparkle \
    -import-objc-header "$TASK_FIXTURES/Driver.h" Sources/JellyMac/AppUpdater.swift \
    "$TASK_FIXTURES/Probe.swift" "$TASK_TEST_ROOT/Driver.o" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$TASK_TEST_ROOT/Probe"
# Only a disposable app is updated. Its random test key never goes into Keychain.
python3 "$TASK_FIXTURES/run.py" "$TASK_TEST_ROOT" "$TASK_ROOT"
