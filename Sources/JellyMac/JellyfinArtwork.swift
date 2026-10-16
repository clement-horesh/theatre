import AppKit
import SwiftUI

/// A memory-only cache shared by this application's artwork views.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var pending: [NSString: Task<Data?, Error>] = [:]
    private var generation = UUID()
    private var localArtwork: [String: URL] = [:]

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = session ?? URLSession(configuration: configuration)
        images.totalCostLimit = 80 * 1024 * 1024
    }

    static func localKey(_ request: URLRequest) -> String {
        guard var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return ""
        }
        parts.query = nil
        return parts.string ?? ""
    }

    func setLocalArtwork(_ files: [String: URL]) { localArtwork = files }

    func image(for request: URLRequest) async throws -> NSImage? {
        if let local = localArtwork[Self.localKey(request)], let image = NSImage(contentsOf: local) { return image }
        let key =
            "\(request.url?.absoluteString ?? ""):\(request.value(forHTTPHeaderField: "Authorization") ?? "")"
            as NSString
        if let image = images.object(forKey: key) { return image }
        // Several cards and carousel prefetching can request the same artwork.
        // Share the download without cancelling it when just one view disappears.
        let generation = generation
        let task: Task<Data?, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            task = Task { [session] in
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return data
            }
            pending[key] = task
        }
        defer { if self.generation == generation { pending[key] = nil } }
        let data = try await task.value
        guard self.generation == generation else { throw CancellationError() }
        if let image = images.object(forKey: key) { return image }
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key, cost: max(data.count, Int(image.size.width * image.size.height * 4)))
        return image
    }

    func clear() {
        generation = UUID()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        images.removeAllObjects()
    }
}

struct JellyfinArtwork<Placeholder: View>: View {
    let request: URLRequest?
    var fit = false
    var progressBlurHeight: CGFloat = 0
    var progressBlurRadius: CGFloat = 12
    var onImageLoaded: ((NSImage) -> Void)? = nil
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if fit {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if progressBlurHeight > 0 {
                    ProgressBlurArtwork(image: image, fadeHeight: progressBlurHeight, radius: progressBlurRadius)
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            } else {
                placeholder()
            }
        }
        .task(id: request) {
            image = nil
            guard let request else { return }
            do {
                let result = try await ArtworkCache.shared.image(for: request)
                try Task.checkCancellation()
                image = result
                if let result { onImageLoaded?(result) }
            } catch { if !Task.isCancelled { image = nil } }
        }
    }
}

/// Fade in a blurred copy of the artwork, keeping its original colors and alignment.
private struct ProgressBlurArtwork: View {
    let image: NSImage
    let fadeHeight: CGFloat
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    if !reduceTransparency {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: radius, opaque: true)
                            .mask(alignment: .bottom) {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.55),
                                    ], startPoint: .top, endPoint: .bottom
                                )
                                .frame(height: min(fadeHeight, geometry.size.height))
                            }
                    }
                }
                .clipped()
        }
    }
}
