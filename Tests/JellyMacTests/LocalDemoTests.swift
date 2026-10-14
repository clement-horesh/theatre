import AppKit
import Foundation
import XCTest
import JellyfinKit
@testable import JellyMac

final class LocalDemoTests: XCTestCase {
    func testByteRangesForPlayerSeeking() {
        XCTAssertEqual(LocalDemoServer.byteRange("bytes=0-1", length: 100), 0..<2)
        XCTAssertEqual(LocalDemoServer.byteRange("bytes=40-", length: 100), 40..<100)
        XCTAssertEqual(LocalDemoServer.byteRange("bytes=-10", length: 100), 90..<100)
        XCTAssertEqual(LocalDemoServer.byteRange("bytes=90-200", length: 100), 90..<100)
        XCTAssertNil(LocalDemoServer.byteRange("bytes=100-", length: 100))
        XCTAssertNil(LocalDemoServer.byteRange("bytes=20-10", length: 100))
        XCTAssertNil(LocalDemoServer.byteRange("bytes=0-1,3-4", length: 100))
    }

    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    @MainActor
    private func signedIn(_ server: LocalDemoServer) async throws -> JellyfinClient {
        let address = try await server.start()
        XCTAssertEqual(address.host, "127.0.0.1")
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "integration-test")
        let session = try await api.authenticate(username: "demo", password: "demo")
        return try api.authenticated(with: session)
    }

    @MainActor
    func testLoginCatalogPaginationSearchAndExternalSubtitles() async throws {
        let server = LocalDemoServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let unauthenticated = try JellyfinClient(address: client.serverURL.absoluteString, deviceID: "bad-login")
        do { _ = try await unauthenticated.authenticate(username: "demo", password: "wrong"); XCTFail("Bad password accepted") }
        catch JellyfinError.unauthorized {}
        let page = try await client.videos(limit: 2)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.totalCount, 6)
        let next = try await client.videos(startIndex: 2, limit: 2)
        XCTAssertEqual(next.items.count, 2)
        XCTAssertNotEqual(next.items[0].id, page.items[0].id)
        let search = try await client.videos(search: "multitrack")
        XCTAssertEqual(search.items.first?.name, "multitrack-h264.mkv")
        let mp4 = try await client.videos(search: "h264-aac.mp4")
        let stream = try await client.playback(for: XCTUnwrap(mp4.items.first))
        XCTAssertEqual(stream.externalSubtitles.count, 1)
        let (subtitles, response) = try await URLSession.shared.data(from: stream.externalSubtitles[0].url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: subtitles, encoding: .utf8)?.contains("JellyMac subtitle test") == true)
        try await client.reportPlayback(.started, stream: stream, seconds: 0)
        try await client.reportPlayback(.progress, stream: stream, seconds: 3)
        try await client.reportPlayback(.stopped, stream: stream, seconds: 3)
        // The fixture reports its actual capability, rather than pretending to transcode.
        do { _ = try await client.playback(for: XCTUnwrap(mp4.items.first), compatibleOnly: true); XCTFail("Demo cannot transcode") }
        catch JellyfinError.noPlayableSource {}
        try await client.logout()
    }

    @MainActor
    func testFilesAddedRemovedAndNestedAreDiscoveredWithoutRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = LocalDemoServer(mediaDirectory: directory)
        let client = try await signedIn(server)
        defer { server.stop() }
        let empty = try await client.videos()
        XCTAssertEqual(empty.totalCount, 0)
        let before = await server.librarySignature()
        let added = directory.appendingPathComponent("My own video.mkv")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("multitrack-h264.mkv"), to: added)
        let nested = directory.appendingPathComponent("Shows")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: added, to: nested.appendingPathComponent(added.lastPathComponent))
        // Files outside the selected media folder must never be included via symlinks.
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("outside.mkv"), withDestinationURL: fixtures.appendingPathComponent("hevc-ac3.mkv"))
        let after = await server.librarySignature()
        XCTAssertNotEqual(before, after)
        let page = try await client.videos()
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(Set(page.items.map(\.id)).count, 2)
        XCTAssertEqual(page.items[0].name, "My own video.mkv")
        try FileManager.default.removeItem(at: added)
        let removed = try await client.videos()
        XCTAssertEqual(removed.totalCount, 1)
    }

    @MainActor
    func testLargeFileRangeAndHeadUseBoundedReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.mkv")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let size: UInt64 = 3 * 1024 * 1024 * 1024
        try handle.truncate(atOffset: size)
        try handle.seek(toOffset: size - 4)
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()
        let server = LocalDemoServer(mediaDirectory: directory)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos()
        let stream = try await client.playback(for: XCTUnwrap(page.items.first))
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=-4", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes \(size - 4)-\(size - 1)/\(size)")
        request.httpMethod = "HEAD"
        request.setValue(nil, forHTTPHeaderField: "Range")
        let (head, headResponse) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(size))
    }

    @MainActor
    func testVLCPlaysAllRepresentativeFormatsAndTrackControls() async throws {
        _ = NSApplication.shared
        let server = LocalDemoServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos()
        XCTAssertEqual(page.items.count, 6)
        let player = VLCPlaybackController()
        player.setVolume(0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = player.videoView
        window.orderBack(nil)
        defer { player.stop(); window.close() }
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
                try await waitUntil { player.audioTracks.filter { $0.id >= 0 }.count >= 2 && player.subtitleTracks.contains { $0.id >= 0 } }
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
    func testVideoLayerFitsAfterRepeatedGrowingAndShrinking() async throws {
        _ = NSApplication.shared
        let server = LocalDemoServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let player = VLCPlaybackController()
        let surface = VideoSurfaceView(videoView: player.videoView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.orderBack(nil)
        defer { player.stop(); window.close() }
        player.setVolume(0)
        player.play(try await client.playback(for: XCTUnwrap(page.items.first)))
        try await waitUntil { player.seconds > 0.3 }
        player.togglePlayback()
        try await waitUntil { !player.isPlaying }
        let output = try XCTUnwrap(player.videoView.subviews.first)
        let layer = try XCTUnwrap(output.layer)
        surface.layoutSubtreeIfNeeded()
        let original = layer.frame
        for size in [CGSize(width: 1400, height: 900), CGSize(width: 400, height: 260),
                     CGSize(width: 1200, height: 500), CGSize(width: 400, height: 260)] {
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
        let server = LocalDemoServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        var stream = try await client.playback(for: XCTUnwrap(page.items.first))
        stream.resumePositionSeconds = 3
        let player = VLCPlaybackController()
        player.setVolume(0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let surface = VideoSurfaceView(videoView: player.videoView)
        window.contentView = surface
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil) }
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
        let server = LocalDemoServer(mediaDirectory: fixtures)
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
    func testPlayerWindowFitsVideoAndLocksHorizontalAndVerticalResizing() throws {
        _ = NSApplication.shared
        let controller = PlayerWindowController(model: MemorySessionStore().makeModel())
        let window = try XCTUnwrap(controller.window)
        defer { controller.closeWithoutCallback() }
        for ratio in [2.4, 4.0 / 3.0, 9.0 / 16.0, 16.0 / 9.0] {
            controller.fitVideo(aspectRatio: ratio)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.width / window.frame.height, ratio, accuracy: 0.001)
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.width / content.bounds.height, ratio, accuracy: 0.001)
            XCTAssertEqual(window.aspectRatio.width / window.aspectRatio.height, ratio, accuracy: 0.001)
            for proposed in [NSSize(width: window.frame.width + 100, height: window.frame.height),
                             NSSize(width: window.frame.width, height: window.frame.height + 100)] {
                let constrained = controller.windowWillResize(window, to: proposed)
                XCTAssertEqual(constrained.width / constrained.height, ratio, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(constrained.width, window.minSize.width)
            }
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            let fullscreen = NSSize(width: 1440, height: 900)
            XCTAssertEqual(controller.windowWillResize(window, to: fullscreen), fullscreen)
            controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
            XCTAssertEqual(window.frame.width / window.frame.height, ratio, accuracy: 0.001)
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
