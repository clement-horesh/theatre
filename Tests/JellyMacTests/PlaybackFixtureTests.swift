import AppKit
import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class PlaybackFixtureTests: XCTestCase {
    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    @MainActor
    private func signedIn(_ server: PlaybackFixtureServer) async throws -> JellyfinClient {
        let address = try await server.start()
        XCTAssertEqual(address.host, "127.0.0.1")
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "integration-test")
        let session = try await api.authenticate(username: "demo", password: "demo")
        return try api.authenticated(with: session)
    }

    @MainActor
    func testLoginCatalogPaginationSearchAndExternalSubtitles() async throws {
        let server = PlaybackFixtureServer(mediaDirectory: fixtures)
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

}
