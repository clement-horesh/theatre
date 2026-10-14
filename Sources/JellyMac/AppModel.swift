import Combine
import AppKit
import Foundation
import JellyfinKit

enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home", shows = "Shows", movies = "Movies"
    var id: String { rawValue }
    var itemTypes: [String] {
        switch self { case .home: return []; case .shows: return ["Series"]; case .movies: return ["Movie"] }
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
    @Published private(set) var isStartingPlayback = false
    @Published private(set) var currentVideo: VideoItem?
    @Published private(set) var isVideoFullscreen = false
    @Published var isPlayerWindowKey = false
    @Published var errorMessage: String?
    @Published private(set) var playbackError: String?
    @Published private(set) var reportWarning: String?
    let playback = VLCPlaybackController()

    private var playerWindow: PlayerWindowController?
    private var stream: PlaybackStream?
    private var connectionTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var connectionGeneration = UUID()
    private var lastReportSeconds = -10.0
    private var hasReportedStart = false
    private weak var fullscreenWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private let sessionStore: any SessionStore
    private let defaults: UserDefaults

    init(sessionStore: (any SessionStore)? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sessionStore = sessionStore ?? KeychainSessionStore()
        address = defaults.string(forKey: "serverAddress") ?? ""
        do {
            if let saved = try self.sessionStore.load() {
                client = try JellyfinClient(address: saved.address, deviceID: saved.deviceID,
                                            transport: Self.makeTransport(), session: saved.session)
                address = saved.address
                username = saved.session.username
            }
        } catch { errorMessage = "Your saved sign-in couldn't be restored. Please connect again." }
        playback.onProgress = { [weak self] seconds, paused in self?.reportProgress(seconds: seconds, paused: paused) }
        playback.onEnded = { [weak self] in self?.finishPlayback() }
        playback.onVideoSize = { [weak self] size in
            guard let self, self.stream?.videoAspectRatio == nil else { return }
            self.playerWindow?.fitVideo(aspectRatio: size.width / size.height)
        }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.currentVideo != nil, let window = note.object as? NSWindow,
                      window === self.playerWindow?.window || window === self.fullscreenWindow else { return }
                self.fullscreenWindow = window
                self.isVideoFullscreen = true
            }
        })
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.fullscreenWindow else { return }
                self.isVideoFullscreen = false
                self.fullscreenWindow = nil
            }
        })
    }

    func toggleVideoFullscreen() {
        guard currentVideo != nil else { return }
        if isVideoFullscreen { exitVideoFullscreen(); return }
        guard let window = playerWindow?.window else { return }
        fullscreenWindow = window
        isVideoFullscreen = true
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func exitVideoFullscreen() {
        guard isVideoFullscreen else { return }
        if let window = fullscreenWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            isVideoFullscreen = false
            fullscreenWindow = nil
        }
    }

    var displayedUsername: String { client?.session?.username ?? "" }
    var canLoadMore: Bool { videos.count < totalCount && !isLoading }

    func progressVideo(for video: VideoItem) -> VideoItem {
        if video.type == "Series", let episode = resumeVideos.first(where: { $0.seriesID == video.id }) { return episode }
        return video
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: "deviceID") { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return id
    }

    func connect() {
        let server = address, user = username.trimmingCharacters(in: .whitespacesAndNewlines), secret = password
        guard !isConnecting, !user.isEmpty else { return }
        connectionTask?.cancel()
        isConnecting = true
        errorMessage = nil
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task {
            do {
                let unauthenticated = try JellyfinClient(address: server, deviceID: deviceID,
                                                         transport: Self.makeTransport())
                let session = try await unauthenticated.authenticate(username: user, password: secret)
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                client = try unauthenticated.authenticated(with: session)
                do {
                    try sessionStore.save(SavedSession(address: unauthenticated.serverURL.absoluteString,
                                                       deviceID: deviceID, session: session))
                    sessionWarning = nil
                } catch { sessionWarning = "Connected, but Keychain couldn't save your sign-in. You may need to sign in next time." }
                defaults.set(server, forKey: "serverAddress")
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
        guard let client else { return }
        if !reset && isLoading { return }
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        if reset { videos = []; recentlyAddedVideos = []; recentContinueMovies = []; totalCount = 0; isLoadingResume = false }
        do {
            let page = try await client.videos(startIndex: reset ? 0 : videos.count, search: search,
                                               itemTypes: librarySection.itemTypes)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            videos.append(contentsOf: page.items.filter { incoming in !videos.contains { $0.id == incoming.id } })
            totalCount = page.totalCount
            if reset, librarySection != .movies {
                let resume = try? await client.resumeVideos()
                guard loadGeneration == generation else { return }
                resumeVideos = resume?.items ?? page.items.filter(\.isInProgress)
                resumeTotalCount = resume?.totalCount ?? resumeVideos.count
            }
            if reset, librarySection == .home, search.isEmpty {
                async let recentPage = client.recentlyAddedTitles(limit: 30)
                async let continuePage = client.resumeVideos(limit: 5, itemTypes: ["Movie"])
                let recent = try await recentPage
                let continuing = try? await continuePage
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                recentlyAddedVideos = recent
                recentContinueMovies = continuing?.items ?? Array(resumeVideos.filter { $0.type == "Movie" }.prefix(5))
            }
        } catch is CancellationError {
        } catch {
            if loadGeneration == generation {
                if case JellyfinError.unauthorized = error {
                    signOut()
                    errorMessage = "Your Jellyfin session expired. Please sign in again."
                } else { errorMessage = Self.friendly(error) }
            }
        }
        if loadGeneration == generation {
            isLoading = false
            if reset, librarySection == .home, search.isEmpty { homeRecommendationRevision += 1 }
        }
    }

    func loadMoreResumeVideos() async {
        guard let client, !isLoadingResume, resumeVideos.count < resumeTotalCount else { return }
        let generation = loadGeneration
        isLoadingResume = true
        defer { if loadGeneration == generation { isLoadingResume = false } }
        do {
            let page = try await client.resumeVideos(startIndex: resumeVideos.count)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            resumeVideos.append(contentsOf: page.items.filter { item in !resumeVideos.contains { $0.id == item.id } })
            resumeTotalCount = page.totalCount
        } catch {
            if loadGeneration == generation { errorMessage = "More unfinished titles couldn't be loaded. Please try again." }
        }
    }

    func refreshRecentlyAddedTitles() async {
        guard let client, !isLoading, librarySection == .home, search.isEmpty else { return }
        let generation = loadGeneration
        do {
            let titles = try await client.recentlyAddedTitles(limit: 30)
            try Task.checkCancellation()
            guard loadGeneration == generation, self.client?.session?.accessToken == client.session?.accessToken,
                  librarySection == .home, search.isEmpty else { return }
            if titles != recentlyAddedVideos {
                recentlyAddedVideos = titles
                homeRecommendationRevision += 1
            }
        } catch { /* A background refresh keeps the last confirmed library visible. */ }
    }

    func play(_ video: VideoItem, compatibleOnly: Bool = false, startFromBeginning: Bool = false) {
        guard let client else { return }
        stopPlayback(leaveFullscreen: false, closeWindow: false)
        currentVideo = video
        isStartingPlayback = true
        playbackTask = Task { [self] in
            do {
                var result = try await client.playback(for: video, compatibleOnly: compatibleOnly)
                try Task.checkCancellation()
                if startFromBeginning { result.resumePositionSeconds = 0 }
                stream = result
                showPlayer(for: video, aspectRatio: result.videoAspectRatio)
                playback.play(result)
                isStartingPlayback = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isStartingPlayback = false
                playbackError = Self.friendly(error)
                showPlayer(for: video, aspectRatio: nil)
            }
        }
    }

    private func showPlayer(for video: VideoItem, aspectRatio: Double?) {
        if playerWindow == nil { playerWindow = PlayerWindowController(model: self) }
        playerWindow?.fitVideo(aspectRatio: aspectRatio ?? 16.0 / 9.0)
        playerWindow?.show(title: video.name)
    }

    func retryCompatible() { if let currentVideo { play(currentVideo, compatibleOnly: true) } }

    func togglePlayback() {
        if playback.hasEnded, let currentVideo { play(currentVideo, startFromBeginning: true) }
        else { playback.togglePlayback() }
    }

    func stopPlayback(leaveFullscreen: Bool = true, closeWindow: Bool = true) {
        if leaveFullscreen {
            isVideoFullscreen = false
            fullscreenWindow = nil
        }
        playbackTask?.cancel(); playbackTask = nil
        finishPlayback()
        playback.stop()
        currentVideo = nil; playbackError = nil; reportWarning = nil
        isStartingPlayback = false; lastReportSeconds = -10; hasReportedStart = false
        if closeWindow {
            let controller = playerWindow
            playerWindow = nil
            isPlayerWindowKey = false
            controller?.closeWithoutCallback()
        }
    }

    func playerWindowDidClose() {
        stopPlayback(closeWindow: false)
        playerWindow = nil
        isPlayerWindowKey = false
    }

    func signOut() {
        try? sessionStore.remove()
        stopPlayback()
        connectionTask?.cancel()
        connectionGeneration = UUID()
        loadGeneration = UUID()
        let previous = client
        client = nil
        videos = []; resumeVideos = []; recentlyAddedVideos = []; recentContinueMovies = []; resumeTotalCount = 0; isLoadingResume = false; totalCount = 0; search = ""
        password = ""; errorMessage = nil
        isConnecting = false; isLoading = false
        sessionWarning = nil; librarySection = .home
        ArtworkCache.shared.clear()
        address = defaults.string(forKey: "serverAddress") ?? ""
        Task { try? await previous?.logout() }
    }

    private func reportProgress(seconds: Double, paused: Bool) {
        guard seconds.isFinite, seconds > 0, let client, let stream else { return }
        let event: PlaybackEvent
        if !hasReportedStart { hasReportedStart = true; event = .started }
        else if abs(seconds - lastReportSeconds) >= 10 { event = .progress }
        else { return }
        lastReportSeconds = seconds
        Task {
            do { try await client.reportPlayback(event, stream: stream, seconds: seconds, paused: paused) }
            catch { if self.stream?.playSessionID == stream.playSessionID { reportWarning = "Playback works, but Jellyfin couldn't save playback progress." } }
        }
    }

    private func finishPlayback() {
        guard let client, let stream else { return }
        let seconds = playback.seconds
        self.stream = nil
        Task {
            do {
                try await client.reportPlayback(.stopped, stream: stream, seconds: seconds)
                guard self.client?.session?.accessToken == client.session?.accessToken else { return }
                let updated = try await client.item(id: stream.itemID)
                guard self.client?.session?.accessToken == client.session?.accessToken else { return }
                if let index = videos.firstIndex(where: { $0.id == updated.id }) { videos[index] = updated }
                if let index = recentlyAddedVideos.firstIndex(where: { $0.id == updated.id }) { recentlyAddedVideos[index] = updated }
                if updated.type == "Episode", let seriesID = updated.seriesID,
                   let show = try? await client.item(id: seriesID) {
                    guard self.client?.session?.accessToken == client.session?.accessToken else { return }
                    if let index = videos.firstIndex(where: { $0.id == seriesID }) { videos[index] = show }
                    if let index = recentlyAddedVideos.firstIndex(where: { $0.id == seriesID }) { recentlyAddedVideos[index] = show }
                }
                if librarySection != .movies, let resume = try? await client.resumeVideos() {
                    guard self.client?.session?.accessToken == client.session?.accessToken else { return }
                    resumeVideos = resume.items; resumeTotalCount = resume.totalCount
                }
                if librarySection == .home, let movies = try? await client.resumeVideos(limit: 5, itemTypes: ["Movie"]) {
                    guard self.client?.session?.accessToken == client.session?.accessToken else { return }
                    recentContinueMovies = movies.items
                }
                playbackRevision += 1
            } catch { /* Leave the last server-confirmed state visible until a refresh. */ }
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
                return "Couldn't reach the Jellyfin server. Check the address, network connection, and local network access."
            case .timedOut: return "The server took too long to respond. Please try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "The server's HTTPS connection could not be verified. Check its certificate."
            default: return "The network request failed. Check the server address and try again."
            }
        }
        return "Something went wrong. Please try again."
    }
}
