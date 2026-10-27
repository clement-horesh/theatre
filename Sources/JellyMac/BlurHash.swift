import CoreGraphics
import Foundation

/// Decode Jellyfin's BlurHash into a small preview; display sizing stays with the artwork view.
// https://github.com/woltapp/blurhash/blob/master/Algorithm.md
enum BlurHash {
    private static let alphabet = Dictionary(
        uniqueKeysWithValues: Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8
        )
        .enumerated().map { ($0.element, $0.offset) })

    static func decode(_ hash: String) -> CGImage? {
        guard (6...166).contains(hash.utf8.count) else { return nil }
        let digits = hash.utf8.compactMap { alphabet[$0] }
        guard digits.count == hash.utf8.count, digits[0] <= 80 else { return nil }
        let columns = digits[0] % 9 + 1
        let rows = digits[0] / 9 + 1
        guard digits.count == 4 + 2 * columns * rows else { return nil }
        let average = digits[2..<6].reduce(0) { $0 * 83 + $1 }
        guard average <= 0xFFFFFF else { return nil }
        var colors = [
            SIMD3(
                linear(average >> 16), linear((average >> 8) & 255), linear(average & 255))
        ]
        let maximum = Double(digits[1] + 1) / 166
        for index in 1..<(columns * rows) {
            let offset = 4 + index * 2
            let value = digits[offset] * 83 + digits[offset + 1]
            guard value < 19 * 19 * 19 else { return nil }
            let channels = [value / 361, value / 19 % 19, value % 19].map {
                let normalized = Double($0 - 9) / 9
                return normalized * abs(normalized) * maximum
            }
            colors.append(SIMD3(channels))
        }
        let size = 64
        let horizontal = (0..<size).map { x in (0..<columns).map { cos(.pi * Double(x * $0) / Double(size)) } }
        let vertical = (0..<size).map { y in (0..<rows).map { cos(.pi * Double(y * $0) / Double(size)) } }
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var color = SIMD3<Double>(repeating: 0)
                for row in 0..<rows {
                    for column in 0..<columns {
                        color += colors[row * columns + column] * horizontal[x][column] * vertical[y][row]
                    }
                }
                let offset = (y * size + x) * 4
                pixels[offset] = sRGB(color.x)
                pixels[offset + 1] = sRGB(color.y)
                pixels[offset + 2] = sRGB(color.z)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func linear(_ byte: Int) -> Double {
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func sRGB(_ linear: Double) -> UInt8 {
        let value = max(0, min(1, linear))
        let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, Int((encoded * 255).rounded()))))
    }
}
