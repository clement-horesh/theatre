import Foundation
import JellyfinKit
import XCTest

@testable import JellyMac

final class MultiServerTests: XCTestCase {
    @MainActor
    private func store() throws -> MemorySessionStore {
        let store = MemorySessionStore()
        for host in ["one.test", "two.test"] {
            let session = try JSONDecoder().decode(
                JellyfinSession.self,
                from: Data("{\"userID\":\"user\",\"username\":\"demo\",\"accessToken\":\"\(host)\"}".utf8))
            store.sessions.append(SavedSession(address: "https://\(host)/", deviceID: "test", session: session))
        }
        return store
    }

    @MainActor
    func testCollidingIDsStayDistinctAndActionsUseTheirOwnServer() async throws {
        var watchedHosts: [String] = []
        let transport = TestURLProtocol.session { request in
            let host = request.url!.host!
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains(host))
            if request.url!.path.contains("UserPlayedItems") {
                watchedHosts.append(host)
                return .json("{}")
            }
            return .json(
                #"{"Items":[{"Id":"same","Name":"Movie","Type":"Movie","ImageTags":{"Primary":"poster"},"People":[{"Id":"person","Name":"Actor"}]}],"TotalRecordCount":1}"#
            )
        }
        defer { transport.invalidateAndCancel() }
        let model = try store().makeModel(transport: transport)
        model.librarySection = .movies
        await model.loadVideos()
        XCTAssertEqual(model.videos.count, 2)
        XCTAssertEqual(Set(model.videos.map(\.libraryID)).count, 2)
        XCTAssertEqual(
            Set(FeaturedRecommendations.candidates(recent: model.videos, continuing: []).map(\.libraryID)).count, 2)
        for video in model.videos {
            let client = try XCTUnwrap(model.client(for: video))
            XCTAssertEqual(client.serverID, video.serverID)
            XCTAssertEqual(video.people?.first?.serverID, video.serverID)
            XCTAssertEqual(
                try client.imageRequest(for: video, type: .primary, maxWidth: 400)?.url?.host, client.serverURL.host)
            await model.toggleWatched(video)
        }
        XCTAssertEqual(Set(watchedHosts), ["one.test", "two.test"])
        await model.prepareForTermination()
    }

    @MainActor
    func testMergedPaginationKeepsAlphabetOrderAndRestoresEachServersCursor() async throws {
        var requests: [String] = []
        let transport = TestURLProtocol.session { request in
            let host = request.url!.host!
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "startIndex" }!.value!)!
            requests.append("\(host):\(offset)")
            let names = host == "one.test" ? ["A", "Z"] : ["B", "C", "M", "N"]
            return .json(
                "{\"Items\":[{\"Id\":\"\(offset)\",\"Name\":\"\(names[offset])\"}],\"TotalRecordCount\":\(names.count)}"
            )
        }
        defer { transport.invalidateAndCancel() }
        let model = try store().makeModel(transport: transport)
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(model.videos.map(\.name), ["A"])
        model.librarySection = .shows
        await model.loadLibraryPage()
        let count = requests.count
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(requests.count, count)
        await model.loadThroughLetter("M")
        XCTAssertEqual(model.videos.map(\.name), ["A", "B", "C", "M"])
        while model.canLoadMore { await model.loadVideos(reset: false) }
        XCTAssertEqual(model.videos.map(\.name), ["A", "B", "C", "M", "N", "Z"])
        XCTAssertEqual(model.totalCount, 6)
        await model.prepareForTermination()
    }

    @MainActor
    func testSearchPaginationAcceptsRelevanceOrderFromEachServer() async throws {
        var offsets: [Int] = []
        let transport = TestURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "searchTerm" }?.value, "spider")
            let offset = Int(query.first { $0.name == "startIndex" }!.value!)!
            offsets.append(offset)
            let names = offset == 0 ? ["Spider-Man", "The Amazing Spider-Man"] : ["Spider-Man 2"]
            let items = names.map { ["Id": $0, "Name": $0, "Type": "Movie"] }
            let body = try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": 3])
            return .json(String(decoding: body, as: UTF8.self))
        }
        defer { transport.invalidateAndCancel() }
        let model = try store().makeModel(transport: transport)
        model.search = "spider"
        await model.loadLibraryPage()
        XCTAssertEqual(model.videos.count, 4, "Relevance-ordered pages must not wait for an alphabet boundary")
        XCTAssertEqual(model.nextVideoOffset, 4)
        XCTAssertTrue(model.canLoadMore)
        await model.loadVideos(reset: false)
        XCTAssertEqual(model.videos.count, 6)
        XCTAssertEqual(Set(model.videos.map(\.libraryID)).count, 6)
        XCTAssertEqual(offsets, [0, 0, 2, 2])
        XCTAssertFalse(model.canLoadMore)
        await model.prepareForTermination()
    }

    @MainActor
    func testServerFilterAndRefreshAllOrOne() async throws {
        var hosts: [String] = []
        let transport = TestURLProtocol.session { request in
            hosts.append(request.url!.host!)
            return .json(#"{"Items":[{"Id":"same","Name":"Movie","Type":"Movie"}],"TotalRecordCount":1}"#)
        }
        defer { transport.invalidateAndCancel() }
        let model = try store().makeModel(transport: transport)
        model.librarySection = .movies
        await model.loadLibraryPage()
        XCTAssertEqual(hosts.count, 2)
        await model.refreshLibrary(serverID: model.servers[0].id)
        XCTAssertEqual(hosts.count, 3, "The other server's catalog must remain cached")
        await model.refreshLibrary()
        XCTAssertEqual(hosts.count, 5)
        model.serverFilter = model.servers[1].id
        await model.loadLibraryPage()
        XCTAssertEqual(model.videos.count, 1)
        XCTAssertEqual(model.client(for: model.videos[0])?.serverURL.host, "two.test")
        model.librarySection = .home
        await model.loadLibraryPage()
        XCTAssertEqual(model.recentlyAddedVideos.count, 2, "Home always combines all servers")
        let revision = model.homeRecommendationRevision
        await model.refreshRecentlyAddedTitles()
        XCTAssertEqual(model.homeRecommendationRevision, revision, "Unchanged merged feeds must keep their order")
        hosts = []
        await model.refreshLibrary(serverID: model.servers[0].id)
        XCTAssertEqual(Set(hosts), ["one.test"])
        XCTAssertEqual(model.recentlyAddedVideos.count, 2)
        XCTAssertEqual(model.resumeVideos.count, 2)
        await model.prepareForTermination()
    }

    @MainActor
    func testSignOutRemovesOnlyOneSavedServerThenReturnsToOnboarding() async throws {
        let transport = TestURLProtocol.session { _ in .json("{}") }
        defer { transport.invalidateAndCancel() }
        let store = try store()
        let model = store.makeModel(transport: transport)
        model.signOut(serverID: model.servers[0].id)
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(store.sessions.count, 1)
        let reopened = store.makeModel(transport: transport)
        XCTAssertEqual(reopened.servers.count, 1)
        reopened.signOut(serverID: reopened.servers[0].id)
        XCTAssertNil(reopened.client)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.makeModel(transport: transport).client)
        await model.prepareForTermination()
        await reopened.prepareForTermination()
    }

    @MainActor
    func testExpiredOrUnavailableServerDoesNotRemoveTheOtherAccount() async throws {
        let transport = TestURLProtocol.session { request in
            if request.url!.host == "one.test" { return .json("{}", status: 401) }
            return .json(#"{"Items":[{"Id":"same","Name":"Movie","Type":"Movie"}],"TotalRecordCount":1}"#)
        }
        defer { transport.invalidateAndCancel() }
        let store = try store()
        let model = store.makeModel(transport: transport)
        model.librarySection = .movies
        await model.loadVideos()
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(model.client?.serverURL.host, "two.test")
        XCTAssertEqual(store.sessions.count, 1)
        await model.prepareForTermination()
    }
    @MainActor
    func testExistingDownloadCatalogsAreCombinedAndReconnectionKeepsEachAccountsFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theatre-Multi-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clients = try store().sessions.map {
            try JellyfinClient(address: $0.address, deviceID: $0.deviceID, session: $0.session)
        }
        for client in clients {
            let directory = root.appendingPathComponent(DownloadManager.accountKey(client))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var record = DownloadRecord(id: UUID(), video: VideoItem(id: "same", name: "Movie", type: "Movie"))
            record.state = .paused
            try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("catalog.json"))
        }
        let library = DownloadLibrary(manager: DownloadManager(root: root))
        library.configure(clients: clients)
        await library.waitUntilReady()
        XCTAssertEqual(library.titles.count, 2)
        XCTAssertEqual(Set(library.titles.map(\.libraryID)).count, 2)
        let firstVideo = try XCTUnwrap(library.titles.first { $0.serverID == clients[0].serverID })
        let firstID = try XCTUnwrap(library.record(for: firstVideo)?.id)
        XCTAssertEqual(library.cachedVideo(id: firstVideo.libraryID)?.serverID, clients[0].serverID)
        library.configure(clients: [clients[1]])
        XCTAssertEqual(library.titles.count, 1)
        // Reconnect before the previous account's asynchronous pause/write has finished.
        library.configure(clients: clients)
        await library.waitUntilReady()
        XCTAssertEqual(library.titles.count, 2)
        XCTAssertEqual(library.record(for: firstVideo)?.id, firstID)
        await library.shutdown()
    }

    @MainActor
    func testAddingAndCancellingServersKeepsTheExistingConnection() async throws {
        let transport = TestURLProtocol.session { request in
            if request.url!.path.contains("AuthenticateByName") {
                return .json(#"{"AccessToken":"new-token","User":{"Id":"user","Name":"new-user"}}"#)
            }
            return .json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { transport.invalidateAndCancel() }
        let store = try store()
        let model = store.makeModel(transport: transport)
        model.addServer()
        model.address = "https://three.test"
        model.username = "new-user"
        model.password = "never-saved"
        model.connect()
        for _ in 0..<100 {
            if !model.isConnecting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.servers.count, 3)
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertFalse(model.showsAddServer)
        XCTAssertTrue(model.password.isEmpty)
        model.addServer()
        model.password = "discarded"
        model.cancelAddingServer()
        XCTAssertEqual(model.servers.count, 3)
        XCTAssertTrue(model.password.isEmpty)
        let reopened = store.makeModel(transport: transport)
        XCTAssertEqual(reopened.servers.count, 3)
        await model.prepareForTermination()
        await reopened.prepareForTermination()
    }

    @MainActor
    func testPlaybackUsesTheSelectedServerAndSigningOutElsewhereKeepsIt() async throws {
        let transport = TestURLProtocol.session { _ in .json("{}") }
        defer { transport.invalidateAndCancel() }
        let model = try store().makeModel(transport: transport)
        let first = VideoItem(id: "same", name: "First", type: "Movie").onServer(model.servers[0].id)
        let second = VideoItem(id: "same", name: "Second", type: "Movie").onServer(model.servers[1].id)
        model.play(first)
        XCTAssertEqual(model.playerSession.client?.serverID, first.serverID)
        model.play(second)
        XCTAssertEqual(model.playerSession.client?.serverID, second.serverID)
        model.signOut(serverID: model.servers[0].id)
        XCTAssertEqual(model.currentVideo?.libraryID, second.libraryID)
        XCTAssertEqual(model.playerSession.client?.serverID, second.serverID)
        await model.prepareForTermination()
    }

}
