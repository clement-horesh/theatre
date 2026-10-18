import Combine
import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class DownloadQueueTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Download queue did not reach the expected state")
        throw URLError(.timedOut)
    }

    @MainActor
    func testQueueBoundsWorkAndProgressDoesNotInvalidateTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for name in ["one", "two", "three"] {
            try Data(repeating: 42, count: 8 * 1024 * 1024).write(to: media.appendingPathComponent("\(name).mp4"))
        }
        let server = PlaybackFixtureServer(mediaDirectory: media, chunkDelay: 0.08)
        let address = try await server.start()
        defer { server.stop() }
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "queue-test")
        let client = try api.authenticated(with: await api.authenticate(username: "demo", password: "demo"))
        let videos = try await client.videos().items
        XCTAssertEqual(videos.count, 3)
        let downloads = DownloadManager(root: root.appendingPathComponent("downloads"), maximumConcurrentDownloads: 1)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        for video in videos { downloads.start(video) }
        XCTAssertEqual(downloads.records.filter { $0.state == .preparing }.count, 1)
        XCTAssertEqual(downloads.records.filter { $0.state == .queued }.count, 2)
        try await waitUntil { (downloads.record(for: videos[0])?.received ?? 0) > 0 }

        let store = MemorySessionStore()
        store.saved = SavedSession(address: address.absoluteString, deviceID: client.deviceID, session: client.session!)
        let model = AppModel(sessionStore: store, defaults: store.defaults, downloads: downloads)
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        let received = downloads.record(for: videos[0])!.received
        let revision = downloads.catalogRevision
        try await waitUntil { (downloads.record(for: videos[0])?.received ?? 0) > received }
        XCTAssertEqual(downloads.catalogRevision, revision)
        XCTAssertEqual(invalidations, 0)
        withExtendedLifetime(observation) {}

        model.showsDownloads = true
        XCTAssertFalse(model.canPlay(videos[0]), "Keyboard and button actions must reject incomplete downloads")
        await downloads.pause(try XCTUnwrap(downloads.record(for: videos[1])))
        XCTAssertEqual(downloads.record(for: videos[1])?.state, .paused)
        await downloads.pause(try XCTUnwrap(downloads.record(for: videos[0])))
        try await waitUntil { (downloads.record(for: videos[2])?.received ?? 0) > 0 }
        XCTAssertEqual(downloads.records.filter { $0.state == .downloading }.count, 1)
        await downloads.remove(try XCTUnwrap(downloads.record(for: videos[2])))
        XCTAssertNil(downloads.record(for: videos[2]))
        downloads.start(videos[1])
        try await waitUntil { (downloads.record(for: videos[1])?.received ?? 0) > 0 }
        await downloads.shutdown()
        XCTAssertTrue(downloads.records.allSatisfy { $0.state == .paused })
    }

    @MainActor
    func testRapidAccountChangesPreserveTheLatestProgressAndExistingCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try JSONDecoder().decode(
            JellyfinSession.self, from: Data(#"{"userID":"one","username":"test","accessToken":"test"}"#.utf8))
        let client = try JellyfinClient(address: "https://catalog.test", deviceID: "catalog-test", session: session)
        let video = VideoItem(id: "movie", name: "Movie", type: "Movie")
        var record = DownloadRecord(id: UUID(), video: video)
        record.state = .complete
        let directory = root.appendingPathComponent(DownloadManager.accountKey(client))
        let folder = directory.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent(record.videoFile))
        let manifest = directory.appendingPathComponent("catalog.json")
        let original = try JSONEncoder().encode([record])
        try original.write(to: manifest)

        // Leaving before the initial read completes must not persist an empty catalog.
        let downloads = DownloadManager(root: root)
        downloads.configure(client: client)
        downloads.configure(client: nil)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        XCTAssertEqual(downloads.titles.map(\.id), [video.id])
        for seconds in 1...30 {
            downloads.saveProgress(itemID: video.id, seconds: Double(seconds), duration: 60, paused: true, force: true)
        }
        downloads.configure(client: nil)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        await downloads.flush()
        XCTAssertEqual(downloads.playbackStream(for: video)?.resumePositionSeconds, 30)
        let persisted = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(persisted.first?.progress?.data.playbackPositionTicks, 300_000_000)

        let removal = Task { await downloads.remove(record) }
        try await waitUntil { downloads.record(for: video) == nil }
        downloads.configure(client: nil)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        await removal.value
        await downloads.flush()
        XCTAssertTrue(downloads.titles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(downloads.records.first?.state, .removed)
        XCTAssertEqual(downloads.records.first?.progress?.pendingSync, true)
        await downloads.shutdown()
    }

    @MainActor
    func testUnreadableCatalogIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try JSONDecoder().decode(
            JellyfinSession.self, from: Data(#"{"userID":"one","username":"test","accessToken":"test"}"#.utf8))
        let client = try JellyfinClient(address: "https://catalog.test", deviceID: "test", session: session)
        let directory = root.appendingPathComponent(DownloadManager.accountKey(client))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("catalog.json")
        let original = Data("unreadable catalog".utf8)
        try original.write(to: manifest)
        let downloads = DownloadManager(root: root)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        XCTAssertNotNil(downloads.errorMessage)
        downloads.configure(client: nil)
        await downloads.waitUntilReady()
        await downloads.flush()
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    @MainActor
    func testFileWorkLeavesTheMainActorResponsive() async throws {
        let files = DownloadFileIO()
        let started = expectation(description: "Background file operation started")
        let release = DispatchSemaphore(value: 0)
        let operation = Task {
            try await files.perform {
                started.fulfill()
                let isMain = Thread.isMainThread
                _ = release.wait(timeout: .now() + 2)
                return isMain
            }
        }
        await fulfillment(of: [started], timeout: 1)
        // This actor must be able to run while the file queue is blocked.
        release.signal()
        let ranOnMain = try await operation.value
        XCTAssertFalse(ranOnMain)
    }

    @MainActor
    func testCompletionFailureAndImmediateRedownloadAdvanceTheQueue() async throws {
        for permitted in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Queue-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let media = root.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let bytes = Data(repeating: 42, count: 1024)
            for name in ["one", "two", "three"] { try bytes.write(to: media.appendingPathComponent("\(name).mp4")) }
            let server = PlaybackFixtureServer(mediaDirectory: media, allowsDownloads: permitted)
            let address = try await server.start()
            defer { server.stop() }
            let api = try JellyfinClient(address: address.absoluteString, deviceID: "queue-test")
            let client = try api.authenticated(with: await api.authenticate(username: "demo", password: "demo"))
            let videos = try await client.videos().items
            let downloads = DownloadManager(
                root: root.appendingPathComponent("downloads"), maximumConcurrentDownloads: 1)
            downloads.configure(client: client)
            await downloads.waitUntilReady()
            for video in videos { downloads.start(video) }
            try await waitUntil {
                downloads.records.count == 3
                    && downloads.records.allSatisfy { $0.state == (permitted ? .complete : .failed) }
            }
            if permitted {
                for video in videos {
                    let stream = try XCTUnwrap(downloads.playbackStream(for: video))
                    XCTAssertEqual(try Data(contentsOf: stream.url), bytes)
                }
                let video = videos[0]
                downloads.saveProgress(itemID: video.id, seconds: 1, duration: 60, paused: true, force: true)
                let record = try XCTUnwrap(downloads.record(for: video))
                let removal = Task { await downloads.remove(record) }
                try await waitUntil { downloads.record(for: video) == nil }
                downloads.start(video)
                await removal.value
                try await waitUntil { downloads.record(for: video)?.state == .complete }
                let stream = try XCTUnwrap(downloads.playbackStream(for: video))
                XCTAssertEqual(try Data(contentsOf: stream.url), bytes)
            }
            await downloads.shutdown()
        }
    }

    @MainActor
    func testResumingWithAnExpiredHeaderRetriesFreshWithoutBlockingTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Resume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bytes = Data(repeating: 42, count: 8 * 1024 * 1024)
        try bytes.write(to: media.appendingPathComponent("large.mp4"))
        let first = PlaybackFixtureServer(mediaDirectory: media, chunkDelay: 0.04)
        let address = try await first.start()
        defer { first.stop() }
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "resume-test")
        let client = try api.authenticated(with: await api.authenticate(username: "demo", password: "demo"))
        let page = try await client.videos()
        let video = try XCTUnwrap(page.items.first)
        let catalog = root.appendingPathComponent("downloads")
        let downloads = DownloadManager(root: catalog, maximumConcurrentDownloads: 1)
        downloads.configure(client: client)
        await downloads.waitUntilReady()
        downloads.start(video)
        try await waitUntil { (downloads.record(for: video)?.received ?? 0) > 0 }
        await downloads.pause(try XCTUnwrap(downloads.record(for: video)))
        await downloads.shutdown()
        await first.expireSessions()
        let fresh = try api.authenticated(with: await api.authenticate(username: "demo", password: "demo"))
        XCTAssertNotEqual(client.session?.accessToken, fresh.session?.accessToken)
        let reopened = DownloadManager(root: catalog, maximumConcurrentDownloads: 1)
        reopened.configure(client: fresh)
        await reopened.waitUntilReady()
        reopened.start(video)
        try await waitUntil {
            reopened.record(for: video)?.state == .complete || reopened.record(for: video)?.state == .failed
        }
        XCTAssertEqual(reopened.record(for: video)?.state, .complete, reopened.record(for: video)?.error ?? "")
        let rejected = await first.rejectedDownloads()
        XCTAssertGreaterThan(rejected, 0, "The stale resume header must exercise the fresh-request fallback")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.playbackStream(for: video)).url), bytes)
        await reopened.shutdown()
    }
}
