import CryptoKit
import Foundation
import XCTest

@testable import JellyMac

final class UpdateReleaseTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    func testUnbundledTestsDoNotStartAnUpdaterOrReadKeychain() {
        let updater = AppUpdater()
        updater.start()
        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)
        XCTAssertNotNil(updater.configurationError)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testReleaseVerificationRejectsChangedFeedArchiveAndSigningKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Update-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("A disposable update archive for signature testing".utf8)
        let archiveURL = directory.appendingPathComponent("Theatre.zip")
        try archive.write(to: archiveURL)
        let archiveSignature = try key.signature(for: archive).base64EncodedString()
        let payload = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><enclosure url="https://example.test/Theatre.zip" length="\(archive.count)" sparkle:edSignature="\(archiveSignature)" /></item>
            </channel></rss>
            """.utf8)
        let signature = try key.signature(for: payload).base64EncodedString()
        let signedFeed =
            payload
            + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(payload.count)\n-->\n".utf8)
        let feedURL = directory.appendingPathComponent("appcast.xml")
        try signedFeed.write(to: feedURL)
        let infoURL = directory.appendingPathComponent("Info.plist")
        func writePublicKey(_ publicKey: Curve25519.Signing.PublicKey) throws {
            let info = ["SUPublicEDKey": publicKey.rawRepresentation.base64EncodedString()]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        }
        try writePublicKey(key.publicKey)

        func verify(archive: Bool = true) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments =
                [
                    "swift", root.appendingPathComponent("Scripts/verify-update.swift").path, infoURL.path,
                    feedURL.path,
                ] + (archive ? [archiveURL.path] : [])
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        XCTAssertTrue(try verify(archive: false), "The signed feed must verify without private-key access")
        XCTAssertTrue(try verify(), "The matching signed archive must verify")
        try (archive + Data([0])).write(to: archiveURL)
        XCTAssertFalse(try verify(), "A modified archive must be rejected")
        try archive.write(to: archiveURL)
        var changed = signedFeed
        changed[20] ^= 1
        try changed.write(to: feedURL)
        XCTAssertFalse(try verify(), "A modified feed must be rejected")
        try signedFeed.write(to: feedURL)
        try writePublicKey(Curve25519.Signing.PrivateKey().publicKey)
        XCTAssertFalse(try verify(), "A feed and archive signed by another key must be rejected")
    }
}
