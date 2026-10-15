import Foundation
import XCTest

@testable import JellyfinKit

final class WatchStatusTests: XCTestCase {
    private func item(
        type: String = "Movie", duration: Int64? = 72_000_000_000,
        userData: [String: Any]? = nil, episode: Bool = false
    ) throws -> VideoItem {
        var data: [String: Any] = ["Id": "video", "Name": "Title", "Type": type]
        data["RunTimeTicks"] = duration
        data["UserData"] = userData
        if episode {
            data["ParentIndexNumber"] = 1
            data["IndexNumber"] = 1
        }
        return try JSONDecoder().decode(VideoItem.self, from: JSONSerialization.data(withJSONObject: data))
    }

    func testUnwatchedWatchedAndUnknownStatusStayDistinct() throws {
        XCTAssertFalse(try item().isUnwatched)
        let fresh = try item(userData: ["Played": false, "PlaybackPositionTicks": 0])
        XCTAssertTrue(fresh.isUnwatched)
        XCTAssertFalse(fresh.isInProgress)
        let watched = try item(userData: ["Played": true, "PlaybackPositionTicks": 0])
        XCTAssertFalse(watched.isUnwatched)
        XCTAssertFalse(watched.isInProgress)
        XCTAssertEqual(watched.resumePositionSeconds, 0)
        let rewatch = try item(userData: ["Played": true, "PlaybackPositionTicks": 6_000_000_000])
        XCTAssertTrue(rewatch.isInProgress)
        XCTAssertFalse(rewatch.isUnwatched)
    }

    func testMovieRemainingTimeAndProgressMatchReference() throws {
        let movie = try item(userData: ["Played": false, "PlaybackPositionTicks": 6_600_000_000])
        XCTAssertTrue(movie.isInProgress)
        XCTAssertEqual(movie.remainingTimeLabel, "1h 49m")
        XCTAssertEqual(movie.progressLabel, "1h 49m")
        XCTAssertEqual(movie.resumePositionSeconds, 660)
        XCTAssertEqual(movie.progressFraction, 11.0 / 120.0, accuracy: 0.0001)
    }

    func testEpisodeRemainingLabelAndSeriesAggregate() throws {
        let episode = try item(
            type: "Episode", duration: 12_000_000_000,
            userData: ["Played": false, "PlaybackPositionTicks": 4_800_000_000], episode: true)
        XCTAssertEqual(episode.progressLabel, "S1, E1 · 12m")
        let series = try item(
            type: "Series", userData: ["Played": false, "UnplayedItemCount": 3, "PlaybackPositionTicks": 10])
        XCTAssertTrue(series.isUnwatched)
        XCTAssertFalse(series.isInProgress)
    }

    func testBadOrMissingTimingDoesNotProduceFalseResumeOrOverflow() throws {
        for position: Int64 in [-10, 72_000_000_000, Int64.max] {
            let movie = try item(userData: ["Played": false, "PlaybackPositionTicks": position])
            XCTAssertFalse(movie.isInProgress)
            XCTAssertGreaterThanOrEqual(movie.progressFraction, 0)
            XCTAssertLessThanOrEqual(movie.progressFraction, 1)
        }
        let unknown = try item(
            duration: nil, userData: ["Played": false, "PlaybackPositionTicks": 60_000_000, "PlayedPercentage": 50])
        XCTAssertTrue(unknown.isInProgress)
        XCTAssertEqual(unknown.remainingTimeLabel, "Continue")
        XCTAssertEqual(unknown.progressFraction, 0.5)
        let hour = try item(duration: 36_000_000_000, userData: ["Played": false, "PlaybackPositionTicks": 1])
        XCTAssertEqual(hour.remainingTimeLabel, "1h")
    }
}
