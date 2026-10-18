import AppKit
import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class DownloadTests: XCTestCase {
    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-DownloadTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor
    private func signedIn(_ server: PlaybackFixtureServer) async throws -> JellyfinClient {
        let address = try await server.start()
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "download-tests")
        return try api.authenticated(with: await api.authenticate(username: "demo", password: "demo"))
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Download did not reach the expected state")
    }

    @MainActor
    func testOriginalDownloadPersistsSubtitlesAndPlaysWithTheServerStopped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let video = try XCTUnwrap(page.items.first)
        let downloads = DownloadManager(root: root)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil {
            downloads.record(for: video)?.state == .complete || downloads.record(for: video)?.state == .failed
        }
        XCTAssertEqual(downloads.record(for: video)?.state, .complete, downloads.record(for: video)?.error ?? "")
        await downloads.shutdown()
        server.stop()

        let reopened = DownloadManager(root: root)
        reopened.configure(client: client)
        await reopened.waitUntilReady()
        let store = MemorySessionStore()
        store.saved = SavedSession(
            address: client.serverURL.absoluteString, deviceID: client.deviceID, session: try XCTUnwrap(client.session))
        let suite = "local.theatre.offline-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(sessionStore: store, defaults: defaults, downloads: reopened)
        model.showsDownloads = true
        await model.loadVideos()
        XCTAssertNotNil(model.client, "Offline launch must restore the saved session without reauthentication")
        XCTAssertEqual(model.downloads.titles.map(\.id), [video.id])
        let stream = try XCTUnwrap(reopened.playbackStream(for: video))
        XCTAssertTrue(stream.url.isFileURL)
        XCTAssertEqual(
            try Data(contentsOf: stream.url), try Data(contentsOf: fixtures.appendingPathComponent("h264-aac.mp4")))
        XCTAssertEqual(stream.externalSubtitles.count, 1)
        XCTAssertTrue(try String(contentsOf: stream.externalSubtitles[0].url).contains("JellyMac subtitle test"))
        let manifest = try String(contentsOf: XCTUnwrap(reopened.directory).appendingPathComponent("catalog.json"))
        XCTAssertFalse(
            manifest.contains(client.session!.accessToken), "Credentials must never enter the download catalog")

        _ = NSApplication.shared
        let player = PlaybackController()
        player.setVolume(0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = VideoSurfaceView(videoView: player.videoView)
        defer {
            player.stop()
            window.close()
        }
        player.play(stream)
        try await waitUntil { player.seconds > 0.3 || player.errorMessage != nil }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isPlaying)
        try await waitUntil { player.subtitleTracks.contains { $0.id >= 0 } }
        let subtitles = try XCTUnwrap(player.subtitleTracks.first { $0.id >= 0 })
        player.selectSubtitle(subtitles.id, remember: false)
        XCTAssertEqual(player.selectedSubtitle, subtitles.id)
        player.stop()

        reopened.saveProgress(itemID: video.id, seconds: 3, duration: 8, paused: true, force: true)
        await reopened.flush()
        let restored = DownloadManager(root: root)
        restored.configure(client: client)
        await restored.waitUntilReady()
        XCTAssertEqual(restored.playbackStream(for: video)?.resumePositionSeconds, 3)
        var watchedElsewhere = video
        watchedElsewhere.userData = VideoUserData(
            played: false, seconds: 5,
            lastPlayedDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)))
        XCTAssertEqual(restored.playbackStream(for: watchedElsewhere)?.resumePositionSeconds, 5)
        await restored.remove(try XCTUnwrap(restored.record(for: video)))
        XCTAssertNil(restored.playbackStream(for: video))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stream.url.path))
    }

    @MainActor
    func testNativePauseCanResumeAfterReopening() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let data = Data(repeating: 42, count: 8 * 1024 * 1024)
        try data.write(to: media.appendingPathComponent("large.mp4"))
        let server = PlaybackFixtureServer(mediaDirectory: media, chunkDelay: 0.04)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos()
        let video = try XCTUnwrap(page.items.first)
        let downloads = DownloadManager(root: root.appendingPathComponent("downloads"))
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil { (downloads.record(for: video)?.received ?? 0) > 0 }
        await downloads.pause(try XCTUnwrap(downloads.record(for: video)))
        XCTAssertEqual(downloads.record(for: video)?.state, .paused)
        let resume = try XCTUnwrap(downloads.directory).appendingPathComponent(
            try XCTUnwrap(downloads.record(for: video)).id.uuidString
        ).appendingPathComponent("resume.data")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resume.path),
            "Range-capable downloads should retain native resume data")
        await downloads.shutdown()
        let reopened = DownloadManager(root: root.appendingPathComponent("downloads"))
        reopened.configure(client: client)
        await reopened.waitUntilReady()
        reopened.start(video)
        try await waitUntil {
            reopened.record(for: video)?.state == .complete || reopened.record(for: video)?.state == .failed
        }
        XCTAssertEqual(reopened.record(for: video)?.state, .complete, reopened.record(for: video)?.error ?? "")
        let stream = try XCTUnwrap(reopened.playbackStream(for: video))
        XCTAssertEqual(try Data(contentsOf: stream.url), data)
        await reopened.shutdown()
    }

    @MainActor
    func testDownloadPermissionFailureNeverCreatesAPlayableFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PlaybackFixtureServer(mediaDirectory: fixtures, allowsDownloads: false)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let video = try XCTUnwrap(page.items.first)
        let downloads = DownloadManager(root: root)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil { downloads.record(for: video)?.state == .failed }
        XCTAssertTrue(downloads.record(for: video)?.error?.contains("isn’t allowed") == true)
        XCTAssertNil(downloads.playbackStream(for: video))
        await downloads.shutdown()
    }

    @MainActor
    func testLowStorageCanBeRetriedAndRemovedFilesCanBeDownloadedAgain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos(search: "h264-aac.mp4")
        let video = try XCTUnwrap(page.items.first)
        var free: Int64 = 0
        let downloads = DownloadManager(root: root, availableSpace: { free })
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil { downloads.record(for: video)?.state == .failed }
        XCTAssertTrue(downloads.record(for: video)?.error?.contains("storage") == true)
        XCTAssertNil(downloads.playbackStream(for: video))
        free = 4 * 1024 * 1024
        downloads.start(video)
        try await waitUntil { downloads.record(for: video)?.state == .complete }
        let file = try XCTUnwrap(downloads.playbackStream(for: video)).url
        try FileManager.default.removeItem(at: file)
        await downloads.checkLocalFiles()
        XCTAssertEqual(downloads.record(for: video)?.state, .failed)
        XCTAssertEqual(downloads.record(for: video)?.received, 0)
        downloads.start(video)
        try await waitUntil { downloads.record(for: video)?.state == .complete }
        XCTAssertEqual(
            try Data(contentsOf: file), try Data(contentsOf: fixtures.appendingPathComponent("h264-aac.mp4")))
        await downloads.shutdown()
    }

    @MainActor
    func testInterruptedDownloadRetriesAfterTheServerReturnsAndAppRelaunches() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let data = Data(repeating: 42, count: 8 * 1024 * 1024)
        try data.write(to: media.appendingPathComponent("large.mp4"))
        let server = PlaybackFixtureServer(mediaDirectory: media, chunkDelay: 0.04)
        let client = try await signedIn(server)
        defer { server.stop() }
        let page = try await client.videos()
        let video = try XCTUnwrap(page.items.first)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let catalog = root.appendingPathComponent("downloads")
        let downloads = DownloadManager(root: catalog, configuration: configuration)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil { (downloads.record(for: video)?.received ?? 0) > 0 }
        server.stop()
        try await waitUntil { downloads.record(for: video)?.state == .failed }
        XCTAssertNil(downloads.playbackStream(for: video))
        await downloads.shutdown()
        let restarted = try await server.start(port: UInt16(try XCTUnwrap(client.serverURL.port)))
        XCTAssertEqual(restarted, client.serverURL)
        let reopened = DownloadManager(root: catalog)
        reopened.configure(client: client)
        await reopened.waitUntilReady()
        XCTAssertEqual(reopened.record(for: video)?.state, .failed)
        reopened.start(video)
        try await waitUntil {
            reopened.record(for: video)?.state == .complete || reopened.record(for: video)?.state == .failed
        }
        XCTAssertEqual(reopened.record(for: video)?.state, .complete, reopened.record(for: video)?.error ?? "")
        let file = try XCTUnwrap(reopened.playbackStream(for: video)).url
        XCTAssertEqual(try Data(contentsOf: file), data)
        await reopened.shutdown()
    }
    @MainActor
    func testOfflineShowsAreGroupedAndProgressIsScopedAndSyncedWithoutLosingRemovedItems() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try JSONDecoder().decode(
            JellyfinSession.self, from: Data(#"{"userID":"one","username":"test","accessToken":"test-token"}"#.utf8))
        var writes: [[String: Any]] = []
        let transport = TestURLProtocol.session { request in
            if request.httpMethod == "POST" {
                writes.append(try TestURLProtocol.body(request))
                return .json("{}")
            }
            return .json(
                #"{"Items":[{"Id":"ep1","Name":"Pilot","Type":"Episode","UserData":{"Played":false,"PlaybackPositionTicks":0}}],"TotalRecordCount":1}"#
            )
        }
        defer { transport.invalidateAndCancel() }
        let client = try JellyfinClient(
            address: "https://downloads.test/jellyfin", deviceID: "test", transport: transport, session: session)
        let show = try JSONDecoder().decode(
            VideoItem.self, from: Data(#"{"Id":"show","Name":"A Show","Type":"Series"}"#.utf8))
        let first = try JSONDecoder().decode(
            VideoItem.self,
            from: Data(
                #"{"Id":"ep1","Name":"Pilot","Type":"Episode","SeriesId":"show","SeriesName":"A Show","ParentIndexNumber":1,"IndexNumber":1,"RunTimeTicks":80000000}"#
                    .utf8))
        let second = try JSONDecoder().decode(
            VideoItem.self,
            from: Data(
                #"{"Id":"ep2","Name":"Next","Type":"Episode","SeriesId":"show","SeriesName":"A Show","ParentIndexNumber":1,"IndexNumber":2,"RunTimeTicks":80000000}"#
                    .utf8))
        var records = [
            DownloadRecord(id: UUID(), video: first, series: show),
            DownloadRecord(id: UUID(), video: second, series: show),
        ]
        let directory = root.appendingPathComponent(DownloadManager.accountKey(client))
        for index in records.indices {
            records[index].state = .complete
            records[index].nextEpisodeID = index == 0 ? second.id : nil
            let folder = directory.appendingPathComponent(records[index].id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent(records[index].videoFile))
        }
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("catalog.json"))
        let downloads = DownloadManager(root: root)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        XCTAssertEqual(downloads.titles.map(\.id), ["show"])
        XCTAssertEqual(downloads.episodes(seriesID: "show").map(\.id), ["ep1", "ep2"])
        downloads.saveProgress(itemID: "ep1", seconds: 3, duration: 8, paused: true, force: true)
        await downloads.remove(try XCTUnwrap(downloads.record(for: first)))
        XCTAssertNil(downloads.record(for: first))
        XCTAssertTrue(downloads.records.first { $0.video.id == "ep1" }?.progress?.pendingSync == true)
        downloads.synchronize()
        await downloads.pendingSync?.value
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["PlaybackPositionTicks"] as? Int, 30_000_000)
        XCTAssertEqual(writes.first?["Played"] as? Bool, false)
        XCTAssertFalse(downloads.records.contains { $0.video.id == "ep1" })
        let otherSession = try JSONDecoder().decode(
            JellyfinSession.self, from: Data(#"{"userID":"two","username":"other","accessToken":"other-token"}"#.utf8))
        let other = try client.authenticated(with: otherSession)
        downloads.configure(client: other)
        await downloads.waitUntilReady()
        XCTAssertTrue(downloads.titles.isEmpty)
        XCTAssertNil(downloads.playbackStream(for: second))
        let otherServer = try JellyfinClient(
            address: "https://another.test/jellyfin", deviceID: "test", session: session)
        XCTAssertNotEqual(DownloadManager.accountKey(client), DownloadManager.accountKey(otherServer))
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        XCTAssertEqual(downloads.episodes(seriesID: "show").map(\.id), ["ep2"])
    }

}
