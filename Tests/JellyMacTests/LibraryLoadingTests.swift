import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class LibraryLoadingTests: XCTestCase {
    @MainActor
    private func model(transport: URLSession) throws -> AppModel {
        let store = MemorySessionStore()
        let session = try JSONDecoder().decode(
            JellyfinSession.self,
            from:
                Data(#"{"userID":"user","username":"demo","accessToken":"test-only-token"}"#.utf8))
        store.saved = SavedSession(address: "https://theatre.test", deviceID: "test", session: session)
        let model = store.makeModel(transport: transport)
        model.librarySection = .movies
        return model
    }

    @MainActor
    func testReturningToTabsRestoresLoadedPagesAndPaginationButRefreshStillFetches() async throws {
        var requests: [String] = []
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let type = query.first { $0.name == "includeItemTypes" }!.value!
            let offset = query.first { $0.name == "startIndex" }!.value!
            requests.append("\(type):\(offset)")
            return .json("{\"Items\":[{\"Id\":\"\(type)-\(offset)\",\"Name\":\"Title\"}],\"TotalRecordCount\":3}")
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        await model.loadVideos(reset: false)
        model.librarySection = .shows
        await model.loadLibraryPage()
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(model.videos.map(\.id), ["Movie-0", "Movie-1"])
        XCTAssertEqual(model.totalCount, 3)
        XCTAssertTrue(model.canLoadMore)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(requests, ["Movie:0", "Movie:1", "Series:0"])
        await model.loadVideos(reset: false)
        XCTAssertEqual(requests.last, "Movie:2")
        XCTAssertFalse(model.canLoadMore)
        await model.loadVideos()
        XCTAssertEqual(requests.last, "Movie:0")
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(model.videos.map(\.id), ["Movie-0"])
    }

    @MainActor
    func testReturningHomeKeepsItsFeedsAndDoesNotRepeatRequests() async throws {
        var requests = 0
        let transport = TestURLProtocol.session { _ in
            requests += 1
            return .json(#"{"Items":[{"Id":"title","Name":"Title","Type":"Movie"}],"TotalRecordCount":1}"#)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        model.librarySection = .home
        await model.loadLibraryPage()
        XCTAssertEqual(requests, 3)
        let revision = model.homeRecommendationRevision
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(model.recentlyAddedVideos.map(\.id), ["title"])
        model.librarySection = .home
        await model.loadLibraryPage()
        model.showsDownloads = true
        await model.loadLibraryPage()
        model.showsDownloads = false
        await model.loadLibraryPage()
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(model.resumeVideos.map(\.id), ["title"])
        XCTAssertEqual(model.recentContinueMovies.map(\.id), ["title"])
        XCTAssertEqual(model.homeRecommendationRevision, revision)
        XCTAssertTrue(model.videos.isEmpty)
    }

    @MainActor
    func testCachedPageRejectsAnOlderResponseAfterQuickTabSwitching() async throws {
        let requested = expectation(description: "Shows request started")
        let transport = TestURLProtocol.session { request in
            if request.url!.query!.contains("Series") {
                requested.fulfill()
                return .json(#"{"Items":[{"Id":"show","Name":"Show"}],"TotalRecordCount":1}"#, delay: 0.1)
            }
            return .json(#"{"Items":[{"Id":"movie","Name":"Movie"}],"TotalRecordCount":1}"#)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        model.librarySection = .shows
        let load = Task { await model.loadLibraryPage() }
        await fulfillment(of: [requested], timeout: 2)
        model.librarySection = .movies
        await model.loadLibraryPage()
        await load.value
        XCTAssertEqual(model.videos.map(\.id), ["movie"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testFailedPagesAreRetriedAndFiltersNeverReuseUnfilteredResults() async throws {
        var requests = 0
        let transport = TestURLProtocol.session { _ in
            requests += 1
            if requests == 1 { return .json("{}", status: 503) }
            return .json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        XCTAssertNotNil(model.errorMessage)
        await model.loadLibraryPage()
        XCTAssertNil(model.errorMessage)
        await model.loadLibraryPage()
        XCTAssertEqual(requests, 2, "Successful empty libraries are cached too")
        model.libraryFilters.genre = "Drama"
        await model.loadLibraryPage()
        XCTAssertEqual(requests, 3)
        model.search = "Title"
        await model.loadLibraryPage()
        XCTAssertEqual(requests, 4)
    }

    @MainActor
    func testWatchStatusChangesInvalidatePreviouslyLoadedTabs() async throws {
        var watched = false
        var catalogRequests = 0
        let transport = TestURLProtocol.session { request in
            if request.url!.path.contains("UserPlayedItems") {
                watched = true
                return .json("{}")
            }
            if request.url!.path.contains("Resume") {
                return .json(#"{"Items":[],"TotalRecordCount":0}"#)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if !query.contains(where: { $0.name == "ids" }) { catalogRequests += 1 }
            return .json(
                "{\"Items\":[{\"Id\":\"movie\",\"Name\":\"Movie\",\"Type\":\"Movie\",\"UserData\":{\"Played\":\(watched)}}],\"TotalRecordCount\":1}"
            )
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        let movie = try XCTUnwrap(model.videos.first)
        model.librarySection = .shows
        await model.loadLibraryPage()
        await model.toggleWatched(movie)
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(catalogRequests, 3)
        XCTAssertTrue(try XCTUnwrap(model.videos.first).userData?.played == true)
    }

    @MainActor
    func testPermissionFailureKeepsSavedSession() async throws {
        let transport = TestURLProtocol.session { _ in .json("{}", status: 403) }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadVideos()
        XCTAssertNotNil(model.client)
        XCTAssertTrue(model.errorMessage?.contains("permission") == true)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testCancellationDoesNotShowANetworkErrorOrSignOut() async throws {
        let requested = expectation(description: "Library request started")
        let transport = TestURLProtocol.session { _ in
            requested.fulfill()
            return .json(#"{"Items":[],"TotalRecordCount":0}"#, delay: 0.1)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        let load = Task { await model.loadVideos() }
        await fulfillment(of: [requested], timeout: 2)
        load.cancel()
        await load.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.client)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testOldSearchResultsCannotReplaceNewQueryBeforeItsDebounceFinishes() async throws {
        let requested = expectation(description: "Old query requested")
        let transport = TestURLProtocol.session { _ in
            requested.fulfill()
            return .json(#"{"Items":[{"Id":"old","Name":"Old result"}],"TotalRecordCount":1}"#, delay: 0.05)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        let load = Task { await model.loadVideos() }
        await fulfillment(of: [requested], timeout: 2)
        model.search = "New query"
        await load.value
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testPaginationCannotUseThePreviousSearchOffsetDuringDebounce() async throws {
        var requests: [String] = []
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let search = query.first { $0.name == "searchTerm" }!.value!
            let offset = query.first { $0.name == "startIndex" }!.value!
            requests.append("\(search):\(offset)")
            return .json("{\"Items\":[{\"Id\":\"\(search)-\(offset)\",\"Name\":\"Title\"}],\"TotalRecordCount\":2}")
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        model.search = "Old"
        await model.loadLibraryPage()
        model.search = "New"
        await model.loadVideos(reset: false)
        XCTAssertEqual(requests, ["Old:0"], "Pagination must wait for the new query's first page")
        await model.loadLibraryPage()
        await model.loadVideos(reset: false)
        XCTAssertEqual(requests, ["Old:0", "New:0", "New:1"])
        XCTAssertEqual(model.videos.map(\.id), ["New-0", "New-1"])
        await model.loadVideos(reset: false)
        XCTAssertEqual(requests.count, 3, "The end of the results must stop pagination")
    }

    @MainActor
    func testOldSearchPaginationCannotReplaceANewQueriesFirstPage() async throws {
        let requested = expectation(description: "Old search pagination requested")
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let search = query.first { $0.name == "searchTerm" }!.value!
            let offset = query.first { $0.name == "startIndex" }!.value!
            let isOldPage = search == "Old" && offset == "1"
            if isOldPage { requested.fulfill() }
            return .json(
                "{\"Items\":[{\"Id\":\"\(search)-\(offset)\",\"Name\":\"Title\"}],\"TotalRecordCount\":3}",
                delay: isOldPage ? 0.1 : 0)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        model.search = "Old"
        await model.loadLibraryPage()
        let load = Task { await model.loadVideos(reset: false) }
        await fulfillment(of: [requested], timeout: 2)
        model.search = "New"
        await model.loadLibraryPage()
        await load.value
        XCTAssertEqual(model.videos.map(\.id), ["New-0"])
        XCTAssertEqual(model.nextVideoOffset, 1)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testRepeatedScrollTriggersShareOnePageAndDuplicatePagesStillAdvance() async throws {
        let requested = expectation(description: "Second page requested")
        var offsets: [String] = []
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = query.first { $0.name == "startIndex" }!.value!
            offsets.append(offset)
            if offset == "1" { requested.fulfill() }
            let id = offset == "2" ? "last" : "first"
            return .json(
                "{\"Items\":[{\"Id\":\"\(id)\",\"Name\":\"Title\"}],\"TotalRecordCount\":3}",
                delay: offset == "1" ? 0.1 : 0)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        let load = Task { await model.loadVideos(reset: false) }
        await fulfillment(of: [requested], timeout: 2)
        await model.loadVideos(reset: false)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(offsets, ["0", "1"])
        await load.value
        XCTAssertEqual(model.videos.map(\.id), ["first"])
        XCTAssertEqual(model.nextVideoOffset, 2, "The automatic trigger must advance even if every item was duplicated")
        await model.loadVideos(reset: false)
        XCTAssertEqual(model.videos.map(\.id), ["first", "last"])
        XCTAssertFalse(model.canLoadMore)
        XCTAssertEqual(offsets, ["0", "1", "2"])
    }

    @MainActor
    func testCancelledPaginationCanResumeAtTheSameOffsetWithoutLosingTitles() async throws {
        let requested = expectation(description: "Pagination requested")
        var offsets: [String] = []
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = query.first { $0.name == "startIndex" }!.value!
            offsets.append(offset)
            if offsets.count == 2 { requested.fulfill() }
            return .json(
                "{\"Items\":[{\"Id\":\"\(offset)\",\"Name\":\"Title\"}],\"TotalRecordCount\":2}",
                delay: offset == "1" ? 0.1 : 0)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadLibraryPage()
        let load = Task { await model.loadVideos(reset: false) }
        await fulfillment(of: [requested], timeout: 2)
        load.cancel()
        await load.value
        XCTAssertEqual(model.videos.map(\.id), ["0"])
        XCTAssertEqual(model.nextVideoOffset, 1)
        XCTAssertTrue(model.canLoadMore)
        XCTAssertNil(model.errorMessage)
        await model.loadVideos(reset: false)
        XCTAssertEqual(model.videos.map(\.id), ["0", "1"])
        XCTAssertEqual(offsets, ["0", "1", "1"])
    }

    @MainActor
    func testOverlappingPagesUseServerOffsetAndStopAtTheEnd() async throws {
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let offset = query?.first { $0.name == "startIndex" }?.value
            if offset == "0" {
                return .json(#"{"Items":[{"Id":"1","Name":"One"},{"Id":"2","Name":"Two"}],"TotalRecordCount":4}"#)
            }
            XCTAssertEqual(offset, "2")
            return .json(#"{"Items":[{"Id":"2","Name":"Two"},{"Id":"3","Name":"Three"}],"TotalRecordCount":4}"#)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadVideos()
        XCTAssertTrue(model.canLoadMore)
        await model.loadVideos(reset: false)
        XCTAssertEqual(model.videos.map(\.id), ["1", "2", "3"])
        XCTAssertFalse(model.canLoadMore)
    }

    @MainActor
    func testFilterChangesRejectAnOlderResponseBeforeTheNewRequestStarts() async throws {
        let requested = expectation(description: "Unfiltered request started")
        let transport = TestURLProtocol.session { _ in
            requested.fulfill()
            return .json(#"{"Items":[{"Id":"old","Name":"Old result"}],"TotalRecordCount":1}"#, delay: 0.05)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        let load = Task { await model.loadVideos() }
        await fulfillment(of: [requested], timeout: 2)
        model.libraryFilters.watchStatus = .unplayed
        await load.value
        XCTAssertTrue(model.videos.isEmpty)
    }

    @MainActor
    func testLetterJumpLoadsOnlyThroughItsSectionAndHonorsTheActiveFilters() async throws {
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "genres" }?.value, "Drama")
            switch query.first(where: { $0.name == "startIndex" })?.value {
            case "0":
                return .json(#"{"Items":[{"Id":"a","Name":"The Arrival","SortName":"arrival"}],"TotalRecordCount":4}"#)
            case "1": return .json(#"{"Items":[{"Id":"m","Name":"Moon"}],"TotalRecordCount":4}"#)
            default:
                XCTFail("Jump should stop once the requested letter is loaded")
                return .json(#"{"Items":[],"TotalRecordCount":4}"#)
            }
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        model.libraryFilters.genre = "Drama"
        await model.loadVideos()
        await model.loadThroughLetter("M")
        XCTAssertEqual(model.videos.map(\.libraryLetter), ["A", "M"])
        XCTAssertTrue(model.canLoadMore)
        await model.loadThroughLetter("A")
        XCTAssertEqual(model.videos.count, 2)
    }

    @MainActor
    func testEmptyPageDoesNotOfferEndlessLoadMoreRequests() async throws {
        let transport = TestURLProtocol.session { _ in .json(#"{"Items":[],"TotalRecordCount":10}"#) }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        await model.loadVideos()
        XCTAssertFalse(model.canLoadMore)
    }

    @MainActor
    func testSwitchingToDownloadsDuringAnInvalidatedLoadClearsLoadingState() async throws {
        let requested = expectation(description: "Catalog requested")
        let transport = TestURLProtocol.session { _ in
            requested.fulfill()
            return .json(#"{"Items":[{"Id":"old","Name":"Old"}],"TotalRecordCount":1}"#, delay: 0.1)
        }
        defer { transport.invalidateAndCancel() }
        let model = try model(transport: transport)
        let load = Task { await model.loadVideos() }
        await fulfillment(of: [requested], timeout: 2)
        model.libraryFilters.genre = "Drama"
        model.showsDownloads = true
        await model.loadVideos()
        await load.value
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isLoadingResume)
        XCTAssertTrue(model.videos.isEmpty)
    }
}
