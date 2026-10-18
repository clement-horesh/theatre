import CryptoKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments[1] == "key" {
    let key = Curve25519.Signing.PrivateKey()
    let keyURL = root.appendingPathComponent("test-only-key")
    try key.rawRepresentation.write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(
        to: root.appendingPathComponent("public-key"))
} else {
    let key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(contentsOf: root.appendingPathComponent("test-only-key")))
    let archive = try Data(contentsOf: root.appendingPathComponent("update.zip"))
    let port = CommandLine.arguments[3]
    let payload = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Disposable updater test</title><item><title>Version 2.0</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:\(port)/update.zip" length="\(archive.count)" type="application/octet-stream" sparkle:edSignature="\(try key.signature(for: archive).base64EncodedString())" /></item></channel></rss>
        """.utf8)
    let signed =
        payload
        + Data(
            "<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: payload).base64EncodedString())\nlength: \(payload.count)\n-->\n"
                .utf8)
    try signed.write(to: root.appendingPathComponent("appcast.xml"))
}
