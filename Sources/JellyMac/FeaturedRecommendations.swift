import JellyfinKit

enum FeaturedRecommendations {
    /// The inputs are server-ordered by added date and last playback respectively.
    static func candidates(recent: [VideoItem], continuing: [VideoItem]) -> [VideoItem] {
        let recentTitles = Array(recent.filter { $0.type != "Episode" }.prefix(10))
        let movies = continuing.filter { $0.type == "Movie" && $0.isInProgress }.prefix(5)
        // Prefer the latest playback information when a movie appears in both sources.
        let resumeByID = Dictionary(movies.map { ($0.libraryID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (recentTitles.map { resumeByID[$0.libraryID] ?? $0 } + movies)
            .filter { seen.insert($0.libraryID).inserted }
    }

    static func choose<R: RandomNumberGenerator>(
        recent: [VideoItem], continuing: [VideoItem],
        using random: inout R
    ) -> [VideoItem] {
        let pool = candidates(recent: recent, continuing: continuing)
        let unseen = pool.filter { $0.isUnwatched && !$0.isInProgress }.shuffled(using: &random)
        let others = pool.filter { !($0.isUnwatched && !$0.isInProgress) }.shuffled(using: &random)
        // candidates already excludes episodes and removes duplicate title IDs.
        return Array((unseen + others).prefix(5)).shuffled(using: &random)
    }

    static func nextIndex(from index: Int, by offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + offset) % count + count) % count
    }
}
