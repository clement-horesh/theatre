import AVFoundation
import AppKit
import Combine
import Foundation
import JellyfinKit
import OSLog

/// Owns one playback session, its engines, window and server lifecycle.
@MainActor
final class PlaybackSession: ObservableObject {
    @Published private(set) var currentVideo: VideoItem?
    @Published private(set) var isStartingPlayback = false
    @Published private(set) var isPreparingSystemPlayback = false
    @Published private(set) var isVideoFullscreen = false
    @Published var isPlayerWindowKey = false
    @Published var presentationError: String?
    @Published private(set) var playbackError: String?
    let playback: PlaybackController
    let preferences: PlaybackPreferences
    var client: JellyfinClient?
    weak var downloads: DownloadManager?
    var onStopped: ((JellyfinClient, String) -> Void)?
    private var playerWindow: PlayerWindowController?
    private var stream: PlaybackStream?
    private var playbackTask: Task<Void, Never>?
    private var systemPlaybackTask: Task<Bool, Never>?
    private var preparedSystemStream: PlaybackStream?
    private var systemPlaybackGeneration = UUID()
    @Published private(set) var nextEpisode: VideoItem?
    @Published private(set) var creditsStart: Double?
    @Published private(set) var intro: MediaSegment?
    private var episodeTask: Task<Void, Never>?
    private var unusedPreparationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var routePickerOpen = false
    private let nowPlaying = NowPlayingController()
    private let logger = Logger(subsystem: "local.jellymac.app", category: "Playback")
    var pendingReport: Task<Void, Error>? { playbackReporter.pendingTask }
    var offersNextEpisode: Bool {
        nextEpisode != nil && (playback.hasEnded || creditsStart.map { playback.seconds >= $0 } == true)
    }
    var offersSkipIntro: Bool {
        !playback.hasEnded && playback.canSeek && intro?.contains(seconds: playback.seconds) == true
            && (intro?.endSeconds ?? .infinity) < playback.duration
    }

    func skipIntro() {
        guard offersSkipIntro, let end = intro?.endSeconds else { return }
        playback.seek(to: end)
    }
    private let playbackReporter = PlaybackReporter()
    private enum EpisodeContext: Sendable {
        case next(VideoItem?)
        case markers([MediaSegment])
    }

    init(preferences: PlaybackPreferences) {
        self.preferences = preferences
        playback = PlaybackController(defaults: preferences.defaults, preferences: preferences)
        playback.onProgress = { [weak self] seconds, paused in self?.reportProgress(seconds: seconds, paused: paused) }
        playback.onEnded = { [weak self] in self?.episodeEnded() }
        playback.applePlayback.onExternalPlaybackActive = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, await self.prepareSystemPlayback(),
                    self.playback.applePlayback.player.isExternalPlaybackActive
                else { return }
                self.activateSystemPlayback()
            }
        }
        playback.applePlayback.onRestoreWindow = { [weak self] in
            guard let window = self?.playerWindow?.window, self?.currentVideo != nil else { return false }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return window.isVisible
        }
        playback.applePlayback.onError = { [weak self] in self?.presentationError = $0 }
        playback.onVideoSize = { [weak self] size in
            guard let self, self.stream?.videoAspectRatio == nil else { return }
            self.playerWindow?.fitVideo(aspectRatio: size.width / size.height)
        }
    }

    deinit {
        playbackTask?.cancel()
        systemPlaybackTask?.cancel()
        episodeTask?.cancel()
        unusedPreparationTask?.cancel()
    }

    func toggleVideoFullscreen() {
        guard currentVideo != nil else { return }
        playerWindow?.window?.toggleFullScreen(nil)
    }

    func exitVideoFullscreen() {
        guard let window = playerWindow?.window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func playerFullscreenChanged(_ fullscreen: Bool) { isVideoFullscreen = fullscreen }

    func play(
        _ video: VideoItem, compatibleOnly: Bool = false, startFromBeginning: Bool = false,
        at position: Double? = nil, playing: Bool = true,
        using nextClient: JellyfinClient? = nil, downloads nextDownloads: DownloadManager? = nil
    ) {
        guard let client = nextClient ?? client else { return }
        let nativePlayback = playback.usesApplePlayback && !compatibleOnly
        stopPlayback(leaveFullscreen: false, closeWindow: false, preservingApplePlayback: nativePlayback)
        self.client = client
        if nextClient != nil { downloads = nextDownloads }
        currentVideo = video
        isStartingPlayback = true
        loadEpisodeContext(video, client: client)
        playbackTask = Task { [self] in
            do {
                let native: (stream: PlaybackStream, item: AVPlayerItem)?
                if nativePlayback, downloads?.playbackStream(for: video) != nil {
                    // A following download may use a format AVPlayer can't open.
                    // Let VLC continue playing it in the regular player window.
                    native = try? await loadAppleStream(video: video, client: client)
                } else {
                    native = nativePlayback ? try await loadAppleStream(video: video, client: client) : nil
                }
                var result: PlaybackStream
                if let native {
                    result = native.stream
                } else if !compatibleOnly, let local = downloads?.playbackStream(for: video) {
                    result = local
                } else {
                    result = try await client.playback(for: video, compatibleOnly: compatibleOnly)
                }
                guard !Task.isCancelled else {
                    releaseEncoding(result, client: client)
                    return
                }
                if startFromBeginning { result.resumePositionSeconds = 0 }
                if let position, position.isFinite { result.resumePositionSeconds = max(0, position) }
                stream = result
                showPlayer(for: video, aspectRatio: result.videoAspectRatio)
                nowPlaying.activate(
                    video: video, toggle: { [weak self] in self?.togglePlayback() },
                    play: { [weak self] in
                        guard let self else { return }
                        if self.playback.hasEnded { self.togglePlayback() } else { self.playback.setPlaying(true) }
                    },
                    pause: { [weak self] in self?.playback.setPlaying(false) },
                    seek: { [weak self] in self?.playback.seek(to: $0) },
                    skip: { [weak self] in self?.playback.seek(by: $0) },
                    next: video.type == "Episode" ? { [weak self] in self?.playNextEpisode() } : nil)
                if let native {
                    playback.playApple(
                        native.item, stream: result, at: result.resumePositionSeconds, playing: playing,
                        preserveTracks: false)
                } else {
                    playback.play(result, playing: playing)
                }
                isStartingPlayback = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isStartingPlayback = false
                playbackError = AppModel.friendly(error)
                showPlayer(for: video, aspectRatio: nil)
            }
        }
    }

    private func showPlayer(for video: VideoItem, aspectRatio: Double?) {
        if playerWindow == nil { playerWindow = PlayerWindowController(session: self) }
        playerWindow?.fitVideo(aspectRatio: aspectRatio ?? 16.0 / 9.0)
        playerWindow?.show(title: video.name)
    }

    func retryCompatible() {
        guard let currentVideo else { return }
        // A failure before playback starts must retain the original saved resume point.
        let position = playback.seconds > 0 ? playback.seconds : currentVideo.resumePositionSeconds
        let playing = playback.isPlaying || playback.errorMessage != nil || playbackError != nil
        play(currentVideo, compatibleOnly: true, at: position, playing: playing)
    }

    func prepareSystemPlayback(reportErrors: Bool = true) async -> Bool {
        if playback.usesApplePlayback { return true }
        if preparedSystemStream != nil, playback.applePlayback.player.currentItem?.status == .readyToPlay {
            return true
        }
        if let systemPlaybackTask { return await systemPlaybackTask.value }
        guard let client, let video = currentVideo, !isStartingPlayback else { return false }
        let generation = UUID()
        systemPlaybackGeneration = generation
        isPreparingSystemPlayback = true
        presentationError = nil
        let task = Task { [self] in
            defer { if systemPlaybackGeneration == generation { isPreparingSystemPlayback = false } }
            do {
                let prepared = try await loadAppleStream(video: video, client: client, preserveSelection: true)
                let result = prepared.stream
                var adopted = false
                defer { if !adopted { releaseEncoding(result, client: client) } }
                try Task.checkCancellation()
                guard systemPlaybackGeneration == generation, currentVideo?.id == video.id else {
                    return false
                }
                preparedSystemStream = result
                adopted = true
                if !routePickerOpen { scheduleUnusedPreparationCleanup() }
                return true
            } catch {
                if !Task.isCancelled, systemPlaybackGeneration == generation,
                    reportErrors || playback.applePlayback.player.isExternalPlaybackActive
                {
                    presentationError =
                        stream?.url.isFileURL == true
                        ? "Apple’s player can’t present this downloaded format. You can keep watching it in Theatre."
                        : AppModel.friendly(error)
                }
                return false
            }
        }
        systemPlaybackTask = task
        let result = await task.value
        if systemPlaybackGeneration == generation { systemPlaybackTask = nil }
        return result
    }

    private func loadAppleStream(video: VideoItem, client: JellyfinClient, preserveSelection: Bool = false) async throws
        -> (stream: PlaybackStream, item: AVPlayerItem)
    {
        if let local = downloads?.playbackStream(for: video) {
            let item = try await playback.applePlayback.prepare(url: local.url)
            return (local, item)
        }
        let source = preserveSelection ? stream?.mediaSourceID : nil
        var audio = preserveSelection ? playback.selectedStreamIndex(type: "Audio") : nil
        var subtitle = preserveSelection ? playback.selectedStreamIndex(type: "Subtitle") : nil
        var result = try await client.playback(
            for: video, nativePlayer: true, mediaSourceID: source, audioStreamIndex: audio,
            subtitleStreamIndex: subtitle)
        var prepared = false
        defer { if !prepared { releaseEncoding(result, client: client) } }
        try Task.checkCancellation()
        if !preserveSelection {
            if let preferred = result.mediaTracks.first(where: {
                $0.type == "Audio"
                    && PlayerTrack(id: 0, name: "", language: $0.language).languageCode == preferences.audioLanguage
            }) {
                audio = preferred.index
            }
            if preferences.subtitleLanguage == "off" {
                subtitle = -1
            } else if let preferred = result.mediaTracks.first(where: {
                $0.type == "Subtitle"
                    && PlayerTrack(id: 0, name: "", language: $0.language).languageCode == preferences.subtitleLanguage
            }) {
                subtitle = preferred.index
            }
            if result.method == "Transcode", audio != nil || subtitle != nil {
                result = try await client.playback(
                    for: video, compatibleOnly: true, nativePlayer: true,
                    mediaSourceID: result.mediaSourceID, audioStreamIndex: audio, subtitleStreamIndex: subtitle)
            }
        }
        do {
            if result.method == "DirectPlay",
                result.mediaTracks.contains(where: { $0.type == "Subtitle" && $0.isExternal && $0.index == subtitle })
            {
                throw JellyfinError.noPlayableSource
            }
            let item = try await playback.applePlayback.prepare(url: result.url)
            try Task.checkCancellation()
            prepared = true
            return (result, item)
        } catch {
            try Task.checkCancellation()
            guard result.method != "Transcode" else { throw error }
            result = try await client.playback(
                for: video, compatibleOnly: true, nativePlayer: true, mediaSourceID: source, audioStreamIndex: audio,
                subtitleStreamIndex: subtitle)
            let item = try await playback.applePlayback.prepare(url: result.url)
            try Task.checkCancellation()
            prepared = true
            return (result, item)
        }
    }

    private func activateSystemPlayback() {
        // Preparing the route picker must not interrupt VLC. Handoff happens only
        // after a receiver connects or the user explicitly requests Picture in Picture.
        guard !playback.usesApplePlayback, let result = preparedSystemStream,
            let item = playback.applePlayback.player.currentItem, item.status == .readyToPlay
        else { return }
        unusedPreparationTask?.cancel()
        let position = playback.seconds
        let wasPlaying = playback.isPlaying
        finishPlayback()
        stream = result
        preparedSystemStream = nil
        playback.playApple(item, stream: result, at: position, playing: wasPlaying)
    }

    func togglePictureInPicture() async {
        guard await prepareSystemPlayback() else { return }
        activateSystemPlayback()
        playback.applePlayback.togglePictureInPicture()
    }

    func togglePlayback() {
        if playback.hasEnded, let currentVideo {
            play(currentVideo, startFromBeginning: true)
        } else {
            playback.togglePlayback()
        }
    }

    func stopPlayback(leaveFullscreen: Bool = true, closeWindow: Bool = true, preservingApplePlayback: Bool = false) {
        discardSystemPreparation()
        episodeTask?.cancel()
        nextEpisode = nil
        creditsStart = nil
        intro = nil
        presentationError = nil
        if leaveFullscreen {
            isVideoFullscreen = false
        }
        playbackTask?.cancel()
        playbackTask = nil
        finishPlayback()
        playback.stop(preservingApplePlayback: preservingApplePlayback)
        nowPlaying.clear()
        currentVideo = nil
        playbackError = nil
        isStartingPlayback = false
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

    private func reportProgress(seconds: Double, paused: Bool) {
        nowPlaying.update(
            seconds: seconds, duration: playback.duration, rate: paused ? 0 : playback.rate,
            hasNext: nextEpisode != nil)
        guard let client, let stream else { return }
        if stream.url.isFileURL {
            downloads?.saveProgress(
                itemID: stream.itemID, seconds: seconds, duration: playback.duration, paused: paused)
        } else {
            _ = playbackReporter.progress(client: client, stream: stream, seconds: seconds, paused: paused)
        }
    }

    private func finishPlayback() {
        guard let client, let stream else { return }
        let seconds = playback.seconds
        self.stream = nil
        if stream.url.isFileURL {
            downloads?.saveProgress(
                itemID: stream.itemID, seconds: seconds, duration: playback.duration,
                paused: true, finished: playback.hasEnded, force: true)
            downloads?.synchronize()
            onStopped?(client, stream.itemID)
            return
        }
        let report = playbackReporter.stop(client: client, stream: stream, seconds: seconds)
        Task {
            _ = try? await report.value
            onStopped?(client, stream.itemID)
        }
    }
    func routePickerTracking(_ active: Bool) {
        routePickerOpen = active
        unusedPreparationTask?.cancel()
        if !active, preparedSystemStream != nil { scheduleUnusedPreparationCleanup() }
    }

    private func scheduleUnusedPreparationCleanup() {
        unusedPreparationTask?.cancel()
        unusedPreparationTask = Task { [weak self] in
            // AVKit can finish connecting after the picker closes. Give that connection time to settle.
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, !self.routePickerOpen, !self.playback.usesApplePlayback,
                !self.playback.applePlayback.player.isExternalPlaybackActive
            else { return }
            self.discardSystemPreparation()
        }
    }

    func discardSystemPreparation() {
        unusedPreparationTask?.cancel()
        unusedPreparationTask = nil
        systemPlaybackTask?.cancel()
        systemPlaybackTask = nil
        systemPlaybackGeneration = UUID()
        if let preparedSystemStream, let client { releaseEncoding(preparedSystemStream, client: client) }
        preparedSystemStream = nil
        isPreparingSystemPlayback = false
        if !playback.usesApplePlayback { playback.applePlayback.stop() }
    }

    private func releaseEncoding(_ stream: PlaybackStream, client: JellyfinClient) {
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            do { try await client.stopEncoding(stream) } catch {
                let failure = error as NSError
                logger.error("Encoding cleanup failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            }
        }
    }

    func shutdown() async {
        let preparing = systemPlaybackTask
        let starting = playbackTask
        stopPlayback()
        _ = await preparing?.value
        await starting?.value
        _ = try? await pendingReport?.value
        await cleanupTask?.value
    }

    private func loadEpisodeContext(_ video: VideoItem, client: JellyfinClient) {
        guard video.type == "Episode" else { return }
        if let record = downloads?.record(for: video), downloads?.playbackStream(for: video) != nil {
            if let id = record.nextEpisodeID, let next = downloads?.cachedVideo(id: id),
                downloads?.playbackStream(for: next) != nil
            {
                nextEpisode = next
            }
            creditsStart = record.creditsStart
            intro = record.intro
            return
        }
        episodeTask = Task { [weak self] in
            // A slow metadata endpoint must not delay intro skipping or continuation.
            await withTaskGroup(of: EpisodeContext.self) { group in
                group.addTask { .next(try? await client.nextEpisode(after: video)) }
                group.addTask { .markers((try? await client.mediaSegments(itemID: video.id)) ?? []) }
                for await context in group {
                    guard let self, !Task.isCancelled, self.currentVideo?.id == video.id else {
                        group.cancelAll()
                        return
                    }
                    switch context {
                    case .next(let next):
                        self.nextEpisode = next
                        if self.playback.hasEnded, self.preferences.automaticallyPlayNext { self.playNextEpisode() }
                    case .markers(let markers):
                        self.creditsStart = markers.filter { $0.type == "Outro" && $0.startTicks > 0 }.map(
                            \.startSeconds
                        ).min()
                        self.intro = markers.filter { $0.type == "Intro" && $0.isSkippable }.min {
                            $0.startTicks < $1.startTicks
                        }
                    }
                }
            }
        }
    }

    private func episodeEnded() {
        finishPlayback()
        if preferences.automaticallyPlayNext { playNextEpisode() }
    }

    func playNextEpisode() {
        guard let nextEpisode, !isStartingPlayback else { return }
        play(nextEpisode)
    }

}
