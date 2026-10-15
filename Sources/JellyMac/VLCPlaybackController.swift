import AVFoundation
import AppKit
import Combine
import Foundation
import JellyfinKit
import VLCKit

struct PlayerTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

/// Uses VLC for broad-format playback and AVPlayer for native AirPlay routing.
@MainActor
final class VLCPlaybackController: ObservableObject {
    let videoView = VLCVideoView(frame: .zero)
    private var engine: VLCMediaPlayer
    let applePlayback = ApplePlaybackController()
    @Published private(set) var usesApplePlayback = false
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var subtitleAppearance: SubtitleAppearance
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var hasEnded = false
    @Published private(set) var seconds = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var canSeek = false
    @Published private(set) var audioTracks: [PlayerTrack] = []
    @Published private(set) var subtitleTracks: [PlayerTrack] = []
    @Published private(set) var selectedAudio: Int32 = -1
    @Published private(set) var selectedSubtitle: Int32 = -1
    @Published private(set) var volume = 80.0
    @Published private(set) var rate = 1.0
    @Published private(set) var errorMessage: String?
    var onProgress: ((Double, Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    private var lastVideoSize = CGSize.zero
    private var pollingTask: Task<Void, Never>?
    private var pendingSubtitles: [PlaybackSubtitle] = []
    private var reportedEnd = false
    private var generation = UUID()
    // VLC's time getter is cached and can stay at the pre-seek time while paused.
    private var pendingSeek: (target: Double, deadline: Date)?
    private var preparationDeadline = Date.distantFuture
    private var pendingResume: Double?
    private let sleepProtection = PlaybackSleepProtection()
    private let defaults: UserDefaults
    private var currentStream: PlaybackStream?
    private var pendingAudio: Int32?
    private var pendingSubtitle: Int32?
    private var pauseAfterPreparing = false
    private var nativeDuration = 0.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let appearance =
            defaults.data(forKey: SubtitleAppearance.defaultsKey)
            .flatMap { try? JSONDecoder().decode(SubtitleAppearance.self, from: $0) } ?? .standard
        subtitleAppearance = appearance
        engine = Self.makeEngine(appearance: appearance)
        videoView.backColor = .black
        videoView.fillScreen = false
        engine.drawable = videoView
        engine.scaleFactor = 0
        engine.audio?.volume = 80
        applePlayback.onPictureInPictureChange = { [weak self] in self?.isPictureInPictureActive = $0 }
    }

    private static func makeEngine(appearance: SubtitleAppearance) -> VLCMediaPlayer {
        VLCMediaPlayer(options: ["--quiet", "--no-video-title-show", "--network-caching=750"] + appearance.vlcOptions)
    }

    func play(_ stream: PlaybackStream) {
        stop()
        currentStream = stream
        errorMessage = nil
        isPreparing = true
        preparationDeadline = Date().addingTimeInterval(45)
        pendingSubtitles = stream.externalSubtitles
        if stream.resumePositionSeconds.isFinite, stream.resumePositionSeconds > 0 {
            pendingResume = stream.resumePositionSeconds
        }
        engine.media = VLCMedia(url: stream.url)
        engine.play()
        engine.rate = Float(rate)
        startPolling()
    }

    private func startPolling() {
        let current = UUID()
        generation = current
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                self.update()
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }

    func stop() {
        reset(stopApple: true)
    }

    private func reset(stopApple: Bool) {
        sleepProtection.release()
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        engine.stop()
        engine.media = nil
        if stopApple { applePlayback.stop() }
        usesApplePlayback = false
        isPictureInPictureActive = false
        currentStream = nil
        pendingAudio = nil
        pendingSubtitle = nil
        pauseAfterPreparing = false
        isPlaying = false
        isPreparing = false
        seconds = 0
        duration = 0
        canSeek = false
        audioTracks = []
        subtitleTracks = []
        selectedAudio = -1
        selectedSubtitle = -1
        pendingSeek = nil
        pendingResume = nil
        lastVideoSize = .zero
        pendingSubtitles = []
        errorMessage = nil
        reportedEnd = false
        hasEnded = false
    }

    func togglePlayback() {
        if usesApplePlayback {
            if applePlayback.player.rate > 0 {
                applePlayback.player.pause()
            } else {
                applePlayback.player.playImmediately(atRate: Float(rate))
            }
            update()
            return
        }
        if engine.isPlaying { engine.pause() } else { engine.play() }
        update()
    }

    func seek(to value: Double) {
        guard value.isFinite, canSeek, duration > 0 else { return }
        let destination = max(0, min(value, duration - 0.05))
        if usesApplePlayback {
            applePlayback.seek(to: destination)
            hasEnded = false
            reportedEnd = false
            seconds = destination
            return
        }
        pendingSeek = (destination, Date().addingTimeInterval(3))
        engine.time = VLCTime(number: NSNumber(value: Int64(destination * 1000)))
        // A paused decoder can retain its old image after repeated seeks. Ask
        // for one decoded frame at the new position without resuming playback.
        if !engine.isPlaying { engine.gotoNextFrame() }
        seconds = destination
        hasEnded = false
    }

    func seek(by interval: Double) { seek(to: seconds + interval) }

    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        rate = max(0.5, min(2, value))
        engine.rate = Float(rate)
        if usesApplePlayback, applePlayback.player.rate > 0 { applePlayback.player.rate = Float(rate) }
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = max(0, min(100, value))
        engine.audio?.volume = Int32(volume)
        applePlayback.player.volume = Float(volume / 100)
    }

    func selectAudio(_ id: Int32) {
        if usesApplePlayback {
            if let group = applePlayback.audioGroup, group.options.indices.contains(Int(id)) {
                applePlayback.player.currentItem?.select(group.options[Int(id)], in: group)
                selectedAudio = id
            }
            return
        }
        engine.currentAudioTrackIndex = id
        selectedAudio = engine.currentAudioTrackIndex
    }
    func selectSubtitle(_ id: Int32) {
        if usesApplePlayback {
            if let group = applePlayback.subtitleGroup {
                let option = group.options.indices.contains(Int(id)) ? group.options[Int(id)] : nil
                applePlayback.player.currentItem?.select(option, in: group)
                selectedSubtitle = option == nil ? -1 : id
            }
            return
        }
        engine.currentVideoSubTitleIndex = id
        selectedSubtitle = engine.currentVideoSubTitleIndex
    }

    private func update() {
        if usesApplePlayback {
            updateApplePlayback()
            return
        }
        let size = engine.videoSize
        if size.width > 0, size.height > 0, size != lastVideoSize {
            lastVideoSize = size
            onVideoSize?(size)
        }
        let engineSeconds = max(0, (engine.time.value?.doubleValue ?? 0) / 1000)
        if let seek = pendingSeek {
            if engine.isPlaying && (abs(engineSeconds - seek.target) < 0.15 || Date() > seek.deadline) {
                pendingSeek = nil
                seconds = engineSeconds
            } else {
                seconds = seek.target
            }
        } else {
            seconds = engineSeconds
        }
        duration = max(0, (engine.media?.length.value?.doubleValue ?? 0) / 1000)
        canSeek = engine.isSeekable
        isPlaying = engine.isPlaying
        if let resume = pendingResume, canSeek, duration > 0, isPlaying {
            pendingResume = nil
            seek(to: resume)
        }
        // Some VLC inputs remain in buffering state while decoded frames/time are
        // already advancing. Do not leave working playback behind a loading overlay.
        if seconds > 0 || videoView.hasVideo { isPreparing = false }
        switch engine.state {
        case .playing, .paused:
            isPreparing = false
            if !pendingSubtitles.isEmpty {
                let tracks = pendingSubtitles
                pendingSubtitles = []
                for track in tracks { _ = engine.addPlaybackSlave(track.url, type: .subtitle, enforce: false) }
            }
        case .error:
            isPreparing = false
            errorMessage = "VLC couldn't play this stream. Check the file or try Jellyfin's compatible stream."
        case .ended:
            isPreparing = false
            hasEnded = true
            if !reportedEnd {
                reportedEnd = true
                onEnded?()
            }
        default: break
        }
        if isPreparing && Date() > preparationDeadline {
            isPreparing = false
            errorMessage = "The video took too long to start. Check the connection or try a compatible stream."
        }
        let audio = tracks(names: engine.audioTrackNames, indexes: engine.audioTrackIndexes)
        let subtitles = tracks(names: engine.videoSubTitlesNames, indexes: engine.videoSubTitlesIndexes)
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
        if selectedAudio != engine.currentAudioTrackIndex { selectedAudio = engine.currentAudioTrackIndex }
        if selectedSubtitle != engine.currentVideoSubTitleIndex { selectedSubtitle = engine.currentVideoSubTitleIndex }
        if let id = pendingAudio, audioTracks.contains(where: { $0.id == id }) {
            selectAudio(id)
            pendingAudio = nil
        }
        if let id = pendingSubtitle, id == -1 || subtitleTracks.contains(where: { $0.id == id }) {
            selectSubtitle(id)
            pendingSubtitle = nil
        }
        if pauseAfterPreparing, !isPreparing, pendingResume == nil {
            engine.pause()
            isPlaying = false
            pauseAfterPreparing = false
        }
        let window = videoView.window
        sleepProtection.update(
            isPlaying: isPlaying && !hasEnded && errorMessage == nil,
            watchingInForeground: NSApp.isActive && window?.isVisible == true && window?.isMiniaturized == false)
        if isPlaying || seconds > 0 { onProgress?(seconds, !isPlaying) }
    }

    func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        guard appearance != subtitleAppearance else { return }
        subtitleAppearance = appearance
        if let data = try? JSONEncoder().encode(appearance) {
            defaults.set(data, forKey: SubtitleAppearance.defaultsKey)
        }
        if usesApplePlayback {
            applePlayback.player.currentItem?.textStyleRules = appearance.nativeStyle.map { [$0] } ?? []
            return
        }
        let savedStream = currentStream
        let position = seconds
        let paused = !isPlaying
        let audio = selectedAudio
        let subtitle = selectedSubtitle
        stop()
        engine.drawable = nil
        engine = Self.makeEngine(appearance: appearance)
        engine.drawable = videoView
        engine.scaleFactor = 0
        engine.audio?.volume = Int32(volume)
        if var savedStream {
            savedStream.resumePositionSeconds = position
            play(savedStream)
            pendingAudio = audio
            pendingSubtitle = subtitle
            pauseAfterPreparing = paused
        }
    }

    func playApple(_ item: AVPlayerItem, stream: PlaybackStream, at position: Double, playing: Bool) {
        let previousDuration = duration
        reset(stopApple: false)
        currentStream = stream
        usesApplePlayback = true
        nativeDuration = previousDuration
        audioTracks = (applePlayback.audioGroup?.options ?? []).enumerated().map {
            PlayerTrack(id: Int32($0.offset), name: $0.element.displayName)
        }
        subtitleTracks = (applePlayback.subtitleGroup?.options ?? []).enumerated().map {
            PlayerTrack(id: Int32($0.offset), name: $0.element.displayName)
        }
        applePlayback.start(
            item: item, at: position, playing: playing, rate: rate, volume: volume,
            appearance: subtitleAppearance)
        startPolling()
    }

    private func updateApplePlayback() {
        let player = applePlayback.player
        let time = player.currentTime().seconds
        seconds = time.isFinite ? max(0, time) : 0
        let length = player.currentItem?.duration.seconds ?? 0
        duration = length.isFinite && length > 0 ? length : nativeDuration
        isPlaying = player.timeControlStatus == .playing
        isPreparing = player.currentItem?.status == .unknown
        canSeek = duration > 0 && player.currentItem?.seekableTimeRanges.isEmpty == false
        if let item = player.currentItem {
            if let group = applePlayback.audioGroup,
                let option = item.currentMediaSelection.selectedMediaOption(in: group)
            {
                selectedAudio = group.options.firstIndex(of: option).map(Int32.init) ?? -1
            } else {
                selectedAudio = -1
            }
            if let group = applePlayback.subtitleGroup,
                let option = item.currentMediaSelection.selectedMediaOption(in: group)
            {
                selectedSubtitle = group.options.firstIndex(of: option).map(Int32.init) ?? -1
            } else {
                selectedSubtitle = -1
            }
            if item.status == .failed {
                errorMessage = "Apple’s player couldn’t play the compatible stream. Try a compatible stream again."
            }
        }
        hasEnded = applePlayback.hasEnded
        if hasEnded && !reportedEnd {
            reportedEnd = true
            onEnded?()
        }
        sleepProtection.update(
            isPlaying: isPlaying && !hasEnded && errorMessage == nil,
            watchingInForeground: NSApp?.isActive == true)
        if isPlaying || seconds > 0 { onProgress?(seconds, !isPlaying) }
    }

    private func tracks(names: [Any], indexes: [Any]) -> [PlayerTrack] {
        zip(names, indexes).compactMap { name, index in
            guard let index = index as? NSNumber, let name = name as? String else { return nil }
            return PlayerTrack(id: index.int32Value, name: index.int32Value == -1 ? "Off" : name)
        }
    }
}
