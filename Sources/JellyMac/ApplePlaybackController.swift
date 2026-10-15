import AVFoundation
import AVKit
import AppKit
import JellyfinKit
import QuartzCore
import SwiftUI

/// Apple's player provides native AirPlay and Picture in Picture.
@MainActor
final class ApplePlaybackController: NSObject, AVPictureInPictureControllerDelegate {
    let player = AVPlayer()
    let layer = AVPlayerLayer()
    private(set) var audioGroup: AVMediaSelectionGroup?
    private(set) var subtitleGroup: AVMediaSelectionGroup?
    private(set) var hasEnded = false
    private var endObserver: NSObjectProtocol?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var videoObservation: NSKeyValueObservation?
    private var routeObservation: NSKeyValueObservation?
    private var wantsPictureInPicture = false
    private weak var sourceView: NSView?
    var onPictureInPictureChange: ((Bool) -> Void)?
    var onExternalPlaybackActive: (() -> Void)?
    var onRestoreWindow: (() -> Bool)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        layer.player = player
        layer.videoGravity = .resizeAspect
        videoObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            self?.schedulePictureInPictureStart()
        }
        player.allowsExternalPlayback = true
        routeObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in self?.onExternalPlaybackActive?() }
        }
    }

    func prepare(url: URL) async throws -> AVPlayerItem {
        player.volume = 0
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw JellyfinError.noPlayableSource }
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        var prepared = false
        defer {
            if !prepared, player.currentItem === item {
                player.replaceCurrentItem(with: nil)
                audioGroup = nil
                subtitleGroup = nil
            }
        }
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard player.currentItem === item else { throw CancellationError() }
            if item.status == .failed { throw JellyfinError.noPlayableSource }
            if item.status == .readyToPlay {
                let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
                try Task.checkCancellation()
                guard player.currentItem === item else { throw CancellationError() }
                audioGroup = audio
                subtitleGroup = subtitles
                prepared = true
                return item
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw URLError(.timedOut)
    }

    func togglePictureInPicture() {
        if pip?.isPictureInPictureActive == true {
            pip?.stopPictureInPicture()
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onError?("Picture in Picture isn’t available on this Mac.")
            return
        }
        wantsPictureInPicture = true
        schedulePictureInPictureStart()
    }

    func attachVideoView(_ view: NSView) {
        sourceView = view
        schedulePictureInPictureStart()
    }

    private nonisolated func schedulePictureInPictureStart() {
        // Never capture SwiftUI's temporary measurement bounds as AVKit's
        // restoration rectangle. Let the current layout transaction finish first.
        DispatchQueue.main.async { [weak self] in self?.startPictureInPictureWhenReady() }
    }

    private func startPictureInPictureWhenReady() {
        // SwiftUI installs the Apple video view after the playback handoff. AVKit
        // must receive an attached view with real bounds before creating its PiP source.
        guard wantsPictureInPicture, let sourceView, sourceView.window != nil,
            !sourceView.bounds.isEmpty, layer.isReadyForDisplay
        else {
            return
        }
        if pip == nil {
            pip = AVPictureInPictureController(playerLayer: layer)
            pip?.delegate = self
            pipObservation = pip?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                self?.schedulePictureInPictureStart()
            }
        }
        guard pip?.isPictureInPicturePossible == true else { return }
        wantsPictureInPicture = false
        pip?.startPictureInPicture()
    }

    func seek(to seconds: Double) {
        hasEnded = false
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func start(
        item: AVPlayerItem, at seconds: Double, playing: Bool, rate: Double,
        volume: Double, appearance: SubtitleAppearance
    ) {
        hasEnded = false
        player.volume = Float(volume / 100)
        item.textStyleRules = appearance.nativeStyle.map { [$0] } ?? []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasEnded = true }
        }
        player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item, finished else { return }
                if playing { self.player.playImmediately(atRate: Float(rate)) }
            }
        }
    }

    func stop() {
        wantsPictureInPicture = false
        pipObservation = nil
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip = nil
        onPictureInPictureChange?(false)
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        audioGroup = nil
        subtitleGroup = nil
        hasEnded = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard self?.pip?.isPictureInPictureActive == true else { return }
            self?.onPictureInPictureChange?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard self?.pip?.isPictureInPictureActive == false else { return }
            self?.onPictureInPictureChange?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.wantsPictureInPicture = false
            self?.onError?("Picture in Picture couldn’t start. Please try again.")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in completion(self?.onRestoreWindow?() ?? false) }
    }

    deinit { if let endObserver { NotificationCenter.default.removeObserver(endObserver) } }
}

struct ApplePlayerView: NSViewRepresentable {
    let playback: ApplePlaybackController
    func makeNSView(context: Context) -> LayerView { LayerView(playback: playback) }
    func updateNSView(_ view: LayerView, context: Context) {}

    final class LayerView: NSView {
        private let playback: ApplePlaybackController
        init(playback: ApplePlaybackController) {
            self.playback = playback
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func makeBackingLayer() -> CALayer { playback.layer }
        override var wantsUpdateLayer: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            playback.attachVideoView(self)
        }
    }
}
