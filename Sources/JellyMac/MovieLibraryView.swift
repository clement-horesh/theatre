import JellyfinKit
import SwiftUI

struct MovieLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var path: [VideoItem] = []
    @State private var showsSearch = false
    @State private var featuredVideos: [VideoItem] = []
    @State private var featuredColor = Color(nsColor: ArtworkColor.pageBackground)
    @State private var windowPhase = LibraryWindowPhase.windowed
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var isHome: Bool { model.librarySection == .home }
    private var showsFeature: Bool { model.librarySection == .home && model.search.isEmpty }
    private var refreshesHome: Bool {
        showsFeature && path.isEmpty && scenePhase == .active && !model.isPlayerWindowKey
    }
    private func featureHeight(width: CGFloat) -> CGFloat { min(680, max(340, (width - 48) / 2.33)) }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack(path: $path) {
                libraryContent(width: geometry.size.width)
                    .navigationTitle("Theatre")
                    .navigationDestination(for: VideoItem.self) { video in
                        MovieDetailView(model: model, initialVideo: video)
                            .navigationBarBackButtonHidden(true)
                    }
            }
            .toolbar { navigationToolbar }
            .toolbar(.visible, for: .windowToolbar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if windowPhase.showsPageNavigation {
                    ZStack {
                        centerNavigation
                        if !path.isEmpty {
                            HStack {
                                backButton
                                Spacer()
                            }
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 24).padding(.vertical, 8)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background {
                LibraryWindowBackground(
                    color: showsFeature && path.isEmpty
                        ? ArtworkColor.pageBackground.blended(withFraction: 0.8, of: NSColor(featuredColor))
                            ?? ArtworkColor.pageBackground
                        : ArtworkColor.pageBackground, animateColor: !reduceMotion,
                    onPhase: { phase in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { windowPhase = phase }
                    }
                )
                .frame(width: 0, height: 0)
            }
            .background {
                ZStack(alignment: .top) {
                    Color(nsColor: ArtworkColor.pageBackground)
                    if showsFeature && path.isEmpty {
                        LinearGradient(
                            stops: [
                                .init(color: featuredColor.opacity(0.8), location: 0),
                                .init(color: featuredColor.opacity(0.35), location: 0.5),
                                .init(color: Color(nsColor: ArtworkColor.pageBackground), location: 1),
                            ], startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: featureHeight(width: geometry.size.width) + 120)
                    }
                }
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: featuredColor)
            }
            .onChange(of: model.librarySection) { _ in path = [] }
            .onChange(of: model.search) { _ in path = [] }
            .onChange(of: model.homeRecommendationRevision) { _ in chooseFeature() }
            .onChange(of: model.playbackRevision) { _ in chooseFeature() }
            .task(id: "\(model.client?.session?.userID ?? ""):\(model.librarySection.rawValue):\(model.search)") {
                do {
                    if !model.search.isEmpty { try await Task.sleep(nanoseconds: 350_000_000) }
                    try Task.checkCancellation()
                    await model.loadVideos()
                } catch {}
            }
            .task(id: "\(model.client?.session?.userID ?? ""):\(refreshesHome)") {
                guard refreshesHome else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard !Task.isCancelled, refreshesHome else { return }
                    await model.refreshRecentlyAddedTitles()
                }
            }
        }
    }

    private func libraryContent(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if showsFeature, !featuredVideos.isEmpty {
                    FeaturedRecommendationCarousel(
                        videos: featuredVideos, client: model.client,
                        isPreparing: model.isStartingPlayback, isActive: path.isEmpty && !model.isPlayerWindowKey,
                        onColor: { featuredColor = Color(nsColor: $0) },
                        onPlay: { video in
                            if video.type == "Series" { path.append(video) } else { model.play(video) }
                        },
                        onToggleWatched: { video in Task { await model.toggleWatched(video) } }
                    )
                    .frame(height: featureHeight(width: width)).padding(.top, 6)
                }
                if isHome {
                    if model.search.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Continue").font(.title2.weight(.semibold))
                            if model.resumeVideos.isEmpty && !model.isLoading {
                                Text("Your unfinished movies and episodes will appear here.").foregroundStyle(
                                    .secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 18) {
                                    ForEach(model.resumeVideos) { video in
                                        Button {
                                            model.play(video)
                                        } label: {
                                            ContinueMediaCard(video: video, client: model.client).frame(width: 340)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { WatchStatusAction(video: video, model: model) }
                                        .disabled(model.isStartingPlayback)
                                        .accessibilityLabel("Resume \(video.title)")
                                        .accessibilityIdentifier("continue-\(video.id)")
                                    }
                                    if model.canLoadMoreResume {
                                        Button("Load more") { Task { await model.loadMoreResumeVideos() } }
                                            .disabled(model.isLoadingResume).padding(20)
                                    }
                                }
                                .padding(.bottom, 6)
                            }
                            .accessibilityIdentifier("continueRow")
                        }
                        .padding(.top, 14)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recently Added").font(.title2.weight(.semibold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 24) {
                                    ForEach(model.recentlyAddedVideos) { video in
                                        NavigationLink(value: video) {
                                            MoviePoster(
                                                video: video, client: model.client,
                                                progressVideo: model.progressVideo(for: video)
                                            ).frame(width: 180)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { WatchStatusAction(video: video, model: model) }
                                        .accessibilityLabel(
                                            "Details for \(video.title)"
                                                + (model.progressVideo(for: video).isInProgress
                                                    ? ", In progress" : (video.isUnwatched ? ", Unwatched" : ""))
                                        )
                                        .accessibilityIdentifier("recent-\(video.id)")
                                    }
                                }
                                .padding(.bottom, 12)
                            }
                            .accessibilityIdentifier("recentlyAddedRow")
                        }
                        .padding(.top, 14)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 18)], spacing: 18)
                        {
                            ForEach(model.videos) { video in
                                NavigationLink(value: video) {
                                    ContinueMediaCard(video: video, client: model.client, showsPlaybackInfo: false)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { WatchStatusAction(video: video, model: model) }
                            }
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24, alignment: .top)],
                        alignment: .leading, spacing: 26
                    ) {
                        ForEach(model.videos) { video in
                            NavigationLink(value: video) {
                                MoviePoster(
                                    video: video, client: model.client, progressVideo: model.progressVideo(for: video))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { WatchStatusAction(video: video, model: model) }
                            .accessibilityLabel(
                                "Details for \(video.title)"
                                    + (model.progressVideo(for: video).isInProgress
                                        ? ", In progress" : (video.isUnwatched ? ", Unwatched" : "")))
                        }
                    }
                }
                if model.canLoadMore && (!isHome || !model.search.isEmpty) {
                    Button("Load more") { Task { await model.loadVideos(reset: false) } }
                        .frame(maxWidth: .infinity).padding(.bottom, 24)
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(24)
            .padding(.bottom, isHome ? 64 : 0)
        }
        .overlay {
            if model.isLoading && model.videos.isEmpty && (!isHome || !model.search.isEmpty) {
                ProgressView("Loading library…")
            } else if !model.isLoading && model.videos.isEmpty && model.errorMessage == nil
                && (!isHome || !model.search.isEmpty
                    || (model.recentlyAddedVideos.isEmpty && model.resumeVideos.isEmpty))
            {
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 34))
                    Text(
                        model.search.isEmpty
                            ? "No \(model.librarySection == .home ? "videos" : model.librarySection.rawValue.lowercased()) in this library"
                            : "No matching titles"
                    ).font(.headline)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if windowPhase.showsToolbarNavigation {
            ToolbarItem(placement: .principal) {
                centerNavigation.buttonStyle(.plain)
            }
            .withoutSharedBackground()
            if !path.isEmpty {
                ToolbarItem(placement: .navigation) { backButton }
                    .withoutSharedBackground()
            }
        }
    }

    private var centerNavigation: some View {
        ZStack {
            libraryNavigation
                .opacity(showsSearch ? 0 : 1)
                .scaleEffect(showsSearch && !reduceMotion ? 0.98 : 1)
                .allowsHitTesting(!showsSearch)
                .accessibilityHidden(showsSearch)
            if showsSearch {
                searchBar.zIndex(1)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .font(.system(size: 13))
        .frame(width: 360, height: 36)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2), value: showsSearch)
    }

    private var backButton: some View {
        Button {
            guard !path.isEmpty else { return }
            path.removeLast()
            closeSearch()
        } label: {
            Image(systemName: "chevron.backward").font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .glassSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back").help("Back")
    }

    private var libraryNavigation: some View {
        HStack(spacing: 8) {
            Button {
                if showsSearch { closeSearch() } else { showsSearch = true }
            } label: {
                Image(systemName: "magnifyingglass").padding(.vertical, 6)
            }
            .help("Search").accessibilityLabel("Search").accessibilityIdentifier("revealSearch")
            .keyboardShortcut("f", modifiers: .command)
            ForEach(LibrarySection.allCases) { section in
                LibraryTabButton(section: section, selected: model.librarySection == section) {
                    model.librarySection = section
                    closeSearch()
                }
            }
        }
        .accessibilityIdentifier("libraryTabs")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your library", text: $model.search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("librarySearch")
                .onExitCommand { closeSearch() }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 6).frame(width: 320, height: 32)
        .glassSurface(in: Capsule(), interactive: true)
        .background {
            GeometryReader { geometry in
                SearchOutsideClick { closeSearch() }
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task { searchFocused = true }
    }

    private func closeSearch() {
        guard showsSearch else { return }
        showsSearch = false
        searchFocused = false
        model.search = ""
    }

    private func chooseFeature() {
        guard showsFeature else { return }
        var random = SystemRandomNumberGenerator()
        featuredVideos = FeaturedRecommendations.choose(
            recent: model.recentlyAddedVideos,
            continuing: model.recentContinueMovies, using: &random)
        if featuredVideos.isEmpty { featuredColor = Color(nsColor: ArtworkColor.pageBackground) }
    }
}

private struct LibraryTabButton: View {
    let section: LibrarySection
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(section.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? .black : .white.opacity(hovered ? 1 : 0.8))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(selected ? 1 : (hovered ? 0.18 : 0)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    fileprivate func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}

struct MoviePoster: View {
    let video: VideoItem
    let client: JellyfinClient?
    var progressVideo: VideoItem? = nil

    private var statusVideo: VideoItem { progressVideo ?? video }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                // Derive the cover height from its width, never the title's height.
                .fixedSize(horizontal: false, vertical: true)
                .overlay {
                    JellyfinArtwork(request: try? client?.imageRequest(for: video, type: .primary, maxWidth: 420)) {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "film").font(.system(size: 32)).foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            WatchStatusTitle(video: video, progressVideo: statusVideo).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let year = video.productionYear { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}
