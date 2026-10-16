# Sources for the bundled VLCKit framework

Theatre uses the unmodified official VLCKit 3.7.2 binary package. The separate [Third-party sources release](https://github.com/clement-horesh/theatre/releases/tag/third-party-vlckit-3.7.2) supplies **`Theatre-VLCKit-3.7.2-sources.tar.gz`**, containing:

- The complete VLCKit source archive, including its libVLC patches, Xcode project, build and packaging scripts, and license.
- The corresponding base libVLC source archive, including its build scripts, licenses, and contrib rules.
- The source tarballs selected by VLCKit’s macOS contrib configuration, with dependencies, fetched and checked against the upstream SHA-512 manifests after applying the included libVLC patches.

The archives retain their upstream copyright and license notices. Theatre makes no changes to the framework source. Native Apple frameworks, the macOS SDK, and compiler are provided by Apple separately.

## Exact upstream revisions

| Component | Revision / download | SHA-256 |
| --- | --- | --- |
| Official binary | `VLCKit-3.7.2-3e42ae47-79128878.tar.xz` | `45fc6398c80d1f8dc0e384a9c80704848e9e82a3a382611bf531fa83c198c276` |
| VLCKit source | `3e42ae4786d74be5a7387e01824733cbd4b294c3` | `15cbafd67ac4d074a1d2c5d92ba9cc619590047d73c418670953c824b198590d` |
| libVLC base source | `79128878` | `7d41aa364f4f5e25d8e4b447f1a87caedfbd96973e071f642ba455e9f45df8cf` |

Upstream downloads:

- Binary: <https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.2-3e42ae47-79128878.tar.xz>
- VLCKit: <https://codeload.github.com/videolan/vlckit/tar.gz/3e42ae4786d74be5a7387e01824733cbd4b294c3>
- libVLC: <https://code.videolan.org/videolan/vlc/-/archive/79128878/vlc-79128878.tar.gz>

## Rebuilding or modifying the framework

Extract the two source archives into a workspace **without spaces in its path**: VLCKit at `VLCKit/`, and libVLC at `VLCKit/libvlc/vlc/`. Apply the patches in `VLCKit/libvlc/patches/` in filename order to that libVLC tree using `patch -p1`. Copy `contrib-tarballs/` into `VLCKit/libvlc/vlc/contrib/tarballs/`.

Follow the included VLCKit README and `buildMobileVLCKit.sh` instructions and install their documented build prerequisites. From the VLCKit directory, `./buildMobileVLCKit.sh -x -a aarch64 -n` selects macOS/Apple Silicon and skips refetching or resetting the already extracted and patched libVLC source. The script builds its tools and dependencies and then the framework. Toolchain prerequisites may need additional downloads. The release ships VideoLAN’s official prebuilt framework; rebuilding that framework has not been validated on Theatre’s current Xcode SDK.

Replace Theatre’s `Vendor/VLCKit.xcframework` with your compatible rebuilt framework and run `bash Scripts/build-app.sh --public-beta` to relink and ad-hoc sign the application. There is no Hardened Runtime library-validation restriction in this beta. Keep your modified build separate from a trusted installed copy.
