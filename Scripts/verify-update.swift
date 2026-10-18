import CryptoKit
import Foundation

// Release verification uses only the public key. It never opens Keychain.
func verify() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 || arguments.count == 4 else {
        throw VerificationError("Usage: swift Scripts/verify-update.swift Info.plist appcast.xml [Theatre.zip]")
    }
    let infoData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
        let encodedKey = info["SUPublicEDKey"] as? String, let rawKey = Data(base64Encoded: encodedKey)
    else { throw VerificationError("Missing update verification key.") }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let signatureRange = feed.range(of: Data("<!-- sparkle-signatures:".utf8), options: .backwards),
        let trailer = String(data: feed[signatureRange.upperBound...], encoding: .utf8)
    else { throw VerificationError("Missing feed signature.") }
    let fields = trailer.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
    }
    guard fields.count == 2, Set(fields.map(\.0)) == ["edSignature", "length"],
        let length = fields.first(where: { $0.0 == "length" }).flatMap({ Int($0.1) }),
        length == signatureRange.lowerBound,
        let signature = fields.first(where: { $0.0 == "edSignature" }).flatMap({ Data(base64Encoded: $0.1) }),
        publicKey.isValidSignature(signature, for: feed.prefix(length))
    else { throw VerificationError("Invalid feed signature or signing key.") }
    let document = try XMLDocument(data: feed)
    if arguments.count == 4 {
        let archiveURL = URL(fileURLWithPath: arguments[3])
        let enclosures = try document.nodes(forXPath: "/rss/channel/item/enclosure").compactMap { $0 as? XMLElement }
        guard
            let enclosure = enclosures.first(where: {
                $0.attribute(forName: "url")?.stringValue.flatMap(URL.init(string:))?.lastPathComponent
                    == archiveURL.lastPathComponent
            }),
            let encodedSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
            let archiveSignature = Data(base64Encoded: encodedSignature)
        else { throw VerificationError("Missing signed archive enclosure.") }
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
            publicKey.isValidSignature(archiveSignature, for: archive)
        else { throw VerificationError("Invalid archive signature or length.") }
    }
    print("Verified signed update feed\(arguments.count == 4 ? " and archive" : "").")
}

struct VerificationError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

do {
    try verify()
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
