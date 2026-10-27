import Foundation
import JellyfinKit
import Security
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
    @MainActor
    func testLegacySessionMigratesAndRemovingOneServerKeepsTheOther() throws {
        let service = "local.theatre.session-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer { defaults.removePersistentDomain(forName: service) }
        let store = KeychainSessionStore(service: service, defaults: defaults)
        defer { try? store.remove() }
        let session = try JSONDecoder().decode(
            JellyfinSession.self,
            from: Data(#"{"userID":"user","username":"demo","accessToken":"test-only-token"}"#.utf8))
        let legacy = SavedSession(address: "https://one.test/", deviceID: "device", session: session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "current-session",
            kSecValueData as String: try JSONEncoder().encode(legacy),
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try store.loadAll().map(\.id), [legacy.id])
        let second = SavedSession(address: "https://two.test", deviceID: "device", session: session)
        try store.saveAll([legacy, second])
        try store.remove(id: legacy.id)
        let reopened = KeychainSessionStore(service: service, defaults: defaults)
        XCTAssertEqual(try reopened.loadAll().map(\.id), [second.id])
        try reopened.remove(id: second.id)
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

}
