import Foundation
import XCTest

@testable import JellyfinKit

final class JellyfinClientTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client(authenticated: Bool = true, address: String = "http://localhost:8096/jellyfin/") throws
        -> JellyfinClient
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session =
            authenticated ? JellyfinSession(userID: "user-1", username: "Alice", accessToken: "secret-token") : nil
        return try JellyfinClient(
            address: address, deviceID: "test-device", transport: URLSession(configuration: configuration),
            session: session)
    }

    private func video() throws -> VideoItem {
        try JSONDecoder().decode(VideoItem.self, from: Data(#"{"Id":"video-1","Name":"Movie","Type":"Movie"}"#.utf8))
    }

    func testRelatedTitlesUseJellyfinsRankingAndExcludeSelfDuplicatesAndEpisodes() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items/current/Similar")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "12")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            return (
                200,
                #"{"Items":[{"Id":"current","Name":"Current","Type":"Movie"},{"Id":"movie","Name":"Related","Type":"Movie"},{"Id":"movie","Name":"Duplicate","Type":"Movie"},{"Id":"episode","Name":"Episode","Type":"Episode"},{"Id":"show","Name":"Related Show","Type":"Series"}],"TotalRecordCount":5}"#
            )
        }
        let result = try await client().relatedTitles(itemID: "current")
        XCTAssertEqual(result.map(\.id), ["movie", "show"])
    }

    func testFilmographyUsesPersonIdentityRoleAndServerPaginationWithNameFallback() async throws {
        for json in [#"{"Id":"actor-1","Name":"Actor","Type":"Actor"}"#, #"{"Name":"Actor","Type":"Director"}"#] {
            let person = try JSONDecoder().decode(VideoPerson.self, from: Data(json.utf8))
            StubProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/jellyfin/Items")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "personIds" }?.value, person.itemID)
                XCTAssertEqual(query.first { $0.name == "person" }?.value, person.itemID == nil ? person.name : nil)
                XCTAssertEqual(query.first { $0.name == "personTypes" }?.value, person.type)
                XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Movie,Series")
                XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "100")
                XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
                return (200, #"{"Items":[{"Id":"movie","Name":"Movie","Type":"Movie"}],"TotalRecordCount":101}"#)
            }
            let page = try await client().titles(for: person, startIndex: 100)
            XCTAssertEqual(page.items.first?.id, "movie")
            XCTAssertEqual(page.totalCount, 101)
        }
    }

    func testIntroMarkersHaveRealBoundsAndNeverSkipUnknownOrInvalidIntervals() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.filter { $0.name == "includeSegmentTypes" }.compactMap(\.value), ["Intro", "Outro"])
            return (
                200,
                #"{"Items":[{"Type":"Intro","StartTicks":100000000,"EndTicks":600000000},{"Type":"Intro","StartTicks":700000000},{"Type":"Intro","StartTicks":800000000,"EndTicks":700000000},{"Type":"Intro","StartTicks":-1,"EndTicks":10000000}]}"#
            )
        }
        let markers = try await client().mediaSegments(itemID: "episode")
        XCTAssertEqual(markers.count, 3)
        let intro = try XCTUnwrap(markers.first)
        XCTAssertFalse(intro.contains(seconds: 9.9))
        XCTAssertTrue(intro.contains(seconds: 10))
        XCTAssertTrue(intro.contains(seconds: 59.9))
        XCTAssertFalse(intro.contains(seconds: 60))
        XCTAssertFalse(intro.contains(seconds: .nan))
        XCTAssertEqual(intro.endSeconds, 60)
        XCTAssertFalse(markers[1].isSkippable)
        XCTAssertFalse(markers[2].isSkippable)
        StubProtocol.handler = { _ in (404, "") }
        let missing = try await client().mediaSegments(itemID: "episode")
        XCTAssertTrue(missing.isEmpty)
    }

    func testLoginUsesJellyfinBodyAndPreservesReverseProxyPath() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Users/AuthenticateByName")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"Theatre\"") == true)
            XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == true)
            let body = try StubProtocol.body(request)
            XCTAssertEqual(body["Username"] as? String, "Alice")
            XCTAssertEqual(body["Pw"] as? String, "a password with spaces")
            return (200, #"{"AccessToken":"token","User":{"Id":"user-1","Name":"Alice"}}"#)
        }
        let result = try await client(authenticated: false).authenticate(
            username: "Alice", password: "a password with spaces")
        XCTAssertEqual(result.userID, "user-1")
        XCTAssertEqual(result.accessToken, "token")
    }

    func testVideoListingUsesAuthenticatedPaginationAndSearch() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(values["userId"], "user-1")
            XCTAssertEqual(values["startIndex"], "100")
            XCTAssertEqual(values["limit"], "100")
            XCTAssertEqual(values["mediaTypes"], "Video")
            XCTAssertEqual(values["recursive"], "true")
            XCTAssertEqual(values["enableImages"], "true")
            XCTAssertEqual(values["enableUserData"], "true")
            XCTAssertEqual(values["sortBy"], "SortName")
            XCTAssertEqual(values["sortOrder"], "Ascending")
            XCTAssertEqual(values["searchTerm"], "science & nature")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            return (
                200,
                #"{"Items":[{"Id":"episode-1","Name":"Pilot","Type":"Episode","SeriesName":"A Show","ParentIndexNumber":1,"IndexNumber":2}],"TotalRecordCount":101}"#
            )
        }
        let result = try await client().videos(startIndex: 100, search: "science & nature")
        XCTAssertEqual(result.totalCount, 101)
        XCTAssertEqual(result.items[0].title, "A Show · S1 E2 — Pilot")
    }

    func testMovieShowAndEpisodeFiltersUseJellyfinItemTypes() async throws {
        for (types, parent) in [(["Movie"], nil), (["Series"], nil), (["Episode"], "series-1")] {
            StubProtocol.handler = { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["includeItemTypes"], types.joined(separator: ","))
                XCTAssertEqual(query["parentId"], parent)
                if types == ["Series"] {
                    XCTAssertNil(query["mediaTypes"])
                } else {
                    XCTAssertEqual(query["mediaTypes"], "Video")
                }
                if parent != nil { XCTAssertEqual(query["sortBy"], "ParentIndexNumber,IndexNumber,SortName") }
                return (200, #"{"Items":[],"TotalRecordCount":0}"#)
            }
            _ = try await client().videos(itemTypes: types, parentID: parent)
        }
    }

    func testCatalogFiltersApplyOnTheServerAlongsideSearchAndPagination() async throws {
        StubProtocol.handler = { request in
            let query = Dictionary(
                uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map
                { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["filters"], "IsUnplayed")
            XCTAssertEqual(query["genres"], "Science Fiction & Fantasy")
            XCTAssertEqual(query["years"], "2024")
            XCTAssertEqual(query["searchTerm"], "star")
            XCTAssertEqual(query["startIndex"], "100")
            XCTAssertEqual(query["includeItemTypes"], "Movie")
            XCTAssertTrue(query["fields"]?.contains("SortName") == true)
            return (200, #"{"Items":[],"TotalRecordCount":0}"#)
        }
        var filters = VideoFilters()
        filters.watchStatus = .unplayed
        filters.genre = "Science Fiction & Fantasy"
        filters.year = 2024
        _ = try await client().videos(startIndex: 100, search: "star", itemTypes: ["Movie"], filters: filters)
    }

    func testAvailableFiltersAreScopedToTheSelectedLibraryType() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items/Filters")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Series")
            XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
            return (200, #"{"Genres":["Drama","Comedy"],"Years":[2024,2020]}"#)
        }
        let options = try await client().videoFilterOptions(itemTypes: ["Series"])
        XCTAssertEqual(options.genres, ["Drama", "Comedy"])
        XCTAssertEqual(options.years, [2024, 2020])
    }

    func testOriginalDownloadAndExternalSubtitlesKeepAuthenticationInHeaders() throws {
        let api = try client()
        let file = try api.downloadRequest(itemID: "movie")
        XCTAssertEqual(file.url?.path, "/jellyfin/Items/movie/Download")
        XCTAssertFalse(file.url!.absoluteString.contains("secret-token"))
        XCTAssertTrue(file.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
        let subtitle = try api.subtitleDownloadRequest(itemID: "movie", sourceID: "source", index: 3, format: "ass")
        XCTAssertEqual(subtitle.url?.path, "/jellyfin/Videos/movie/source/Subtitles/3/Stream.ass")
        XCTAssertNotNil(subtitle.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(
            try api.subtitleDownloadRequest(itemID: "movie", sourceID: "source", index: 3, format: "../file"))
    }

    func testRecentlyAddedRequestsNewestItemsAcrossTheLibrary() async throws {
        StubProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            XCTAssertEqual(query["userId"], "user-1")
            XCTAssertEqual(query["sortBy"], "DateCreated")
            XCTAssertEqual(query["sortOrder"], "Descending")
            XCTAssertEqual(query["limit"], "30")
            XCTAssertEqual(query["startIndex"], "0")
            XCTAssertEqual(query["recursive"], "true")
            XCTAssertEqual(query["mediaTypes"], "Video")
            XCTAssertEqual(query["enableImages"], "true")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            return (
                200,
                #"{"Items":[{"Id":"new","Name":"Z New Movie","Type":"Movie"},{"Id":"old","Name":"A Old Episode","Type":"Episode"}],"TotalRecordCount":200}"#
            )
        }
        let result = try await client().videos(limit: 30, newestFirst: true)
        XCTAssertEqual(result.items.map(\.id), ["new", "old"])
    }

    func testResumeCatalogIncludesUserPlaybackData() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/UserItems/Resume")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
            XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
            XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "100")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
            return (
                200,
                #"{"Items":[{"Id":"ep-1","Name":"Pilot","Type":"Episode","SeriesId":"series-1","RunTimeTicks":12000000000,"UserData":{"Played":false,"PlaybackPositionTicks":4800000000}}],"TotalRecordCount":1}"#
            )
        }
        let result = try await client().resumeVideos(limit: 50, startIndex: 100)
        XCTAssertEqual(result.items[0].seriesID, "series-1")
        XCTAssertEqual(result.items[0].resumePositionSeconds, 480)
        XCTAssertEqual(result.items[0].remainingTimeLabel, "12m")
    }

    func testPlaybackCarriesTheSavedResumePosition() async throws {
        let movie = try JSONDecoder().decode(
            VideoItem.self,
            from: Data(
                #"{"Id":"video-1","Name":"Movie","RunTimeTicks":1000000000,"UserData":{"Played":false,"PlaybackPositionTicks":300000000}}"#
                    .utf8))
        StubProtocol.handler = { _ in
            (200, #"{"MediaSources":[{"Id":"source","Container":"mkv","SupportsDirectPlay":true}]}"#)
        }
        let direct = try await client().playback(for: movie)
        XCTAssertEqual(direct.resumePositionSeconds, 30)
        StubProtocol.handler = { _ in
            (200, #"{"MediaSources":[{"Id":"source","TranscodingUrl":"/Videos/video-1/master.m3u8"}]}"#)
        }
        let converted = try await client().playback(for: movie)
        XCTAssertEqual(converted.resumePositionSeconds, 30)
    }

    func testRecommendationResumeQueryFiltersMoviesBeforeLimitingToFive() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/UserItems/Resume")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Movie")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "5")
            XCTAssertEqual(query.first { $0.name == "fields" }?.value, "Overview,Genres")
            return (
                200,
                #"{"Items":[{"Id":"movie","Name":"Movie","Type":"Movie","UserData":{"LastPlayedDate":"2026-10-15T00:00:00Z"}}],"TotalRecordCount":1}"#
            )
        }
        let result = try await client().resumeVideos(limit: 5, itemTypes: ["Movie"])
        XCTAssertEqual(result.items.first?.userData?.lastPlayedDate, "2026-10-15T00:00:00Z")
    }

    func testCastPortraitUsesAuthenticatedJellyfinArtworkAndProxyPrefix() throws {
        let person = try JSONDecoder().decode(
            VideoPerson.self, from: Data(#"{"Id":"person-1","Name":"Actor","PrimaryImageTag":"portrait-v1"}"#.utf8))
        let request = try XCTUnwrap(client().imageRequest(for: person))
        XCTAssertEqual(request.url?.path, "/jellyfin/Items/person-1/Images/Primary")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
        XCTAssertFalse(request.url!.absoluteString.contains("secret-token"))
        XCTAssertTrue(request.url!.absoluteString.contains("portrait-v1"))
        XCTAssertThrowsError(try client(authenticated: false).imageRequest(for: person))
    }

    func testSeasonsLoadFromTheSelectedShowForCurrentUser() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Shows/show-1/Seasons")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
            XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            return (
                200,
                #"{"Items":[{"Id":"season-0","Name":"Specials","Type":"Season","IndexNumber":0},{"Id":"season-1","Name":"Season 1","Type":"Season","IndexNumber":1}],"TotalRecordCount":2}"#
            )
        }
        let result = try await client().seasons(seriesID: "show-1")
        XCTAssertEqual(result.items.map(\.indexNumber), [0, 1])
        XCTAssertEqual(result.items[1].id, "season-1")
    }

    func testEpisodeQueryIsScopedToSeasonAndIncludesSynopsisAndPlaybackInfo() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Shows/show-1/Episodes")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "seasonId" }?.value, "season-2")
            XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "100")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
            XCTAssertEqual(query.first { $0.name == "isMissing" }?.value, "false")
            XCTAssertTrue(query.first { $0.name == "fields" }?.value?.contains("Overview") == true)
            XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
            return (
                200,
                #"{"Items":[{"Id":"episode","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":2,"Overview":"An episode synopsis.","RunTimeTicks":18000000000,"ImageTags":{"Primary":"episode-image"},"UserData":{"Played":false,"PlaybackPositionTicks":8400000000}}],"TotalRecordCount":101}"#
            )
        }
        let result = try await client().episodes(seriesID: "show-1", seasonID: "season-2", startIndex: 100, limit: 50)
        XCTAssertEqual(result.totalCount, 101)
        let episode = try XCTUnwrap(result.items.first)
        XCTAssertEqual(episode.overview, "An episode synopsis.")
        XCTAssertEqual(episode.imageTags?["Primary"], "episode-image")
        XCTAssertEqual(episode.remainingTimeLabel, "16m")
        XCTAssertTrue(episode.isInProgress)
    }

    func testShowBrowsingRequiresAuthentication() async throws {
        do {
            _ = try await client(authenticated: false).seasons(seriesID: "show")
            XCTFail("Season browsing must require sign-in")
        } catch JellyfinError.unauthorized {}
        do {
            _ = try await client(authenticated: false).episodes(seriesID: "show", seasonID: "season")
            XCTFail("Episode browsing must require sign-in")
        } catch JellyfinError.unauthorized {}
    }

    func testShowPlayTargetUsesLatestResumableEpisodeWithoutLoadingAllEpisodes() async throws {
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            XCTAssertEqual(query.first { $0.name == "parentId" }?.value, "show")
            XCTAssertEqual(query.first { $0.name == "filters" }?.value, "IsResumable")
            XCTAssertEqual(query.first { $0.name == "sortBy" }?.value, "DatePlayed,ParentIndexNumber,IndexNumber")
            XCTAssertEqual(query.first { $0.name == "sortOrder" }?.value, "Descending,Ascending,Ascending")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "1")
            return (
                200,
                #"{"Items":[{"Id":"later-season","Name":"Later","Type":"Episode","UserData":{"PlaybackPositionTicks":100000000}}],"TotalRecordCount":40}"#
            )
        }
        let items = try await client().showPlaybackCandidates(seriesID: "show")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(items.first?.resumePositionSeconds, 10)
    }

    func testShowPlayTargetUsesServerNextUpAndNextEpisodeCrossesSeasons() async throws {
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Items") { return (200, #"{"Items":[],"TotalRecordCount":0}"#) }
            if request.url!.path.hasSuffix("/NextUp") {
                return (
                    200,
                    #"{"Items":[{"Id":"next","Name":"Next","Type":"Episode","ParentIndexNumber":2,"IndexNumber":1}],"TotalRecordCount":1}"#
                )
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "startItemId" }?.value, "current")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "2")
            return (
                200, #"{"Items":[{"Id":"current","Name":"Current"},{"Id":"next","Name":"Next"}],"TotalRecordCount":2}"#
            )
        }
        let items = try await client().showPlaybackCandidates(seriesID: "show")
        XCTAssertEqual(items.first?.id, "next")
        let episode = try JSONDecoder().decode(
            VideoItem.self, from: Data(#"{"Id":"current","Name":"Current","Type":"Episode","SeriesId":"show"}"#.utf8))
        let next = try await client().nextEpisode(after: episode)
        XCTAssertEqual(next?.id, "next")
    }

    func testMovieDetailLoadsMetadataAndArtworkForCurrentUser() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "userId" }?.value, "user-1")
            XCTAssertEqual(query.first { $0.name == "ids" }?.value, "video-1")
            let fields = Set((query.first { $0.name == "fields" }?.value ?? "").split(separator: ",").map(String.init))
            XCTAssertTrue(
                Set(["People", "Studios", "ProductionLocations", "MediaStreams", "MediaSources", "RemoteTrailers"])
                    .isSubset(of: fields))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            return (
                200,
                #"{"Items":[{"Id":"video-1","Name":"Movie","Overview":"A movie synopsis.","Genres":["Drama"],"ImageTags":{"Primary":"poster-tag","Logo":"logo-tag"},"BackdropImageTags":["backdrop-tag"],"People":[{"Id":"actor","Name":"Actor","Type":"Actor","PrimaryImageTag":"portrait"}],"Studios":[{"Name":"Studio"}],"ProductionLocations":["United States of America"],"MediaStreams":[{"Type":"Audio","Language":"eng","Codec":"eac3"},{"Type":"Subtitle","Language":"fre","Codec":"subrip","IsHearingImpaired":true}]}],"TotalRecordCount":1}"#
            )
        }
        let movie = try await client().item(id: "video-1")
        XCTAssertEqual(movie.overview, "A movie synopsis.")
        XCTAssertEqual(movie.genres, ["Drama"])
        XCTAssertEqual(movie.imageTags?["Primary"], "poster-tag")
        XCTAssertEqual(movie.backdropImageTags, ["backdrop-tag"])
        XCTAssertEqual(movie.actors.first?.name, "Actor")
        XCTAssertEqual(movie.studios?.first?.name, "Studio")
        XCTAssertEqual(movie.productionLocations, ["United States of America"])
        XCTAssertEqual(movie.detailStreams.count, 2)
        XCTAssertTrue(movie.mediaBadges.contains("SDH"))
    }

    func testArtworkPreservesProxyPrefixAndAuthenticatesWithoutTokenInURL() throws {
        let movie = try JSONDecoder().decode(
            VideoItem.self,
            from: Data(
                #"{"Id":"video-1","Name":"Movie","ImageTags":{"Primary":"poster-tag","Logo":"logo-tag"},"BackdropImageTags":["backdrop-tag"]}"#
                    .utf8))
        for type in [JellyfinImageType.primary, .logo, .backdrop] {
            let request = try XCTUnwrap(client().imageRequest(for: movie, type: type, maxWidth: 420))
            XCTAssertEqual(request.url?.path, "/jellyfin/Items/video-1/Images/\(type.rawValue)")
            XCTAssertFalse(request.url!.absoluteString.contains("secret-token"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == true)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "maxWidth" }?.value, "420")
            XCTAssertNotNil(query.first { $0.name == "tag" })
            if type == .logo { XCTAssertEqual(query.first { $0.name == "format" }?.value, "Png") }
            if type == .backdrop { XCTAssertEqual(query.first { $0.name == "imageIndex" }?.value, "0") }
        }
    }

    func testMissingArtworkAndInheritedEpisodeArtwork() throws {
        let api = try client()
        XCTAssertNil(try api.imageRequest(for: video(), type: .primary, maxWidth: 420))
        XCTAssertNil(try api.imageRequest(for: video(), type: .logo, maxWidth: 420))
        let episode = try JSONDecoder().decode(
            VideoItem.self,
            from: Data(
                #"{"Id":"episode-1","Name":"Pilot","ParentBackdropItemId":"series-1","ParentBackdropImageTags":["backdrop"],"ParentLogoItemId":"series-1","ParentLogoImageTag":"logo"}"#
                    .utf8))
        XCTAssertEqual(
            try api.imageRequest(for: episode, type: .backdrop, maxWidth: 1920)?.url?.path,
            "/jellyfin/Items/series-1/Images/Backdrop")
        XCTAssertEqual(
            try api.imageRequest(for: episode, type: .logo, maxWidth: 900)?.url?.path,
            "/jellyfin/Items/series-1/Images/Logo")
        XCTAssertThrowsError(try client(authenticated: false).imageRequest(for: episode, type: .logo, maxWidth: 900))
    }

    func testDirectPlaybackUsesServerEndpointAndToken() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items/video-1/PlaybackInfo")
            let body = try StubProtocol.body(request)
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
            let transcodes = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
            XCTAssertEqual(transcodes[0]["Protocol"] as? String, "hls")
            XCTAssertEqual(transcodes[0]["VideoCodec"] as? String, "h264")
            return (
                200,
                #"{"MediaSources":[{"Id":"source-1","Container":"mp4","Path":"/server/private/movie.mp4","SupportsDirectPlay":true}],"PlaySessionId":"play-1"}"#
            )
        }
        let stream = try await client().playback(for: video())
        XCTAssertEqual(stream.method, "DirectPlay")
        XCTAssertEqual(stream.url.path, "/jellyfin/Videos/video-1/stream.mp4")
        let query = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "api_key" }?.value, "secret-token")
        XCTAssertEqual(query.first { $0.name == "mediaSourceId" }?.value, "source-1")
    }

    func testPlaybackUsesDisplayAspectRatioThenFallsBackToDimensions() async throws {
        for (metadata, expected) in [
            (#""AspectRatio":"16:9","Width":720,"Height":576"#, 16.0 / 9.0),
            (#""AspectRatio":"2.35:1""#, 2.35),
            (#""AspectRatio":"1.85""#, 1.85),
            (#""AspectRatio":"invalid","Width":3840,"Height":1600"#, 2.4),
            (#""Width":1080,"Height":1920"#, 9.0 / 16.0),
        ] {
            StubProtocol.handler = { _ in
                (
                    200,
                    "{\"MediaSources\":[{\"Id\":\"source\",\"Container\":\"mkv\",\"SupportsDirectPlay\":true,\"MediaStreams\":[{\"Index\":0,\"Type\":\"Video\",\(metadata)}]}]}"
                )
            }
            let stream = try await client().playback(for: video())
            XCTAssertEqual(try XCTUnwrap(stream.videoAspectRatio), expected, accuracy: 0.0001)
        }
    }

    func testUnsupportedDirectSourceFallsBackToHLSAndDoesNotDuplicateBasePath() async throws {
        StubProtocol.handler = { _ in
            (
                200,
                #"{"MediaSources":[{"Id":"source-1","Container":"mkv","SupportsDirectPlay":false,"TranscodingUrl":"/jellyfin/Videos/video-1/master.m3u8?VideoCodec=h264&api_key=stale"}],"PlaySessionId":"play-1"}"#
            )
        }
        let stream = try await client().playback(for: video())
        XCTAssertEqual(stream.method, "Transcode")
        XCTAssertEqual(stream.url.path, "/jellyfin/Videos/video-1/master.m3u8")
        let tokens = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)!.queryItems!.filter {
            $0.name == "api_key"
        }
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].value, "secret-token")
    }

    func testMKVAndCompoundMP4ContainersPreferDirectPlayback() async throws {
        for (container, expected) in [
            ("matroska", "mkv"), ("mov,mp4,m4a,3gp,3g2,mj2", "mp4"), ("avi", "avi"), ("webm", "webm"),
        ] {
            StubProtocol.handler = { request in
                let body = try StubProtocol.body(request)
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                XCTAssertEqual(profile["Name"] as? String, "Theatre VLCKit")
                let direct = try XCTUnwrap(profile["DirectPlayProfiles"] as? [[String: Any]])
                XCTAssertTrue((direct[0]["Container"] as? String)?.contains("mkv") == true)
                return (
                    200,
                    "{\"MediaSources\":[{\"Id\":\"source\",\"Container\":\"\(container)\",\"SupportsDirectPlay\":true,\"TranscodingUrl\":\"/Videos/video-1/master.m3u8\"}]}"
                )
            }
            let stream = try await client().playback(for: video())
            XCTAssertEqual(stream.method, "DirectPlay")
            XCTAssertTrue(stream.url.path.hasSuffix("stream.\(expected)"))
        }
    }

    func testPrefersAnyDirectPlayableVersionOverFirstTranscodedVersion() async throws {
        StubProtocol.handler = { _ in
            (
                200,
                #"{"MediaSources":[{"Id":"convert","SupportsDirectPlay":false,"TranscodingUrl":"/Videos/video-1/master.m3u8"},{"Id":"direct","Container":"mkv","SupportsDirectPlay":true}]}"#
            )
        }
        let stream = try await client().playback(for: video())
        XCTAssertEqual(stream.mediaSourceID, "direct")
        XCTAssertEqual(stream.method, "DirectPlay")
    }

    func testExternalSubtitlesStayAuthenticatedAndUnderServerPrefix() async throws {
        StubProtocol.handler = { _ in
            (
                200,
                #"{"MediaSources":[{"Id":"source","Container":"mkv","SupportsDirectPlay":true,"MediaStreams":[{"Index":3,"Type":"Subtitle","IsExternal":true,"DisplayTitle":"English","DeliveryUrl":"/Videos/video-1/Subtitles/3/Stream.srt"}]}]}"#
            )
        }
        let stream = try await client().playback(for: video())
        XCTAssertEqual(stream.externalSubtitles.count, 1)
        XCTAssertEqual(stream.externalSubtitles[0].name, "English")
        XCTAssertEqual(stream.externalSubtitles[0].url.path, "/jellyfin/Videos/video-1/Subtitles/3/Stream.srt")
        XCTAssertTrue(stream.externalSubtitles[0].url.query?.contains("api_key=secret-token") == true)
    }

    func testCompatibleRetryDisablesDirectPlayAndStreamCopy() async throws {
        StubProtocol.handler = { request in
            let body = try StubProtocol.body(request)
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
            XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
            XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false)
            XCTAssertEqual(body["AllowAudioStreamCopy"] as? Bool, false)
            return (
                200,
                #"{"MediaSources":[{"Id":"source-1","Container":"mp4","SupportsDirectPlay":true,"TranscodingUrl":"/Videos/video-1/master.m3u8"}],"PlaySessionId":"play-1"}"#
            )
        }
        let stream = try await client().playback(for: video(), compatibleOnly: true)
        XCTAssertEqual(stream.method, "Transcode")
        XCTAssertEqual(stream.url.path, "/jellyfin/Videos/video-1/master.m3u8")
    }

    func testSystemPlaybackRequestsH264AACAndSelectableHLSSubtitles() async throws {
        StubProtocol.handler = { request in
            let body = try StubProtocol.body(request)
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true)
            XCTAssertEqual(body["EnableDirectStream"] as? Bool, true)
            XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, true)
            XCTAssertEqual(body["AllowAudioStreamCopy"] as? Bool, true)
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
            let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
            XCTAssertEqual(transcode["VideoCodec"] as? String, "h264")
            XCTAssertEqual(transcode["AudioCodec"] as? String, "aac")
            XCTAssertEqual(transcode["EnableSubtitlesInManifest"] as? Bool, true)
            let subtitles = try XCTUnwrap(profile["SubtitleProfiles"] as? [[String: String]])
            XCTAssertEqual(subtitles, [["Format": "vtt", "Method": "Hls"]])
            return (
                200,
                #"{"MediaSources":[{"Id":"source-1","TranscodingUrl":"/Videos/video-1/master.m3u8"}],"PlaySessionId":"play-1"}"#
            )
        }
        let stream = try await client().playback(for: video(), nativePlayer: true)
        XCTAssertEqual(stream.method, "Transcode")
        XCTAssertEqual(stream.url.path, "/jellyfin/Videos/video-1/master.m3u8")
    }

    func testCreditMarkersAreServerProvidedAndOlderServersCanOmitThem() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/MediaSegments/video-1")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            // This endpoint binds repeated enum values; a comma-delimited value can collapse to Intro.
            let types = query.filter { $0.name == "includeSegmentTypes" }.compactMap(\.value)
            XCTAssertEqual(types, ["Intro", "Outro"])
            return (
                200,
                types.contains("Outro")
                    ? #"{"Items":[{"Type":"Intro","StartTicks":10000000},{"Type":"Outro","StartTicks":600000000}],"TotalRecordCount":2}"#
                    : #"{"Items":[{"Type":"Intro","StartTicks":10000000}],"TotalRecordCount":1}"#
            )
        }
        let start = try await client().creditsStart(itemID: "video-1")
        XCTAssertEqual(start, 60)
        StubProtocol.handler = { _ in (404, "") }
        let absent = try await client().creditsStart(itemID: "video-1")
        XCTAssertNil(absent)
    }

    func testWatchStatusAndUnusedEncodingCleanupUseAuthenticatedScopedRequests() async throws {
        var methods: [String] = []
        StubProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == true)
            methods.append(request.httpMethod ?? "")
            if request.url!.path.hasSuffix("ActiveEncodings") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "playSessionId" }?.value, "encoding-to-stop")
                XCTAssertNotNil(query.first { $0.name == "deviceId" })
            } else {
                XCTAssertEqual(request.url!.path, "/jellyfin/UserPlayedItems/video-1")
            }
            return (204, "")
        }
        let client = try client()
        try await client.setWatched(true, itemID: "video-1")
        try await client.setWatched(false, itemID: "video-1")
        let stream = PlaybackStream(
            url: URL(string: "https://example.test")!, itemID: "video-1", mediaSourceID: "source",
            playSessionID: "encoding-to-stop", method: "Transcode")
        try await client.stopEncoding(stream)
        XCTAssertEqual(methods, ["POST", "DELETE", "DELETE"])
    }

    func testNativeNegotiationPreservesTheSourceAndSelectedTrackIndexes() async throws {
        StubProtocol.handler = { request in
            let body = try StubProtocol.body(request)
            XCTAssertEqual(body["MediaSourceId"] as? String, "selected-version")
            XCTAssertEqual(body["AudioStreamIndex"] as? Int, 3)
            XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true)
            return (
                200,
                #"{"MediaSources":[{"Id":"selected-version","Container":"mp4","SupportsDirectPlay":true}],"PlaySessionId":"native"}"#
            )
        }
        let stream = try await client().playback(
            for: video(), nativePlayer: true, mediaSourceID: "selected-version", audioStreamIndex: 3,
            subtitleStreamIndex: -1)
        XCTAssertEqual(stream.method, "DirectPlay")
    }

    func testRejectsStreamingTokenLeakToAnotherServer() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"MediaSources":[{"Id":"source-1","TranscodingUrl":"https://other.example/steal"}]}"#)
        }
        do {
            _ = try await client().playback(for: video())
            XCTFail("An external stream must not receive credentials")
        } catch JellyfinError.unsafeStreamURL {}
    }

    func testPermissionFailureIsNotAnExpiredSession() async throws {
        StubProtocol.handler = { _ in (403, "Forbidden") }
        do {
            _ = try await client().videos()
            XCTFail("Expected a permission failure")
        } catch JellyfinError.forbidden {}
    }

    func testStreamCannotEscapeReverseProxyPrefixUsingDotSegments() async throws {
        for path in [
            "http://localhost:8096/jellyfin/../private/master.m3u8",
            "http://localhost:8096/jellyfin/%2e%2e/private/master.m3u8",
            "//other.example/stream.m3u8",
        ] {
            StubProtocol.handler = { _ in
                (200, "{\"MediaSources\":[{\"Id\":\"source-1\",\"TranscodingUrl\":\"\(path)\"}]}")
            }
            do {
                _ = try await client().playback(for: video())
                XCTFail("Stream escaped the configured server path: \(path)")
            } catch JellyfinError.unsafeStreamURL {}
        }
    }

    func testUnauthorizedAndMalformedResponsesHaveUsefulErrors() async throws {
        StubProtocol.handler = { _ in (401, "Password must not appear in an error") }
        do {
            _ = try await client().videos()
            XCTFail("Expected unauthorized")
        } catch JellyfinError.unauthorized {}
        StubProtocol.handler = { _ in (200, "<html>not jellyfin</html>") }
        do {
            _ = try await client().videos()
            XCTFail("Expected invalidResponse")
        } catch JellyfinError.invalidResponse {}
    }

    func testNoPlayableSourceIsReportedInsteadOfStreamingServerFilePath() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"MediaSources":[{"Id":"source-1","Container":"mkv","Path":"/private/movie.mkv"}]}"#)
        }
        do {
            _ = try await client().playback(for: video())
            XCTFail("Expected noPlayableSource")
        } catch JellyfinError.noPlayableSource {}
    }

    func testInvalidAddressesAreRejected() throws {
        for address in [
            "localhost:8096", "file:///tmp/server", "https://user:password@example.com",
            "https://example.com?token=secret", "https://example.com/#secret",
        ] {
            XCTAssertThrowsError(try client(address: address), "\(address) should not be accepted")
        }
        XCTAssertEqual(
            try client(address: "  HTTPS://example.com/jellyfin/ \n").serverURL.absoluteString,
            "https://example.com/jellyfin")
    }

    func testRecentlyAddedGroupsEpisodesIntoShowsWithSeriesArtworkAndSynopsis() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            if let ids = query.first(where: { $0.name == "ids" })?.value {
                XCTAssertEqual(Set(ids.split(separator: ",")), Set(["show-b", "show-a"]))
                // Return shows in a different order to prove the raw date order is retained.
                return (
                    200,
                    #"{"Items":[{"Id":"show-a","Name":"Show A","Type":"Series"},{"Id":"show-b","Name":"Show B","Type":"Series","Overview":"Whole show synopsis","ChildCount":3,"ImageTags":{"Primary":"show-poster","Logo":"show-logo"},"BackdropImageTags":["show-backdrop"]}],"TotalRecordCount":2}"#
                )
            }
            XCTAssertEqual(query.first { $0.name == "sortBy" }?.value, "DateCreated")
            XCTAssertEqual(query.first { $0.name == "sortOrder" }?.value, "Descending")
            XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Movie,Series,Episode")
            return (
                200,
                #"{"Items":[{"Id":"ep-new","Name":"Episode title","Type":"Episode","SeriesId":"show-b","ImageTags":{"Primary":"episode-thumbnail"}},{"Id":"movie","Name":"Movie","Type":"Movie"},{"Id":"ep-old","Name":"Older episode","Type":"Episode","SeriesId":"show-b"},{"Id":"show-a","Name":"Show A","Type":"Series"},{"Id":"show-b","Name":"Show B","Type":"Series"}],"TotalRecordCount":5}"#
            )
        }
        let titles = try await client().recentlyAddedTitles()
        XCTAssertEqual(titles.map(\.id), ["show-b", "movie", "show-a"])
        XCTAssertEqual(titles.first?.type, "Series")
        XCTAssertEqual(titles.first?.overview, "Whole show synopsis")
        XCTAssertEqual(titles.first?.imageTags?["Primary"], "show-poster")
        XCTAssertEqual(titles.first?.childCount, 3)
        XCTAssertFalse(titles.contains { $0.type == "Episode" })
    }

    func testNewEpisodeMovesExistingShowAheadOfOlderMovie() async throws {
        var newEpisodeAdded = false
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "ids" }) {
                return (200, #"{"Items":[{"Id":"show","Name":"Show","Type":"Series"}],"TotalRecordCount":1}"#)
            }
            if newEpisodeAdded {
                return (
                    200,
                    #"{"Items":[{"Id":"new","Name":"New episode","Type":"Episode","SeriesId":"show"},{"Id":"movie","Name":"Movie","Type":"Movie"},{"Id":"old","Name":"Older episode","Type":"Episode","SeriesId":"show"}],"TotalRecordCount":3}"#
                )
            }
            return (
                200,
                #"{"Items":[{"Id":"movie","Name":"Movie","Type":"Movie"},{"Id":"old","Name":"Older episode","Type":"Episode","SeriesId":"show"}],"TotalRecordCount":2}"#
            )
        }
        let api = try client()
        let before = try await api.recentlyAddedTitles()
        newEpisodeAdded = true
        let after = try await api.recentlyAddedTitles()
        XCTAssertEqual(before.map(\.id), ["movie", "show"])
        XCTAssertEqual(after.map(\.id), ["show", "movie"])
    }

    func testSeasonImportDoesNotHideOlderDistinctTitlesBeyondFirstPage() async throws {
        let importedEpisodes: [[String: Any]] = (0..<100).map {
            ["Id": "episode-\($0)", "Name": "Episode \($0)", "Type": "Episode", "SeriesId": "show"]
        }
        let firstPage = String(
            data: try JSONSerialization.data(withJSONObject: ["Items": importedEpisodes, "TotalRecordCount": 101]),
            encoding: .utf8)!
        var offsets: [String] = []
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "ids" }) {
                return (200, #"{"Items":[{"Id":"show","Name":"Show","Type":"Series"}],"TotalRecordCount":1}"#)
            }
            let offset = query.first { $0.name == "startIndex" }!.value!
            offsets.append(offset)
            if offset == "0" { return (200, firstPage) }
            return (200, #"{"Items":[{"Id":"movie","Name":"Older Movie","Type":"Movie"}],"TotalRecordCount":101}"#)
        }
        let titles = try await client().recentlyAddedTitles(limit: 2)
        XCTAssertEqual(offsets, ["0", "100"])
        XCTAssertEqual(titles.map(\.id), ["show", "movie"])
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
