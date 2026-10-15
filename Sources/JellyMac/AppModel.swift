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

@MainActor
final class AppModel: ObservableObject {
    @Published var address = ""
    @Published var username = ""
    @Published var password = ""
    @Published var search = ""
    @Published var librarySection: LibrarySection = .home
    @Published private(set) var sessionWarning: String?
    @Published private(set) var client: JellyfinClient?
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
    private var playbackObservation: AnyCancellable?
    var playback: PlaybackController { playerSession.playback }
    var currentVideo: VideoItem? { playerSession.currentVideo }
    var isStartingPlayback: Bool { playerSession.isStartingPlayback }
    var isPreparingSystemPlayback: Bool { playerSession.isPreparingSystemPlayback }
    var isVideoFullscreen: Bool { playerSession.isVideoFullscreen }
    var playbackError: String? { playerSession.playbackError }
    var isPlayerWindowKey: Bool {
        get { playerSession.isPlayerWindowKey }
        set { playerSession.isPlayerWindowKey = newValue }
    }
    var presentationError: String? {
        get { playerSession.presentationError }
        set { playerSession.presentationError = newValue }
    }

    private var connectionTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var connectionGeneration = UUID()
    private var nextVideoOffset = 0
    private var nextResumeOffset = 0
    private let sessionStore: any SessionStore
    private let defaults: UserDefaults
    private let transport: URLSession

    init(
        sessionStore: (any SessionStore)? = nil, defaults: UserDefaults = .standard,
        transport: URLSession? = nil
    ) {
        preferences = PlaybackPreferences(defaults: defaults)
        playerSession = PlaybackSession(preferences: preferences)
        self.defaults = defaults
        self.transport = transport ?? Self.makeTransport()
        self.sessionStore = sessionStore ?? KeychainSessionStore(defaults: defaults)
        address = defaults.string(forKey: "serverAddress") ?? ""
        do {
            if let saved = try self.sessionStore.load() {
                client = try JellyfinClient(
                    address: saved.address, deviceID: saved.deviceID,
                    transport: self.transport, session: saved.session)
                address = saved.address
                username = saved.session.username
            }
        } catch { errorMessage = "Your saved sign-in couldn't be restored. Please connect again." }
        playerSession.client = client
        playerSession.onStopped = { [weak self] client, itemID in
            Task { await self?.refreshPlayedItem(client: client, itemID: itemID) }
        }
        playbackObservation = playerSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit {
        connectionTask?.cancel()
    }

    func toggleVideoFullscreen() { playerSession.toggleVideoFullscreen() }
    func exitVideoFullscreen() { playerSession.exitVideoFullscreen() }
    func playerFullscreenChanged(_ fullscreen: Bool) { playerSession.playerFullscreenChanged(fullscreen) }
    var displayedUsername: String { client?.session?.username ?? "" }
    var canLoadMore: Bool { nextVideoOffset < totalCount && !isLoading }
    var canLoadMoreResume: Bool { nextResumeOffset < resumeTotalCount }

    func progressVideo(for video: VideoItem) -> VideoItem {
        if video.type == "Series", let episode = resumeVideos.first(where: { $0.seriesID == video.id }) {
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
                client = try unauthenticated.authenticated(with: session)
                playerSession.client = client
                do {
                    try sessionStore.save(
                        SavedSession(
                            address: unauthenticated.serverURL.absoluteString,
                            deviceID: deviceID, session: session))
                    sessionWarning = nil
                } catch {
                    sessionWarning =
                        "Connected, but Keychain couldn't save your sign-in. You may need to sign in next time."
                }
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

    func loadVideos(reset: Bool = true) async {
        guard let client, !Task.isCancelled else { return }
        if !reset && isLoading { return }
        let section = librarySection
        let query = search
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if loadGeneration == generation { isLoading = false } }
        if reset {
            videos = []
            recentlyAddedVideos = []
            recentContinueMovies = []
            totalCount = 0
            nextVideoOffset = 0
            isLoadingResume = false
        }
        do {
            if section == .home, query.isEmpty {
                // Home has its own feeds; it doesn't need the general catalog page.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.loadHomeResume(client: client, generation: generation) }
                    group.addTask { await self.loadHomeRecent(client: client, generation: generation) }
                    group.addTask { await self.loadHomeMovies(client: client, generation: generation) }
                }
            } else {
                let page = try await client.videos(
                    startIndex: nextVideoOffset, search: query, itemTypes: section.itemTypes)
                try Task.checkCancellation()
                guard isCurrentLoad(generation, section: section, query: query) else { return }
                nextVideoOffset = page.items.isEmpty ? page.totalCount : nextVideoOffset + page.items.count
                var ids = Set(videos.map(\.id))
                videos.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
                totalCount = page.totalCount
            }

        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, isCurrentLoad(generation, section: section, query: query) {
                if case JellyfinError.unauthorized = error {
                    signOut()
                    errorMessage = "Your Jellyfin session expired. Please sign in again."
                } else {
                    errorMessage = Self.friendly(error)
                }
            }
        }
        if isCurrentLoad(generation, section: section, query: query), !Task.isCancelled {
            if reset, section == .home, query.isEmpty { homeRecommendationRevision += 1 }
        }
    }

    private func loadHomeResume(client: JellyfinClient, generation: UUID) async {
        do {
            let page = try await client.resumeVideos()
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            resumeVideos = page.items
            resumeTotalCount = page.totalCount
            nextResumeOffset = page.items.count
        } catch { homeLoadFailed(error, generation: generation) }
    }

    private func loadHomeRecent(client: JellyfinClient, generation: UUID) async {
        do {
            let items = try await client.recentlyAddedTitles(limit: 30)
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            recentlyAddedVideos = items
            homeRecommendationRevision += 1
        } catch { homeLoadFailed(error, generation: generation) }
    }

    private func loadHomeMovies(client: JellyfinClient, generation: UUID) async {
        do {
            let page = try await client.resumeVideos(limit: 5, itemTypes: ["Movie"])
            guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
            recentContinueMovies = page.items
            homeRecommendationRevision += 1
        } catch { homeLoadFailed(error, generation: generation) }
    }

    private func homeLoadFailed(_ error: Error, generation: UUID) {
        guard !Task.isCancelled, isCurrentLoad(generation, section: .home, query: "") else { return }
        if case JellyfinError.unauthorized = error {
            signOut()
            errorMessage = "Your Jellyfin session expired. Please sign in again."
        } else {
            errorMessage = Self.friendly(error)
        }
    }

    func toggleWatched(_ video: VideoItem) async {
        guard let client else { return }
        do {
            try await client.setWatched(video.userData?.played != true, itemID: video.id)
            await refreshPlayedItem(client: client, itemID: video.id)
        } catch { errorMessage = Self.friendly(error) }
    }

    private func isCurrentLoad(_ generation: UUID, section: LibrarySection, query: String) -> Bool {
        loadGeneration == generation && librarySection == section && search == query
    }

    func loadMoreResumeVideos() async {
        guard let client, !isLoadingResume, canLoadMoreResume else { return }
        let generation = loadGeneration
        isLoadingResume = true
        defer { if loadGeneration == generation { isLoadingResume = false } }
        do {
            let page = try await client.resumeVideos(startIndex: nextResumeOffset)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            nextResumeOffset = page.items.isEmpty ? page.totalCount : nextResumeOffset + page.items.count
            var ids = Set(resumeVideos.map(\.id))
            resumeVideos.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
            resumeTotalCount = page.totalCount
        } catch {
            if !Task.isCancelled, loadGeneration == generation {
                errorMessage = "More unfinished titles couldn't be loaded. Please try again."
            }
        }
    }

    func refreshRecentlyAddedTitles() async {
        guard let client, !isLoading, librarySection == .home, search.isEmpty else { return }
        let generation = loadGeneration
        do {
            let titles = try await client.recentlyAddedTitles(limit: 30)
            try Task.checkCancellation()
            guard loadGeneration == generation, self.client?.session?.accessToken == client.session?.accessToken,
                librarySection == .home, search.isEmpty
            else { return }
            if titles != recentlyAddedVideos {
                recentlyAddedVideos = titles
                homeRecommendationRevision += 1
            }
        } catch {
            // A background refresh keeps the last confirmed library visible.
        }
    }

    func play(_ video: VideoItem, compatibleOnly: Bool = false, startFromBeginning: Bool = false) {
        playerSession.play(video, compatibleOnly: compatibleOnly, startFromBeginning: startFromBeginning)
    }
    func togglePlayback() { playerSession.togglePlayback() }
    func stopPlayback(leaveFullscreen: Bool = true, closeWindow: Bool = true) {
        playerSession.stopPlayback(leaveFullscreen: leaveFullscreen, closeWindow: closeWindow)
    }
    func signOut() {
        try? sessionStore.remove()
        stopPlayback()
        connectionTask?.cancel()
        connectionGeneration = UUID()
        loadGeneration = UUID()
        let previous = client
        client = nil
        playerSession.client = nil
        videos = []
        resumeVideos = []
        recentlyAddedVideos = []
        recentContinueMovies = []
        resumeTotalCount = 0
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
        ArtworkCache.shared.clear()
        address = defaults.string(forKey: "serverAddress") ?? ""
        let pendingReport = playerSession.pendingReport
        Task {
            _ = try? await pendingReport?.value
            try? await previous?.logout()
        }
    }

    private func refreshPlayedItem(client: JellyfinClient, itemID: String) async {
        do {
            guard self.client?.session?.accessToken == client.session?.accessToken else { return }
            let updated = try await client.item(id: itemID)
            guard self.client?.session?.accessToken == client.session?.accessToken
            else { return }
            if let index = videos.firstIndex(where: { $0.id == updated.id }) { videos[index] = updated }
            if let index = recentlyAddedVideos.firstIndex(where: { $0.id == updated.id }) {
                recentlyAddedVideos[index] = updated
            }
            if updated.type == "Episode", let seriesID = updated.seriesID,
                let show = try? await client.item(id: seriesID)
            {
                guard self.client?.session?.accessToken == client.session?.accessToken
                else { return }
                if let index = videos.firstIndex(where: { $0.id == seriesID }) { videos[index] = show }
                if let index = recentlyAddedVideos.firstIndex(where: { $0.id == seriesID }) {
                    recentlyAddedVideos[index] = show
                }
            }
            if let resume = try? await client.resumeVideos() {
                guard self.client?.session?.accessToken == client.session?.accessToken
                else { return }
                resumeVideos = resume.items
                resumeTotalCount = resume.totalCount
                nextResumeOffset = resume.items.count
            }
            if librarySection == .home, let movies = try? await client.resumeVideos(limit: 5, itemTypes: ["Movie"]) {
                guard self.client?.session?.accessToken == client.session?.accessToken
                else { return }
                recentContinueMovies = movies.items
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
