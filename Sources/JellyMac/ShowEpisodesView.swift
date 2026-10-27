import JellyfinKit
import SwiftUI

struct ShowEpisodesView: View {
    @ObservedObject var model: AppModel
    let series: VideoItem
    @State private var seasons: [SeasonOption] = []
    @State private var usesSavedEpisodes = false
    @State private var selectedSeasonID: String?
    @State private var episodes: [VideoItem] = []
    @State private var total = 0
    @State private var nextOffset = 0
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var seasonError: String?
    @State private var episodeError: String?
    @State private var generation = UUID()
    @State private var retry = 0
    @State private var loadedSeasonQuery: String?
    @State private var loadedEpisodeQuery: String?
    @State private var loadedSeasonID: String?
    @FocusState private var focusedEpisode: String?

    private var selectedSeason: SeasonOption? { seasons.first { $0.id == selectedSeasonID } }
    private var savedSeasonNumbers: [Int] {
        Set(
            model.downloads.episodes(seriesID: series.libraryID, completedOnly: false).map { $0.parentIndexNumber ?? 0 }
        )
        .sorted()
    }
    private var visibleEpisodes: [VideoItem] {
        if model.showsDownloads || usesSavedEpisodes {
            return model.downloads.episodes(seriesID: series.libraryID, completedOnly: false)
                .filter { ($0.parentIndexNumber ?? 0) == selectedSeason?.indexNumber }
        }
        return episodes
    }
    private var errorMessage: String? { seasonError ?? episodeError }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Season", selection: $selectedSeasonID) {
                        ForEach(seasons) { season in Text(season.name).tag(Optional(season.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 10) {
                        Text(selectedSeason?.name ?? "Seasons").font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(seasons.isEmpty)
                .accessibilityLabel("Select season").accessibilityIdentifier("seasonSelector")
                if isLoadingSeasons || isLoadingEpisodes { ProgressView().controlSize(.small) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    if visibleEpisodes.isEmpty && (isLoadingSeasons || isLoadingEpisodes) {
                        ForEach(0..<4) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                MediaCardSkeleton()
                                LoadingPlaceholder().frame(width: 220, height: 16)
                                LoadingPlaceholder().frame(height: 40)
                                Spacer(minLength: 0)
                            }
                            .frame(width: 300, height: 284)
                            .accessibilityHidden(true)
                        }
                    }
                    ForEach(visibleEpisodes) { episode in
                        EpisodeMediaCard(
                            model: model, episode: episode, client: model.client(for: episode),
                            isPreparing: model.isStartingPlayback
                        ) { fromBeginning in
                            model.play(episode, startFromBeginning: fromBeginning)
                        }
                        .frame(width: 300, height: 284)
                        .focusable()
                        .libraryCardFocus(episode.id, focus: $focusedEpisode, items: visibleEpisodes.map(\.id)) {
                            if model.canPlay(episode) { model.play(episode) }
                        }
                    }
                    if !model.showsDownloads && !usesSavedEpisodes && nextOffset < total {
                        Button("Load more episodes") { Task { await loadEpisodes(reset: false) } }
                            .disabled(isLoadingEpisodes).padding(20)
                    }
                }
                .padding(.bottom, 8)
            }
            .accessibilityIdentifier("seasonEpisodes")
            .focusSection()
            .id(selectedSeasonID)
            if let errorMessage {
                HStack {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }
                }
            } else if !isLoadingSeasons && !isLoadingEpisodes && visibleEpisodes.isEmpty {
                Text(seasons.isEmpty ? "No seasons available." : "No episodes available for this season.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: savedSeasonNumbers) { _ in
            if model.showsDownloads || usesSavedEpisodes { loadSavedSeasons() }
        }
        .task(id: "\(series.libraryID):\(retry)") {
            let query = "\(series.libraryID):\(retry)"
            guard loadedSeasonQuery != query else { return }
            await loadSeasons()
            if !Task.isCancelled && seasonError == nil { loadedSeasonQuery = query }
        }
        .task(id: "\(series.libraryID):\(selectedSeasonID ?? ""):\(model.playbackRevision):\(retry)") {
            let query = "\(series.libraryID):\(selectedSeasonID ?? ""):\(model.playbackRevision):\(retry)"
            guard loadedEpisodeQuery != query else { return }
            await loadEpisodes(reset: true)
            if !Task.isCancelled && episodeError == nil && selectedSeasonID != nil { loadedEpisodeQuery = query }
        }
    }

    private func loadSavedSeasons() {
        usesSavedEpisodes = true
        seasons = Set(
            model.downloads.episodes(seriesID: series.libraryID, completedOnly: false).map { $0.parentIndexNumber ?? 0 }
        )
        .sorted().map {
            SeasonOption(id: "offline:\($0)", name: $0 == 0 ? "Specials" : "Season \($0)", indexNumber: $0)
        }
        if !seasons.contains(where: { $0.id == selectedSeasonID }) {
            selectedSeasonID = seasons.first(where: { ($0.indexNumber ?? 0) > 0 })?.id ?? seasons.first?.id
        }
    }

    private func loadSeasons() async {
        if model.showsDownloads {
            loadSavedSeasons()
            return
        }
        guard let client = model.client(for: series) else { return }
        isLoadingSeasons = true
        seasonError = nil
        defer { isLoadingSeasons = false }
        do {
            let page = try await client.seasons(seriesID: series.id)
            try Task.checkCancellation()
            seasons = page.items.map { SeasonOption(id: $0.id, name: $0.name, indexNumber: $0.indexNumber) }.sorted {
                ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
            }
            if !seasons.contains(where: { $0.id == selectedSeasonID }) {
                selectedSeasonID = seasons.first(where: { ($0.indexNumber ?? 0) > 0 })?.id ?? seasons.first?.id
            }
        } catch {
            if !Task.isCancelled {
                if !model.downloads.episodes(seriesID: series.libraryID).isEmpty {
                    loadSavedSeasons()
                } else {
                    seasonError = "Seasons couldn’t be loaded."
                }
            }
        }
    }

    private func loadEpisodes(reset: Bool) async {
        if model.showsDownloads || usesSavedEpisodes {
            episodes = model.downloads.episodes(seriesID: series.libraryID, completedOnly: false)
                .filter { ($0.parentIndexNumber ?? 0) == selectedSeason?.indexNumber }
            total = episodes.count
            nextOffset = total
            return
        }
        guard let client = model.client(for: series), let seasonID = selectedSeasonID else { return }
        guard reset || !isLoadingEpisodes else { return }
        let requestGeneration = UUID()
        generation = requestGeneration
        isLoadingEpisodes = true
        episodeError = nil
        if reset && loadedSeasonID != seasonID {
            episodes = []
            total = 0
            nextOffset = 0
        }
        defer { if generation == requestGeneration { isLoadingEpisodes = false } }
        do {
            let offset = reset ? 0 : nextOffset
            let page = try await client.episodes(seriesID: series.id, seasonID: seasonID, startIndex: offset)
            try Task.checkCancellation()
            guard generation == requestGeneration, selectedSeasonID == seasonID else { return }
            nextOffset = page.items.isEmpty ? page.totalCount : offset + page.items.count
            if reset { episodes = [] }
            var ids = Set(episodes.map(\.id))
            episodes.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
            total = page.totalCount
            loadedSeasonID = seasonID
        } catch {
            if !Task.isCancelled && generation == requestGeneration { episodeError = "Episodes couldn’t be loaded." }
        }
    }
}

private struct SeasonOption: Identifiable {
    let id: String
    let name: String
    let indexNumber: Int?
}
