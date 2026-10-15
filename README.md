# Theatre

A minimal native SwiftUI macOS client for Jellyfin, now using **VideoLAN VLCKit 3.7.2** for broad-format playback. VLC is embedded inside the app; a separate VLC installation is not needed.

## Project layout

The `mac` folder is the self-contained app project to publish on GitHub. Its sources, tests, scripts, icon, and dependency notices are included. Build output, Swift caches, and the downloaded VLC framework are excluded by `.gitignore`; the setup script downloads VLC when needed. Personal media and Jellyfin server data stay in the parent workspace, outside this folder.

## Local Jellyfin server

Development now uses a real **Jellyfin Server 12.2**, with its official web interface and **Jellyfin FFmpeg 8.1.3**. It listens only on this Mac at **http://127.0.0.1:8096**. Theatre uses the standard server login: enter this address and the account created in the web setup, then click **Connect**. The last server address is remembered.

**Put videos in `../Media`, alongside the `mac` project folder.** This folder is registered as the server’s **Media** library. Keep original names and extensions; nested folders are supported. Jellyfin monitors this folder and scans new files. Use **Refresh** in Theatre after the server has indexed them. No import button or rebuild is needed.

The server runs independently of Theatre for the current macOS login. Quit/reopen Theatre without losing the server or its library. After restarting the Mac, double-click **Start Local Jellyfin.command** in the parent workspace folder. **Stop Local Jellyfin.command** stops it. Server state, cache, logs, and installed binaries are in `../LocalJellyfin/`, outside this app project and excluded from Git by the parent workspace. No media is moved or copied into the server’s state directory.

The optional local-server scripts live in the parent workspace, outside the app repository. To use them on this Apple Silicon Mac, run these commands from `mac`:

```sh
bash ../Scripts/setup-local-jellyfin.sh
bash ../Scripts/start-local-jellyfin.sh
# To stop:
bash ../Scripts/stop-local-jellyfin.sh
```

The setup script downloads the official pinned server/transcoder archives and verifies SHA-256. Its initial configuration binds to `127.0.0.1`, disables discovery/remote access, and does not enable port forwarding. The service is registered for the current login, with no automatic launch at future logins.

The loopback-only `LocalDemoServer` lives in `Tests/JellyMacTests/Support` as an integration-test fixture. It and the generated test videos are not included in the app. Theatre always connects through the real Jellyfin API.

## Browse and play

The app always uses dark mode, including sign-in, Jellyfin Informations, native menus, and player windows. Home features up to five distinct recommendations with Jellyfin backdrops and smaller logos, followed by metadata and a three-line description. The pool contains the ten newest grouped movies/shows and the five movies most recently continued; unwatched additions have priority, and the picks and their order are randomized when Home loads or refreshes. A dominant color sampled from that backdrop tints the top of the page and fades into the dark background near the bottom of the feature. The carousel advances every eight seconds with a smooth crossfade. The page gradient and native title-bar color smoothly blend to the current artwork’s dominant color. Background-free hover arrows with full-height edge targets, horizontal trackpad swipes or mouse drags, and closely spaced bottom-center dots navigate manually and restart the eight-second timer. Rotation pauses when the app is inactive, a detail page is open, or the player has focus. Clicking the artwork opens its details; the Liquid Glass Play/Resume button stays at the bottom right. Featured shows use their own series logo, backdrop, synopsis and season count, with a View Show button opening their episode page. There is no add button. The native title bar shares the page tint. Windowed mode places navigation in the native top bar; fullscreen uses the same controls over the page gradient. Search/Home/Shows/Movies are evenly spaced with no shared background. The selected tab has a white pill; hovering an unselected tab shows a dimmer pill. Search fades and scales into a Liquid Glass field in the same centered position and hides the tabs without moving the page. Both fullscreen transitions switch navigation at the start of the animation, with exactly one navigation surface visible at a time. Clicking outside it or pressing Escape dismisses it and clears the query.

Use the centered **Home**, **Shows**, and **Movies** tabs to browse the library. The search icon reveals a search field for the selected tab. Home displays a horizontally scrolling **Continue** section using Jellyfin backdrops, logos, and saved playback information, with no text beneath the cards. Clicking a Continue card directly plays or resumes that exact movie or episode in the player window. Below it, **Recently Added** shows primary posters for up to 30 distinct movies and shows. Episodes are grouped under their parent show using its poster and detail-page destination. A show is ranked by its newest added episode, so adding another episode moves that show forward without duplicating it. Home checks for changed additions every minute while it is visible and active; unchanged data leaves the carousel alone. Movies and Shows retain primary-image posters and titles. Home search results also use landscape artwork. Shows open their series artwork and episode list; episodes play in the same separate player window. Use **Theatre → Jellyfin Informations…** in the macOS menu bar, or **Command-comma**, to open the server and account information window. **Refresh Library** (**Command-R**) and **Sign Out** are available directly in the Theatre menu. The bottom title-count bar is removed. In fullscreen, the native traffic lights remain available when moving to the top edge.

The library displays Jellyfin **Primary** images as a poster grid. Search and refresh use the same authenticated server connection. Selecting a poster opens a detail view with Jellyfin’s **Backdrop** and transparent **Logo**, plus the movie’s year, duration, rating, genres, and synopsis. Items with missing artwork use a simple placeholder or their text title. Episode details can inherit Jellyfin’s parent backdrop and logo.

Movie details start with a full-width Jellyfin backdrop hero: logo, category and rating, a short synopsis with More linking to About, year/runtime and source-format badges, and a Liquid Glass Play/Resume/Play Again button. Starring and director credits appear at the lower right. Below the hero are a horizontal Cast & Crew row with authenticated Jellyfin portraits and roles, an About card with the full synopsis, and Information, Languages, and Accessibility columns. Quality and accessibility badges come from the item’s actual stream metadata; missing photos use a person silhouette, and unavailable metadata has a simple empty state. Hero synopsis previews use 70% of their previous width. Show heroes have a Liquid Glass Start/Continue button. It resumes the most recently watched unfinished episode across all seasons, falling back to episode order when playback dates are missing or tied. With no unfinished episode, it picks the first available unplayed regular episode in season order. New shows say Start; fully watched shows offer Play Again from their first regular episode. Specials can be resumed but do not displace regular episodes in the automatic unplayed selection. The action refreshes after playback, independently of the season currently being browsed. Shows display a Liquid Glass season dropdown below the hero and a horizontal row of episode cards. Each card uses episode artwork (or an inherited backdrop), with the same untinted artwork blur as Continue behind its episode number, title, two-line synopsis with tail truncation, play symbol and timing. Episode cards use a stronger blur for readability. Unfinished episodes show a small progress bar and remaining time; unstarted episodes show the full runtime. Clicking a card plays or resumes it in the separate player, and its menu can restart an unfinished episode. Changing seasons resets the row to the beginning, and returning from playback refreshes its saved progress.

Click **Play** on the detail view to open a separate native player window. The library stays open for browsing. The player reuses the VLC controls, audio/subtitle menus, and paused seeking. Its window opens at the video’s display aspect ratio and keeps that ratio while resizing, with the picture filling the window. Use the standard macOS window controls to close it or enter fullscreen. Closing its window stops playback and reports the stop to Jellyfin; signing out closes the player. Playback keyboard shortcuts apply while the player window is active.

Unwatched titles have a small blue dot; started but unfinished titles have a yellow dot instead, including rewatches. Movie and show posters have no playback overlay or artwork blur. Progress bars and remaining time appear on Continue and episode cards; Continue information sits over a soft blur of the original artwork with no added color. Shows use the resumable episode supplied by Jellyfin for their status dot. Play and Resume use native Liquid Glass buttons. Resume starts at the saved position, and closing the player refreshes the server’s watched/progress status.

Artwork requests use Jellyfin’s image tags to version a memory cache. Authentication is sent in headers; image URLs do not contain access tokens. Signing out clears the artwork cache.

## Playback controls

Select a video to play. The native SwiftUI controls float over the video in Apple Liquid Glass on macOS 26+, with a native material fallback on earlier systems. They appear on mouse movement, stay visible while paused or interacting with them, and fade away after three seconds of idle playback. In windowed playback, leaving the window hides the controls immediately, including while paused, and moving back into the window reveals them again. Open menus and active scrubbing finish before hiding. The native traffic lights follow the controls’ visibility, including automatic hiding during playback. The controls provide:

- Play/pause and replay after the video ends.
- A bottom timeline and centered play/pause and ten-second controls. Seeking while paused updates the displayed frame without resuming playback.
- Volume and native window fullscreen, preserving the video’s aspect ratio.
- Separate native audio and subtitle menus with checked selections and a subtitle Off option. Menus stay open while the video plays.
- Playback speed from 0.5× to 2× and a volume control in the upper-right corner.

The cursor hides with the controls while it is over the active video area, and returns on mouse movement, pause, focus loss, or closing the player. Native window controls retain the cursor. Active playback holds a temporary display-sleep assertion; foreground viewing also refreshes user activity to prevent idle screensaver/locking. Pause, stop, playback errors, and completion release these assertions. No macOS sleep or lock settings are changed.

Use **F** or the green macOS window button to enter/exit video fullscreen, **Escape** to exit, **Space** to play/pause, and the **left/right arrow keys** to seek ten seconds. Double-clicking the video also toggles fullscreen. These transitions reuse the playing video surface without restarting its stream.

Embedded tracks remain available because the player receives the original file. For external subtitles, put a matching file beside the video, for example:

```
../Media/My Movie.mkv
../Media/My Movie.en.srt
../Media/My Movie.fr.ass
```

Jellyfin discovers and advertises external subtitle tracks; Theatre uses their authenticated delivery URLs. Embedded subtitle tracks are passed to VLC with the original media. Actual availability depends on the file and server metadata.

## Connect to your real Jellyfin server

Click **Sign Out**, enter your server address, username, and password, then **Connect**. Reverse-proxy prefixes such as `https://example.com/jellyfin` are supported.

The app advertises a VLC device profile covering common containers and codecs and prefers a direct-playable source. If direct playback is unavailable, it uses Jellyfin's returned compatible stream. **Try compatible stream** requests H.264/AAC HLS conversion from a real Jellyfin server. The server must have working transcoding and the user must have permission to use it. The local Jellyfin server includes a working FFmpeg transcoder.

The Jellyfin session token is stored in macOS Keychain and restored when Theatre opens. Passwords are cleared after connecting and are never saved. Sign Out removes the saved session and logs out of Jellyfin. An expired session returns to the sign-in screen; a temporary network failure keeps the session. The last server address and a device identifier are also remembered. HTTP support is included for local servers; use HTTPS for remote connections. Stream URLs carry Jellyfin authentication and are not logged by the app. The test fixture excludes symlinks to files outside its selected media folder.

The build uses an installed Apple Development or Developer ID Application certificate so Keychain recognizes app updates. If more than one valid Apple certificate is installed, set `THEATRE_SIGNING_IDENTITY` to the intended certificate’s fingerprint. Signing is checked before changing the app bundle. Switching from the previous temporary signature may require one final Keychain “Always Allow.”

The build compiles the current `theatre.icon` artwork and uses a content-based icon asset name, so changed artwork gets a fresh rendition. Each build increments the bundle version. Quit and reopen Theatre after rebuilding to load the new icon into the Dock.

## Build and run

The app runs on macOS 13 or later. Building requires Xcode 26 or later with the macOS 26 SDK or newer for the Liquid Glass APIs. Run these commands from this `mac` folder (or from the root of a standalone clone). The app can connect to any Jellyfin server; the sibling local server and media folders are optional.

```sh
bash Scripts/build-app.sh
open dist/Theatre.app
```

The setup script downloads the official, stable VLCKit 3.7.2 macOS XCFramework and verifies its pinned SHA-256. It supports Apple Silicon and Intel. The build declares the selected macOS SDK version so native window controls and toolbars adopt that system’s appearance. The app build embeds and signs the framework and includes its license and source notices. The build packages and verifies a fresh app bundle before replacing the previous build, and does not create or modify media folders. The generated app is a local development build for the build machine's architecture, not a notarized release. See `Vendor/THIRD-PARTY-NOTICES.md`.

Open `Package.swift` in Xcode to edit the project. `JellyfinKit` contains reusable API code for later iPhone and Apple TV clients. The current interface and integrated VLC binary target macOS; iOS/tvOS integration is a subsequent milestone.

## Code quality and verification

Swift code follows the checked-in `.swift-format` configuration: four-space indentation, a 120-column target, conventional Swift names, explicit JSON wire keys, and the formatter’s default lint rules. Native glass surfaces share a single availability-checked helper. Player controls use a `GlassEffectContainer` on supported macOS versions, following [Apple’s custom glass guidance](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views). View work checks cancellation before publishing results, in keeping with [SwiftUI task lifetime](https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)).

```sh
bash Scripts/lint.sh
bash Scripts/test.sh
```

The default test command runs formatting and shell syntax checks, API/model tests, and loopback integration tests. It never opens player windows or accesses Keychain. Pass additional Swift test arguments directly, for example `bash Scripts/test.sh --filter JellyfinClientTests`.

Player-window playback checks and the isolated Keychain round-trip test are explicitly interactive:

```sh
bash Scripts/test.sh --interactive
```

The interactive run opens native player windows and can show a macOS Keychain authorization dialog.

Regression coverage includes cancelled/stale library requests, pagination with overlapping pages, permission errors that preserve sign-in, shared artwork downloads scoped to each account, and ordered playback reports with a bounded queue for slow servers.

The test script gives XCTest bundles the Frameworks layout required by VideoLAN's macOS framework. Tests cover API authentication, paging/search, base paths, direct playback across containers, compatible-stream fallback, authenticated external subtitles, and preventing tokens from being sent to another server.

Local integration tests cover new/removed/nested files, stable unique IDs, symlink exclusion, searching/paging, subtitle delivery, and HEAD/range requests on a sparse 3 GiB file. The interactive playback tests actually decode and seek six generated videos:

| File | Video | Audio | Other coverage |
| --- | --- | --- | --- |
| MP4 | H.264 | AAC | External SRT subtitle |
| MKV | H.264 | Two AAC tracks | Embedded SRT and audio switching |
| MKV | HEVC | AC-3 | Different video/audio codecs |
| MOV | H.264 | PCM | Uncompressed audio |
| AVI | MPEG-4 Part 2 | MP3 | Non-AVPlayer container/codec combination |
| WebM | VP9 | Opus | Web-oriented codecs |

Fixtures are original generated test patterns and tones, with no third-party video assets. `Scripts/generate-format-fixtures.py /path/to/ffmpeg` regenerates them. FFmpeg is needed only to regenerate fixtures, and is not bundled with or required by the application.

These tests do not establish HDR, Dolby Vision, Atmos/passthrough, every subtitle format, or performance on every Apple device. Your remote server still needs its own login and compatibility checks. Downloads, automatic next-episode playback, iPhone, and Apple TV UIs are not included yet.

Implemented against Jellyfin's public API. No Infuse code or assets are used.

- Jellyfin API: https://repo.jellyfin.org/releases/openapi/jellyfin-openapi-stable.json
- VideoLAN VLCKit: https://github.com/videolan/vlckit

The app uses the supplied `theatre.icon` Icon Composer artwork. The build compiles the layered icon and a legacy `.icns` fallback with Apple’s asset compiler.
