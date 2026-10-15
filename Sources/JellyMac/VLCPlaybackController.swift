import AppKit
import Combine
import Foundation
import JellyfinKit
import VLCKit

struct PlayerTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

/// Owns a single embedded VLC player; SwiftUI supplies the native controls.
@MainActor
final class VLCPlaybackController: ObservableObject {
    let videoView = VLCVideoView(frame: .zero)
    private let engine = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show", "--network-caching=750"])
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

    init() {
        videoView.backColor = .black
        videoView.fillScreen = false
        engine.drawable = videoView
        engine.scaleFactor = 0
        engine.audio?.volume = 80
    }

    func play(_ stream: PlaybackStream) {
        stop()
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
        sleepProtection.release()
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        engine.stop()
        engine.media = nil
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
        if engine.isPlaying { engine.pause() } else { engine.play() }
        update()
    }

    func seek(to value: Double) {
        guard value.isFinite, canSeek, duration > 0 else { return }
        let destination = max(0, min(value, duration - 0.05))
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
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = max(0, min(100, value))
        engine.audio?.volume = Int32(volume)
    }

    func selectAudio(_ id: Int32) {
        engine.currentAudioTrackIndex = id
        selectedAudio = engine.currentAudioTrackIndex
    }
    func selectSubtitle(_ id: Int32) {
        engine.currentVideoSubTitleIndex = id
        selectedSubtitle = engine.currentVideoSubTitleIndex
    }

    private func update() {
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
        let window = videoView.window
        sleepProtection.update(
            isPlaying: isPlaying && !hasEnded && errorMessage == nil,
            watchingInForeground: NSApp.isActive && window?.isVisible == true && window?.isMiniaturized == false)
        if isPlaying || seconds > 0 { onProgress?(seconds, !isPlaying) }
    }

    private func tracks(names: [Any], indexes: [Any]) -> [PlayerTrack] {
        zip(names, indexes).compactMap { name, index in
            guard let index = index as? NSNumber, let name = name as? String else { return nil }
            return PlayerTrack(id: index.int32Value, name: index.int32Value == -1 ? "Off" : name)
        }
    }
}
