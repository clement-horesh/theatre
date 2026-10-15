import AppKit
import QuartzCore
import SwiftUI

enum LibraryWindowPhase: Equatable {
    case windowed, enteringFullscreen, fullscreen, exitingFullscreen

    var showsPageNavigation: Bool { self == .enteringFullscreen || self == .fullscreen }
    var showsToolbarNavigation: Bool { self == .windowed || self == .exitingFullscreen }
}

/// Matches the native title bar to the page behind the shared navigation.
struct LibraryWindowBackground: NSViewRepresentable {
    let color: NSColor
    var animateColor = true
    let onPhase: (LibraryWindowPhase) -> Void
    func makeNSView(context: Context) -> TintView { TintView() }
    func updateNSView(_ view: TintView, context: Context) {
        view.color = color
        view.animateColor = animateColor
        view.onPhase = onPhase
        view.apply()
    }

    final class TintView: NSView {
        var color = ArtworkColor.pageBackground
        var animateColor = true
        var onPhase: ((LibraryWindowPhase) -> Void)?
        private var lastPhase = LibraryWindowPhase.windowed
        private var transitionPhase: LibraryWindowPhase?
        private var observers: [NSObjectProtocol] = []
        private var targetColor: NSColor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            transitionPhase = nil
            targetColor = nil
            guard let window else { return }
            window.animations["backgroundColor"] = CABasicAnimation()
            for name in [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            switch name {
                            case NSWindow.willEnterFullScreenNotification: self.transitionPhase = .enteringFullscreen
                            case NSWindow.willExitFullScreenNotification: self.transitionPhase = .exitingFullscreen
                            default: self.transitionPhase = nil
                            }
                            self.apply(deferStateChanges: false)
                        }
                    })
            }
            apply()
        }

        func apply(deferStateChanges: Bool = true) {
            guard let window else { return }
            updateColor(of: window)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            window.toolbar?.showsBaselineSeparator = false
            // Switch between page and toolbar navigation at the start of each
            // transition, so only one navigation surface is visible at a time.
            let phase = transitionPhase ?? (window.styleMask.contains(.fullScreen) ? .fullscreen : .windowed)
            if phase != lastPhase {
                lastPhase = phase
                if deferStateChanges {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onPhase?(self.lastPhase)
                    }
                } else {
                    onPhase?(phase)
                }
            }
        }

        private func updateColor(of window: NSWindow) {
            guard targetColor != color else { return }
            let wasConfigured = targetColor != nil
            targetColor = color
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animateColor && wasConfigured ? 0.65 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().backgroundColor = color
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

struct PageFullscreenNavigation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.windowToolbarFullScreenVisibility(.onHover) } else { content }
    }
}
