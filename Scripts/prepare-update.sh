#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [ "$#" -ne 2 ]; then
    printf 'Usage: bash Scripts/prepare-update.sh /path/to/Theatre.app v0.2.0\n' >&2
    exit 1
fi
TASK_APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TASK_TAG="$2"
if ! [[ "$TASK_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    printf 'Specify a versioned GitHub release tag, such as v0.2.0.\n' >&2
    exit 1
fi
TASK_TOOLS="$TASK_ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$TASK_TOOLS/generate_appcast" ]; then
    printf 'Build Theatre first to resolve Sparkle and its signing tools.\n' >&2
    exit 1
fi
bash Scripts/verify-app.sh "$TASK_APP"
python3 - "$TASK_APP/Contents/Info.plist" "$TASK_ROOT/Resources/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    app = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    expected = plistlib.load(source)
for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'SUFeedURL', 'SUPublicEDKey'):
    if app.get(key) != expected.get(key):
        raise SystemExit(f'The app differs from the release sources: {key}. Rebuild before preparing an update.')
PY
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
case "$TASK_TAG" in
    "v$TASK_VERSION"|"v$TASK_VERSION"-*) ;;
    *) printf 'The release tag must match app version %s.\n' "$TASK_VERSION" >&2; exit 1 ;;
esac
TASK_OUTPUT="$TASK_ROOT/dist/updates/$TASK_TAG"
TASK_NAME="Theatre-$TASK_VERSION"
if [ -e "$TASK_OUTPUT" ]; then
    printf 'Update output already exists: %s. Move it aside before regenerating.\n' "$TASK_OUTPUT" >&2
    exit 1
fi
mkdir -p "$TASK_ROOT/dist/updates"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/dist/updates/.prepare.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_STAGE/$TASK_NAME.zip"
cp updates/appcast.xml "$TASK_STAGE/appcast.xml"
cp RELEASE_NOTES.md "$TASK_STAGE/$TASK_NAME.md"
# The updater uses a single application release feed. Publish only Theatre releases to it.
"$TASK_TOOLS/generate_appcast" --account theatre-updates --maximum-deltas 0 \
    --embed-release-notes --link https://github.com/clement-horesh/theatre \
    --download-url-prefix "https://github.com/clement-horesh/theatre/releases/download/$TASK_TAG/" "$TASK_STAGE"
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache" swift Scripts/verify-update.swift \
    "$TASK_APP/Contents/Info.plist" "$TASK_STAGE/appcast.xml" "$TASK_STAGE/$TASK_NAME.zip"
mv "$TASK_STAGE" "$TASK_OUTPUT"
printf 'Prepared %s\nUpload %s.zip to that GitHub release, then copy appcast.xml to updates/appcast.xml and commit it.\n' \
    "$TASK_OUTPUT" "$TASK_NAME"
