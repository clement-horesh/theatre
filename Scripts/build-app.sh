#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_MEDIA_ROOT="$(dirname "$TASK_ROOT")/Media"
# Apple signatures give Keychain a stable app identity across updates.
TASK_SIGNING_IDENTITIES="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Mac Developer:|"Developer ID Application:/ { print $2 }')"
TASK_SIGNING_IDENTITY="${THEATRE_SIGNING_IDENTITY:-$TASK_SIGNING_IDENTITIES}"
case "$TASK_SIGNING_IDENTITY" in
    ""|*$'\n'*)
        printf '%s\n' 'Install one Apple signing certificate, or set THEATRE_SIGNING_IDENTITY to the fingerprint of the certificate to use.' >&2
        exit 1 ;;
esac
if ! printf '%s\n' "$TASK_SIGNING_IDENTITIES" | awk -v selected="$TASK_SIGNING_IDENTITY" 'toupper($0) == toupper(selected) { found = 1 } END { exit !found }'; then
    printf '%s\n' 'The selected Apple signing certificate is not installed or valid.' >&2
    exit 1
fi
mkdir -p .build/module-cache dist
bash Scripts/setup-vlckit.sh
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
if [ ! -f Sources/JellyMac/DemoMedia/blue-orbit.mp4 ] || [ ! -f Sources/JellyMac/DemoMedia/green-waves.mp4 ] || [ ! -f Sources/JellyMac/DemoMedia/orange-sunrise.mp4 ]; then
    swift Scripts/generate-demo-media.swift Sources/JellyMac/DemoMedia
fi
TASK_SDK_VERSION="$(xcrun --show-sdk-version)"
swift build -c release --disable-sandbox -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$TASK_SDK_VERSION"
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_PATH="$TASK_ROOT/dist/Theatre.app"
TASK_PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
case "$TASK_PREVIOUS_BUILD" in ""|*[!0-9]*) TASK_PREVIOUS_BUILD=0 ;; esac
TASK_BUILD_VERSION=$((10#$TASK_PREVIOUS_BUILD + 1))
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
cp "$BIN_DIR/Theatre" "$APP_PATH/Contents/MacOS/Theatre"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TASK_BUILD_VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TheatreDemoMediaDirectory string $TASK_MEDIA_ROOT" "$APP_PATH/Contents/Info.plist"
mkdir -p "$TASK_MEDIA_ROOT"
# Give changed Icon Composer artwork its own asset name instead of reusing a
# cached Dock rendition under the old name.
TASK_ICON_NAME="theatre-$(python3 - <<'PY'
from pathlib import Path
import hashlib
root = Path('theatre.icon')
digest = hashlib.sha256()
for path in sorted(root.rglob('*')):
    if path.is_file() and path.name != '.DS_Store':
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
print(digest.hexdigest()[:12])
PY
)"
TASK_ICON_SOURCE="$TASK_ROOT/.build/icons/$TASK_ICON_NAME.icon"
if [ ! -d "$TASK_ICON_SOURCE" ]; then
    mkdir -p "$TASK_ROOT/.build/icons"
    cp -R "$TASK_ROOT/theatre.icon" "$TASK_ICON_SOURCE"
fi
xcrun actool "$TASK_ICON_SOURCE" --compile "$APP_PATH/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target 13.0 \
    --app-icon "$TASK_ICON_NAME" --output-partial-info-plist "$TASK_ROOT/.build/theatre-icon-info.plist" \
    --output-format human-readable-text
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName $TASK_ICON_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $TASK_ICON_NAME" "$APP_PATH/Contents/Info.plist"
cp -R Sources/JellyMac/DemoMedia "$APP_PATH/Contents/Resources/"
cp Vendor/VLCKit-COPYING.txt "$APP_PATH/Contents/Resources/"
cp Vendor/THIRD-PARTY-NOTICES.md "$APP_PATH/Contents/Resources/"
if [ -d "$APP_PATH/Contents/Frameworks/VLCKit.framework" ]; then
    rm -rf "$APP_PATH/Contents/Frameworks/VLCKit.framework"
fi
cp -R Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework "$APP_PATH/Contents/Frameworks/"
codesign --force --deep --sign "$TASK_SIGNING_IDENTITY" "$APP_PATH/Contents/Frameworks/VLCKit.framework"
codesign --force --sign "$TASK_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
