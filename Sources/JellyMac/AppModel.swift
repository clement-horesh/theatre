import AppKit
import Combine
import Foundation
import JellyfinKit

enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home"
    case shows = "Shows"
    case movies = "Movies"
    var id: String { rawValue }
    var itemTypes: [String] {
        switch self {
        case .home: return []
        case .shows: return ["Series"]
        case .movies: return ["Movie"]
        }
    }
}

struct ServerConnection: Identifiable {
    let client: JellyfinClient
    var id: String { client.serverID }
    var label: String { "\(client.serverURL.absoluteString) — \(client.session?.username ?? "")" }
    var savedSession: SavedSession? {
        client.session.map {
            SavedSession(address: client.serverURL.absoluteString, deviceID: client.deviceID, session: $0)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var address = ""
    @Published var username = ""
    @Published var password = ""
    @Published var search = "" {
        didSet { if oldValue != search { invalidateLibraryLoad() } }
    }
    @Published var showsDownloads = false {
        didSet { if oldValue != showsDownloads { invalidateLibraryLoad() } }
    }
    @Published var librarySection: LibrarySection = .home {
        didSet {
            if oldValue != librarySection {
                invalidateLibraryLoad()
                libraryFilters = VideoFilters()
            }
        }
    }
    @Published var libraryFilters = VideoFilters() {
        didSet { if oldValue != libraryFilters { invalidateLibraryLoad() } }
    }
    @Published private(set) var sessionWarning: String?
    @Published private(set) var servers: [ServerConnection] = []
    @Published var showsAddServer = false
    @Published var serverFilter: String? {
        didSet { if oldValue != serverFilter { invalidateLibraryLoad() } }
    }
    var client: JellyfinClient? { servers.first?.client }
    var libraryIdentity: String { servers.map(\.id).joined(separator: ";") }
    var browsingClients: [JellyfinClient] {
        servers.filter { librarySection == .home || serverFilter == nil || $0.id == serverFilter }.map(\.client)
    }
    func client(for video: VideoItem) -> JellyfinClient? { client(serverID: video.serverID) }
    func client(serverID: String?) -> JellyfinClient? {
        guard let serverID else { return client }
        return servers.first { $0.id == serverID }?.client
    }

    func addServer() {
        address = ""
        username = ""
        password = ""
        errorMessage = nil
        showsAddServer = true
    }

    func dismissSessionWarning() { sessionWarning = nil }

    func cancelAddingServer() {
        connectionTask?.cancel()
        connectionGeneration = UUID()
        isConnecting = false
        password = ""
        errorMessage = nil
        showsAddServer = false
    }
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var resumeVideos: [VideoItem] = []
    @Published private(set) var recentlyAddedVideos: [VideoItem] = []
    @Published private(set) var recentContinueMovies: [VideoItem] = []
    @Published private(set) var homeRecommendationRevision = 0
    @Published private(set) var resumeTotalCount = 0
    @Published private(set) var isLoadingResume = false
    @Published private(set) var playbackRevision = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    let playerSession: PlaybackSession
    let preferences: PlaybackPreferences
    let downloads: DownloadLibrary
    private var downloadObservation: AnyCancellable?
    private var playbackObservation: AnyCancellable?
    var playback: PlaybackController { playerSession.playback }
    var currentVideo: VideoItem? { playerSession.currentVideo }
    var isStartingPlayback: Bool { playerSession.isStartingPlayback }
    var isVideoFullscreen: Bool { playerSession.isVideoFullscreen }
    var isPlayerWindowKey: Bool { playerSession.isPlayerWindowKey }

    func prepareForTermination() async {
        async let playback: Void = playerSession.shutdown()
        await downloads.shutdown()
        await playback
        // Playback shutdown can save its final position after downloads have paused.
        await downloads.flush()
    }

    private var connectionTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var connectionGeneration = UUID()
    private(set) var nextVideoOffset = 0
    private var nextResumeOffset = 0
    private var catalogCursors: [String: CatalogCursor] = [:]
    private var resumeOffsets: [String: Int] = [:]
    private var resumeCounts: [String: Int] = [:]
    private struct CatalogCursor {
        var items: [VideoItem] = []
        var offset = 0
        var total: Int?
    }
    private var hasLoadedHome = false
    // shortcut: cache only unfiltered tabs; add bounded query caching if search/filter revisits need it.
    private var libraryPages: [LibrarySection: LibraryPage] = [:]
    private struct LibraryPage {
        let videos: [VideoItem]
        let totalCount: Int
        let nextOffset: Int
        let cursors: [String: CatalogCursor]
    }
    private let sessionStore: any SessionStore
    private let defaults: UserDefaults
    private let transport: URLSession

    init(
        sessionStore: (any SessionStore)? = nil, defaults: UserDefaults = .standard,
        transport: URLSession? = nil, downloads: DownloadManager? = nil
    ) {
        self.downloads = DownloadLibrary(manager: downloads ?? DownloadManager())
        preferences = PlaybackPreferences(defaults: defaults)
        playerSession = PlaybackSession(preferences: preferences)
        self.defaults = defaults
        self.transport = transport ?? Self.makeTransport()
        self.sessionStore = sessionStore ?? KeychainSessionStore(defaults: defaults)
        address = defaults.string(forKey: "serverAddress") ?? ""
        do {
            for saved in try self.sessionStore.loadAll() {
                let restored = try JellyfinClient(
                    address: saved.address, deviceID: saved.deviceID,
                    transport: self.transport, session: saved.session)
                if !servers.contains(where: { $0.id == restored.serverID }) {
                    servers.append(ServerConnection(client: restored))
                }
            }
            address = client?.serverURL.absoluteString ?? address
            username = client?.session?.username ?? ""
        } catch { errorMessage = "Your saved sign-in couldn't be restored. Please connect again." }
        playerSession.client = client
        playerSession.downloads = self.downloads.manager(serverID: client?.serverID)
        self.downloads.configure(clients: servers.map(\.client))
        // Byte progress belongs to transfer rows, not every library view.
        downloadObservation = self.downloads.$catalogRevision.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        playerSession.onStopped = { [weak self] client, itemID in
            guard let self else { return }
            if let record = self.downloads.records.first(where: {
                $0.video.id == itemID && $0.video.serverID == client.serverID
            }),
                record.progress?.pendingSync == true
            {
                if let index = self.videos.firstIndex(where: { $0.id == itemID && $0.serverID == client.serverID }) {
                    self.videos[index] = record.displayedVideo
                }
                self.playbackRevision += 1
            }
            Task {
                await self.downloads.pendingSync.value
                await self.refreshPlayedItem(client: client, itemID: itemID)
            }
        }
        playbackObservation = playerSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit {
        connectionTask?.cancel()
    }

    func toggleVideoFullscreen() { playerSession.toggleVideoFullscreen() }
    var displayedUsername: String { client?.session?.username ?? "" }
    var canLoadMore: Bool { nextVideoOffset < totalCount && !isLoading }
    var canLoadMoreResume: Bool { nextResumeOffset < resumeTotalCount }

    func canPlay(_ video: VideoItem) -> Bool {
        !isStartingPlayback && (!showsDownloads || downloads.playbackStream(for: video) != nil)
    }

    private func invalidateLibraryLoad() {
        loadGeneration = UUID()
        isLoading = false
        isLoadingResume = false
        nextVideoOffset = 0
        totalCount = 0
        catalogCursors = [:]
    }

    func progressVideo(for video: VideoItem) -> VideoItem {
        if showsDownloads {
            if video.type == "Series" {
                return downloads.episodes(seriesID: video.libraryID).first(where: \.isInProgress) ?? video
            }
            return downloads.cachedVideo(id: video.libraryID) ?? video
        }
        if video.type == "Series", let episode = resumeVideos.first(where: { $0.seriesLibraryID == video.libraryID }) {
            return episode
        }
        return video
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: "deviceID") { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return id
    }

    func connect() {
        let server = address
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        guard !isConnecting, !user.isEmpty else { return }
        connectionTask?.cancel()
        isConnecting = true
        errorMessage = nil
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task {
            do {
                let unauthenticated = try JellyfinClient(
                    address: server, deviceID: deviceID,
                    transport: transport)
                let session = try await unauthenticated.authenticate(username: user, password: secret)
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                let connected = try unauthenticated.authenticated(with: session)
                if let index = servers.firstIndex(where: { $0.id == connected.serverID }) {
                    servers[index] = ServerConnection(client: connected)
                } else {
                    servers.append(ServerConnection(client: connected))
                }
                downloads.configure(clients: servers.map(\.client))
                do {
                    try sessionStore.saveAll(servers.compactMap(\.savedSession))
                    sessionWarning = nil
                } catch {
                    sessionWarning =
                        "Connected, but Keychain couldn't save your sign-in. You may need to sign in next time."
                }
                libraryPages.removeAll()
                hasLoadedHome = false
                invalidateLibraryLoad()
                showsAddServer = false
                defaults.set(unauthenticated.serverURL.absoluteString, forKey: "serverAddress")
                password = ""
                search = ""
                librarySection = .home
            } catch is CancellationError {
            } catch {
                if connectionGeneration == generation { errorMessage = Self.friendly(error) }
            }
            if connectionGeneration == generation { isConnecting = false }
        }
    }

    func loadLibraryPage() async {
        guard !Task.isCancelled, client != nil, !showsDownloads else { return }
        if search.isEmpty && libraryFilters.isEmpty && (librarySection == .home || serverFilter == nil) {
            if librarySection == .home && hasLoadedHome {
                invalidateLibraryLoad()
                videos = []
                totalCount = 0
                nextVideoOffset = 0
                errorMessage = nil
                return
            }
            if let page = libraryPages[librarySection] {
                invalidateLibraryLoad()
                videos = page.videos
                totalCount = page.totalCount
                nextVideoOffset = page.nextOffset
                catalogCursors = page.cursors
                errorMessage = nil
                return
            }
        }
        await loadVideos(refresh: false)
    }

    func loadVideos(reset: Bool = true, refresh: Bool = true, homeServerID: String? = nil) async {
        guard !servers.isEmpty, !Task.isCancelled else { return }
        let identity = libraryIdentity
        await downloads.waitUntilReady()
        guard !Task.isCancelled, libraryIdentity == identity else { return }
        downloads.synchronize()
        if showsDownloads { return }
        if reset && refresh {
            for server in servers { server.client.clearBrowsingCache() }
            libraryPages.removeAll()
            hasLoadedHome = false
        }
        if !reset && !canLoadMore { return }
        let section = librarySection
        let query = search
        let filters = section == .home ? VideoFilters() : libraryFilters
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if loadGeneration == generation { isLoading = false } }
        if reset {
            videos = []
            totalCount = 0
            nextVideoOffset = 0
            catalogCursors = [:]
            isLoadingResume = false
        }
        do {
            if section == .home, query.isEmpty {
                // Home has its own feeds; it doesn't need the general catalog page.
                await withTaskGroup(of: Void.self) { group in
                    resumeVideos.removeAll { homeServerID == nil || $0.serverID == homeServerID }
                    recentlyAddedVideos.removeAll { homeServerID == nil || $0.serverID == homeServerID }
                    recentContinueMovies.removeAll { homeServerID == nil || $0.serverID == homeServerID }
                    for server in servers where homeServerID == nil || server.id == homeServerID {
                        resumeOffsets[server.id] = 0
                        resumeCounts[server.id] = 0
                        group.addTask { await self.loadHomeResume(client: server.client, generation: generation) }
                        group.addTask { await self.loadHomeRecent(client: server.client, generation: generation) }
                        group.addTask { await self.loadHomeMovies(client: server.client, generation: generation) }
                    }
                }
            } else {
                var cursors = catalogCursors
                for client in browsingClients {
                    var cursor = cursors[client.serverID] ?? CatalogCursor()
                    if cursor.items.isEmpty && (cursor.total == nil || cursor.offset < cursor.total!) {
                        do {
                            let page = try await client.videos(
                                startIndex: cursor.offset, search: query, itemTypes: section.itemTypes, filters: filters
                            )
                            try Task.checkCancellation()
                            guard isCurrentLoad(generation, section: section, query: query) else { return }
                            cursor.items = page.items
                            cursor.offset = page.items.isEmpty ? page.totalCount : cursor.offset + page.items.count
                            cursor.total = page.totalCount
                        } catch is CancellationError { throw CancellationError() } catch {
                            serverLoadFailed(error, client: client, generation: generation)
                        }
                    }
                    cursors[client.serverID] = cursor
                }
                guard isCurrentLoad(generation, section: section, query: query) else { return }
                // Browse pages share an alphabet boundary; search pages are ranked by relevance.
                let boundary =
                    query.isEmpty
                    ? cursors.values.compactMap { cursor in
                        cursor.offset < (cursor.total ?? 0) ? cursor.items.last : nil
                    }.min(by: Self.titleOrder) : nil
                var incoming: [VideoItem] = []
                for id in cursors.keys {
                    guard var cursor = cursors[id] else { continue }
                    let count =
                        boundary.map { boundary in
                            cursor.items.prefix { !Self.titleOrder(boundary, $0) }.count
                        } ?? cursor.items.count
                    incoming.append(contentsOf: cursor.items.prefix(count))
                    cursor.items.removeFirst(count)
                    cursors[id] = cursor
                }
                catalogCursors = cursors
                nextVideoOffset += incoming.count
                var ids = Set(videos.map(\.libraryID))
                videos.append(contentsOf: incoming.filter { ids.insert($0.libraryID).inserted })
                if browsingClients.count > 1 { videos.sort(by: Self.titleOrder) }
                totalCount = cursors.values.reduce(0) { $0 + ($1.total ?? 0) }
                if cursors.values.allSatisfy({ $0.items.isEmpty && $0.offset >= ($0.total ?? 0) }) {
                    nextVideoOffset = totalCount
                }
            }

        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, isCurrentLoad(generation, section: section, query: query) {
                errorMessage = Self.friendly(error)
            }
        }
        if isCurrentLoad(generation, section: section, query: query), !Task.isCancelled {
            if reset, section == .home, query.isEmpty { homeRecommendationRevision += 1 }
            if errorMessage == nil, query.isEmpty, filters.isEmpty, section == .home || serverFilter == nil {
                if section == .home {
                    hasLoadedHome = true
                } else {
                    libraryPages[section] = LibraryPage(
                        videos: videos, totalCount: totalCount, nextOffset: nextVideoOffset, cursors: catalogCursors)
                }
            }
        }
    }

    private func loadHomeResume(client: JellyfinClient, generation: UUID) async {
        do {
            let page = try await client.resumeVideos()
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            resumeVideos.append(contentsOf: page.items)
            sortResumeVideos()
            resumeCounts[client.serverID] = page.totalCount
            resumeOffsets[client.serverID] = page.items.isEmpty ? page.totalCount : page.items.count
            updateResumeCounts()
        } catch { serverLoadFailed(error, client: client, generation: generation) }
    }

    private func loadHomeRecent(client: JellyfinClient, generation: UUID) async {
        do {
            let items = try await client.recentlyAddedTitles(limit: 30)
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            recentlyAddedVideos.append(contentsOf: items)
            sortRecentlyAddedVideos()
            homeRecommendationRevision += 1
        } catch { serverLoadFailed(error, client: client, generation: generation) }
    }

    private func loadHomeMovies(client: JellyfinClient, generation: UUID) async {
        do {
            let page = try await client.resumeVideos(limit: 5, itemTypes: ["Movie"])
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            recentContinueMovies.append(contentsOf: page.items)
            recentContinueMovies.sort(by: Self.playbackOrder)
            homeRecommendationRevision += 1
        } catch { serverLoadFailed(error, client: client, generation: generation) }
    }

    private func serverLoadFailed(_ error: Error, client: JellyfinClient, generation: UUID) {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if case JellyfinError.unauthorized = error {
            signOut(serverID: client.serverID)
            errorMessage = "Your Jellyfin session expired. Please sign in again."
            if !servers.isEmpty { Task { await self.loadLibraryPage() } }
        } else {
            errorMessage = Self.friendly(error)
        }
    }

    func toggleWatched(_ video: VideoItem) async {
        if showsDownloads {
            downloads.setWatched(video.userData?.played != true, video: video)
            playbackRevision += 1
            return
        }
        guard let client = client(for: video) else { return }
        do {
            try await client.setWatched(video.userData?.played != true, itemID: video.id)
            await refreshPlayedItem(client: client, itemID: video.id)
            if librarySection != .home, !libraryFilters.isEmpty { await loadVideos() }
        } catch { errorMessage = Self.friendly(error) }
    }

    private func isCurrentLoad(_ generation: UUID, section: LibrarySection, query: String) -> Bool {
        loadGeneration == generation && librarySection == section && search == query
    }

    /// Load only as far as a requested alphabet section, retaining normal server pagination.
    func loadThroughLetter(_ letter: String) async {
        let section = librarySection
        let query = search
        let filters = libraryFilters
        while !Task.isCancelled, section == librarySection, query == search, filters == libraryFilters,
            !isLoading, nextVideoOffset < totalCount,
            !videos.contains(where: { $0.libraryLetter == letter }),
            videos.last.map({ $0.libraryLetter == "#" || $0.libraryLetter < letter }) == true
        {
            await loadVideos(reset: false)
            if errorMessage != nil { return }
        }
    }

    func loadMoreResumeVideos() async {
        guard !servers.isEmpty, !isLoadingResume, canLoadMoreResume else { return }
        let generation = loadGeneration
        isLoadingResume = true
        defer { if loadGeneration == generation { isLoadingResume = false } }
        for server in servers {
            let client = server.client
            let offset = resumeOffsets[server.id] ?? 0
            guard offset < (resumeCounts[server.id] ?? 0) else { continue }
            do {
                let page = try await client.resumeVideos(startIndex: offset)
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                resumeOffsets[server.id] = page.items.isEmpty ? page.totalCount : offset + page.items.count
                resumeCounts[server.id] = page.totalCount
                var ids = Set(resumeVideos.map(\.libraryID))
                resumeVideos.append(contentsOf: page.items.filter { ids.insert($0.libraryID).inserted })
                sortResumeVideos()
                updateResumeCounts()
            } catch { serverLoadFailed(error, client: client, generation: generation) }
        }
    }

    func refreshRecentlyAddedTitles() async {
        guard !servers.isEmpty, !isLoading, librarySection == .home, search.isEmpty else { return }
        let generation = loadGeneration
        for server in servers {
            if let titles = try? await server.client.recentlyAddedTitles(limit: 30) {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                let previous = recentlyAddedVideos
                recentlyAddedVideos.removeAll { $0.serverID == server.id }
                recentlyAddedVideos.append(contentsOf: titles)
                sortRecentlyAddedVideos()
                if previous != recentlyAddedVideos { homeRecommendationRevision += 1 }
            }
        }
    }

    private static func titleOrder(_ lhs: VideoItem, _ rhs: VideoItem) -> Bool {
        let order = (lhs.sortName ?? lhs.name).localizedStandardCompare(rhs.sortName ?? rhs.name)
        return order == .orderedSame ? lhs.libraryID < rhs.libraryID : order == .orderedAscending
    }

    private func sortResumeVideos() {
        guard servers.count > 1 else { return }
        resumeVideos.sort(by: Self.playbackOrder)
    }

    private func sortRecentlyAddedVideos() {
        guard servers.count > 1 else { return }
        recentlyAddedVideos.sort {
            let lhs = Self.feedDate($0.dateCreated)
            let rhs = Self.feedDate($1.dateCreated)
            return lhs == rhs ? $0.libraryID < $1.libraryID : lhs > rhs
        }
    }

    private static func playbackOrder(_ lhs: VideoItem, _ rhs: VideoItem) -> Bool {
        let left = feedDate(lhs.userData?.lastPlayedDate)
        let right = feedDate(rhs.userData?.lastPlayedDate)
        return left == right ? lhs.libraryID < rhs.libraryID : left > right
    }

    private static let feedDateFormatter = ISO8601DateFormatter()
    private static let fractionalFeedDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()
    private static func feedDate(_ date: String?) -> Date {
        guard let date else { return .distantPast }
        return fractionalFeedDateFormatter.date(from: date) ?? feedDateFormatter.date(from: date) ?? .distantPast
    }

    private func updateResumeCounts() {
        resumeTotalCount = resumeCounts.values.reduce(0, +)
        nextResumeOffset = resumeOffsets.values.reduce(0, +)
    }

    func videoFilterOptions() async throws -> VideoFilterOptions {
        var genres = Set<String>()
        var years = Set<Int>()
        for client in browsingClients {
            let options = try await client.videoFilterOptions(itemTypes: librarySection.itemTypes)
            genres.formUnion(options.genres)
            years.formUnion(options.years)
        }
        return VideoFilterOptions(genres: genres.sorted(), years: years.sorted(by: >))
    }

    func refreshLibrary(serverID: String? = nil) async {
        let homeServerID = hasLoadedHome ? serverID : nil
        for server in servers where serverID == nil || server.id == serverID { server.client.clearBrowsingCache() }
        libraryPages.removeAll()
        hasLoadedHome = false
        await loadVideos(refresh: false, homeServerID: homeServerID)
    }

    func play(_ video: VideoItem, compatibleOnly: Bool = false, startFromBeginning: Bool = false) {
        guard let client = client(for: video) else { return }
        playerSession.play(
            video, compatibleOnly: compatibleOnly, startFromBeginning: startFromBeginning,
            using: client, downloads: downloads.manager(serverID: client.serverID))
    }
    func togglePlayback() { playerSession.togglePlayback() }
    func stopPlayback(leaveFullscreen: Bool = true, closeWindow: Bool = true) {
        playerSession.stopPlayback(leaveFullscreen: leaveFullscreen, closeWindow: closeWindow)
    }
    func signOut() {
        for id in servers.map(\.id) { signOut(serverID: id) }
    }

    func signOut(serverID: String) {
        guard let previous = servers.first(where: { $0.id == serverID })?.client else { return }
        try? sessionStore.remove(id: serverID)
        if playerSession.client?.serverID == serverID { stopPlayback() }
        servers.removeAll { $0.id == serverID }
        showsAddServer = false
        if serverFilter == serverID { serverFilter = nil }
        connectionTask?.cancel()
        connectionGeneration = UUID()
        loadGeneration = UUID()
        libraryPages.removeAll()
        hasLoadedHome = false
        if playerSession.client?.serverID == serverID { playerSession.client = nil }
        downloads.configure(clients: servers.map(\.client))
        showsDownloads = false
        videos = []
        resumeVideos = []
        recentlyAddedVideos = []
        recentContinueMovies = []
        resumeTotalCount = 0
        resumeOffsets = [:]
        resumeCounts = [:]
        isLoadingResume = false
        totalCount = 0
        search = ""
        nextVideoOffset = 0
        nextResumeOffset = 0
        password = ""
        errorMessage = nil
        isConnecting = false
        isLoading = false
        sessionWarning = nil
        librarySection = .home
        libraryFilters = VideoFilters()
        if servers.isEmpty { ArtworkCache.shared.clear() }
        address = defaults.string(forKey: "serverAddress") ?? ""
        let pendingReport = playerSession.pendingReport
        Task {
            _ = try? await pendingReport?.value
            try? await previous.logout()
        }
    }

    private func refreshPlayedItem(client: JellyfinClient, itemID: String) async {
        guard self.client(serverID: client.serverID)?.session?.accessToken == client.session?.accessToken else {
            return
        }
        client.clearBrowsingCache()
        libraryPages.removeAll()
        hasLoadedHome = false
        do {
            let updated = try await client.item(id: itemID)
            guard self.client(serverID: client.serverID)?.session?.accessToken == client.session?.accessToken
            else { return }
            if let index = videos.firstIndex(where: { $0.libraryID == updated.libraryID }) { videos[index] = updated }
            if let index = recentlyAddedVideos.firstIndex(where: { $0.libraryID == updated.libraryID }) {
                recentlyAddedVideos[index] = updated
            }
            if updated.type == "Episode", let seriesID = updated.seriesID,
                let show = try? await client.item(id: seriesID)
            {
                guard self.client(serverID: client.serverID)?.session?.accessToken == client.session?.accessToken
                else { return }
                if let index = videos.firstIndex(where: { $0.id == seriesID && $0.serverID == client.serverID }) {
                    videos[index] = show
                }
                if let index = recentlyAddedVideos.firstIndex(where: {
                    $0.id == seriesID && $0.serverID == client.serverID
                }) {
                    recentlyAddedVideos[index] = show
                }
            }
            if let resume = try? await client.resumeVideos() {
                guard self.client(serverID: client.serverID)?.session?.accessToken == client.session?.accessToken
                else { return }
                resumeVideos.removeAll { $0.serverID == client.serverID }
                resumeVideos.append(contentsOf: resume.items)
                sortResumeVideos()
                resumeCounts[client.serverID] = resume.totalCount
                resumeOffsets[client.serverID] = resume.items.count
                updateResumeCounts()
            }
            if librarySection == .home, let movies = try? await client.resumeVideos(limit: 5, itemTypes: ["Movie"]) {
                guard self.client(serverID: client.serverID)?.session?.accessToken == client.session?.accessToken
                else { return }
                recentContinueMovies.removeAll { $0.serverID == client.serverID }
                recentContinueMovies.append(contentsOf: movies.items)
                if servers.count > 1 { recentContinueMovies.sort(by: Self.playbackOrder) }
            }
            playbackRevision += 1
        } catch {
            // Keep the last server-confirmed state until the next refresh.
        }
    }

    private static func makeTransport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    static func friendly(_ error: Error) -> String {
        if let error = error as? JellyfinError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost:
                return
                    "Couldn't reach the Jellyfin server. Check the address, network connection, and local network access."
            case .timedOut: return "The server took too long to respond. Please try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "The server's HTTPS connection could not be verified. Check its certificate."
            default: return "The network request failed. Check the server address and try again."
            }
        }
        return "Something went wrong. Please try again."
    }
}
