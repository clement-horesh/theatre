import AppKit
import JellyfinKit
import SwiftUI

struct LibraryNavigationActions {
    var video: (VideoItem) -> Void = { _ in }
    var person: (VideoPerson) -> Void = { _ in }
}

private struct LibraryNavigationKey: EnvironmentKey {
    static let defaultValue = LibraryNavigationActions()
}

extension EnvironmentValues {
    var libraryNavigation: LibraryNavigationActions {
        get { self[LibraryNavigationKey.self] }
        set { self[LibraryNavigationKey.self] = newValue }
    }
}

extension View {
    func libraryCardFocus(
        _ id: String, focus: FocusState<String?>.Binding, items: [String], columns: Int = 1,
        activate: @escaping () -> Void
    ) -> some View {
        modifier(LibraryCardFocus(id: id, focus: focus, items: items, columns: columns, activate: activate))
    }
}

private struct LibraryCardFocus: ViewModifier {
    let id: String
    let focus: FocusState<String?>.Binding
    let items: [String]
    let columns: Int
    let activate: () -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: id)
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    focus.wrappedValue == id ? Color.accentColor : .clear, lineWidth: 3
                ).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onCommand(#selector(NSResponder.insertNewline(_:))) {
                if isEnabled, focus.wrappedValue == id { activate() }
            }
            .onMoveCommand { direction in
                guard isEnabled, focus.wrappedValue == id, let index = items.firstIndex(of: id) else { return }
                let step: Int
                switch direction {
                case .left: step = layoutDirection == .rightToLeft ? 1 : -1
                case .right: step = layoutDirection == .rightToLeft ? -1 : 1
                case .up: step = -max(1, columns)
                case .down: step = max(1, columns)
                @unknown default: return
                }
                let next = index + step
                if items.indices.contains(next) { focus.wrappedValue = items[next] }
            }
    }
}
