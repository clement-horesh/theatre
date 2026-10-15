import AppKit
import SwiftUI

/// Let AppKit recognize page swipes without intercepting events elsewhere in the window.
struct CarouselSwipeInput: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) { view.onSwipe = onSwipe }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?

        // Leave clicks and mouse drags to the artwork and its controls below this overlay.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                event.phase == .began || event.phase == .changed
            else {
                super.scrollWheel(with: event)
                return
            }
            var committed = false
            event.trackSwipeEvent(options: .lockDirection, dampenAmountThresholdMin: -1, max: 1) {
                [weak self] amount, phase, _, _ in
                // Start the fade during the swipe; keep tracking so momentum cannot advance another item.
                guard !committed, phase != .cancelled, abs(amount) >= 0.25 else { return }
                committed = true
                self?.onSwipe?(amount < 0 ? 1 : -1)
            }
        }
    }
}
