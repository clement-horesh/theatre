import Foundation

public struct JellyfinSession: Codable, Sendable {
    public let userID: String
    public let username: String
    public let accessToken: String
}

public struct VideoItem: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let type: String?
    public let seriesName: String?
    public let seriesID: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let childCount: Int?
    public let productionYear: Int?
    public let runTimeTicks: Int64?
    public let overview: String?
    public let officialRating: String?
    public let genres: [String]?
    public let people: [VideoPerson]?
    public let productionLocations: [String]?
    public let premiereDate: String?
    public let studios: [VideoStudio]?
    public let mediaStreams: [VideoDetailStream]?
    public let mediaSources: [VideoDetailSource]?
    public let imageTags: [String: String]?
    public let backdropImageTags: [String]?
    public let parentBackdropItemID: String?
    public let parentBackdropImageTags: [String]?
    public let parentLogoItemID: String?
    public let parentLogoImageTag: String?
    public let userData: VideoUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", seriesName = "SeriesName"
        case seriesID = "SeriesId", userData = "UserData"
        case indexNumber = "IndexNumber", parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case productionYear = "ProductionYear", runTimeTicks = "RunTimeTicks"
        case overview = "Overview", officialRating = "OfficialRating", genres = "Genres"
        case people = "People", productionLocations = "ProductionLocations", premiereDate = "PremiereDate"
        case studios = "Studios", mediaStreams = "MediaStreams", mediaSources = "MediaSources"
        case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags"
        case parentBackdropItemID = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemID = "ParentLogoItemId", parentLogoImageTag = "ParentLogoImageTag"
    }

    // Synthesized equality compares the whole snapshot, so SwiftUI refreshes
    // metadata and watch status even when the movie's stable identity is unchanged.
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var title: String {
        guard type == "Episode", let seriesName else { return name }
        let episode = [parentIndexNumber.map { "S\($0)" }, indexNumber.map { "E\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        return "\(seriesName) · \(episode.isEmpty ? name : "\(episode) — \(name)")"
    }

    public var detail: String {
        [type, productionYear.map(String.init), runTimeTicks.map { "\(max(1, $0 / 600_000_000)) min" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    public var isUnwatched: Bool {
        userData?.played == false || (userData?.unplayedItemCount ?? 0) > 0
    }

    public var isInProgress: Bool {
        guard type != "Series", let position = userData?.playbackPositionTicks,
              position > 0 else { return false }
        if let duration = runTimeTicks, duration > 0 { return position < duration }
        return true
    }

    public var resumePositionSeconds: Double {
        isInProgress ? Double(userData?.playbackPositionTicks ?? 0) / 10_000_000 : 0
    }

    public var progressFraction: Double {
        if let duration = runTimeTicks, duration > 0 {
            return max(0, min(1, Double(userData?.playbackPositionTicks ?? 0) / Double(duration)))
        }
        let value = (userData?.playedPercentage ?? 0) / 100
        return value.isFinite ? max(0, min(1, value)) : 0
    }

    public var remainingTimeLabel: String {
        guard let duration = runTimeTicks, duration > 0 else { return "Continue" }
        let position = max(0, userData?.playbackPositionTicks ?? 0)
        let minutes = Int(ceil(Double(max(0, duration - position)) / 600_000_000))
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    public var progressLabel: String {
        guard type == "Episode" else { return remainingTimeLabel }
        let episode = [parentIndexNumber.map { "S\($0)" }, indexNumber.map { "E\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        return episode.isEmpty ? remainingTimeLabel : "\(episode) · \(remainingTimeLabel)"
    }
}

public struct VideoUserData: Decodable, Sendable, Equatable {
    public let played: Bool?
    public let lastPlayedDate: String?
    public let playbackPositionTicks: Int64?
    public let playedPercentage: Double?
    public let unplayedItemCount: Int?
    enum CodingKeys: String, CodingKey {
        case played = "Played", playbackPositionTicks = "PlaybackPositionTicks"
        case lastPlayedDate = "LastPlayedDate"
        case playedPercentage = "PlayedPercentage", unplayedItemCount = "UnplayedItemCount"
    }
}

public enum JellyfinImageType: String, Sendable {
    case primary = "Primary", backdrop = "Backdrop", logo = "Logo"
}

public struct VideoPage: Decodable, Sendable {
    public let items: [VideoItem]
    public let totalCount: Int
    enum CodingKeys: String, CodingKey { case items = "Items", totalCount = "TotalRecordCount" }
}

public struct PlaybackStream: Sendable {
    public let url: URL
    public let itemID: String
    public let mediaSourceID: String
    public let playSessionID: String
    public let method: String
    public var externalSubtitles: [PlaybackSubtitle] = []
    public var videoAspectRatio: Double? = nil
    public var resumePositionSeconds: Double = 0
}

public struct PlaybackSubtitle: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let url: URL
}

public enum JellyfinError: LocalizedError {
    case invalidAddress, unauthorized, serverStatus(Int), invalidResponse, noPlayableSource, unsafeStreamURL

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a valid http:// or https:// server address, without a username, password, or query string."
        case .unauthorized: return "The server rejected your credentials or your session expired. Sign in again."
        case .serverStatus(let code): return "The Jellyfin server returned HTTP \(code). Please check the server and try again."
        case .invalidResponse: return "The server returned an unexpected response. Check that the address points to Jellyfin."
        case .noPlayableSource: return "No compatible video stream is available. The Jellyfin user may need permission to transcode videos."
        case .unsafeStreamURL: return "The server supplied a stream address outside this Jellyfin server."
        }
    }
}
