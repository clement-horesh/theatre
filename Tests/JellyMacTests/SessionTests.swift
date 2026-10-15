import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

@MainActor
final class MemorySessionStore: SessionStore {
    private let defaultsName = "local.theatre.model-tests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: defaultsName)!
    var saved: SavedSession?
    var failsToSave = false
    func load() throws -> SavedSession? { saved }
    func save(_ session: SavedSession) throws {
        if failsToSave { throw NSError(domain: "SessionTests", code: 1) }
        saved = session
    }
    func remove() throws { saved = nil }
    func makeModel(transport: URLSession? = nil) -> AppModel {
        AppModel(sessionStore: self, defaults: defaults, transport: transport)
    }
}

final class SessionTests: XCTestCase {
    @MainActor
    func testSignInSurvivesNewAppModelAndSignOutRemovesSession() async throws {
        let server = PlaybackFixtureServer(
            mediaDirectory: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!)
        let address = try await server.start()
        defer { server.stop() }
        let store = MemorySessionStore()
        let original = store.makeModel()
        original.address = address.absoluteString
        original.username = "demo"
        original.password = "demo"
        original.connect()
        for _ in 0..<100 {
            if original.client != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(original.client)
        XCTAssertEqual(original.password, "")
        XCTAssertNotNil(store.saved)
        let reopened = store.makeModel()
        XCTAssertEqual(reopened.displayedUsername, "demo")
        await reopened.loadVideos()
        XCTAssertTrue(reopened.videos.isEmpty)
        XCTAssertEqual(reopened.recentlyAddedVideos.count, 6)
        XCTAssertGreaterThan(reopened.homeRecommendationRevision, 0)
        let revision = reopened.homeRecommendationRevision
        await reopened.refreshRecentlyAddedTitles()
        XCTAssertEqual(
            reopened.homeRecommendationRevision, revision, "Unchanged Home data must not reshuffle the carousel")
        XCTAssertEqual(reopened.client?.deviceID, original.client?.deviceID)
        reopened.signOut()
        XCTAssertNil(store.saved)
        XCTAssertNil(store.makeModel().client)
    }

    @MainActor
    func testExpiredSessionReturnsToLoginButNetworkFailureKeepsSession() async throws {
        let server = PlaybackFixtureServer(
            mediaDirectory: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!)
        let address = try await server.start()
        let store = MemorySessionStore()
        let api = try JellyfinClient(address: address.absoluteString, deviceID: "session-test")
        let session = try await api.authenticate(username: "demo", password: "demo")
        store.saved = SavedSession(address: address.absoluteString, deviceID: "session-test", session: session)
        let offline = store.makeModel()
        server.stop()
        await offline.loadVideos()
        XCTAssertNotNil(offline.client)
        XCTAssertNotNil(store.saved)
        let restartedAddress = try await server.start()
        defer { server.stop() }
        let invalid = try JSONDecoder().decode(
            JellyfinSession.self, from: Data(#"{"userID":"user","username":"demo","accessToken":"expired"}"#.utf8))
        store.saved = SavedSession(address: restartedAddress.absoluteString, deviceID: "session-test", session: invalid)
        let expired = store.makeModel()
        await expired.loadVideos()
        XCTAssertNil(expired.client)
        XCTAssertNil(store.saved)
        XCTAssertTrue(expired.errorMessage?.contains("expired") == true)
    }

}
