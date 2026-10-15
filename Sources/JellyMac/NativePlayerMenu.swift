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
    var onAppearance: (() -> Void)? = nil

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
    final class Coordinator: NSObject {
        var configuration: NativePlayerMenu
        private var isTracking = false
        private var selectionAction: ((Int) -> Void)?
        private var appearanceAction: (() -> Void)?

        init(_ configuration: NativePlayerMenu) { self.configuration = configuration }

        @objc func openMenu(_ button: NSButton) {
            guard !isTracking else { return }
            isTracking = true
            let snapshot = configuration
            selectionAction = snapshot.onSelect
            appearanceAction = snapshot.onAppearance
            snapshot.onTrackingChange(true)
            defer {
                isTracking = false
                snapshot.onTrackingChange(false)
                selectionAction = nil
                appearanceAction = nil
            }
            let popup = NSMenu(title: snapshot.title)
            popup.autoenablesItems = false
            popup.minimumWidth = 210
            popup.appearance = NSAppearance(named: .darkAqua)
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
            if snapshot.onAppearance != nil {
                popup.addItem(.separator())
                let item = NSMenuItem(title: "Appearance…", action: #selector(openAppearance), keyEquivalent: "")
                item.target = self
                popup.addItem(item)
            }
            popup.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        }

        @objc private func openAppearance() {
            let action = appearanceAction
            DispatchQueue.main.async { action?() }
        }

        @objc func selectChoice(_ item: NSMenuItem) { selectionAction?(item.tag) }
    }
}
