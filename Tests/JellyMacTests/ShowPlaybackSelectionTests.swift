import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class ShowPlaybackSelectionTests: XCTestCase {
    func testNewShowStartsFirstRegularEpisodeInSeasonOrder() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("s2e1", season: 2, number: 1), episode("s1e2", number: 2),
                episode("special", season: 0), episode("s1e1"),
            ]))
        XCTAssertEqual(selection.episode.id, "s1e1")
        XCTAssertEqual(selection.title, "Start")
    }

    func testContinueSkipsPlayedEpisodesAndCrossesSeasonBoundary() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("s1e1", played: true), episode("s1e2", number: 2, played: true),
                episode("s2e1", season: 2), episode("s2e2", season: 2, number: 2),
            ]))
        XCTAssertEqual(selection.episode.id, "s2e1")
        XCTAssertEqual(selection.title, "Continue")
    }

    func testUnwatchedGapIsSelectedBeforeLaterEpisodes() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("one", played: true), episode("three", number: 3, played: true),
                episode("four", number: 4), episode("two", number: 2),
            ]))
        XCTAssertEqual(selection.episode.id, "two")
    }

    func testMostRecentlyWatchedUnfinishedEpisodeWinsAcrossSeasons() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("older", position: 100_000_000, lastPlayed: "2026-10-14T14:00:00Z"),
                episode(
                    "latest", season: 2, number: 8, position: 200_000_000,
                    lastPlayed: "2026-10-14T18:00:00.1234567Z"),
                episode("unplayed", number: 2),
            ]))
        XCTAssertEqual(selection.episode.id, "latest")
        XCTAssertEqual(selection.episode.resumePositionSeconds, 20)
        XCTAssertEqual(selection.title, "Continue")
    }

    func testDatesWithDifferentOffsetsAreComparedAsInstants() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("earlier", position: 100, lastPlayed: "2026-10-14T20:00:00+02:00"),
                episode("later", number: 2, position: 100, lastPlayed: "2026-10-14T18:30:00Z"),
            ]))
        XCTAssertEqual(selection.episode.id, "later")
    }

    func testMultipleUnfinishedEpisodesWithoutDatesUseEpisodeOrder() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("three", number: 3, position: 100), episode("two", number: 2, position: 100),
            ]))
        XCTAssertEqual(selection.episode.id, "two")
    }

    func testRewatchInProgressIsResumedEvenIfMarkedPlayed() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("one", played: true, position: 100_000_000), episode("two", number: 2),
            ]))
        XCTAssertEqual(selection.episode.id, "one")
        XCTAssertEqual(selection.title, "Continue")
    }

    func testFullyWatchedShowCanBeReplayedFromFirstRegularEpisode() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("special", season: 0), episode("one", played: true),
                episode("two", number: 2, played: true),
            ]))
        XCTAssertEqual(selection.episode.id, "one")
        XCTAssertEqual(selection.episode.resumePositionSeconds, 0)
        XCTAssertEqual(selection.title, "Play Again")
    }

    func testUnfinishedSpecialCanBeResumedAndSpecialOnlyShowCanStart() throws {
        let selection = try XCTUnwrap(
            ShowPlaybackSelection(episodes: [
                episode("one"), episode("special", season: 0, position: 100),
            ]))
        XCTAssertEqual(selection.episode.id, "special")
        XCTAssertEqual(selection.title, "Continue")
        let specialOnly = try XCTUnwrap(ShowPlaybackSelection(episodes: [episode("only", season: 0)]))
        XCTAssertEqual(specialOnly.episode.id, "only")
        XCTAssertEqual(specialOnly.title, "Start")
    }

    func testEmptyShowHasNoPlayTarget() {
        XCTAssertNil(ShowPlaybackSelection(episodes: []))
    }

    private func episode(
        _ id: String, season: Int = 1, number: Int = 1, played: Bool = false,
        position: Int64 = 0, lastPlayed: String? = nil
    ) throws -> VideoItem {
        var userData: [String: Any] = ["Played": played, "PlaybackPositionTicks": position]
        if let lastPlayed { userData["LastPlayedDate"] = lastPlayed }
        let json: [String: Any] = [
            "Id": id, "Name": id, "Type": "Episode", "SeriesId": "show",
            "ParentIndexNumber": season, "IndexNumber": number,
            "RunTimeTicks": 18_000_000_000 as Int64, "UserData": userData,
        ]
        return try JSONDecoder().decode(VideoItem.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
