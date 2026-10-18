import AppKit
import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

/// These tests intentionally create native player windows. Run with Scripts/test.sh --interactive.
final class PlayerIntegrationTests: XCTestCase {
    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    @MainActor
    private func signedIn(_ server: PlaybackFixtureServer) async throws -> JellyfinClient {
        let address = try await server.start()
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "player-test")
        let session = try await api.authenticate(username: "demo", password: "demo")
        return try api.authenticated(with: session)
    }

    @MainActor
    func testVideoLayerFitsAfterRepeatedGrowingAndShrinking() async throws {
        _ = NSApplication.shared
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let player = PlaybackController()
        let surface = VideoSurfaceView(videoView: player.videoView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.orderBack(nil)
        defer {
            player.stop()
            window.close()
        }
        player.setVolume(0)
        player.play(try await client.playback(for: XCTUnwrap(page.items.first)))
        try await waitUntil { player.seconds > 0.3 }
        player.togglePlayback()
        try await waitUntil { !player.isPlaying }
        let output = try XCTUnwrap(player.videoView.subviews.first)
        let layer = try XCTUnwrap(output.layer)
        surface.layoutSubtreeIfNeeded()
        let original = layer.frame
        for size in [
            CGSize(width: 1400, height: 900), CGSize(width: 400, height: 260),
            CGSize(width: 1200, height: 500), CGSize(width: 400, height: 260),
        ] {
            window.setContentSize(size)
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(player.videoView.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(player.videoView.bounds.height, size.height, accuracy: 1)
            XCTAssertLessThanOrEqual(layer.frame.width, size.width + 1)
            XCTAssertLessThanOrEqual(layer.frame.height, size.height + 1)
            XCTAssertEqual(output.frame.width, size.width, accuracy: 1)
            XCTAssertEqual(output.frame.height, size.height, accuracy: 1)
            XCTAssertEqual(layer.frame.width, size.width, accuracy: 1)
            XCTAssertEqual(layer.frame.height, size.height, accuracy: 1)
            XCTAssertEqual(layer.frame.midX, size.width / 2, accuracy: 1)
            XCTAssertEqual(layer.frame.midY, size.height / 2, accuracy: 1)
        }
        XCTAssertEqual(layer.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(layer.frame.height, original.height, accuracy: 1)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testVLCResumesAtSavedPositionInsteadOfStartingAtZero() async throws {
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        var stream = try await client.playback(for: XCTUnwrap(page.items.first))
        stream.resumePositionSeconds = 3
        let player = PlaybackController()
        player.setVolume(0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        let surface = VideoSurfaceView(videoView: player.videoView)
        window.contentView = surface
        window.orderFront(nil)
        defer {
            player.stop()
            window.orderOut(nil)
        }
        player.play(stream)
        try await waitUntil { player.seconds >= 3 && player.canSeek }
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertGreaterThan(player.seconds, 5.5)
        XCTAssertTrue(player.isPlaying)
        player.stop()
        stream.resumePositionSeconds = 0
        player.play(stream)
        try await waitUntil { player.seconds > 0.1 }
        XCTAssertLessThan(player.seconds, 2)
    }

    @MainActor
    func testPlayerOpensItsOwnWindowAndClosingStopsPlayback() async throws {
        _ = NSApplication.shared
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let address = try await server.start()
        defer { server.stop() }
        let model = MemorySessionStore().makeModel()
        model.address = address.absoluteString
        model.username = "demo"
        model.password = "demo"
        model.connect()
        try await waitUntil { model.client != nil }
        let client = try XCTUnwrap(model.client)
        let page = try await client.videos(search: "h264-aac.mp4")
        let video = try XCTUnwrap(page.items.first)
        defer { model.signOut() }
        model.playback.setVolume(0)
        model.play(video)
        try await waitUntil { model.playback.seconds > 0.3 }
        let window = try XCTUnwrap(model.playback.videoView.window)
        XCTAssertEqual(window.title, "h264-aac.mp4 — Player")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.width / window.frame.height, 16.0 / 9.0, accuracy: 0.001)
        window.performClose(nil)
        XCTAssertNil(model.currentVideo)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertFalse(model.isVideoFullscreen)
        model.play(video)
        try await waitUntil { model.playback.seconds > 0.3 }
        let reopened = try XCTUnwrap(model.playback.videoView.window)
        XCTAssertFalse(reopened === window)
        model.signOut()
        XCTAssertFalse(reopened.isVisible)
        XCTAssertFalse(model.playback.isPlaying)
    }

    @MainActor
    func testPlayerWindowFitsVideoAndConfiguresNativeAspectConstraint() throws {
        _ = NSApplication.shared
        let model = MemorySessionStore().makeModel()
        let controller = PlayerWindowController(session: model.playerSession)
        let window = try XCTUnwrap(controller.window)
        defer { controller.closeWithoutCallback() }
        for ratio in [2.4, 4.0 / 3.0, 9.0 / 16.0, 16.0 / 9.0] {
            controller.fitVideo(aspectRatio: ratio)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.width / window.frame.height, ratio, accuracy: 0.001)
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.width / content.bounds.height, ratio, accuracy: 0.001)
            XCTAssertEqual(window.aspectRatio.width / window.aspectRatio.height, ratio, accuracy: 0.001)
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
            XCTAssertEqual(window.frame.width / window.frame.height, ratio, accuracy: 0.001)
        }
    }

    @MainActor
    func testCompatibleRetryKeepsCurrentPositionAndPausedState() async throws {
        _ = NSApplication.shared
        let server = PlaybackFixtureServer(mediaDirectory: fixtures, allowsCompatiblePlayback: true)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let video = try XCTUnwrap(page.items.first)
        let suite = "local.theatre.retry-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = PlaybackSession(preferences: PlaybackPreferences(defaults: defaults))
        session.client = client
        session.playback.setVolume(0)
        defer { session.stopPlayback() }
        session.play(video)
        try await waitUntil { session.playback.seconds > 0.3 && session.playback.canSeek }
        session.playback.setPlaying(false)
        try await waitUntil { !session.playback.isPlaying }
        session.playback.seek(to: 3)
        session.retryCompatible()
        try await waitUntil {
            !session.isStartingPlayback && !session.playback.isPreparing
                && session.playback.canSeek && session.playback.seconds >= 2.9
        }
        XCTAssertEqual(session.playback.seconds, 3, accuracy: 0.3)
        XCTAssertFalse(session.playback.isPlaying)
        session.playback.setPlaying(true)
        try await waitUntil { session.playback.isPlaying && session.playback.seconds > 3.3 }
        let position = session.playback.seconds
        session.retryCompatible()
        try await waitUntil { session.playback.isPlaying && session.playback.seconds >= position - 0.2 }
        XCTAssertGreaterThan(session.playback.seconds, 3)
        await session.shutdown()
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
