# Playback validation

Validation uses original generated fixtures and loopback servers. Default checks are muted, keep their drawables hidden, and never access the user's Keychain. They do not alter the local Jellyfin library.

## Automated coverage

Run `bash Scripts/test.sh`.

| Area | Checks |
| --- | --- |
| Formats | Real decoding and time advancement for MP4/H.264/AAC, MOV/H.264/PCM, MKV/HEVC/AC-3, AVI/MPEG-4/MP3, WebM/VP9/Opus, and MKV with multiple audio tracks and embedded subtitles. |
| Transport | Pause/resume, seeking forwards and backwards while paused, volume changes, saved resume position, natural end, and starting another video without a second Play action. |
| Tracks | Selecting audio variants and embedded subtitles, turning subtitles off, loading/selecting downloaded external SRT, and subtitle-appearance persistence. Selection checks do not establish visual rendering quality. |
| Native presentation | AVPlayer preparation without switching the active VLC engine; cancelled preparation cleanup; paused position, speed, tracks, and subtitle styling during native handoff; AVPlayerLayer aspect-fit sizing. |
| Shows | Start/Continue ordering, season boundaries, unwatched gaps, most recently played unfinished episode, special-only shows, rewatching, and completed shows. Intro ranges come from Jellyfin and are validated; missing markers remain absent. |
| Downloads | Original bytes, subtitles, offline playback after restart, interruption and retry after server recovery, native pause/resume data, low-storage failure and retry, missing-file replacement, account isolation, watch-progress persistence and synchronization. |
| Library discovery | Person-ID/name queries, role filtering, pagination, authenticated requests, and related-title ordering/deduplication. |

The representative-format check was moved from the interactive suite into the default suite. It exercises the same playback controls without displaying a window.

## Local reference check — 16 October 2026

On the user's 16-inch M1 Pro MacBook Pro, AVPlayer reported HDR playback eligibility. The built-in display reported potential extended dynamic range of 16.0 and current headroom of approximately 1.2 at the time of the check. These values describe capability and current display conditions, not a measurement of Theatre's video output.

A local 3840×2072 HEVC 10-bit reference in MKV was probed: BT.2020 primaries, PQ transfer, Dolby Vision profile 8 with HDR10-compatible base layer, E-AC-3 5.1 and TrueHD 7.1 tracks. Hidden, muted VLC playback advanced normally, reported the full video dimensions, exposed both audio/subtitle tracks, and supported paused seeking. This establishes decoding/transport, not Dolby Vision processing, visible HDR accuracy, or receiver output.

Repeat with another local reference without changing Jellyfin watch history:

```sh
THEATRE_VALIDATION_MEDIA='/absolute/path/to/reference.mkv' bash Scripts/test.sh --filter PlaybackValidationTests.testReferenceMediaWhenProvided
```

## Hardware checks still required

Target hardware supplied by the user: 16-inch MacBook Pro with M1 Pro. No surround or AirPlay receiver has been specified.

The fixtures are SDR and do not establish HDR/Dolby Vision display output or multichannel receiver output. Source badges are not playback measurements.

Use a known reference title, record the display/receiver, macOS version, file container/codecs and video range, and distinguish direct playback from a server transcode.

1. **HDR / Dolby Vision:** compare a known reference with a trusted player on the same HDR display. Check black level, highlights, colors, windowed/fullscreen transitions, and an SDR display. Repeat separately for the file's Dolby Vision profile and container; one successful title does not establish every profile.
2. **Surround:** use a channel-identification clip through the intended HDMI/AirPlay receiver. Verify channel positions and the receiver's reported format. Successful AC-3 decoding alone does not establish 5.1/7.1 or Atmos output.
3. **Subtitles:** inspect external SRT, styled ASS/SSA, and image subtitles on real footage. Check timing, accented/non-Latin text, placement and readability. Styled/image tracks may ignore appearance overrides.
4. **Picture in Picture:** drag and resize the system window, restore the player, close PiP, and repeat while paused and after an episode transition. Verify position, sound, aspect ratio and absence of duplicate audio.
5. **AirPlay:** cancel the picker without selecting a device; then connect a real receiver, pause/seek, change episode, disconnect and reconnect. Check that local playback is uninterrupted on cancellation and there is only one audible output after handoff.
6. **Keyboard / VoiceOver:** traverse cards with Tab and arrows, open with Return, return with Escape, check offscreen cards and person pages, and inspect labels with VoiceOver. Native keyboard navigation follows the user's macOS keyboard settings.

Run `bash Scripts/test.sh --interactive` only when native test windows and the Keychain check are appropriate. Physical receiver and image-quality checks require the actual devices and reference footage.
