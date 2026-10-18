# Install Theatre

This release is for **Apple Silicon Macs (M1 or later)**. The deployment target is macOS 13; hands-on validation has been on macOS 27.2. Older macOS versions have not yet been verified. Theatre requires your own Jellyfin server and account. It includes no films, shows, or server.

1. Download `Theatre-0.1.1.dmg` from this repository’s GitHub Releases page.
2. Open the disk image and drag **Theatre** into **Applications**.
3. Eject the disk image and open Theatre from Applications.
4. Enter your Jellyfin server address, including `http://` or `https://` and any port or base path, then your Jellyfin username and password.

## macOS approval

This release is **ad-hoc signed and not notarized by Apple**. The signature checks the app’s integrity; it does not verify the publisher’s identity.

If macOS blocks the app because the developer cannot be verified, attempt to open it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. This is Apple’s documented approval process: <https://support.apple.com/en-us/102445>.

Only approve a download you trust. A malware warning or a failed checksum should not be bypassed. You do not need to disable Gatekeeper or change system security settings to use this documented process. Managed Macs may restrict approval.

GitHub displays a SHA-256 digest beside each release asset. To check a download in Terminal, run `shasum -a 256` on the downloaded file and compare its result with the digest shown on GitHub.

## Updates and saved sign-in

The original 0.1.0 beta needs one manual update: quit Theatre and replace it in Applications with a release that includes the updater. Downloads and preferences are stored outside the application bundle.

Starting with 0.1.1, use the macOS **Theatre → Update App → Check for Updates…** menu. A dot appears in the menu title when a newer version is available. Choose **Install Update…** to see the release notes and download, install, and restart. Checks run daily unless disabled in that menu or Settings. Theatre saves playback progress and pauses downloads before an update restarts it. Scheduled checks do not interrupt playback. Feed and update signatures are verified before installation. This does not replace Apple notarization or remove macOS's first-launch checks.

Theatre saves the Jellyfin session token in Keychain, not your password. Ad-hoc builds do not have a stable verified developer identity, so macOS may ask you to authorize Keychain access again after an update. **Theatre → Server → Sign Out** removes the saved session. Do not share passwords, session tokens, or private server addresses in public bug reports.

## Known limitations

- Intel builds are not included in this release.
- HDR/Dolby Vision image accuracy, surround output, and AirPlay receiver behavior still need hardware validation. Source badges describe the file, not guaranteed output capabilities.
- Native Picture in Picture and AirPlay depend on Apple’s supported formats; Jellyfin transcoding may be needed and must be permitted for your account.
- Styled or image-based subtitles may ignore subtitle appearance overrides.
- The update feed must be published with the matching GitHub release before it can offer that release.

Report problems through this repository’s GitHub Issues, with the Theatre version, macOS version, Mac model, and steps to reproduce. See `PLAYBACK_VALIDATION.md` for the checks already performed.
