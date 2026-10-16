import Foundation

public struct RemoteTrailer: Codable, Hashable, Sendable {
    public let url: String?
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case url = "Url"
        case name = "Name"
    }

    public var webURL: URL? {
        guard let url, let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // Jellyfin can import Kodi's YouTube plugin URLs from NFO metadata.
        if components.scheme == "plugin", components.host == "plugin.video.youtube",
            let id = components.queryItems?.first(where: { $0.name == "videoid" })?.value,
            Self.isVideoID(id)
        {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        guard ["https", "http"].contains(components.scheme?.lowercased()),
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }

    public static func youtubeEmbedURL(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id: String?
        switch components.host?.lowercased() {
        case "youtu.be", "www.youtu.be": id = url.pathComponents.dropFirst().first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com":
            if ["embed", "shorts", "live"].contains(url.pathComponents.dropFirst().first) {
                id = url.pathComponents.dropFirst(2).first
            } else {
                id = components.queryItems?.first(where: { $0.name == "v" })?.value
            }
        default: return nil
        }
        guard let id, isVideoID(id) else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(id)?autoplay=1&playsinline=1")
    }

    public static func youtubeThumbnailURL(for url: URL) -> URL? {
        guard let embed = youtubeEmbedURL(for: url) else { return nil }
        // The 16:9 thumbnail avoids the letterboxing baked into hqdefault's 4:3 image.
        return URL(string: "https://i.ytimg.com/vi/\(embed.lastPathComponent)/mqdefault.jpg")
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.count == 11
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
    }
}
