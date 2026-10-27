import Foundation

public struct VideoFilters: Equatable, Hashable, Sendable {
    public enum WatchStatus: String, CaseIterable, Sendable {
        case all = "All"
        case unplayed = "Unwatched"
        case resumable = "In Progress"
        case played = "Watched"

        var queryValue: String? {
            switch self {
            case .all: nil
            case .unplayed: "IsUnplayed"
            case .resumable: "IsResumable"
            case .played: "IsPlayed"
            }
        }
    }

    public var watchStatus: WatchStatus = .all
    public var genre = ""
    public var year: Int? = nil
    public init() {}
    public var isEmpty: Bool { self == VideoFilters() }
}

public struct VideoFilterOptions: Decodable, Sendable {
    public let genres: [String]
    public let years: [Int]
    public init(genres: [String], years: [Int]) {
        self.genres = genres
        self.years = years
    }
    enum CodingKeys: String, CodingKey {
        case genres = "Genres"
        case years = "Years"
    }
}
