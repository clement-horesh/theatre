import SwiftUI

struct SubtitleAppearanceView: View {
    let onApply: (SubtitleAppearance) -> Void
    @State private var draft: SubtitleAppearance
    @Environment(\.dismiss) private var dismiss

    init(appearance: SubtitleAppearance, onApply: @escaping (SubtitleAppearance) -> Void) {
        self.onApply = onApply
        _draft = State(initialValue: appearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Subtitle Appearance").font(.headline)
            Form {
                Picker("Position", selection: $draft.position) {
                    ForEach(SubtitleAppearance.Position.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Size", selection: $draft.size) {
                    ForEach(SubtitleAppearance.Size.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Color", selection: $draft.color) {
                    ForEach(SubtitleAppearance.TextColor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Dark background", isOn: $draft.background)
            }
            Text(
                "Applies to text subtitles. Picture subtitles and embedded styling may keep their original appearance."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset") { draft = .standard }
                Spacer()
                Button("Apply") {
                    onApply(draft)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 280)
    }
}
