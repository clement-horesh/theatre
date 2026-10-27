import Foundation

public struct JellyfinSession: Codable, Sendable {
    public let userID: String
    public let username: String
    public let accessToken: String
}

public struct VideoItem: Codable, Identifiable, Sendable, Hashable {
    public var serverID: String?
    public var libraryID: String { serverID.map { "\($0)|\(id)" } ?? id }
    public var seriesLibraryID: String? { seriesID.map { id in serverID.map { "\($0)|\(id)" } ?? id } }
    public let id: String
    public let name: String
    public var dateCreated: String?
    public let sortName: String?
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
    public var people: [VideoPerson]?
    public let productionLocations: [String]?
    public let premiereDate: String?
    public let studios: [VideoStudio]?
    public let mediaStreams: [VideoDetailStream]?
    public let mediaSources: [VideoDetailSource]?
    public let remoteTrailers: [RemoteTrailer]?
    public var imageBlurHashes: [String: [String: String]]?
    public let imageTags: [String: String]?
    public let backdropImageTags: [String]?
    public let parentBackdropItemID: String?
    public let parentBackdropImageTags: [String]?
    public let parentLogoItemID: String?
    public let parentLogoImageTag: String?
    public var userData: VideoUserData?

    /// A title placeholder for an offline group whose full metadata is not available yet.
    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
        sortName = nil
        seriesName = nil
        seriesID = nil
        indexNumber = nil
        parentIndexNumber = nil
        childCount = nil
        productionYear = nil
        runTimeTicks = nil
        overview = nil
        officialRating = nil
        genres = nil
        people = nil
        productionLocations = nil
        premiereDate = nil
        studios = nil
        mediaStreams = nil
        mediaSources = nil
        remoteTrailers = nil
        imageTags = nil
        backdropImageTags = nil
        parentBackdropItemID = nil
        parentBackdropImageTags = nil
        parentLogoItemID = nil
        parentLogoImageTag = nil
        userData = nil
    }

    enum CodingKeys: String, CodingKey {
        case imageBlurHashes = "ImageBlurHashes"
        case serverID = "TheatreServerID"
        case id = "Id"
        case name = "Name"
        case dateCreated = "DateCreated"
        case sortName = "SortName"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesID = "SeriesId"
        case userData = "UserData"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case overview = "Overview"
        case officialRating = "OfficialRating"
        case genres = "Genres"
        case people = "People"
        case productionLocations = "ProductionLocations"
        case premiereDate = "PremiereDate"
        case studios = "Studios"
        case mediaStreams = "MediaStreams"
        case mediaSources = "MediaSources"
        case remoteTrailers = "RemoteTrailers"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemID = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
    }

    public func onServer(_ serverID: String) -> VideoItem {
        var item = self
        item.serverID = serverID
        item.people = people?.map { person in
            var person = person
            person.serverID = serverID
            return person
        }
        return item
    }

    // Synthesized equality compares the whole snapshot, so SwiftUI refreshes
    // metadata and watch status even when the movie's stable identity is unchanged.
    public func hash(into hasher: inout Hasher) { hasher.combine(libraryID) }

    public var title: String {
        guard type == "Episode", let seriesName else { return name }
        let episode = [parentIndexNumber.map { "S\($0)" }, indexNumber.map { "E\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        return "\(seriesName) · \(episode.isEmpty ? name : "\(episode) — \(name)")"
    }

    public var isUnwatched: Bool {
        userData?.played == false || (userData?.unplayedItemCount ?? 0) > 0
    }

    public var isInProgress: Bool {
        guard type != "Series", let position = userData?.playbackPositionTicks,
            position > 0
        else { return false }
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
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    public var progressLabel: String {
        guard type == "Episode" else { return remainingTimeLabel }
        let episode = [parentIndexNumber.map { "S\($0)" }, indexNumber.map { "E\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        return episode.isEmpty ? remainingTimeLabel : "\(episode) · \(remainingTimeLabel)"
    }
}

public struct VideoUserData: Codable, Sendable, Equatable {
    public let played: Bool?
    public let lastPlayedDate: String?
    public let playbackPositionTicks: Int64?
    public let playedPercentage: Double?
    public let unplayedItemCount: Int?
    public init(played: Bool, seconds: Double, lastPlayedDate: String, unplayedItemCount: Int? = nil) {
        self.played = played
        self.lastPlayedDate = lastPlayedDate
        playbackPositionTicks = Int64(max(0, min(seconds.isFinite ? seconds : 0, 1e10)) * 10_000_000)
        playedPercentage = nil
        self.unplayedItemCount = unplayedItemCount
    }
    enum CodingKeys: String, CodingKey {
        case played = "Played"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case lastPlayedDate = "LastPlayedDate"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
    }
}

public enum JellyfinImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
}

public struct VideoPage: Decodable, Sendable {
    public var items: [VideoItem]
    public let totalCount: Int
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalCount = "TotalRecordCount"
    }
}

public struct PlaybackStream: Sendable {
    public let url: URL
    public let itemID: String
    public let mediaSourceID: String
    public let playSessionID: String
    public let method: String
    public var externalSubtitles: [PlaybackSubtitle] = []
    public var mediaTracks: [PlaybackTrack] = []
    public var videoAspectRatio: Double? = nil
    public var resumePositionSeconds: Double = 0
    public init(
        url: URL, itemID: String, mediaSourceID: String, playSessionID: String, method: String,
        videoAspectRatio: Double? = nil, resumePositionSeconds: Double = 0
    ) {
        self.url = url
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.method = method
        self.videoAspectRatio = videoAspectRatio
        self.resumePositionSeconds = resumePositionSeconds
    }

}

public struct PlaybackTrack: Sendable {
    public let index: Int
    public let type: String
    public let language: String?
    public let name: String?
    public let isExternal: Bool
}

public struct PlaybackSubtitle: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let url: URL
    public init(id: Int, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

}

public enum JellyfinError: LocalizedError {
    case invalidAddress, unauthorized, forbidden
    case serverStatus(Int)
    case invalidResponse, noPlayableSource, unsafeStreamURL

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Enter a valid http:// or https:// server address, without a username, password, or query string."
        case .unauthorized: return "The server rejected your credentials or your session expired. Sign in again."
        case .forbidden:
            return
                "Your Jellyfin account doesn't have permission for this action. Check its access settings on the server."
        case .serverStatus(let code):
            return "The Jellyfin server returned HTTP \(code). Please check the server and try again."
        case .invalidResponse:
            return "The server returned an unexpected response. Check that the address points to Jellyfin."
        case .noPlayableSource:
            return "No compatible video stream is available. The Jellyfin user may need permission to transcode videos."
        case .unsafeStreamURL: return "The server supplied a stream address outside this Jellyfin server."
        }
    }
}
