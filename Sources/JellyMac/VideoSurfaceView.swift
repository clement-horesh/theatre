import AppKit
import QuartzCore
import SwiftUI
import VLCKit

struct VLCPlayerView: NSViewRepresentable {
    let playback: PlaybackController
    func makeNSView(context: Context) -> VideoSurfaceView { VideoSurfaceView(videoView: playback.videoView) }
    func updateNSView(_ view: VideoSurfaceView, context: Context) { view.needsLayout = true }
}

/// SwiftUI resizes this container; VLC keeps its own layer layout manager.
/// Returning the drawable directly lets SwiftUI manage the video layer itself.
final class VideoSurfaceView: NSView {
    let videoView: VLCVideoView

    init(videoView: VLCVideoView) {
        self.videoView = videoView
        super.init(frame: .zero)
        addSubview(videoView)
        videoView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = bounds
        videoView.bounds = CGRect(origin: .zero, size: bounds.size)
        videoView.fillScreen = false
        videoView.layer?.setNeedsLayout()
        videoView.layer?.layoutIfNeeded()
        CATransaction.commit()
    }
}
