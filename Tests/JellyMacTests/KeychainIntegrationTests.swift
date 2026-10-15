import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

/// Uses an isolated Keychain item and may show a macOS authorization dialog.
final class KeychainIntegrationTests: XCTestCase {
    @MainActor
    func testKeychainRoundTripAndSignOutAcrossStoreInstances() throws {
        let service = "local.theatre.session-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer { defaults.removePersistentDomain(forName: service) }
        let store = KeychainSessionStore(service: service, defaults: defaults)
        defer { try? store.remove() }
        let session = try JSONDecoder().decode(
            JellyfinSession.self,
            from: Data(#"{"userID":"user","username":"demo","accessToken":"test-only-token"}"#.utf8))
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
