import Foundation
import XCTest

@testable import JellyfinKit

final class BrowseCacheTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try JellyfinClient(
            address: "https://theatre.test", deviceID: "test", transport: URLSession(configuration: configuration),
            session: JellyfinSession(userID: "user", username: "Demo", accessToken: "first-account"))
    }

    func testRepeatedBrowseRequestsUseCacheAndKeepQueriesSeparate() async throws {
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, #"{"Items":[{"Id":"movie","Name":"Movie"}],"TotalRecordCount":1}"#)
        }
        let client = try client()
        let person = try JSONDecoder().decode(VideoPerson.self, from: Data(#"{"Id":"actor","Name":"Actor"}"#.utf8))
        for _ in 0..<2 {
            _ = try await client.item(id: "movie")
            _ = try await client.relatedTitles(itemID: "movie")
            _ = try await client.seasons(seriesID: "show")
            _ = try await client.episodes(seriesID: "show", seasonID: "one")
            _ = try await client.titles(for: person)
            _ = try await client.videos(search: "Moon")
        }
        XCTAssertEqual(requests, 6)
        _ = try await client.episodes(seriesID: "show", seasonID: "two")
        _ = try await client.episodes(seriesID: "show", seasonID: "one", startIndex: 100)
        _ = try await client.videos(search: "Arrival")
        XCTAssertEqual(requests, 9)
    }

    func testLiveFeedsBypassCacheAndMutationsAndRefreshInvalidateIt() async throws {
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, #"{"Items":[{"Id":"movie","Name":"Movie"}],"TotalRecordCount":1}"#)
        }
        let client = try client()
        for _ in 0..<2 {
            _ = try await client.resumeVideos()
            _ = try await client.recentlyAddedTitles()
            _ = try await client.videos(resumableOnly: true)
        }
        XCTAssertEqual(requests, 6)
        _ = try await client.item(id: "movie")
        _ = try await client.item(id: "movie")
        XCTAssertEqual(requests, 7)
        try await client.setWatched(true, itemID: "movie")
        _ = try await client.item(id: "movie")
        XCTAssertEqual(requests, 9)
        client.clearBrowsingCache()
        _ = try await client.item(id: "movie")
        XCTAssertEqual(requests, 10)
        let second = try client.authenticated(
            with: JellyfinSession(userID: "other", username: "Other", accessToken: "second-account"))
        _ = try await second.item(id: "movie")
        XCTAssertEqual(requests, 11)
    }

    func testMalformedAndFailedResponsesAreNeverCached() async throws {
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            switch requests {
            case 1: return (503, "")
            case 2: return (200, "not JSON")
            default: return (200, #"{"Items":[],"TotalRecordCount":0}"#)
            }
        }
        let client = try client()
        for _ in 0..<2 {
            do {
                _ = try await client.seasons(seriesID: "show")
                XCTFail("Expected invalid server response")
            } catch {}
        }
        _ = try await client.seasons(seriesID: "show")
        _ = try await client.seasons(seriesID: "show")
        XCTAssertEqual(requests, 3)
    }

    func testInvalidationRejectsAnInFlightResponse() {
        let cache = JellyfinBrowseCache()
        let url = URL(string: "https://theatre.test/Items")!
        let previous = cache.response(for: url)
        cache.clear()
        cache.store(Data("old".utf8), for: url, generation: previous.generation)
        XCTAssertNil(cache.response(for: url).data)
        let current = cache.response(for: url)
        cache.store(Data("new".utf8), for: url, generation: current.generation)
        XCTAssertEqual(cache.response(for: url).data, Data("new".utf8))
    }
}
