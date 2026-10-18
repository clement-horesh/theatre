# Release Theatre

The next release is **v0.1.1**, build **100**, for Apple Silicon. It adds the updater. Existing 0.1.0 users must install this release manually once. Later versions can update inside Theatre.

## Signing keys

Sparkle 2.10.0 is pinned in `Package.swift` and `Package.resolved`. The app embeds its public Ed25519 verification key in `Resources/Info.plist`. The corresponding private key is stored only in the release builder's login Keychain under the Sparkle account **theatre-updates**. Users do not need that key or Keychain access to verify updates.

The key was created once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account theatre-updates`. Do not replace the embedded public key casually: existing apps trust the current key. Keep a secure backup of the signing key outside this repository using Sparkle's documented key-export procedure. Losing the key can prevent updating installed ad-hoc builds; their users would need another manual installation. Never commit private keys, exports, credentials, or Keychain contents.

The public build is still ad-hoc signed and not notarized. Update signatures authenticate release archives; they do not make the publisher Apple-verified or bypass Gatekeeper. Use Developer ID signing and notarization when available. Keep local Apple-signed builds separate and use the same Apple identity for subsequent local builds to preserve Keychain recognition.

## Prepare a release

1. Increase `CFBundleShortVersionString` and the positive integer `CFBundleVersion` in `Resources/Info.plist` for every new published version. Build numbers must exceed all previously published builds. Builds use these tracked values directly, on every machine; they no longer increment a local bundle counter.
2. Update `RELEASE_NOTES.md`, installation instructions, and any versioned download links for the intended release. Run `bash Scripts/test.sh`. Default tests do not open windows or read Keychain; they verify the existing feed with its public key.
3. Commit the release sources. `package-beta.sh` refuses a dirty tree so the release tag can match the built source.
4. Prepare `dist/beta/Theatre-VLCKit-3.7.2-sources.tar.gz` as described in `Vendor/SOURCE.md`, if it is not already available. Continue making those third-party sources publicly available while distributing VLCKit.
5. Run `bash Scripts/package-beta.sh v0.1.1` on Apple Silicon. It builds and verifies the app, makes a DMG, and invokes `prepare-update.sh` to make a signed update ZIP and feed. Sparkle's `generate_appcast` may ask to access **theatre-updates** in Keychain for release signing. This is unrelated to GitHub sign-in. Package downloads have Keychain and netrc lookup disabled.

For an already built app, run `bash Scripts/prepare-update.sh dist/beta/Theatre.app v0.1.1` directly. It verifies the app matches the source version and public key, preserves framework symlinks in the ZIP, embeds the release notes, signs the archive and feed, and verifies both using only the public key. Outputs are under `dist/updates/<tag>/`. It refuses to overwrite an existing output directory. Moving an output aside lets you regenerate it; do not change an archive after publishing its signature.

The feed URL is `https://raw.githubusercontent.com/clement-horesh/theatre/main/updates/appcast.xml`. It avoids a separate service or GitHub Pages setup. The committed initial feed is signed and empty; it offers no update until a release is published. The feed contains Theatre application releases only; do not add the separate VLCKit sources release to it.

## Verify

- Verify the DMG mounts and contains Theatre, Applications, installation instructions, and the GPL license.
- Run `bash Scripts/verify-app.sh /path/to/Theatre.app`. It verifies signatures and that every bundled framework can be found using the executable's runtime search paths. The main binary must be arm64. Sparkle's nested helpers and framework must be embedded and signed. Its license is included in Resources.
- Run `swift Scripts/verify-update.swift Resources/Info.plist dist/updates/<tag>/appcast.xml dist/updates/<tag>/Theatre-<version>-<build>.zip`. This checks the feed and ZIP against the public key without Keychain. A changed feed or ZIP must fail verification.
- Test a genuine older updater-equipped copy against a newer signed build, including detection, the menu indicator, download, install, and relaunch. Check playback progress, paused downloads, preferences, and sign-in afterward. A downloaded/quarantined installation on a second Mac remains necessary for Gatekeeper and older-macOS validation.
- Run `bash Scripts/test-updater.sh` for an automated native installer check. It compiles the real AppUpdater adapter into a disposable app, serves a signed update over loopback, and verifies detection, download, signature validation, the pre-install save hook, replacement, and relaunch. It uses a random temporary test key and does not open Keychain or modify Theatre. Run on a logged-in Mac with a GUI session; Sparkle's native helper needs macOS services even though the test has no interactive windows.
- Check all archives and release notes exclude local media, server data, credentials, private keys, and unrelated build outputs. GitHub's source archives should refer to the release tag.

## Publish

No packaging script pushes Git changes or publishes a GitHub release.

1. Push the release commit and create its matching tag, such as `v0.1.1`.
2. Create a normal GitHub release in `https://github.com/clement-horesh/theatre`, using `RELEASE_NOTES.md` for its description. Attach `dist/beta/Theatre-0.1.1.dmg` for manual installation and `dist/updates/v0.1.1/Theatre-0.1.1-100.zip` for Sparkle. Keep both assets immutable after publication. Keep the existing separate VLCKit sources release accessible.
3. Verify both public downloads are available. Only then copy `dist/updates/v0.1.1/appcast.xml` to `updates/appcast.xml`, commit, and push to `main`. This announces the update. Do not edit the signed XML manually. Serving it before the ZIP is published would offer a broken download.
4. Verify the public feed and its signature, then check for updates from an older installed version. Update README download links to the now-published version.

Future releases repeat these steps with a higher version/build. Existing feed entries are retained when generating the next feed. Full update ZIPs are used initially; delta generation is disabled to keep release preparation simple.
