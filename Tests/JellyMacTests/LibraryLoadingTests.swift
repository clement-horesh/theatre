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
}
