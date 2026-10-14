import AppKit
import SwiftUI

struct PlayerMenuChoice: Equatable {
    let id: Int
    let title: String
}

/// Build a snapshot when opened. Playback polling cannot rebuild a tracking menu.
struct NativePlayerMenu: NSViewRepresentable {
    let symbol: String
    let title: String
    let identifier: String
    let choices: [PlayerMenuChoice]
    let selection: Int
    let onSelect: (Int) -> Void
    let onTrackingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.configuration = self
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        button.toolTip = title
        button.isEnabled = !choices.isEmpty
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 30, height: 28)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var configuration: NativePlayerMenu
        private var menu: NSMenu?
        private var selectionAction: ((Int) -> Void)?
        private var trackingAction: ((Bool) -> Void)?

        init(_ configuration: NativePlayerMenu) { self.configuration = configuration }

        @objc func openMenu(_ button: NSButton) {
            guard menu == nil else { return }
            let snapshot = configuration
            selectionAction = snapshot.onSelect
            trackingAction = snapshot.onTrackingChange
            trackingAction?(true)
            let popup = NSMenu(title: snapshot.title)
            popup.autoenablesItems = false
            popup.minimumWidth = 210
            popup.appearance = NSAppearance(named: .darkAqua)
            popup.delegate = self
            let heading = NSMenuItem(title: snapshot.title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            popup.addItem(heading)
            popup.addItem(.separator())
            for choice in snapshot.choices {
                let item = NSMenuItem(title: choice.title, action: #selector(selectChoice(_:)), keyEquivalent: "")
                item.target = self
                item.tag = choice.id
                item.state = choice.id == snapshot.selection ? .on : .off
                popup.addItem(item)
            }
            menu = popup
            popup.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
            // Also runs for dismissal without a selection.
            finishTracking()
        }

        @objc func selectChoice(_ item: NSMenuItem) { selectionAction?(item.tag) }
        func menuDidClose(_ menu: NSMenu) { finishTracking() }
        private func finishTracking() {
            guard menu != nil else { return }
            menu = nil
            trackingAction?(false)
            trackingAction = nil
            // Keep the selection closure until popUp returns: menuDidClose can
            // run before AppKit dispatches the chosen item's action.
        }
    }
}
