import AppKit
import Foundation
import JellyfinKit
import XCTest

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
        do {
            _ = try await unauthenticated.authenticate(username: "demo", password: "wrong")
            XCTFail("Bad password accepted")
        } catch JellyfinError.unauthorized {}
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
        do {
            _ = try await client.playback(for: XCTUnwrap(mp4.items.first), compatibleOnly: true)
            XCTFail("Demo cannot transcode")
        } catch JellyfinError.noPlayableSource {}
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
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("outside.mkv"),
            withDestinationURL: fixtures.appendingPathComponent("hevc-ac3.mkv"))
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
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
            "bytes \(size - 4)-\(size - 1)/\(size)")
        request.httpMethod = "HEAD"
        request.setValue(nil, forHTTPHeaderField: "Range")
        let (head, headResponse) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(size))
    }

}
