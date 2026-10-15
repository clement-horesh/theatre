import Foundation
import JellyfinKit

/// A single show-level action, independent of the season currently being browsed.
struct ShowPlaybackSelection {
    let episode: VideoItem
    let title: String

    init?(episodes: [VideoItem]) {
        let ordered = episodes.enumerated().filter { $0.element.type == "Episode" }.sorted {
            ($0.element.parentIndexNumber ?? Int.max, $0.element.indexNumber ?? Int.max, $0.offset)
                < ($1.element.parentIndexNumber ?? Int.max, $1.element.indexNumber ?? Int.max, $1.offset)
        }.map(\.element)
        guard let first = ordered.first else { return nil }

        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDate = ISO8601DateFormatter()
        func lastPlayed(_ item: VideoItem?) -> Date {
            guard let value = item?.userData?.lastPlayedDate else { return .distantPast }
            return fractionalDate.date(from: value) ?? plainDate.date(from: value) ?? .distantPast
        }
        // Ordered input makes ties or missing dates fall back to episode order.
        var unfinished: VideoItem?
        for candidate in ordered where candidate.isInProgress {
            if unfinished == nil || lastPlayed(candidate) > lastPlayed(unfinished) { unfinished = candidate }
        }
        if let unfinished {
            episode = unfinished
            title = "Continue"
            return
        }
        // Specials can be resumed explicitly, but don't displace regular episodes.
        let regular = ordered.filter { $0.parentIndexNumber != 0 }
        let playable = regular.isEmpty ? ordered : regular
        episode = playable.first { $0.userData?.played != true } ?? playable.first ?? first
        if episode.userData?.played == true {
            title = "Play Again"
        } else {
            title = ordered.contains { $0.userData?.played == true } ? "Continue" : "Start"
        }
    }
}
