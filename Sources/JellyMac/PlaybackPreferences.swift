import Combine
import Foundation
import SwiftUI

@MainActor
final class PlaybackPreferences: ObservableObject {
    @Published var automaticallyPlayNext: Bool {
        didSet { defaults.set(automaticallyPlayNext, forKey: "automaticallyPlayNext") }
    }
    @Published var audioLanguage: String { didSet { defaults.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var subtitleLanguage: String { didSet { defaults.set(subtitleLanguage, forKey: "subtitleLanguage") } }
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyPlayNext = defaults.object(forKey: "automaticallyPlayNext") as? Bool ?? true
        audioLanguage = defaults.string(forKey: "audioLanguage") ?? ""
        subtitleLanguage = defaults.string(forKey: "subtitleLanguage") ?? ""
    }
}

struct PlaybackSettingsView: View {
    @ObservedObject var preferences: PlaybackPreferences
    private let languages = Locale.LanguageCode.isoLanguageCodes.map(\.identifier).sorted {
        (Locale.current.localizedString(forLanguageCode: $0) ?? $0)
            .localizedStandardCompare(Locale.current.localizedString(forLanguageCode: $1) ?? $1) == .orderedAscending
    }

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Automatically play the next episode", isOn: $preferences.automaticallyPlayNext)
                Text("The next episode starts when the current one ends.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Languages") {
                Picker("Preferred audio", selection: $preferences.audioLanguage) { languageOptions }
                Picker("Preferred subtitles", selection: $preferences.subtitleLanguage) {
                    Text("Off").tag("off")
                    languageOptions
                }
                Text(
                    "Used when a matching track is available. Choosing a language in the player remembers it for future videos."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 460, height: 300)
    }

    private var languageOptions: some View {
        Group {
            Text("Default").tag("")
            ForEach(languages, id: \.self) { code in
                Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
            }
        }
    }
}
