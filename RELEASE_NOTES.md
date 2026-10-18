# Theatre 0.1.1

A native Mac client for your Jellyfin server. This release is for Apple Silicon Macs and is ad-hoc signed, not Apple-notarized.

## Changes in 0.1.1

- In-app updates through Sparkle: the macOS **Theatre → Update App** menu checks daily, indicates a newer version with a dot, and offers a native install/restart flow. Automatic checks can be disabled. Scheduled checks do not interrupt playback; update feeds and archives are signed and verified.
- Download preparation and transfers share a limit of two concurrent jobs. Catalog and file operations run off the main thread, progress no longer refreshes the whole library, and queued transfers have Pause/Resume/Retry controls.
- Compatible-stream retries retain the current playback position and paused state. Playback cleanup handles cancellation during native preparation.
- Fixed credits markers being omitted from requests, which prevented early **Next Episode** prompts. Skip Intro and Next Episode now sit to the left of the bottom-right player controls.
- Authenticated requests reject redirects to another origin or scheme. Failure logs avoid exposing stream URLs and credentials.
- Library loading, recommendations, trailer selection, and episode keyboard actions have reliability and consistency improvements.
- Reorganized the native Theatre menu, grouping connection information and Sign Out under Server. Information uses the same grouped form style as Settings.

## Included

- Jellyfin sign-in with the server-issued session token saved in Keychain.
- Home recommendations, Continue, Recently Added, search, and Movies/Shows libraries with grid and alphabetical views and filters.
- Movie and show details, seasons, episodes, cast and crew, actor filmographies, related titles, and Jellyfin-provided remote trailers.
- Broad-format VLC playback, resume, audio and subtitle selection, subtitle styling, keyboard/media controls, and automatic next-episode playback.
- Skip Intro and credits actions when Jellyfin provides valid markers.
- Offline downloads with pause/resume/retry, cached artwork, and watch-progress synchronization.
- Dark appearance, native Mac controls, Liquid Glass on supported macOS versions, and hover/focus feedback.

## Installation

Download **Theatre-0.1.1.dmg**, drag Theatre into Applications, and connect to your own Jellyfin server. No media or server is bundled. Existing 0.1.0 users need this manual installation once to acquire the updater; subsequent updates can be installed from **Theatre → Update App**.

This build is not notarized. If macOS blocks it as an unidentified developer, use Apple’s **System Settings → Privacy & Security → Open Anyway** process after attempting to open the app. Read [installation instructions](INSTALL.md) for details and limitations.

The build targets macOS 13 or later; hands-on validation has been on macOS 27.2. Intel and older macOS validation remain outstanding. HDR/Dolby Vision accuracy, surround output, and AirPlay require further hardware checks. PiP and AirPlay format support depends on AVPlayer and Jellyfin transcoding permissions. Ad-hoc updates may prompt again for Jellyfin session access in Keychain; update signature verification itself does not require Keychain access.

## License and source

Theatre is licensed under **GPL-3.0-only**. VLCKit and its components retain their upstream licenses; notices are included in the app. GitHub provides Theatre’s source archives automatically. VLC and dependency sources are available in the separate [Third-party sources release](https://github.com/clement-horesh/theatre/releases/tag/third-party-vlckit-3.7.2). Only the DMG is needed to install the app. See [third-party notices](Vendor/THIRD-PARTY-NOTICES.md).
