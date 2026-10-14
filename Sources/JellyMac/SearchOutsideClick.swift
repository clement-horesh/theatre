import AppKit
import SwiftUI

/// Observe clicks without consuming them, so the clicked control still works.
struct SearchOutsideClick: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> ClickRegion { ClickRegion() }
    func updateNSView(_ view: ClickRegion, context: Context) { view.onDismiss = onDismiss }
    static func dismantleNSView(_ view: ClickRegion, coordinator: ()) { view.stopObserving() }

    final class ClickRegion: NSView {
        var onDismiss: (() -> Void)?
        private var monitor: Any?
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    // Dismiss after dispatch so clicks on tabs and media retain their action.
                    DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
                }
                return event
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDismiss?() }
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            monitor = nil; observer = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
