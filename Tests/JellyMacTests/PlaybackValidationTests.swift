import AVFoundation
import AppKit
import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

/// Decode real fixture files and exercise transport/track controls with a muted, hidden drawable.
final class PlaybackValidationTests: XCTestCase {
    @MainActor
    func testReferenceMediaWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["THEATRE_VALIDATION_MEDIA"] else {
            throw XCTSkip(
                "Set THEATRE_VALIDATION_MEDIA to a local reference file for an additional muted decode check.")
        }
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        _ = NSApplication.shared
        print("AVPlayer HDR eligibility: \(AVPlayer.eligibleForHDRPlayback)")
        for screen in NSScreen.screens {
            print(
                "Display \(screen.localizedName): current EDR \(screen.maximumExtendedDynamicRangeColorComponentValue), potential EDR \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference EDR \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)"
            )
        }
        let player = PlaybackController()
        player.setVolume(0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = VideoSurfaceView(videoView: player.videoView)
        defer {
            player.stop()
            window.close()
        }
        var size = CGSize.zero
        player.onVideoSize = { size = $0 }
        player.play(
            PlaybackStream(
                url: url, itemID: "reference", mediaSourceID: "reference", playSessionID: "", method: "DirectPlay"))
        try await waitUntil { player.seconds > 1 && size.width > 0 || player.errorMessage != nil }
        XCTAssertNil(player.errorMessage)
        XCTAssertGreaterThan(player.seconds, 1)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertTrue(player.canSeek)
        player.setPlaying(false)
        try await waitUntil { !player.isPlaying }
        player.seek(to: 10)
        try await waitUntil { abs(player.seconds - 10) < 0.5 }
        print(
            "Reference decoded at \(Int(size.width))×\(Int(size.height)); audio tracks: \(player.audioTracks.filter { $0.id >= 0 }.count), subtitle tracks: \(player.subtitleTracks.filter { $0.id >= 0 }.count)"
        )
    }

    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    @MainActor
    private func signedIn(_ server: PlaybackFixtureServer) async throws -> JellyfinClient {
        let address = try await server.start()
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "player-test")
        let session = try await api.authenticate(username: "demo", password: "demo")
        return try api.authenticated(with: session)
    }

    @MainActor
    func testVLCPlaysAllRepresentativeFormatsAndTrackControls() async throws {
        _ = NSApplication.shared
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos()
        XCTAssertEqual(page.items.count, 6)
        let player = PlaybackController()
        player.setVolume(0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = player.videoView
        defer {
            player.stop()
            window.close()
        }
        for video in page.items {
            let stream = try await client.playback(for: video)
            XCTAssertEqual(stream.method, "DirectPlay", video.name)
            player.setVolume(0)
            player.play(stream)
            try await waitUntil { player.seconds > 0.4 || player.errorMessage != nil }
            XCTAssertNil(player.errorMessage, video.name)
            XCTAssertGreaterThan(player.seconds, 0.4, video.name)
            XCTAssertFalse(player.isPreparing, video.name)
            XCTAssertEqual(player.duration, 8, accuracy: 0.5, video.name)
            XCTAssertTrue(player.canSeek, video.name)
            player.togglePlayback()
            try await waitUntil { !player.isPlaying }
            let pausedAt = player.seconds
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(player.seconds, pausedAt, accuracy: 0.35, video.name)
            player.seek(to: 3)
            // Polling used to overwrite the requested time with VLC's cached,
            // pre-seek time as long as playback was paused.
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertFalse(player.isPlaying, video.name)
            XCTAssertEqual(player.seconds, 3, accuracy: 0.35, video.name)
            player.seek(to: 1)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(player.isPlaying, video.name)
            XCTAssertEqual(player.seconds, 1, accuracy: 0.35, video.name)
            player.seek(to: 3)
            player.togglePlayback()
            try await waitUntil { player.seconds >= 3.6 }
            player.setVolume(32)
            XCTAssertEqual(player.volume, 32)
            player.setVolume(0)
            if video.name == "multitrack-h264.mkv" {
                try await waitUntil {
                    player.audioTracks.filter { $0.id >= 0 }.count >= 2 && player.subtitleTracks.contains { $0.id >= 0 }
                }
                let audio = try XCTUnwrap(player.audioTracks.last { $0.id >= 0 })
                player.selectAudio(audio.id)
                try await waitUntil { player.selectedAudio == audio.id }
                let subtitles = try XCTUnwrap(player.subtitleTracks.first { $0.id >= 0 })
                player.selectSubtitle(subtitles.id)
                try await waitUntil { player.selectedSubtitle == subtitles.id }
                player.selectSubtitle(-1)
                try await waitUntil { player.selectedSubtitle == -1 }
            }
            if video.name == "h264-aac.mp4" {
                try await waitUntil { player.subtitleTracks.contains { $0.id >= 0 } }
            }
            player.stop()
            print("Verified VLC playback: \(video.name)")
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for playback condition")
        throw NSError(domain: "JellyMacPlaybackTests", code: 1)
    }
}
