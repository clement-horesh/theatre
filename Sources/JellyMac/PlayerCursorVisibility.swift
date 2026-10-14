import AppKit
import SwiftUI

@MainActor
final class PlaybackCursorState {
    private let setHidden: (Bool) -> Void
    private var ownsHiddenCursor = false

    init(setHidden: ((Bool) -> Void)? = nil) {
        self.setHidden = setHidden ?? { NSCursor.setHiddenUntilMouseMoves($0) }
    }

    func update(controlsHidden: Bool, pointerInVideo: Bool, windowIsKey: Bool, applicationIsActive: Bool) {
        let hidden = controlsHidden && pointerInVideo && windowIsKey && applicationIsActive
        guard hidden != ownsHiddenCursor else { return }
        ownsHiddenCursor = hidden
        setHidden(hidden)
    }

    func restore() {
        guard ownsHiddenCursor else { return }
        ownsHiddenCursor = false
        setHidden(false)
    }
}

struct PlayerCursorVisibility: NSViewRepresentable {
    let controlsHidden: Bool
    let onActivity: () -> Void

    func makeNSView(context: Context) -> CursorRegion { CursorRegion() }
    func updateNSView(_ view: CursorRegion, context: Context) {
        view.controlsHidden = controlsHidden
        view.onActivity = onActivity
        view.refresh()
    }
    static func dismantleNSView(_ view: CursorRegion, coordinator: ()) { view.stopObserving() }

    final class CursorRegion: NSView {
        var controlsHidden = false
        var onActivity: (() -> Void)?
        private let cursor = PlaybackCursorState()
        private var region: NSTrackingArea?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cursor.restore() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                      object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cursor.restore() }
            })
            refresh()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let region { removeTrackingArea(region) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self)
            addTrackingArea(tracking)
            region = tracking
        }

        func refresh() {
            guard let window else { cursor.restore(); return }
            let pointer = window.mouseLocationOutsideOfEventStream
            let inside = bounds.contains(convert(pointer, from: nil)) && window.contentLayoutRect.contains(pointer)
            cursor.update(controlsHidden: controlsHidden, pointerInVideo: inside,
                          windowIsKey: window.isKeyWindow, applicationIsActive: NSApp.isActive)
        }
        override func mouseEntered(with event: NSEvent) { pointerActivity() }
        override func mouseMoved(with event: NSEvent) { pointerActivity() }
        override func mouseExited(with event: NSEvent) { pointerActivity() }
        private func pointerActivity() { cursor.restore(); onActivity?() }

        func stopObserving() {
            cursor.restore()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
