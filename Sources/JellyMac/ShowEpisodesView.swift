import JellyfinKit
import SwiftUI

struct ShowEpisodesView: View {
    @ObservedObject var model: AppModel
    let series: VideoItem
    @State private var seasons: [VideoItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [VideoItem] = []
    @State private var total = 0
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var seasonError: String?
    @State private var episodeError: String?
    @State private var generation = UUID()
    @State private var retry = 0

    private var selectedSeason: VideoItem? { seasons.first { $0.id == selectedSeasonID } }
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
                    .modifier(SeasonSelectorGlass())
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(seasons.isEmpty)
                .accessibilityLabel("Select season").accessibilityIdentifier("seasonSelector")
                if isLoadingSeasons || isLoadingEpisodes { ProgressView().controlSize(.small) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(episodes) { episode in
                        EpisodeMediaCard(episode: episode, client: model.client, isPreparing: model.isStartingPlayback) { fromBeginning in
                            model.play(episode, startFromBeginning: fromBeginning)
                        }
                        .frame(width: 300, height: 284)
                    }
                    if episodes.count < total {
                        Button("Load more episodes") { Task { await loadEpisodes(reset: false) } }
                            .disabled(isLoadingEpisodes).padding(20)
                    }
                }
                .padding(.bottom, 8)
            }
            .accessibilityIdentifier("seasonEpisodes")
            .id(selectedSeasonID)
            if let errorMessage {
                HStack {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }
                }
            } else if !isLoadingSeasons && !isLoadingEpisodes && episodes.isEmpty {
                Text(seasons.isEmpty ? "No seasons available." : "No episodes available for this season.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(series.id):\(retry)") { await loadSeasons() }
        .task(id: "\(series.id):\(selectedSeasonID ?? ""):\(model.playbackRevision):\(retry)") {
            await loadEpisodes(reset: true)
        }
    }

    private func loadSeasons() async {
        guard let client = model.client else { return }
        isLoadingSeasons = true
        seasonError = nil
        defer { if !Task.isCancelled { isLoadingSeasons = false } }
        do {
            let page = try await client.seasons(seriesID: series.id)
            try Task.checkCancellation()
            seasons = page.items.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            if !seasons.contains(where: { $0.id == selectedSeasonID }) {
                selectedSeasonID = seasons.first(where: { ($0.indexNumber ?? 0) > 0 })?.id ?? seasons.first?.id
            }
        } catch {
            if !Task.isCancelled { seasonError = "Seasons couldn’t be loaded." }
        }
    }

    private func loadEpisodes(reset: Bool) async {
        guard let client = model.client, let seasonID = selectedSeasonID else { return }
        guard reset || !isLoadingEpisodes else { return }
        let requestGeneration = UUID()
        generation = requestGeneration
        isLoadingEpisodes = true
        episodeError = nil
        if reset { episodes = []; total = 0 }
        defer { if generation == requestGeneration { isLoadingEpisodes = false } }
        do {
            let page = try await client.episodes(seriesID: series.id, seasonID: seasonID, startIndex: episodes.count)
            try Task.checkCancellation()
            guard generation == requestGeneration, selectedSeasonID == seasonID else { return }
            episodes.append(contentsOf: page.items.filter { incoming in !episodes.contains { $0.id == incoming.id } })
            total = page.totalCount
        } catch {
            if !Task.isCancelled && generation == requestGeneration { episodeError = "Episodes couldn’t be loaded." }
        }
    }
}

private struct SeasonSelectorGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.ultraThinMaterial, in: Capsule()) }
    }
}
