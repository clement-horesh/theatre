#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [ -f Vendor/VLCKit.xcframework/Info.plist ]; then exit 0; fi
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/jellymac-vlckit.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
curl -fL --retry 2 'https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.2-3e42ae47-79128878.tar.xz' -o "$TASK_TEMP/vlckit.tar.xz"
EXPECTED_SHA='45fc6398c80d1f8dc0e384a9c80704848e9e82a3a382611bf531fa83c198c276'
ACTUAL_SHA="$(shasum -a 256 "$TASK_TEMP/vlckit.tar.xz" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    printf 'VLCKit archive checksum mismatch.\n' >&2
    exit 1
fi
tar -xf "$TASK_TEMP/vlckit.tar.xz" -C "$TASK_TEMP"
mkdir -p Vendor
cp -R "$TASK_TEMP/VLCKit - binary package/VLCKit.xcframework" Vendor/
cp "$TASK_TEMP/VLCKit - binary package/COPYING.txt" Vendor/VLCKit-COPYING.txt
printf 'Installed official VLCKit 3.7.2 (macOS arm64 + x86_64).\n'
