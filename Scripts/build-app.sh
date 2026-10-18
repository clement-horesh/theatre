#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_APP_DESTINATION="$TASK_ROOT/dist/Theatre.app"
case "${1:-}" in
    --public-beta)
        # Ad-hoc signing needs no certificate. Keep this separate from the local
        # Apple-signed app so packaging does not change its Keychain identity.
        TASK_SIGNING_IDENTITY=-
        TASK_APP_DESTINATION="$TASK_ROOT/dist/beta/Theatre.app"
        ;;
    "")
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
        ;;
    *) printf 'Usage: bash Scripts/build-app.sh [--public-beta]\n' >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Too many arguments.\n' >&2; exit 1; fi
mkdir -p .build/module-cache dist
bash Scripts/setup-vlckit.sh
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
TASK_SDK_VERSION="$(xcrun --show-sdk-version)"
swift build -c release --disable-keychain --disable-netrc --disable-sandbox \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$TASK_SDK_VERSION"
BIN_DIR="$(swift build -c release --disable-keychain --disable-netrc --show-bin-path)"
mkdir -p "$(dirname "$TASK_APP_DESTINATION")"
TASK_STAGING_ROOT="$(mktemp -d "$TASK_ROOT/dist/.theatre-build.XXXXXX")"
trap 'rm -rf "$TASK_STAGING_ROOT"' EXIT
APP_PATH="$TASK_STAGING_ROOT/Theatre.app"
TASK_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if ! [[ "$TASK_BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
    printf 'CFBundleVersion must be a positive integer, increased in source for every release.\n' >&2
    exit 1
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
cp "$BIN_DIR/Theatre" "$APP_PATH/Contents/MacOS/Theatre"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TASK_BUILD_VERSION" "$APP_PATH/Contents/Info.plist"
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
cp Vendor/VLCKit-COPYING.txt "$APP_PATH/Contents/Resources/"
cp Vendor/THIRD-PARTY-NOTICES.md "$APP_PATH/Contents/Resources/"
cp Vendor/SOURCE.md "$APP_PATH/Contents/Resources/"
cp LICENSE "$APP_PATH/Contents/Resources/"
cp -R Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework "$APP_PATH/Contents/Frameworks/"
TASK_SPARKLE_ROOT="$TASK_ROOT/.build/artifacts/sparkle/Sparkle"
cp "$TASK_SPARKLE_ROOT/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
cp -R "$TASK_SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_PATH/Contents/Frameworks/"
TASK_SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Sign Sparkle's nested helpers from the inside out, retaining their sandbox entitlements.
for TASK_HELPER in "$TASK_SPARKLE"/Versions/B/XPCServices/*.xpc \
    "$TASK_SPARKLE/Versions/B/Updater.app" "$TASK_SPARKLE/Versions/B/Autoupdate"; do
    codesign --force --sign "$TASK_SIGNING_IDENTITY" --preserve-metadata=entitlements "$TASK_HELPER"
done
codesign --force --sign "$TASK_SIGNING_IDENTITY" "$TASK_SPARKLE"
codesign --force --deep --sign "$TASK_SIGNING_IDENTITY" "$APP_PATH/Contents/Frameworks/VLCKit.framework"
codesign --force --sign "$TASK_SIGNING_IDENTITY" "$APP_PATH"
bash Scripts/verify-app.sh "$APP_PATH"
# Install only after compilation, packaging, signing, and verification succeed.
if [ -d "$TASK_APP_DESTINATION" ]; then
    mv "$TASK_APP_DESTINATION" "$TASK_STAGING_ROOT/previous.app"
fi
if ! mv "$APP_PATH" "$TASK_APP_DESTINATION"; then
    if [ -d "$TASK_STAGING_ROOT/previous.app" ]; then
        mv "$TASK_STAGING_ROOT/previous.app" "$TASK_APP_DESTINATION"
    fi
    exit 1
fi
printf 'Built %s\n' "$TASK_APP_DESTINATION"
