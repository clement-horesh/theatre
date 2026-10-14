import SwiftUI

struct GlassPlayButton: View {
    var resume = false
    var disabled = false
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                button.buttonStyle(.glass).buttonBorderShape(.capsule)
            } else {
                button.buttonStyle(.bordered)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .controlSize(.large)
        .foregroundStyle(.white).disabled(disabled)
    }

    private var button: some View {
        Button(action: action) {
            Label(title ?? (resume ? "Resume" : "Play"), systemImage: "play.fill")
                .font(.headline).padding(.horizontal, 18).padding(.vertical, 5)
        }
    }
}
