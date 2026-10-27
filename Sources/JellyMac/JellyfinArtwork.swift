import AppKit
import JellyfinKit
import SwiftUI

/// A memory-only cache shared by this application's artwork views.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images: NSCache<NSString, NSImage>
    private let previews = NSCache<NSString, NSImage>()
    private let encodedImages = NSCache<NSString, NSData>()
    private let session: URLSession
    private var pending: [NSString: Task<Data?, Error>] = [:]
    private var generation = UUID()
    private var localArtwork: [String: [String: URL]] = [:]

    init(session: URLSession? = nil, images: NSCache<NSString, NSImage> = NSCache()) {
        self.images = images
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = session ?? URLSession(configuration: configuration)
        previews.countLimit = 256
        images.totalCostLimit = 80 * 1024 * 1024
        encodedImages.totalCostLimit = 32 * 1024 * 1024
    }

    static func localKey(_ request: URLRequest) -> String {
        guard var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return ""
        }
        parts.query = nil
        return parts.string ?? ""
    }

    func setLocalArtwork(_ files: [String: URL], account: String = "") {
        // A download can replace artwork at the same file URL.
        for file in Set((localArtwork[account] ?? [:]).values).union(files.values) {
            images.removeObject(forKey: file.absoluteString as NSString)
        }
        localArtwork[account] = files
    }

    private func cacheKey(_ request: URLRequest) -> NSString {
        "\(request.url?.absoluteString ?? ""):\(request.value(forHTTPHeaderField: "Authorization") ?? "")"
            as NSString
    }

    func cachedImage(for request: URLRequest) -> NSImage? {
        let localKey = Self.localKey(request)
        if let local = localArtwork.values.lazy.compactMap({ $0[localKey] }).first {
            let key = local.absoluteString as NSString
            if let image = images.object(forKey: key) { return image }
            if let image = NSImage(contentsOf: local) {
                images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
                return image
            }
        }
        let key = cacheKey(request)
        if let image = images.object(forKey: key) { return image }
        guard let data = encodedImages.object(forKey: key), let image = NSImage(data: data as Data) else { return nil }
        images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    func preview(for request: URLRequest, hashes: [String: [String: String]]?) -> NSImage? {
        guard let url = request.url,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let tag = parts.queryItems?.first(where: { $0.name == "tag" })?.value,
            let hash = hashes?[url.lastPathComponent]?[tag]
        else { return nil }
        if let image = previews.object(forKey: hash as NSString) { return image }
        guard let decoded = BlurHash.decode(hash) else { return nil }
        let image = NSImage(
            cgImage: decoded, size: NSSize(width: CGFloat(decoded.width), height: CGFloat(decoded.height)))
        previews.setObject(image, forKey: hash as NSString)
        return image
    }

    func image(for request: URLRequest) async throws -> NSImage? {
        if let image = cachedImage(for: request) { return image }
        let key = cacheKey(request)
        // Several cards and carousel prefetching can request the same artwork.
        // Share the download without cancelling it when just one view disappears.
        let generation = generation
        let task: Task<Data?, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            task = Task { [session] in
                let (data, response) = try await session.data(for: request, delegate: JellyfinRedirectPolicy.shared)
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
        encodedImages.setObject(data as NSData, forKey: key, cost: data.count)
        images.setObject(image, forKey: key, cost: max(data.count, Int(image.size.width * image.size.height * 4)))
        return image
    }

    func clear() {
        generation = UUID()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        previews.removeAllObjects()
        images.removeAllObjects()
        encodedImages.removeAllObjects()
    }
}

struct JellyfinArtwork<Placeholder: View>: View {
    let request: URLRequest?
    var blurHashes: [String: [String: String]]? = nil
    var fit = false
    var progressBlurHeight: CGFloat = 0
    var progressBlurRadius: CGFloat = 12
    var onImageLoaded: ((NSImage) -> Void)? = nil
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var loadedRequest: URLRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let loadedImage = loadedRequest == request ? image : nil
        let cachedImage = loadedImage == nil ? request.flatMap { ArtworkCache.shared.cachedImage(for: $0) } : nil
        ZStack {
            if let image = loadedImage ?? cachedImage {
                Group {
                    if fit {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else if progressBlurHeight > 0 {
                        ProgressBlurArtwork(image: image, fadeHeight: progressBlurHeight, radius: progressBlurRadius)
                    } else {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                }
                .transition(.opacity)
            } else if let request, loadedRequest != request || isLoading, !fit {
                if let preview = ArtworkCache.shared.preview(for: request, hashes: blurHashes) {
                    Image(nsImage: preview).resizable().interpolation(.high).transition(.opacity)
                } else {
                    LoadingPlaceholder()
                }
            } else {
                placeholder()
            }
        }
        .task(id: request) {
            guard loadedRequest != request || image == nil else { return }
            image = nil
            loadedRequest = request
            isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }
            guard let request else { return }
            if let cached = ArtworkCache.shared.cachedImage(for: request) {
                image = cached
                onImageLoaded?(cached)
                return
            }
            do {
                let result = try await ArtworkCache.shared.image(for: request)
                try Task.checkCancellation()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = result }
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
