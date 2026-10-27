import AppKit
import SwiftUI
import XCTest

@testable import JellyMac

final class LoadingPresentationTests: XCTestCase {
    func testBlurHashDecodesReferenceColorsAndRejectsMalformedServerData() throws {
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(BlurHash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj")))
        XCTAssertEqual(bitmap.pixelsWide, 64)
        XCTAssertEqual(bitmap.pixelsHigh, 64)
        for (x, y, expected) in [(0, 0, [135, 164, 177]), (32, 32, [158, 125, 108]), (62, 62, [133, 142, 147])] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: x, y: y)
            for (actual, value) in zip(pixel.prefix(3), expected) {
                XCTAssertEqual(Double(actual), Double(value), accuracy: 1)
            }
            XCTAssertEqual(pixel[3], 255)
        }
        for hash in [
            "", "00000", "~00000", "00~~~~", "100000~~", "00TI:j!", "00TI:é", String(repeating: "0", count: 167),
        ] {
            XCTAssertNil(BlurHash.decode(hash), hash)
        }
        for hash in ["000000", "00TI:j", "0009dg", "000036", "00TSUA"] {
            XCTAssertNotNil(BlurHash.decode(hash))
        }
    }

    @MainActor
    func testPreviewUsesTheRequestsExactImageTypeAndTagWithoutNetworking() throws {
        let transport = TestURLProtocol.session { _ in
            XCTFail("A BlurHash preview must not request an image")
            return .json("{}", status: 503)
        }
        defer { transport.invalidateAndCancel() }
        let cache = ArtworkCache(session: transport)
        let request = URLRequest(url: URL(string: "https://theatre.test/Items/movie/Images/Primary?tag=poster")!)
        let hashes = ["Primary": ["poster": "00TI:j"], "Backdrop": ["backdrop": "000036"]]
        let preview = try XCTUnwrap(cache.preview(for: request, hashes: hashes))
        XCTAssertTrue(preview === cache.preview(for: request, hashes: hashes))
        XCTAssertNil(cache.preview(for: request, hashes: ["Backdrop": ["poster": "00TI:j"]]))
        XCTAssertNil(cache.preview(for: request, hashes: ["Primary": ["old-poster": "00TI:j"]]))
        XCTAssertNil(cache.preview(for: request, hashes: ["Primary": ["poster": "broken"]]))
        XCTAssertNil(cache.preview(for: request, hashes: nil))
        cache.clear()
        XCTAssertFalse(preview === cache.preview(for: request, hashes: hashes))
    }

    @MainActor
    func testBlurredCoverAppearsOnTheFirstFrameBeforeAnyImageDownload() throws {
        let request = URLRequest(url: URL(string: "https://theatre.test/Items/loading/Images/Primary?tag=poster")!)
        let renderer = ImageRenderer(
            content: JellyfinArtwork(request: request, blurHashes: ["Primary": ["poster": "00TI:j"]]) { Color.clear }
                .frame(width: 180, height: 270))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let center = try XCTUnwrap(bitmap.colorAt(x: 90, y: 135)?.usingColorSpace(.sRGB))
        XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(center.redComponent, 0.95)
        XCTAssertGreaterThan(center.redComponent, center.greenComponent + 0.6)
        XCTAssertGreaterThan(center.redComponent, center.blueComponent + 0.6)
    }

    @MainActor
    func testCachedArtworkWinsOverItsBlurredPreviewOnTheFirstFrame() throws {
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cached-artwork-\(UUID()).tiff")
        try XCTUnwrap(image.tiffRepresentation).write(to: file)
        let request = URLRequest(url: URL(string: "https://theatre.test/Items/cached/Images/Primary?tag=poster")!)
        ArtworkCache.shared.setLocalArtwork([ArtworkCache.localKey(request): file])
        defer {
            ArtworkCache.shared.setLocalArtwork([:])
            try? FileManager.default.removeItem(at: file)
        }
        let renderer = ImageRenderer(
            content: JellyfinArtwork(request: request, blurHashes: ["Primary": ["poster": "000036"]]) { Color.clear }
                .frame(width: 180, height: 270))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let center = try XCTUnwrap(bitmap.colorAt(x: 90, y: 135)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(center.redComponent, 0.9)
        XCTAssertGreaterThan(center.redComponent, center.blueComponent + 0.6)
    }

    @MainActor
    func testMissingBlurHashUsesAUniformPlaceholderAndSkeletonReservesPosterSpace() throws {
        let request = URLRequest(url: URL(string: "https://theatre.test/Items/no-hash/Images/Primary?tag=poster")!)
        let content = ImageRenderer(
            content: JellyfinArtwork(request: request) { Color.clear }.frame(width: 180, height: 270))
        let pixels = NSBitmapImageRep(cgImage: try XCTUnwrap(content.cgImage))
        let first = try XCTUnwrap(pixels.colorAt(x: 12, y: 12))
        XCTAssertGreaterThan(first.alphaComponent, 0)
        XCTAssertEqual(first, pixels.colorAt(x: 13, y: 13))
        for width: CGFloat in [150, 180, 210] {
            let skeleton = ImageRenderer(content: MediaCardSkeleton(poster: true).frame(width: width))
            let rendered = try XCTUnwrap(skeleton.cgImage)
            XCTAssertEqual(rendered.width, Int(width))
            XCTAssertEqual(rendered.height, Int(width * 1.5 + 40))
        }
    }
}
