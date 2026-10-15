import Foundation
import JellyfinKit
import MediaPlayer

/// Publish playback to macOS and use its standard media-key routing.
@MainActor
final class NowPlayingController {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var information: [String: Any] = [:]
    private var lastSecond = -1
    private var lastRate = -1.0

    func activate(
        video: VideoItem, toggle: @escaping () -> Void, play: @escaping () -> Void,
        pause: @escaping () -> Void, seek: @escaping (Double) -> Void,
        skip: @escaping (Double) -> Void, next: (() -> Void)?
    ) {
        clear()
        information = [
            MPMediaItemPropertyTitle: video.name,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let series = video.seriesName { information[MPMediaItemPropertyArtist] = series }
        let commands = MPRemoteCommandCenter.shared()
        register(commands.togglePlayPauseCommand) { _ in toggle() }
        register(commands.playCommand) { _ in play() }
        register(commands.pauseCommand) { _ in pause() }
        register(commands.changePlaybackPositionCommand) { event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { seek(event.positionTime) }
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        register(commands.skipForwardCommand) { _ in skip(10) }
        register(commands.skipBackwardCommand) { _ in skip(-10) }
        if let next { register(commands.nextTrackCommand) { _ in next() } }
        update(seconds: 0, duration: Double(video.runTimeTicks ?? 0) / 10_000_000, rate: 0, hasNext: false)
    }

    func update(seconds: Double, duration: Double, rate: Double, hasNext: Bool) {
        guard !information.isEmpty, seconds.isFinite else { return }
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
        let second = Int(seconds)
        guard second != lastSecond || rate != lastRate else { return }
        lastSecond = second
        lastRate = rate
        information[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
        information[MPMediaItemPropertyPlaybackDuration] = duration
        information[MPNowPlayingInfoPropertyPlaybackRate] = rate
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = information
        center.playbackState = rate > 0 ? .playing : .paused
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { event in
            Task { @MainActor in action(event) }
            return .success
        }
        targets.append((command, target))
    }

    func clear() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        if !information.isEmpty {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        information = [:]
        lastSecond = -1
        lastRate = -1
    }
}
