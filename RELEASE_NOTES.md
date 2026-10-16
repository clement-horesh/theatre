# Theatre 0.1.0 — Public Beta 1

A native Mac client for your Jellyfin server. This first public beta is for Apple Silicon Macs and is ad-hoc signed, not Apple-notarized.

## Included

- Jellyfin sign-in with the server-issued session token saved in Keychain.
- Home recommendations, Continue, Recently Added, search, and Movies/Shows libraries with grid and alphabetical views and filters.
- Movie and show details, seasons, episodes, cast and crew, actor filmographies, related titles, and Jellyfin-provided remote trailers.
- Broad-format VLC playback, resume, audio and subtitle selection, subtitle styling, keyboard/media controls, and automatic next-episode playback.
- Skip Intro and credits actions when Jellyfin provides valid markers.
- Offline downloads with pause/resume/retry, cached artwork, and watch-progress synchronization.
- Dark appearance, native Mac controls, Liquid Glass on supported macOS versions, and hover/focus feedback.

## Installation

Download **Theatre-0.1.0.dmg**, drag Theatre into Applications, and connect to your own Jellyfin server. No media or server is bundled.

This build is not notarized. If macOS blocks it as an unidentified developer, use Apple’s **System Settings → Privacy & Security → Open Anyway** process after attempting to open the app. Read [installation instructions](INSTALL.md) for details and limitations.

The build targets macOS 13 or later; hands-on validation has been on macOS 27.2. Intel and older macOS validation remain outstanding. HDR/Dolby Vision accuracy, surround output, and AirPlay require further hardware checks. PiP and AirPlay format support depends on AVPlayer and Jellyfin transcoding permissions. Ad-hoc updates may prompt again for Keychain authorization. Updates are manual.

## License and source

Theatre is licensed under **GPL-3.0-only**. VLCKit and its components retain their upstream licenses; notices are included in the app. GitHub provides Theatre’s source archives automatically. The release also includes `Theatre-VLCKit-3.7.2-sources.tar.gz` with third-party sources. Only the DMG is needed to install the app. See [third-party notices](Vendor/THIRD-PARTY-NOTICES.md).
