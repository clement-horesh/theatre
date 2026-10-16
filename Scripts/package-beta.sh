#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [ "$(uname -m)" != arm64 ]; then
    printf 'The first public beta must be built on Apple Silicon.\n' >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    printf 'Commit the release sources before packaging so the published tag matches the app.\n' >&2
    exit 1
fi
TASK_VLC_SOURCES="$TASK_ROOT/dist/beta/Theatre-VLCKit-3.7.2-sources.tar.gz"
if [ ! -f "$TASK_VLC_SOURCES" ]; then
    printf 'Prepare the VLCKit source package described in Vendor/SOURCE.md first.\n' >&2
    exit 1
fi
bash Scripts/lint.sh
bash Scripts/build-app.sh --public-beta
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TASK_NAME="Theatre-$TASK_VERSION"
TASK_RELEASE="$TASK_ROOT/dist/beta"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/dist/.theatre-dmg.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
ditto "$TASK_RELEASE/Theatre.app" "$TASK_STAGE/Theatre.app"
cp INSTALL.md "$TASK_STAGE/Read Me.md"
cp LICENSE "$TASK_STAGE/LICENSE.txt"
ln -s /Applications "$TASK_STAGE/Applications"
codesign --verify --deep --strict "$TASK_STAGE/Theatre.app"
if [ "$(xcrun lipo -archs "$TASK_STAGE/Theatre.app/Contents/MacOS/Theatre")" != arm64 ]; then
    printf 'The beta executable must contain only the arm64 architecture.\n' >&2
    exit 1
fi
hdiutil create -ov -volname "Theatre $TASK_VERSION Beta 1" -srcfolder "$TASK_STAGE" \
    -format UDZO "$TASK_RELEASE/$TASK_NAME.dmg"
cp RELEASE_NOTES.md "$TASK_RELEASE/RELEASE_NOTES.md"
(
    cd "$TASK_RELEASE"
    shasum -a 256 "$TASK_NAME.dmg" "$(basename "$TASK_VLC_SOURCES")"
)
hdiutil verify "$TASK_RELEASE/$TASK_NAME.dmg"
printf 'Beta installer, VLC sources, and release notes: %s\n' "$TASK_RELEASE"
