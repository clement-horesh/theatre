import AVFoundation
import AppKit
import Combine
import Foundation
import JellyfinKit
import VLCKit

struct PlayerTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    var language: String? = nil

    var languageCode: String? {
        guard let language, !language.isEmpty, language != "und" else { return nil }
        return Locale.canonicalLanguageIdentifier(from: language).components(separatedBy: "-").first
    }

    func match(in tracks: [PlayerTrack]) -> PlayerTrack? {
        tracks.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? tracks.first { languageCode != nil && $0.languageCode == languageCode }
    }

}

/// Uses VLC for broad-format playback and AVPlayer for native AirPlay routing.
@MainActor
final class PlaybackController: ObservableObject {
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
    private var endObservation: NSObjectProtocol?
    private var pendingSubtitles: [PlaybackSubtitle] = []
    private var reportedEnd = false
    private var generation = UUID()
    // VLC's time getter is cached and can stay at the pre-seek time while paused.
    private var pendingSeek: (target: Double, deadline: Date)?
    private var preparationDeadline = Date.distantFuture
    private var pendingResume: Double?
    private let sleepProtection = PlaybackSleepProtection()
    private let defaults: UserDefaults
    private let preferences: PlaybackPreferences
    private var needsAudioLanguage = false
    private var needsSubtitleLanguage = false
    private var currentStream: PlaybackStream?
    private var pendingAudio: Int32?
    private var pendingSubtitle: Int32?
    private var pauseAfterPreparing = false
    private var nativeDuration = 0.0

    init(defaults: UserDefaults = .standard, preferences: PlaybackPreferences? = nil) {
        self.preferences = preferences ?? PlaybackPreferences(defaults: defaults)
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
        observeEngineEnd()
    }

    deinit {
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
    }

    private func observeEngineEnd() {
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        endObservation = NotificationCenter.default.addObserver(
            forName: Notification.Name(VLCMediaPlayerStateChanged), object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.state == .ended else { return }
                self.playbackEnded()
            }
        }
    }

    private func playbackEnded() {
        guard !reportedEnd, !isPreparing, currentStream != nil else { return }
        reportedEnd = true
        hasEnded = true
        isPlaying = false
        seconds = max(seconds, duration)
        sleepProtection.release()
        let current = generation
        // Finish the old engine update before the session starts another video.
        Task { [weak self] in
            guard let self, self.generation == current else { return }
            self.onEnded?()
        }
    }

    private static func makeEngine(appearance: SubtitleAppearance) -> VLCMediaPlayer {
        // VLCKit defaults to pausing at EOF, which suppresses the end event.
        VLCMediaPlayer(
            options: ["--quiet", "--no-video-title-show", "--network-caching=750", "--no-play-and-pause"]
                + appearance.vlcOptions)
    }

    func play(_ stream: PlaybackStream) {
        stop()
        currentStream = stream
        errorMessage = nil
        isPreparing = true
        preparationDeadline = Date().addingTimeInterval(45)
        needsAudioLanguage = true
        needsSubtitleLanguage = true
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

    func stop(preservingApplePlayback: Bool = false) {
        reset(stopApple: !preservingApplePlayback)
    }

    private func reset(stopApple: Bool) {
        sleepProtection.release()
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        engine.stop()
        engine.media = nil
        if stopApple { applePlayback.stop() } else { applePlayback.player.pause() }
        if stopApple {
            usesApplePlayback = false
            isPictureInPictureActive = false
        }
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

    func setPlaying(_ playing: Bool) {
        if playing != isPlaying { togglePlayback() }
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

    func selectAudio(_ id: Int32, remember: Bool = true) {
        needsAudioLanguage = false
        if remember, let language = audioTracks.first(where: { $0.id == id })?.languageCode {
            preferences.audioLanguage = language
        }
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
    func selectSubtitle(_ id: Int32, remember: Bool = true) {
        needsSubtitleLanguage = false
        if remember {
            if id == -1 {
                preferences.subtitleLanguage = "off"
            } else if let language = subtitleTracks.first(where: { $0.id == id })?.languageCode {
                preferences.subtitleLanguage = language
            }
        }
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
        case .error:
            isPreparing = false
            errorMessage = "VLC couldn't play this stream. Check the file or try Jellyfin's compatible stream."
        case .ended:
            playbackEnded()
        default: break
        }
        if !isPreparing, !hasEnded, errorMessage == nil, !pendingSubtitles.isEmpty {
            let tracks = pendingSubtitles
            pendingSubtitles = []
            for track in tracks { _ = engine.addPlaybackSlave(track.url, type: .subtitle, enforce: false) }
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
        if !isPreparing { applyPreferredLanguages() }
        if let id = pendingAudio, audioTracks.contains(where: { $0.id == id }) {
            selectAudio(id, remember: false)
            pendingAudio = nil
        }
        if let id = pendingSubtitle, id == -1 || subtitleTracks.contains(where: { $0.id == id }) {
            selectSubtitle(id, remember: false)
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
        observeEngineEnd()
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

    func playApple(
        _ item: AVPlayerItem, stream: PlaybackStream, at position: Double, playing: Bool, preserveTracks: Bool = true
    ) {
        let audio = preserveTracks ? audioTracks.first { $0.id == selectedAudio } : nil
        let subtitlesOff = preserveTracks && selectedSubtitle == -1
        let subtitle = preserveTracks ? subtitleTracks.first { $0.id == selectedSubtitle } : nil
        let previousDuration = duration
        reset(stopApple: false)
        currentStream = stream
        usesApplePlayback = true
        nativeDuration = previousDuration
        audioTracks = (applePlayback.audioGroup?.options ?? []).enumerated().map {
            PlayerTrack(
                id: Int32($0.offset), name: $0.element.displayName,
                language: $0.element.extendedLanguageTag ?? $0.element.locale?.identifier)
        }
        subtitleTracks = (applePlayback.subtitleGroup?.options ?? []).enumerated().map {
            PlayerTrack(
                id: Int32($0.offset), name: $0.element.displayName,
                language: $0.element.extendedLanguageTag ?? $0.element.locale?.identifier)
        }
        needsAudioLanguage = true
        needsSubtitleLanguage = true
        applyPreferredLanguages()
        if let audio, let match = audio.match(in: audioTracks) {
            selectAudio(match.id, remember: false)
        }
        if subtitlesOff {
            selectSubtitle(-1, remember: false)
        } else if let subtitle, let match = subtitle.match(in: subtitleTracks) {
            selectSubtitle(match.id, remember: false)
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
        if hasEnded { playbackEnded() }
        sleepProtection.update(
            isPlaying: isPlaying && !hasEnded && errorMessage == nil,
            watchingInForeground: NSApp?.isActive == true)
        if isPlaying || seconds > 0 { onProgress?(seconds, !isPlaying) }
    }

    private func applyPreferredLanguages() {
        func matching(_ code: String, in tracks: [PlayerTrack]) -> PlayerTrack? {
            guard !code.isEmpty else { return nil }
            let preferred = PlayerTrack(id: 0, name: "", language: code).languageCode
            return tracks.first { $0.id >= 0 && $0.languageCode == preferred }
        }
        if needsAudioLanguage {
            if let audio = matching(preferences.audioLanguage, in: audioTracks) {
                selectAudio(audio.id, remember: false)
            } else if preferences.audioLanguage.isEmpty {
                needsAudioLanguage = false
            }
        }
        if needsSubtitleLanguage {
            if preferences.subtitleLanguage == "off" {
                selectSubtitle(-1, remember: false)
            } else if let subtitle = matching(preferences.subtitleLanguage, in: subtitleTracks) {
                selectSubtitle(subtitle.id, remember: false)
            } else if preferences.subtitleLanguage.isEmpty {
                needsSubtitleLanguage = false
            }
        }
    }

    func selectedStreamIndex(type: String) -> Int? {
        let options = type == "Audio" ? audioTracks : subtitleTracks
        let selected = type == "Audio" ? selectedAudio : selectedSubtitle
        if type == "Subtitle", selected == -1 { return -1 }
        guard let choice = options.first(where: { $0.id == selected }) else { return nil }
        let source = currentStream?.mediaTracks.filter { $0.type == type } ?? []
        if let exact = source.first(where: { $0.index == Int(selected) }) { return exact.index }
        if let named = source.first(where: { $0.name == choice.name }) { return named.index }
        if let language = choice.languageCode,
            let matching = source.first(where: {
                PlayerTrack(id: 0, name: "", language: $0.language).languageCode == language
            })
        {
            return matching.index
        }
        if let ordinal = options.filter({ $0.id >= 0 }).firstIndex(where: { $0.id == selected }),
            source.indices.contains(ordinal)
        {
            return source[ordinal].index
        }
        return nil
    }

    private func tracks(names: [Any], indexes: [Any]) -> [PlayerTrack] {
        zip(names, indexes).compactMap { name, index -> PlayerTrack? in
            guard let index = index as? NSNumber, let name = name as? String else { return nil }
            let info = engine.media?.tracksInformation.compactMap { $0 as? [String: Any] }.first {
                ($0[VLCMediaTracksInformationId] as? NSNumber)?.int32Value == index.int32Value
            }
            return PlayerTrack(
                id: index.int32Value, name: index.int32Value == -1 ? "Off" : name,
                language: info?[VLCMediaTracksInformationLanguage] as? String)
        }
    }
}
