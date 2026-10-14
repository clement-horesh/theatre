import Foundation
import JellyfinKit
import XCTest
@testable import JellyMac

final class FeaturedRecommendationsTests: XCTestCase {
    func testOnlyTenNewestAdditionsAndFiveLatestContinueMoviesAreEligible() throws {
        let recent = try (0..<14).map { try item("recent-\($0)", played: true) }
        let resume = try (0..<8).reversed().map {
            try item("resume-\($0)", position: 200_000_000,
                     lastPlayed: "2026-10-\(String(format: "%02d", $0 + 1))T12:00:00Z")
        }
        let episode = try item("episode", type: "Episode", position: 200_000_000,
                               lastPlayed: "2026-10-15T12:00:00Z")
        let pool = FeaturedRecommendations.candidates(recent: recent, continuing: resume + [episode])
        XCTAssertEqual(Set(pool.map(\.id)), Set(recent.prefix(10).map(\.id) + (3..<8).map { "resume-\($0)" }))
    }

    func testUnseenAdditionsHavePriorityOverWatchedAndContinueItems() throws {
        let unseen = try (0..<3).map { try item("unseen-\($0)", played: false) }
        let watched = try (0..<7).map { try item("watched-\($0)", played: true) }
        let resume = try (0..<5).map { try item("resume-\($0)", position: 200_000_000) }
        for seed in 1...20 {
            var random = SeededRandom(state: UInt64(seed))
            let selection = FeaturedRecommendations.choose(recent: watched + unseen, continuing: resume, using: &random)
            XCTAssertEqual(selection.count, 5)
            XCTAssertTrue(Set(unseen.map(\.id)).isSubset(of: Set(selection.map(\.id))))
        }
    }

    func testDuplicateMovieUsesCurrentResumeStateAndAppearsOnlyOnce() throws {
        let recent = try item("overlap", played: false)
        let resumed = try item("overlap", position: 200_000_000)
        var random = SeededRandom(state: 42)
        let selection = FeaturedRecommendations.choose(recent: [recent, recent], continuing: [resumed, resumed], using: &random)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(try XCTUnwrap(selection.first).isInProgress)
    }

    func testFiveDistinctRandomChoicesAndSmallOrEmptyLibraries() throws {
        let recent = try (0..<10).map { try item("item-\($0)", played: false) }
        var firstRandom = SeededRandom(state: 1), secondRandom = SeededRandom(state: 2)
        let first = FeaturedRecommendations.choose(recent: recent, continuing: [], using: &firstRandom)
        let second = FeaturedRecommendations.choose(recent: recent, continuing: [], using: &secondRandom)
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(Set(first.map(\.id)).count, 5)
        XCTAssertNotEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(FeaturedRecommendations.choose(recent: Array(recent.prefix(2)), continuing: [], using: &firstRandom).count, 2)
        XCTAssertTrue(FeaturedRecommendations.choose(recent: [], continuing: [], using: &firstRandom).isEmpty)
    }

    func testCarouselWrapsInBothDirectionsIncludingSingleItem() {
        XCTAssertEqual(FeaturedRecommendations.nextIndex(from: 4, by: 1, count: 5), 0)
        XCTAssertEqual(FeaturedRecommendations.nextIndex(from: 0, by: -1, count: 5), 4)
        XCTAssertEqual(FeaturedRecommendations.nextIndex(from: 0, by: 1, count: 1), 0)
        XCTAssertEqual(FeaturedRecommendations.nextIndex(from: 0, by: -1, count: 0), 0)
    }

    func testCarouselUsesWholeShowAndNeverAnIndividualEpisode() throws {
        let episodes = try (0..<5).map { try item("episode-\($0)", type: "Episode", seriesID: "show") }
        let show = try item("show", type: "Series")
        let movie = try item("movie")
        var random = SeededRandom(state: 42)
        let selection = FeaturedRecommendations.choose(recent: episodes + [show, show, movie], continuing: [], using: &random)
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(selection.filter { $0.type == "Series" && $0.id == "show" }.count, 1)
        XCTAssertFalse(selection.contains { $0.type == "Episode" })
        XCTAssertTrue(selection.contains { $0.id == "movie" })
    }

    private func item(_ id: String, type: String = "Movie", played: Bool = false,
                      position: Int64 = 0, lastPlayed: String? = nil, seriesID: String? = nil) throws -> VideoItem {
        var user: [String: Any] = ["Played": played, "PlaybackPositionTicks": position]
        if let lastPlayed { user["LastPlayedDate"] = lastPlayed }
        var json: [String: Any] = ["Id": id, "Name": id, "Type": type,
                                   "RunTimeTicks": Int64(36_000_000_000), "UserData": user]
        if let seriesID { json["SeriesId"] = seriesID }
        return try JSONDecoder().decode(VideoItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
