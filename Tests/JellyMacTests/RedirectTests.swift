import Foundation
import JellyfinKit
import XCTest

final class RedirectTests: XCTestCase {
    @MainActor
    func testLoginDoesNotForwardItsBodyToAnotherOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Redirect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = PlaybackFixtureServer(mediaDirectory: root)
        let target = try await destination.start().appendingPathComponent("redirected-login")
        defer { destination.stop() }
        let origin = PlaybackFixtureServer(mediaDirectory: root, authenticationRedirect: target)
        let address = try await origin.start()
        defer { origin.stop() }
        let client = try JellyfinClient(address: address.absoluteString, deviceID: "redirect-test")
        do {
            _ = try await client.authenticate(username: "demo", password: "demo")
            XCTFail("A redirected login must not succeed on another origin")
        } catch JellyfinError.serverStatus(307) {}
        let requests = await destination.loginRequests()
        XCTAssertEqual(requests, 0, "The destination must never receive the credentials")
    }

    @MainActor
    func testLoginCanFollowARelativeRedirectOnItsOwnOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Redirect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PlaybackFixtureServer(
            mediaDirectory: root, authenticationRedirect: URL(string: "/redirected-login")!)
        let address = try await server.start()
        defer { server.stop() }
        let client = try JellyfinClient(address: address.absoluteString, deviceID: "redirect-test")
        let session = try await client.authenticate(username: "demo", password: "demo")
        XCTAssertEqual(session.username, "demo")
        let requests = await server.loginRequests()
        XCTAssertEqual(requests, 2)
    }

    func testOriginComparisonRejectsDowngradesAndRecognizesDefaultPorts() {
        func allowed(_ origin: String, _ target: String) -> Bool {
            JellyfinRedirectPolicy.allowsRedirect(from: URL(string: origin), to: URL(string: target))
        }
        XCTAssertTrue(allowed("https://server.test/base", "https://SERVER.test:443/new"))
        XCTAssertTrue(allowed("http://server.test/base", "http://server.test:80/new"))
        XCTAssertFalse(allowed("https://server.test", "http://server.test"))
        XCTAssertFalse(allowed("https://server.test", "https://server.test:444"))
        XCTAssertFalse(allowed("https://server.test", "https://other.test"))
        XCTAssertFalse(allowed("https://server.test", "https://user:password@server.test"))
    }
}
