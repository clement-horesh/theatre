import AppKit
import JellyfinKit
import SwiftUI

struct FeaturedMediaView: View {
    let video: VideoItem
    let client: JellyfinClient?
    let onColor: (NSColor) -> Void

    private var metadata: String {
        let duration =
            video.type == "Series"
            ? video.childCount.flatMap { $0 > 0 ? "\($0) season\($0 == 1 ? "" : "s")" : nil }
            : video.runtimeLabel
        return [
            video.type, video.genres?.prefix(2).joined(separator: " · "),
            video.productionYear.map(String.init), duration,
            video.officialRating,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                JellyfinArtwork(request: backdropRequest, onImageLoaded: { onColor(ArtworkColor.dominant(in: $0)) }) {
                    Color(white: 0.08)
                }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.25), location: 0.35),
                        .init(color: .black.opacity(0.8), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(
                    width: min(geometry.size.width * 0.72, 680),
                    height: min(geometry.size.height * 0.85, 360)
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.35),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing))
                VStack(alignment: .leading, spacing: 10) {
                    JellyfinArtwork(
                        request: try? client?.imageRequest(for: video, type: .logo, maxWidth: 700), fit: true
                    ) {
                        Text(video.title).font(.system(size: 30, weight: .bold)).lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(
                        width: min(geometry.size.width * 0.32, 320), height: min(geometry.size.height * 0.2, 80),
                        alignment: .bottomLeading
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    if !metadata.isEmpty {
                        Text(metadata).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2).shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    }
                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                            .lineLimit(3).lineSpacing(2)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    }
                }
                .frame(maxWidth: min(geometry.size.width * 0.55, 460), alignment: .leading)
                .padding(.horizontal, 30).padding(.bottom, 50)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured: \(video.title). \(metadata). Open details.")
    }

    private var backdropRequest: URLRequest? {
        (try? client?.imageRequest(for: video, type: .backdrop, maxWidth: 2560))
            ?? (try? client?.imageRequest(for: video, type: .primary, maxWidth: 1600))
    }
}

/// Samples a small image and groups colors by hue. Dark shadows and neutral
/// pixels do not drown out the main colored area of the artwork.
@MainActor
enum ArtworkColor {
    static let pageBackground = NSColor(srgbRed: 0.035, green: 0.035, blue: 0.045, alpha: 1)

    static func dominant(in image: NSImage) -> NSColor {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return pageBackground }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        struct Bucket {
            var score = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var buckets: [Int: Bucket] = [:]
        var neutral = Bucket()
        for y in 0..<48 {
            for x in 0..<48 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5
                else { continue }
                let brightness = color.brightnessComponent
                let saturation = color.saturationComponent
                guard brightness > 0.1 else { continue }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                neutral.score += 1
                neutral.red += red
                neutral.green += green
                neutral.blue += blue
                guard saturation > 0.18 else { continue }
                let key = min(23, Int(color.hueComponent * 24))
                let weight = Double(saturation) * (0.5 + Double(brightness))
                var bucket = buckets[key, default: Bucket()]
                bucket.score += weight
                bucket.red += red * weight
                bucket.green += green * weight
                bucket.blue += blue * weight
                buckets[key] = bucket
            }
        }
        let chosen = buckets.values.max { $0.score < $1.score } ?? neutral
        guard chosen.score > 0 else { return pageBackground }
        return NSColor(
            srgbRed: chosen.red / chosen.score, green: chosen.green / chosen.score,
            blue: chosen.blue / chosen.score, alpha: 1)
    }
}
