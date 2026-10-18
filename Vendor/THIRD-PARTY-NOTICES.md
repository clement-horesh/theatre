# Third-party software

## Sparkle

Theatre embeds the official **Sparkle 2.10.0** framework for application updates.
Sparkle uses a permissive MIT-style license and includes components under their
own licenses. The complete upstream license and component notices are included as
`Sparkle-LICENSE.txt` in the app's Resources directory.

Project and source: https://github.com/sparkle-project/Sparkle/tree/2.10.0
The dependency revision is pinned in `Package.resolved`; Swift Package Manager
verifies the upstream binary artifact checksum declared by that package.
Theatre does not modify Sparkle's source. Its embedded helpers are re-signed
along with the app when packaging.

## VLCKit

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

`Theatre-VLCKit-3.7.2-sources.tar.gz` is available in the separate Third-party sources release:
https://github.com/clement-horesh/theatre/releases/tag/third-party-vlckit-3.7.2
It contains the exact VLCKit/libVLC source archives, upstream patches,
build scripts, and the source tarballs for the macOS dependencies. See
`SOURCE.md` next to this notice for revisions, checksums, and rebuilding instructions.
Theatre's original source is distributed separately under GPL-3.0-only.
