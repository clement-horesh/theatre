import AVKit
import AppKit
import SwiftUI

struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    let onPrepare: () -> Void
    let onTracking: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        // Keep AVKit's routing and hit target; SwiftUI supplies the video AirPlay symbol.
        for state in [AVRoutePickerView.ButtonState.normal, .normalHighlighted, .active, .activeHighlighted] {
            view.setRoutePickerButtonColor(.clear, for: state)
        }
        view.player = player
        view.delegate = context.coordinator
        view.setAccessibilityLabel("AirPlay")
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.configuration = self
        view.player = player
    }
    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var configuration: AirPlayPicker
        init(_ configuration: AirPlayPicker) { self.configuration = configuration }
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in
                self?.configuration.onTracking(true)
                self?.configuration.onPrepare()
            }
        }
        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in self?.configuration.onTracking(false) }
        }
    }
}
