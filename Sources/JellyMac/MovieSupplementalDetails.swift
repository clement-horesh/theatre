import JellyfinKit
import SwiftUI

struct MovieCastSection: View {
    let video: VideoItem
    let client: JellyfinClient?
    let width: CGFloat
    @FocusState private var focusedPerson: String?
    @Environment(\.libraryNavigation) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast & Crew").font(.title2.weight(.semibold))
            if let people = video.people, !people.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(people) { person in
                            NavigationLink(value: person) {
                                VStack(spacing: 8) {
                                    JellyfinArtwork(
                                        request: try? client?.imageRequest(for: person),
                                        blurHashes: person.imageBlurHashes
                                    ) {
                                        ZStack {
                                            Color(white: 0.17)
                                            Image(systemName: "person.fill").font(.system(size: 42)).foregroundStyle(
                                                .white.opacity(0.4))
                                        }
                                    }
                                    .frame(width: portraitSize, height: portraitSize).clipShape(Circle())
                                    Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        .frame(height: 34, alignment: .top)
                                    Text(person.credit).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(height: 32, alignment: .top)
                                }
                                .frame(width: portraitSize).multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                            .libraryCardFocus(person.id, focus: $focusedPerson, items: people.map(\.id)) {
                                navigation.person(person)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(person.name + (person.credit.isEmpty ? "" : ", " + person.credit))
                            .accessibilityHint("View titles in your library featuring \(person.name)")
                        }
                    }
                    .padding(.bottom, 6)
                }
            } else {
                Text("Cast information isn’t available for this title.").foregroundStyle(.secondary)
            }
        }
        .focusSection().accessibilityIdentifier("movieCast")
    }
    private var portraitSize: CGFloat { min(160, max(112, width * 0.09)) }
}

struct MovieAboutSection: View {
    let video: VideoItem
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text(video.name).font(.title2.weight(.semibold))
                if let genres = video.genres, !genres.isEmpty {
                    Text(genres.joined(separator: ", ").uppercased()).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(video.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "No description available.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).lineSpacing(3)
            }
            .padding(20).frame(width: min(width, max(480, width * 0.52)), alignment: .leading)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("movieAbout")
    }
}

struct MovieInformationSection: View {
    let video: VideoItem
    let width: CGFloat
    private var audio: [VideoDetailStream] { video.detailStreams.filter { $0.type == "Audio" } }
    private var subtitles: [VideoDetailStream] { video.detailStreams.filter { $0.type == "Subtitle" } }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 32, alignment: .topLeading), count: width >= 920 ? 3 : 2),
            alignment: .leading, spacing: 32
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Information").font(.title2.weight(.semibold))
                if let year = video.productionYear {
                    field("Released", String(year))
                } else if let premiere = video.premiereDate {
                    field("Released", String(premiere.prefix(4)))
                }
                if let runtime = video.runtimeLabel { field("Run Time", runtime) }
                if let rating = video.officialRating, !rating.isEmpty { field("Rated", rating) }
                if let locations = video.productionLocations, !locations.isEmpty {
                    field("Region of Origin", locations.joined(separator: ", "))
                }
                if let studios = video.studios, !studios.isEmpty {
                    field("Studio", studios.map(\.name).joined(separator: ", "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 20) {
                Text("Languages").font(.title2.weight(.semibold))
                if let original = audio.first(where: { $0.isOriginal == true })?.languageName {
                    field("Original Audio", original)
                }
                if !audio.isEmpty { field("Audio", labels(audio)) }
                if !subtitles.isEmpty { field("Subtitles", labels(subtitles)) }
                if audio.isEmpty && subtitles.isEmpty {
                    Text("No language information available.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 20) {
                Text("Accessibility").font(.title2.weight(.semibold))
                if subtitles.contains(where: \.hasSDH) {
                    accessibility(
                        "SDH",
                        "Includes subtitles with dialogue and relevant sound information for viewers who are deaf or hard of hearing."
                    )
                }
                if subtitles.contains(where: \.hasCC) { accessibility("CC", "Closed captions are available.") }
                if audio.contains(where: \.hasAudioDescription) {
                    accessibility(
                        "AD",
                        "Includes an audio track describing on-screen action for viewers who are blind or have low vision."
                    )
                }
                if !video.detailStreams.contains(where: { $0.hasSDH || $0.hasCC || $0.hasAudioDescription }) {
                    Text("No accessibility information available.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13)).textSelection(.enabled)
    }
    private func labels(_ tracks: [VideoDetailStream]) -> String {
        var seen = Set<String>()
        return tracks.map(\.label).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ", ")
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundStyle(.white.opacity(0.9))
            Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func accessibility(_ badge: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MovieMediaBadge(text: badge)
            Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
