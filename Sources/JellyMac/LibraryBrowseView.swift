import JellyfinKit
import SwiftUI

extension VideoItem {
    var libraryLetter: String {
        let title = (sortName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        guard let first = title.first, first.isASCII, first >= "A", first <= "Z" else { return "#" }
        return String(first)
    }
    var libraryMetadata: String {
        [productionYear.map { String($0) }, genres?.prefix(2).joined(separator: " · ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private enum LibraryLayout: String, CaseIterable {
    case grid = "Grid"
    case alphabetical = "Alphabetical"
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct LibraryBrowseView: View {
    @ObservedObject var model: AppModel
    var downloaded = false
    @State private var downloadType = "All"
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .grid
    @State private var filterOptions: VideoFilterOptions?
    @State private var filterError: String?
    @State private var requestedLetter: String?
    @State private var jumpID = UUID()
    @State private var gridColumns = 1
    @State private var hoveredRow: String?
    @FocusState private var focusedCard: String?
    @Environment(\.libraryNavigation) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let alphabet = ["#"] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    private var videos: [VideoItem] {
        guard downloaded else { return model.videos }
        return model.downloads.titles.filter { video in
            (downloadType == "All" || (downloadType == "Movies" ? video.type == "Movie" : video.type != "Movie"))
                && (model.search.isEmpty || video.title.localizedCaseInsensitiveContains(model.search))
                && (model.libraryFilters.genre.isEmpty || video.genres?.contains(model.libraryFilters.genre) == true)
                && (model.libraryFilters.year == nil || video.productionYear == model.libraryFilters.year)
                && (model.libraryFilters.watchStatus == .all
                    || (model.libraryFilters.watchStatus == .played && video.userData?.played == true)
                    || (model.libraryFilters.watchStatus == .unplayed && video.isUnwatched)
                    || (model.libraryFilters.watchStatus == .resumable
                        && (video.isInProgress
                            || (video.type == "Series"
                                && model.downloads.episodes(seriesID: video.id).contains(where: \.isInProgress)))))
        }
    }
    private var groups: [String: [VideoItem]] { Dictionary(grouping: videos, by: \.libraryLetter) }
    private var sections: [String] {
        downloaded ? ["Movies", "Shows"].filter { downloadType == "All" || downloadType == $0 } : [""]
    }
    private func sectionVideos(_ section: String) -> [VideoItem] {
        videos.filter { section.isEmpty || (section == "Movies" ? $0.type == "Movie" : $0.type != "Movie") }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(downloaded ? "Downloads" : model.librarySection.rawValue).font(.title2.weight(.semibold))
                Spacer()
                filtersMenu
                Picker("View", selection: $layout) {
                    ForEach(LibraryLayout.allCases, id: \.self) { layout in
                        Label(layout.rawValue, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                .help("Choose a library view")
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if downloaded { DownloadTransfersView(downloads: model.downloads) }
                            ForEach(sections, id: \.self) { section in
                                VStack(alignment: .leading, spacing: 16) {
                                    if !section.isEmpty { Text(section).font(.title2.weight(.semibold)) }
                                    if layout == .grid {
                                        posterGrid(sectionVideos(section))
                                    } else {
                                        alphabeticalList(sectionVideos(section), section: section)
                                    }
                                    if downloaded, sectionVideos(section).isEmpty {
                                        Text("No downloaded \(section.lowercased()).").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if !downloaded && model.canLoadMore {
                                Button("Load more") { Task { await model.loadVideos(reset: false) } }
                                    .frame(maxWidth: .infinity)
                            }
                            if !downloaded && model.isLoading && !model.videos.isEmpty {
                                ProgressView().frame(maxWidth: .infinity)
                            }
                            if !downloaded, let error = model.errorMessage {
                                LibraryConnectionIssue(model: model, message: error)
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 48).id("libraryTop")
                    }
                    if layout == .alphabetical { letterIndex }
                }
                .task(id: jumpID) {
                    guard let letter = requestedLetter else { return }
                    if !downloaded { await model.loadThroughLetter(letter) }
                    guard !Task.isCancelled else { return }
                    // Missing letters jump to the next available group.
                    let target =
                        alphabet.first { $0 >= letter && groups[$0] != nil }
                        ?? alphabet.last { groups[$0] != nil }
                    if let target,
                        let section = sections.first(where: {
                            sectionVideos($0).contains { $0.libraryLetter == target }
                        })
                    {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo("\(section):\(target)", anchor: .top)
                        }
                    }
                }
                .onChange(of: model.librarySection) { _ in resetScroll(proxy) }
                .onChange(of: model.search) { _ in resetScroll(proxy) }
                .onChange(of: model.libraryFilters) { _ in resetScroll(proxy) }
                .onChange(of: downloaded) { _ in
                    downloadType = "All"
                    resetScroll(proxy)
                }
                .onChange(of: downloadType) { _ in resetScroll(proxy) }
                .onChange(of: layout) { _ in resetScroll(proxy) }
            }
        }
        .task(id: "\(model.librarySection.rawValue):\(downloaded)") {
            if downloaded {
                await model.downloads.waitUntilReady()
                await model.downloads.checkLocalFiles()
                model.downloads.synchronize()
            } else {
                await loadFilterOptions()
            }
        }
    }

    private func posterGrid(_ videos: [VideoItem]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24, alignment: .top)],
            alignment: .leading, spacing: 26
        ) {
            ForEach(videos) { video in
                NavigationLink(value: video) {
                    VStack(alignment: .leading, spacing: 6) {
                        MoviePoster(video: video, client: model.client, progressVideo: model.progressVideo(for: video))
                        if downloaded { DownloadStatus(downloads: model.downloads, video: video) }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { WatchStatusAction(video: video, model: model) }
                .accessibilityLabel("Details for \(video.title)")
                .accessibilityValue(model.progressVideo(for: video).accessibleWatchStatus)
                .libraryCardFocus(video.id, focus: $focusedCard, items: videos.map(\.id), columns: gridColumns) {
                    navigation.video(video)
                }
            }
        }
        .focusSection()
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { gridColumns = max(1, Int((geometry.size.width + 24) / 174)) }
                    .onChange(of: geometry.size.width) { gridColumns = max(1, Int(($0 + 24) / 174)) }
            }
        }
    }

    private func alphabeticalList(_ videos: [VideoItem], section: String) -> some View {
        let grouped = Dictionary(grouping: videos, by: \.libraryLetter)
        return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(alphabet.filter { grouped[$0] != nil }, id: \.self) { letter in
                Section {
                    ForEach(grouped[letter] ?? []) { video in
                        NavigationLink(value: video) {
                            alphabeticalRow(video)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { hoveredRow = video.id } else if hoveredRow == video.id { hoveredRow = nil }
                        }
                        .libraryCardFocus(video.id, focus: $focusedCard, items: videos.map(\.id)) {
                            navigation.video(video)
                        }
                        .accessibilityLabel("Details for \(video.title)")
                        .accessibilityValue(model.progressVideo(for: video).accessibleWatchStatus)
                        .contextMenu { WatchStatusAction(video: video, model: model) }
                        Divider()
                    }
                } header: {
                    Text(letter).font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        .background(Color(nsColor: ArtworkColor.pageBackground))
                        .id("\(section):\(letter)")
                }
            }
        }
    }

    private func alphabeticalRow(_ video: VideoItem) -> some View {
        HStack(spacing: 16) {
            JellyfinArtwork(
                request: try? model.client?.imageRequest(for: video, type: .primary, maxWidth: 120)
            ) {
                Color.secondary.opacity(0.12).overlay { Image(systemName: "film") }
            }
            .frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 6) {
                WatchStatusTitle(video: video, progressVideo: model.progressVideo(for: video))
                    .font(.body.weight(.medium))
                Text(video.libraryMetadata)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if downloaded { DownloadStatus(downloads: model.downloads, video: video) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10).contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(hoveredRow == video.id ? 0.07 : 0))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredRow == video.id)
    }

    private var letterIndex: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(alphabet, id: \.self) { letter in
                    Button {
                        requestedLetter = letter
                        jumpID = UUID()
                    } label: {
                        Text(letter).font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Jump to \(letter == "#" ? "numbers and symbols" : letter)")
                    .disabled(!downloaded && model.isLoading)
                }
            }
        }
        .frame(width: 32).padding(.trailing, 8)
    }

    private var filtersMenu: some View {
        Menu {
            if downloaded {
                Picker("Content", selection: $downloadType) {
                    ForEach(["All", "Movies", "Shows"], id: \.self) { Text($0).tag($0) }
                }
                Divider()
            }
            Picker("Watch Status", selection: $model.libraryFilters.watchStatus) {
                ForEach(
                    VideoFilters.WatchStatus.allCases.filter {
                        downloaded || model.librarySection == .movies || $0 != .resumable
                    },
                    id: \.self
                ) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            Picker("Genre", selection: $model.libraryFilters.genre) {
                Text("All Genres").tag("")
                ForEach(
                    (downloaded
                        ? Array(Set(model.downloads.titles.flatMap { $0.genres ?? [] })) : filterOptions?.genres ?? [])
                        .sorted(), id: \.self
                ) { Text($0).tag($0) }
            }
            Picker("Year", selection: $model.libraryFilters.year) {
                Text("All Years").tag(nil as Int?)
                ForEach(
                    (downloaded
                        ? Array(Set(model.downloads.titles.compactMap(\.productionYear))) : filterOptions?.years ?? [])
                        .sorted(by: >), id: \.self
                ) { Text(String($0)).tag(Optional($0)) }
            }
            if !downloaded, let filterError {
                Text(filterError)
                Button("Retry Loading Filters") { Task { await loadFilterOptions() } }
            }
            Divider()
            Button("Clear Filters") {
                model.libraryFilters = VideoFilters()
                downloadType = "All"
            }
            .disabled(model.libraryFilters.isEmpty && downloadType == "All")
        } label: {
            Label(
                model.libraryFilters.isEmpty && downloadType == "All" ? "Filters" : "Filters •",
                systemImage: "line.3.horizontal.decrease")
        }
        .fixedSize().help("Filter by watch status, genre, or year")
    }

    private func resetScroll(_ proxy: ScrollViewProxy) {
        requestedLetter = nil
        jumpID = UUID()
        proxy.scrollTo("libraryTop", anchor: .top)
    }

    private func loadFilterOptions() async {
        filterOptions = nil
        filterError = nil
        let section = model.librarySection
        do {
            let options = try await model.client?.videoFilterOptions(itemTypes: section.itemTypes)
            guard !Task.isCancelled, model.librarySection == section else { return }
            filterOptions = options
        } catch {
            guard !Task.isCancelled, model.librarySection == section else { return }
            filterError = "Genre and year filters couldn’t be loaded."
        }
    }
}
