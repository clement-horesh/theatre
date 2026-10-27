# Theatre 0.2.0

Multiple Jellyfin servers in one library, smoother artwork loading, and more reliable browsing and playback. This release includes the full update since 0.1.1.

## Multiple servers

- Connect your first server through the existing onboarding, then add more from **Theatre → Server → Add Server…**.
- Browse Home, Continue, Recently Added, Movies, Shows, search, and downloads across connected servers. Movies and Shows include a server filter.
- Each server has its own address, username, saved session, and Sign Out action. Signing out of every server returns to onboarding. Passwords are never displayed or saved.
- **Theatre → Refresh Library** offers individual servers and **Refresh All**. **⌘R** refreshes every connected server.
- Playback, artwork, details, watch history, and offline progress use the title’s own server and account. Existing download catalogs and files are retained; signing out hides that account’s downloads rather than deleting them.

## Loading and browsing

- Covers use Jellyfin’s BlurHash metadata for an immediate 64-pixel blurred preview, then fade to the loaded artwork without an extra preview request. Cached artwork appears immediately, and Reduce Motion disables the transition.
- Neutral placeholders reserve space while recommendations, posters, details, seasons, episodes, and cast pages load.
- Session caches reuse library pages, details, seasons, filter options, person pages, searches, and artwork. Refresh and watch-progress changes invalidate browsing data; Continue and Recently Added remain live.
- Library and search pages load more results automatically as you scroll. Fixed stale search responses and pagination using a previous query’s offset.
- Fixed multi-server search pagination when Jellyfin returns results by relevance rather than alphabetical order.
- Fixed Recently Added being filled with virtual episode records instead of available movies and shows, and a query flag that could cause Jellyfin 10.11 to ignore search filtering.
- Improved season, episode, and person-page loading so refreshes preserve existing content while new data arrives.

## HTTPS compatibility

HTTPS direct playback now uses URLSession for ranged network reads while VLC decodes the original video, improving compatibility with modern TLS servers. API requests, artwork, downloads, and HTTPS direct playback also accept unverified certificates, including self-signed certificates.

**These Jellyfin HTTPS connections are encrypted, but Theatre does not verify the server’s identity.** Only connect to servers you trust. Authenticated redirects remain restricted to the original server. See [privacy information](https://github.com/clement-horesh/theatre/blob/v0.2.0/PRIVACY.md).

## Installation and updates

Download **Theatre-0.2.0.dmg**, open it, and drag Theatre into Applications. Theatre requires your own Jellyfin server and account; no media or server is bundled.

Existing 0.1.1 users can use **Theatre → Update App → Check for Updates…**. The original 0.1.0 beta needs one manual installation to acquire the updater. The update archive and feed are signed with the existing Sparkle key.

This release is for **Apple Silicon Macs**, targets macOS 13 or later, and is **ad-hoc signed, not notarized by Apple**. If macOS blocks the first launch, follow the documented **System Settings → Privacy & Security → Open Anyway** process. Ad-hoc updates may ask for Keychain authorization again. See [installation instructions](https://github.com/clement-horesh/theatre/blob/v0.2.0/INSTALL.md).

## Known limitations

- Search retains Jellyfin’s native matching: `spider` or `Spider-Man` matches the title; `spiderman` without the hyphen does not.
- Intel and older macOS versions have not been verified. HDR/Dolby Vision accuracy, surround output, and AirPlay still need hardware validation. PiP and AirPlay format support depends on AVPlayer and Jellyfin transcoding permissions.
- Signing out does not delete downloaded media. Use download removal controls to delete saved files.

## License and source

Theatre is licensed under **GPL-3.0-only**. VLCKit and its components retain their upstream licenses; notices are included in the app. GitHub provides source archives for this release tag. Corresponding VLC and dependency sources remain available in the separate [Third-party sources release](https://github.com/clement-horesh/theatre/releases/tag/third-party-vlckit-3.7.2). Only the DMG is needed for manual installation.
