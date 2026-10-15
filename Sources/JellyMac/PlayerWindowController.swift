import AppKit
import SwiftUI

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private weak var model: AppModel?
    private var videoAspectRatio: CGFloat = 16.0 / 9.0
    private var changingFullscreen = false

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PlayerPane(model: model, playback: model.playback)
                .ignoresSafeArea().onExitCommand { model.exitVideoFullscreen() })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(title: String) {
        window?.title = "\(title) — Player"
        window?.makeKeyAndOrderFront(nil)
    }

    func fitVideo(aspectRatio: Double) {
        guard aspectRatio.isFinite, aspectRatio > 0, let window else { return }
        videoAspectRatio = aspectRatio
        guard !changingFullscreen, !window.styleMask.contains(.fullScreen) else { return }
        // Video covers the title bar too, so constrain the entire window frame.
        window.contentAspectRatio = .zero
        window.aspectRatio = NSSize(width: videoAspectRatio, height: 1)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(
            window.isVisible ? window.frame.width : 960, screen.width * 0.85,
            screen.height * 0.85 * videoAspectRatio)
        let size = NSSize(width: width, height: width / videoAspectRatio)
        let minimumWidth = min(480, 200 * videoAspectRatio, width)
        window.minSize = NSSize(width: minimumWidth, height: minimumWidth / videoAspectRatio)
        var frame = NSRect(
            x: window.frame.midX - size.width / 2,
            y: window.frame.midY - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - size.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - size.height))
        window.setFrame(frame, display: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !changingFullscreen, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let widthChange = abs(frameSize.width - sender.frame.width)
        let heightChange = abs(frameSize.height - sender.frame.height) * videoAspectRatio
        let width = max(
            sender.minSize.width,
            widthChange >= heightChange ? frameSize.width : frameSize.height * videoAspectRatio)
        return NSSize(width: width, height: width / videoAspectRatio)
    }

    func windowWillEnterFullScreen(_ notification: Notification) { changingFullscreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { changingFullscreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullscreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullscreen = false
        fitVideo(aspectRatio: videoAspectRatio)
    }

    func closeWithoutCallback() {
        window?.delegate = nil
        close()
    }

    func windowWillClose(_ notification: Notification) { model?.playerWindowDidClose() }
    func windowDidBecomeKey(_ notification: Notification) { model?.isPlayerWindowKey = true }
    func windowDidResignKey(_ notification: Notification) { model?.isPlayerWindowKey = false }
}
