import Foundation
import JellyfinKit
import Security

struct SavedSession: Codable {
    var id: String {
        let url = (try? JellyfinClient(address: address, deviceID: deviceID))?.serverURL.absoluteString ?? address
        return "\(url)|\(session.userID)"
    }
    let address: String
    let deviceID: String
    let session: JellyfinSession
}

@MainActor
protocol SessionStore {
    func loadAll() throws -> [SavedSession]
    func saveAll(_ sessions: [SavedSession]) throws
    func remove(id: String) throws
    func remove() throws
}

extension SessionStore {
    func load() throws -> SavedSession? { try loadAll().first }
    func save(_ session: SavedSession) throws { try saveAll([session]) }
}

/// Saves the server-issued token, never the user's password.
@MainActor
final class KeychainSessionStore: SessionStore {
    private let defaults: UserDefaults
    private let service: String
    private var signOutKey: String { "\(service).signedOut" }
    init(service: String = "local.jellymac.app.jellyfin-session", defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "current-session",
        ]
    }

    func loadAll() throws -> [SavedSession] {
        guard !defaults.bool(forKey: signOutKey) else { return [] }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return [] }
        try check(code)
        guard let data = result as? Data else { throw SessionStoreError() }
        let sessions: [SavedSession]
        if let saved = try? JSONDecoder().decode([SavedSession].self, from: data) {
            sessions = saved
        } else {
            sessions = [try JSONDecoder().decode(SavedSession.self, from: data)]
        }
        let removed = defaults.stringArray(forKey: "\(service).removed") ?? []
        return sessions.filter { !removed.contains($0.id) }
    }

    func saveAll(_ sessions: [SavedSession]) throws {
        let data = try JSONEncoder().encode(sessions)
        let changes = [kSecValueData as String: data]
        let code = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if code == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Theatre Jellyfin sign-in"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(code)
        }
        defaults.set(false, forKey: signOutKey)
        defaults.removeObject(forKey: "\(service).removed")
    }

    func remove(id: String) throws {
        var removed = defaults.stringArray(forKey: "\(service).removed") ?? []
        removed.append(id)
        defaults.set(removed, forKey: "\(service).removed")
        try saveAll(loadAll())
    }

    func remove() throws {
        // Do not restore a signed-out session even if the Keychain is locked.
        defaults.set(true, forKey: signOutKey)
        let code = SecItemDelete(query as CFDictionary)
        if code != errSecItemNotFound { try check(code) }
    }
    private func check(_ code: OSStatus) throws {
        if code != errSecSuccess { throw SessionStoreError() }
    }
}

private struct SessionStoreError: Error {}
