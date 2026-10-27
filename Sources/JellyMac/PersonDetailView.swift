import JellyfinKit
import SwiftUI

struct PersonDetailView: View {
    @ObservedObject var model: AppModel
    let person: VideoPerson
    @State private var videos: [VideoItem] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var loadedQuery: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var gridColumns = 1
    @FocusState private var focusedCard: String?
    @Environment(\.libraryNavigation) private var navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 24) {
                    JellyfinArtwork(
                        request: try? model.client(serverID: person.serverID)?.imageRequest(for: person),
                        blurHashes: person.imageBlurHashes
                    ) {
                        Color(white: 0.15).overlay { Image(systemName: "person.fill").font(.largeTitle) }
                    }
                    .frame(width: 120, height: 120).clipShape(Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.name).font(.largeTitle.weight(.bold))
                        Text(model.showsDownloads ? "In your downloads" : "In your Jellyfin library")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(["Movie", "Series"], id: \.self) { type in
                    let titles = videos.filter { $0.type == type }
                    if !titles.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(type == "Movie" ? "Movies" : "Shows").font(.title2.weight(.semibold))
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24, alignment: .top)
                                ], alignment: .leading, spacing: 26
                            ) {
                                ForEach(titles, id: \.libraryID) { video in
                                    NavigationLink(value: video) {
                                        MoviePoster(
                                            video: video, client: model.client(for: video),
                                            progressVideo: model.progressVideo(for: video))
                                    }
                                    .buttonStyle(.plain).libraryCardFocus(
                                        video.libraryID, focus: $focusedCard, items: titles.map(\.libraryID),
                                        columns: gridColumns
                                    ) { navigation.video(video) }
                                    .contextMenu { WatchStatusAction(video: video, model: model) }
                                    .accessibilityLabel("Details for \(video.title)")
                                    .accessibilityValue(model.progressVideo(for: video).accessibleWatchStatus)
                                }
                            }
                            .focusSection()
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.onAppear { gridColumns = max(1, Int((geometry.size.width + 24) / 174)) }
                                        .onChange(of: geometry.size.width) {
                                            gridColumns = max(1, Int(($0 + 24) / 174))
                                        }
                                }
                            }
                        }
                    }
                }
                if isLoading {
                    if videos.isEmpty { PosterSkeletonGrid() } else { ProgressView("Loading titles…") }
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                } else if !isLoading, videos.isEmpty {
                    Text("No titles featuring \(person.name) are available here.").foregroundStyle(.secondary)
                }
                if offset < total && error == nil { Button("Load more") { Task { await load() } }.disabled(isLoading) }
            }
            .padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: ArtworkColor.pageBackground))
        .navigationTitle(person.name)
        .task(id: "\(person.id):\(model.playbackRevision)") {
            let query = "\(person.id):\(model.playbackRevision)"
            guard loadedQuery != query else { return }
            videos = []
            total = 0
            offset = 0
            await load()
            if !Task.isCancelled && error == nil { loadedQuery = query }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        if model.showsDownloads {
            videos = model.downloads.titles.filter { item in
                item.serverID == person.serverID
                    && (item.people ?? []).contains {
                        guard person.type == nil || $0.type == person.type else { return false }
                        if let id = person.itemID, !id.isEmpty { return $0.itemID == id }
                        return $0.name.localizedCaseInsensitiveCompare(person.name) == .orderedSame
                    }
            }
            return
        }
        guard let client = model.client(serverID: person.serverID) else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await client.titles(for: person, startIndex: offset)
            try Task.checkCancellation()
            offset = page.items.isEmpty ? page.totalCount : offset + page.items.count
            total = page.totalCount
            var seen = Set(videos.map(\.libraryID))
            videos.append(contentsOf: page.items.filter { seen.insert($0.libraryID).inserted })
        } catch {
            if !Task.isCancelled { self.error = AppModel.friendly(error) }
        }
    }
}

struct RelatedTitlesSection: View {
    @ObservedObject var model: AppModel
    let titles: [VideoItem]
    @FocusState private var focusedCard: String?
    @Environment(\.libraryNavigation) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Related Titles").font(.title2.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(titles, id: \.libraryID) { title in
                        NavigationLink(value: title) {
                            MoviePoster(
                                video: title, client: model.client(for: title),
                                progressVideo: model.progressVideo(for: title))
                        }
                        .buttonStyle(.plain)
                        .libraryCardFocus(title.libraryID, focus: $focusedCard, items: titles.map(\.libraryID)) {
                            navigation.video(title)
                        }
                        .frame(width: 180)
                        .contextMenu { WatchStatusAction(video: title, model: model) }
                        .accessibilityLabel("Details for \(title.title)")
                        .accessibilityValue(model.progressVideo(for: title).accessibleWatchStatus)
                    }
                }
                .focusSection().padding(.bottom, 12)
            }
        }
    }
}
