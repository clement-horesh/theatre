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
    func makeModel() -> AppModel { AppModel(sessionStore: self, defaults: defaults) }
}

final class SessionTests: XCTestCase {
    @MainActor
    func testSignInSurvivesNewAppModelAndSignOutRemovesSession() async throws {
        let server = LocalDemoServer(mediaDirectory: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!)
        let address = try await server.start()
        defer { server.stop() }
        let store = MemorySessionStore()
        let original = store.makeModel()
        original.address = address.absoluteString
        original.username = "demo"; original.password = "demo"
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
        XCTAssertEqual(reopened.videos.count, 6)
        XCTAssertEqual(reopened.homeRecommendationRevision, 1)
        await reopened.refreshRecentlyAddedTitles()
        XCTAssertEqual(reopened.homeRecommendationRevision, 1, "Unchanged Home data must not reshuffle the carousel")
        XCTAssertEqual(reopened.client?.deviceID, original.client?.deviceID)
        reopened.signOut()
        XCTAssertNil(store.saved)
        XCTAssertNil(store.makeModel().client)
    }

    @MainActor
    func testExpiredSessionReturnsToLoginButNetworkFailureKeepsSession() async throws {
        let server = LocalDemoServer(mediaDirectory: Bundle.module.url(forResource: "Fixtures", withExtension: nil)!)
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
        let invalid = try JSONDecoder().decode(JellyfinSession.self, from: Data(#"{"userID":"user","username":"demo","accessToken":"expired"}"#.utf8))
        store.saved = SavedSession(address: restartedAddress.absoluteString, deviceID: "session-test", session: invalid)
        let expired = store.makeModel()
        await expired.loadVideos()
        XCTAssertNil(expired.client)
        XCTAssertNil(store.saved)
        XCTAssertTrue(expired.errorMessage?.contains("expired") == true)
    }

    @MainActor
    func testKeychainRoundTripAndSignOutAcrossStoreInstances() throws {
        let service = "local.theatre.session-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer { defaults.removePersistentDomain(forName: service) }
        let store = KeychainSessionStore(service: service, defaults: defaults)
        defer { try? store.remove() }
        let session = try JSONDecoder().decode(JellyfinSession.self, from: Data(#"{"userID":"user","username":"demo","accessToken":"test-only-token"}"#.utf8))
        try store.save(SavedSession(address: "http://localhost:8096", deviceID: "device", session: session))
        let second = KeychainSessionStore(service: service, defaults: defaults)
        let saved = try XCTUnwrap(second.load())
        XCTAssertEqual(saved.session.accessToken, "test-only-token")
        XCTAssertEqual(saved.address, "http://localhost:8096")
        try second.remove()
        XCTAssertNil(try store.load())
        try store.save(saved)
        XCTAssertNotNil(try second.load())
    }
}
