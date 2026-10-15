import AVFoundation
import AppKit
import CoreMedia
import XCTest

@testable import JellyMac
@testable import JellyfinKit

final class PlayerPresentationTests: XCTestCase {
    @MainActor
    func testAppleVideoLayerIsTheViewsBackingLayerAndResizesWithAppKit() {
        let playback = ApplePlaybackController()
        defer { playback.stop() }
        let view = ApplePlayerView.LayerView(playback: playback)
        XCTAssertTrue(view.layer === playback.layer)
        for size in [
            CGSize(width: 960, height: 540), CGSize(width: 360, height: 202.5), CGSize(width: 1280, height: 720),
        ] {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(playback.layer.bounds.size, size)
        }
    }

    func testDefaultAppearancePreservesEmbeddedStylingAndCustomSettingsMapToBothPlayers() throws {
        XCTAssertTrue(SubtitleAppearance.standard.vlcOptions.isEmpty)
        XCTAssertNil(SubtitleAppearance.standard.nativeStyle)
        let appearance = SubtitleAppearance(position: .raised, size: .large, color: .yellow, background: true)
        XCTAssertEqual(
            try JSONDecoder().decode(SubtitleAppearance.self, from: JSONEncoder().encode(appearance)), appearance)
        XCTAssertTrue(appearance.vlcOptions.contains("--sub-margin=60"))
        XCTAssertTrue(appearance.vlcOptions.contains("--freetype-rel-fontsize=16"))
        XCTAssertTrue(appearance.vlcOptions.contains("--freetype-color=16776960"))
        XCTAssertTrue(appearance.vlcOptions.contains("--freetype-background-opacity=180"))
        let style = try XCTUnwrap(appearance.nativeStyle?.textMarkupAttributes)
        XCTAssertEqual(style[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double], [1, 1, 1, 0])
        XCTAssertEqual(
            style[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String]
                as? Double,
            85)
    }

    @MainActor
    func testAppearancePersistsAcrossPlayersWithoutChangingVolumeOrSpeed() throws {
        let suite = "local.theatre.subtitle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults)
        defer { player.stop() }
        player.setVolume(35)
        player.setRate(1.5)
        let appearance = SubtitleAppearance(position: .higher, size: .extraLarge, color: .cyan)
        player.applySubtitleAppearance(appearance)
        XCTAssertEqual(player.subtitleAppearance, appearance)
        XCTAssertEqual(player.volume, 35)
        XCTAssertEqual(player.rate, 1.5)
        let reopened = PlaybackController(defaults: defaults)
        defer { reopened.stop() }
        XCTAssertEqual(reopened.subtitleAppearance, appearance)
        reopened.applySubtitleAppearance(.standard)
        XCTAssertEqual(player.subtitleAppearance, appearance)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SubtitleAppearance.self, from: XCTUnwrap(defaults.data(forKey: SubtitleAppearance.defaultsKey))),
            .standard)
    }

    @MainActor
    func testNativeHandoffKeepsPausedPositionAndSupportsSeekingWithoutOpeningAWindow() async throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("h264-aac.mp4")
        let suite = "local.theatre.presentation-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults)
        defer { player.stop() }
        player.setRate(1.5)
        player.setVolume(0)
        let item = try await player.applePlayback.prepare(url: url)
        XCTAssertFalse(player.usesApplePlayback, "Preparing an AirPlay choice must not switch the local player")
        XCTAssertEqual(player.applePlayback.player.rate, 0)
        XCTAssertEqual(player.applePlayback.player.volume, 0)
        let stream = PlaybackStream(
            url: url, itemID: "movie", mediaSourceID: "source", playSessionID: "session", method: "Transcode")
        player.playApple(item, stream: stream, at: 2, playing: false)
        try await waitUntil { player.seconds > 1.9 && player.canSeek }
        XCTAssertTrue(player.usesApplePlayback)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.seconds, 2, accuracy: 0.1)
        XCTAssertEqual(player.duration, 8, accuracy: 0.1)
        XCTAssertEqual(player.rate, 1.5)
        player.applySubtitleAppearance(.init(size: .large))
        XCTAssertEqual(item.textStyleRules?.count, 1)
        XCTAssertTrue(player.applePlayback.player.currentItem === item)
        player.seek(to: 4)
        try await waitUntil { abs(player.applePlayback.player.currentTime().seconds - 4) < 0.1 }
        XCTAssertFalse(player.isPlaying)
        player.stop(preservingApplePlayback: true)
        XCTAssertTrue(player.usesApplePlayback)
        XCTAssertTrue(player.applePlayback.player.currentItem === item)
        XCTAssertEqual(player.applePlayback.player.rate, 0)
        player.playApple(item, stream: stream, at: 1, playing: false, preserveTracks: false)
        try await waitUntil { abs(player.applePlayback.player.currentTime().seconds - 1) < 0.1 }
        player.stop()
        XCTAssertNil(player.applePlayback.player.currentItem)
        XCTAssertFalse(player.usesApplePlayback)
    }

    @MainActor
    func testCancelledNativePreparationDoesNotLeaveAnItemLoaded() async throws {
        let player = ApplePlaybackController()
        defer { player.stop() }
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("h264-aac.mp4")
        let task = Task { try await player.prepare(url: url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled preparation must not switch playback")
        } catch is CancellationError {}
        XCTAssertNil(player.player.currentItem)
    }

    @MainActor
    func testPlaybackPreferencesPersistAndTrackMatchingPrefersTheExactVariant() throws {
        let name = "local.theatre.preferences-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertTrue(preferences.automaticallyPlayNext)
        preferences.automaticallyPlayNext = false
        preferences.audioLanguage = "fr"
        preferences.subtitleLanguage = "off"
        let restored = PlaybackPreferences(defaults: defaults)
        XCTAssertFalse(restored.automaticallyPlayNext)
        XCTAssertEqual(restored.audioLanguage, "fr")
        XCTAssertEqual(restored.subtitleLanguage, "off")
        XCTAssertEqual(PlayerTrack(id: 0, name: "English", language: "eng").languageCode, "en")
        let choice = PlayerTrack(id: 10, name: "English AD", language: "en")
        let tracks = [
            PlayerTrack(id: 0, name: "English", language: "en"), PlayerTrack(id: 1, name: "English AD", language: "en"),
        ]
        XCTAssertEqual(choice.match(in: tracks)?.id, 1)
        XCTAssertEqual(PlayerTrack(id: 4, name: "Different display name", language: "en-US").match(in: tracks)?.id, 0)
    }

    @MainActor
    func testVLCEndStartsTheFollowingVideoWithoutAnotherPlayAction() async throws {
        _ = NSApplication.shared
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("h264-aac.mp4")
        let player = PlaybackController()
        player.setVolume(0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = VideoSurfaceView(videoView: player.videoView)
        defer {
            player.stop()
            window.close()
        }
        var nextStarted = false
        let next = PlaybackStream(
            url: url, itemID: "next", mediaSourceID: "next", playSessionID: "next", method: "DirectPlay")
        player.onEnded = {
            guard !nextStarted else { return }
            nextStarted = true
            player.play(next)
        }
        var first = PlaybackStream(
            url: url, itemID: "first", mediaSourceID: "first", playSessionID: "first", method: "DirectPlay")
        first.resumePositionSeconds = 7
        player.play(first)
        try await waitUntil { nextStarted }
        XCTAssertTrue(nextStarted, "Natural end must trigger continuation")
        try await waitUntil { nextStarted && player.isPlaying && player.seconds > 0.3 && player.seconds < 6 }
        XCTAssertTrue(player.isPlaying, "The following video must play without another button press")
        XCTAssertFalse(player.hasEnded)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for the native player")
    }
}
