# Public beta release

The first release is **v0.1.0-beta.1**, for Apple Silicon. It uses ad-hoc signing and is not notarized. No Apple account or signing certificate is needed to build this package. Keep development builds Apple-signed if you want their stable Keychain identity.

## Prepare

1. Review the changes, license, installation instructions, release notes, and third-party source/license material.
2. Run `bash Scripts/test.sh`. The default suite does not open windows or access Keychain. Physical playback checks remain documented in `PLAYBACK_VALIDATION.md`.
3. Commit the release sources. Packaging refuses an uncommitted working tree so the source archive matches the built revision.
4. Prepare `dist/beta/Theatre-VLCKit-3.7.2-sources.tar.gz` as described in `Vendor/SOURCE.md`, preserving the upstream archives and notices.
5. Run `bash Scripts/package-beta.sh` on an Apple Silicon Mac with the required Xcode SDK.

The script builds the app separately at `dist/beta/Theatre.app`, packages a disk image with an Applications shortcut and installation instructions, exports the exact Git revision as a source archive, and writes checksums. It does not open Theatre, change the local Apple-signed application, push Git changes, or publish anything.

## Verify

- Verify the disk image mounts and contains Theatre, Applications, Read Me, and the GPL license. Confirm `codesign --verify --deep --strict` succeeds for the mounted app.
- Confirm the app signature is ad-hoc and the executable is arm64. A Gatekeeper assessment may reject this unnotarized app; do not describe it as Apple-approved.
- Compare checksums, and check the source archive contains all build scripts, code, tests, icon assets, license, and notices, without `.git`, `.build`, local server data, credentials, personal media, or the binary framework.
- Perform a download/install/launch check on a second Mac before claiming that installation or older macOS support is verified. Local packaging checks do not reproduce Gatekeeper quarantine after download.

## Publish

Use the existing repository, `https://github.com/clement-horesh/mac`. Review its history before changing visibility from private to public; the history will become public too.

Push the release commit, create tag `v0.1.0-beta.1` at that commit, and create a GitHub **prerelease** titled **Theatre 0.1.0 — Public Beta 1**. Use `RELEASE_NOTES.md` as the description, and attach:

- `Theatre-0.1.0-beta.1-apple-silicon.dmg`
- `Theatre-0.1.0-beta.1-source.tar.gz`
- `SHA256SUMS.txt`
- `Theatre-VLCKit-3.7.2-sources.tar.gz`

GitHub’s automatic source archives refer to the tag. The explicit source archive and its checksum also identify the exact code packaged locally. Do not upload the entire `dist/beta` directory: the standalone app is a packaging intermediate.

For later releases, update the app version/build number, beta name in the packaging script, installation filename, and release notes together. Downloaded updates are installed manually. Developer ID signing and notarization can be added when an Apple Developer Program membership is available.
