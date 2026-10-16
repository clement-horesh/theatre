import Foundation
import XCTest

@testable import JellyMac

final class ArtworkCacheTests: XCTestCase {
    private let pixel = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!

    @MainActor
    func testDownloadedArtworkLoadsWithoutContactingTheServer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Artwork-\(UUID()).png")
        try pixel.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = TestURLProtocol.session { _ in
            XCTFail("Offline artwork must not need a server request")
            return .json("{}", status: 503)
        }
        defer { transport.invalidateAndCancel() }
        let cache = ArtworkCache(session: transport)
        let small = URLRequest(
            url: URL(string: "https://theatre.test/Items/movie/Images/Primary?maxWidth=120&tag=one")!)
        let large = URLRequest(
            url: URL(string: "https://theatre.test/Items/movie/Images/Primary?maxWidth=420&tag=one")!)
        cache.setLocalArtwork([ArtworkCache.localKey(small): file])
        let image = try await cache.image(for: large)
        XCTAssertNotNil(image)
    }

    @MainActor
    func testConcurrentArtworkIsDownloadedOnceAndCacheSeparatesAccounts() async throws {
        var requests = 0
        let transport = TestURLProtocol.session { [pixel] _ in
            requests += 1
            return .init(data: pixel, delay: 0.02)
        }
        defer { transport.invalidateAndCancel() }
        let cache = ArtworkCache(session: transport)
        var request = URLRequest(url: URL(string: "https://theatre.test/image")!)
        request.setValue("first-account", forHTTPHeaderField: "Authorization")
        let initial = request
        async let first = cache.image(for: initial)
        async let second = cache.image(for: initial)
        let images = try await (first, second)
        XCTAssertNotNil(images.0)
        XCTAssertNotNil(images.1)
        XCTAssertEqual(requests, 1)
        _ = try await cache.image(for: request)
        XCTAssertEqual(requests, 1)
        request.setValue("second-account", forHTTPHeaderField: "Authorization")
        _ = try await cache.image(for: request)
        XCTAssertEqual(requests, 2)
        cache.clear()
        _ = try await cache.image(for: request)
        XCTAssertEqual(requests, 3)
    }

    @MainActor
    func testClearingCacheCancelsInFlightArtworkAndCannotRepopulateIt() async throws {
        let requested = expectation(description: "Artwork download started")
        let transport = TestURLProtocol.session { [pixel] _ in
            requested.fulfill()
            return .init(data: pixel, delay: 0.1)
        }
        defer { transport.invalidateAndCancel() }
        let cache = ArtworkCache(session: transport)
        let request = URLRequest(url: URL(string: "https://theatre.test/image")!)
        let load = Task { try await cache.image(for: request) }
        await fulfillment(of: [requested], timeout: 2)
        cache.clear()
        do {
            _ = try await load.value
            XCTFail("A cleared cache must discard its old download")
        } catch {}
    }
}
