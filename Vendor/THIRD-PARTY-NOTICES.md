# Third-party software

Theatre embeds the unmodified official VideoLAN **VLCKit 3.7.2** macOS binary framework,
including libVLC and its included components. It provides the media decoder and renderer.

VLCKit is distributed under LGPL version 2.1 or later. Its license is included as
`VLCKit-COPYING.txt` next to this notice in the app's Resources directory. Copyright
and license headers for the public API are retained in the embedded framework.
The framework is dynamically linked and can be replaced by a compatible framework
with the app re-signed for local execution. Theatre makes no changes to its source.

Project: https://code.videolan.org/videolan/VLCKit
Official source mirror: https://github.com/videolan/vlckit
Pinned binary release: https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.2-3e42ae47-79128878.tar.xz
Archive SHA-256: `45fc6398c80d1f8dc0e384a9c80704848e9e82a3a382611bf531fa83c198c276`

The reproducible download is handled by `Scripts/setup-vlckit.sh`. The macOS
framework contains Apple Silicon and Intel slices. Each included component retains
its upstream license; consult VideoLAN's source distribution and COPYING for details.

The public beta includes `Theatre-VLCKit-3.7.2-sources.tar.gz` alongside the app
download. It contains the exact VLCKit/libVLC source archives, upstream patches,
build scripts, and the source tarballs for the macOS dependencies. See
`SOURCE.md` next to this notice for revisions, checksums, and rebuilding instructions.
Theatre's original source is distributed separately under GPL-3.0-only.
