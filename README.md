# Theatre

A native macOS Jellyfin client with a dark SwiftUI interface, Liquid Glass controls, and embedded VideoLAN VLCKit for broad-format playback.

## Build

Open `Package.swift` in Xcode, or build the signed app:

```sh
bash Scripts/build-app.sh
```

The app is created at `dist/Theatre.app`. Packaging requires a valid Apple Development or Developer ID signing identity. If several are installed, set `THEATRE_SIGNING_IDENTITY` to the certificate fingerprint you want to use. Reuse the same identity for updates so Keychain continues recognizing the app.

The setup script downloads the official VLCKit 3.7.2 macOS framework and verifies its SHA-256. It is dynamically linked, embedded, and signed with the app. See [third-party notices](Vendor/THIRD-PARTY-NOTICES.md).

This is a development build for the build machine's architecture, not a notarized release. macOS 13 is the minimum deployment target; newer system effects are availability-checked. Building requires an Xcode SDK that includes the newer APIs used by those checks.

## Use

Enter your Jellyfin server address and account credentials. Theatre saves the server-issued token in Keychain; it never saves your password. **Theatre → Sign Out** removes the saved session. HTTP and HTTPS servers and reverse-proxy base paths are supported.

- **Home:** rotating recommendations, Continue cards that launch playback directly, and Recently Added posters grouped by show.
- **Shows / Movies:** poster libraries, search, and detail pages with Jellyfin artwork and metadata.
- **Show details:** native season selector, episode cards, and a Start/Continue action resolved from resumable and next-up episodes.
- **Player:** separate window with a locked video aspect ratio, audio/subtitle selection, subtitle appearance controls, native Picture in Picture and AirPlay.
- **Watch status:** right-click a title or use an episode's three-dot menu to mark it watched or unwatched.

**Theatre → Settings…** contains automatic next-episode playback (enabled by default) and preferred audio/subtitle languages. A manual language selection in the player is remembered for later videos. If Jellyfin supplies an Outro marker, a Next Episode button appears at the credits; otherwise it appears at the end. Automatic continuation waits for the video to end.

Playback is shared with macOS Now Playing and standard media keys. Local playback uses VLC; native presentation prefers Apple-compatible originals, then asks Jellyfin for a compatible stream when needed. Server transcoding permission is required when conversion is necessary. Subtitle appearance overrides may not apply to image subtitles or fully styled embedded subtitles.

Shortcuts: **Space** play/pause, **← / →** seek ten seconds, **F** video fullscreen, **Escape** leave fullscreen, **⌘F** search, **⌘R** refresh, **⌘,** settings.

**Theatre → Jellyfin Informations…** shows connection details. Jellyfin owns all artwork, metadata, media indexing, and watch history; no local media server is bundled with Theatre.

## Code and checks

`Sources/JellyfinKit` contains the reusable API/models. `AppModel` manages sign-in and library state; `PlaybackSession` owns playback tasks, server reporting, and the player window. `PlaybackController` coordinates VLC and AVPlayer. Small AppKit adapters supply native window and input behavior.

```sh
bash Scripts/lint.sh
bash Scripts/test.sh
```

Default checks cover API contracts, pagination, cancellation, preferences, watch status, and headless player behavior. They do not open player windows or access Keychain. The loopback playback server is only a test fixture; its original generated video patterns are in `Tests/JellyMacTests/Fixtures`.

Explicit interactive checks:

```sh
bash Scripts/test.sh --interactive
```

These open player windows and may show Keychain prompts. Native PiP interaction, AirPlay receivers, HDR rendering and surround output require separate live verification. Metadata badges describe the source, not verified output capabilities.

## Repository layout

Publish this `mac` folder independently. `.build`, `dist`, and downloaded frameworks are ignored. Personal media and Jellyfin state stay outside it. Local workspace setup is described in [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md).

`JellyfinKit` can be reused for future iPhone and Apple TV clients; their interfaces and player integration are not implemented here.
