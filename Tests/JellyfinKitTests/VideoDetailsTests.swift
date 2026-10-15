import Foundation
import XCTest

@testable import JellyfinKit

final class VideoDetailsTests: XCTestCase {
    func testHydratingDetailsForSameMovieIsAContentChange() throws {
        let catalog = try decode(#"{"Id":"movie","Name":"Movie"}"#)
        let hydrated = try decode(
            #"""
            {"Id":"movie","Name":"Movie","People":[{"Id":"actor","Name":"Actor","Type":"Actor"}],
             "MediaStreams":[{"Type":"Audio","Language":"eng"}],"Studios":[{"Name":"Studio"}],
             "ProductionLocations":["Canada"]}
            """#)
        XCTAssertEqual(catalog.id, hydrated.id, "List identity must stay stable while details load")
        XCTAssertNotEqual(catalog, hydrated, "Detail sections must see the new cast and track data")
        XCTAssertEqual(
            hydrated,
            try decode(
                #"""
                {"Id":"movie","Name":"Movie","People":[{"Id":"actor","Name":"Actor","Type":"Actor"}],
                 "MediaStreams":[{"Type":"Audio","Language":"eng"}],"Studios":[{"Name":"Studio"}],
                 "ProductionLocations":["Canada"]}
                """#))
    }

    func testWatchStatusRefreshForSameMovieIsAContentChange() throws {
        let unwatched = try decode(
            #"{"Id":"movie","Name":"Movie","UserData":{"Played":false,"PlaybackPositionTicks":0}}"#)
        let started = try decode(
            #"{"Id":"movie","Name":"Movie","UserData":{"Played":false,"PlaybackPositionTicks":100000000}}"#)
        XCTAssertEqual(unwatched.id, started.id)
        XCTAssertNotEqual(unwatched, started, "Poster status must refresh when playback changes")
    }

    func testCastAndMediaMetadataDecodeFromJellyfinItem() throws {
        let video = try decode(
            #"""
            {"Id":"movie","Name":"Movie","RunTimeTicks":66000000000,"ProductionLocations":["Canada"],
             "Studios":[{"Name":"Studio"}],"People":[
                {"Id":"actor","Name":"Actor Name","Type":"Actor","Role":"Character","PrimaryImageTag":"portrait"},
                {"Id":"director","Name":"Director Name","Type":"Director"}],
             "MediaStreams":[
                {"Type":"Video","Width":3840,"Height":1600,"VideoRange":"HDR","VideoRangeType":"DOVIWithHDR10"},
                {"Type":"Audio","Language":"eng","DisplayTitle":"English · Dolby Atmos","AudioSpatialFormat":"DolbyAtmos","IsOriginal":true,"Title":"English AD"},
                {"Type":"Subtitle","Language":"eng","IsHearingImpaired":true,"Codec":"eia_608"}]}
            """#)
        XCTAssertEqual(video.actors.first?.credit, "Character")
        XCTAssertEqual(video.actors.first?.primaryImageTag, "portrait")
        XCTAssertEqual(video.directors.first?.name, "Director Name")
        XCTAssertEqual(video.runtimeLabel, "1h 50m")
        XCTAssertEqual(video.productionLocations, ["Canada"])
        XCTAssertEqual(video.studios?.first?.name, "Studio")
        XCTAssertEqual(video.mediaBadges, ["4K", "Dolby Vision", "Dolby Atmos", "CC", "SDH", "AD"])
        XCTAssertEqual(video.detailStreams[1].label, "English · Dolby Atmos")
        XCTAssertEqual(video.detailStreams[1].languageName, "English")
    }

    func testMissingMetadataDoesNotInventBadgesAndSupportsOldItems() throws {
        let video = try decode(#"{"Id":"movie","Name":"Movie"}"#)
        XCTAssertNil(video.people)
        XCTAssertNil(video.runtimeLabel)
        XCTAssertTrue(video.detailStreams.isEmpty)
        XCTAssertTrue(video.mediaBadges.isEmpty)
    }

    func testSourceTracksFallbackDoesNotClaimAtmosOrDolbyVisionFromOrdinaryCodecs() throws {
        let video = try decode(
            #"""
            {"Id":"movie","Name":"Movie","MediaSources":[{"MediaStreams":[
                {"Type":"Video","Width":1920,"Height":1080,"VideoRangeType":"DOVIInvalid","VideoRange":"SDR"},
                {"Type":"Audio","Codec":"eac3","Title":"Addendum","Channels":6},
                {"Type":"Subtitle","Codec":"srt","Title":"English"}]}]}
            """#)
        XCTAssertEqual(video.mediaBadges, ["HD"])
        XCTAssertFalse(video.detailStreams[1].hasAudioDescription)
    }

    func testAttachedCoverImageDoesNotDetermineVideoQuality() throws {
        let video = try decode(
            #"""
            {"Id":"movie","Name":"Movie","MediaStreams":[
                {"Type":"Video","Width":4000,"Height":4000,"IsAttachedPic":true},
                {"Type":"Video","Width":720,"Height":480,"VideoRange":"SDR"}]}
            """#)
        XCTAssertTrue(video.mediaBadges.isEmpty)
    }

    private func decode(_ json: String) throws -> VideoItem {
        try JSONDecoder().decode(VideoItem.self, from: Data(json.utf8))
    }
}
