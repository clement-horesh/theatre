import JellyfinKit
import SwiftUI

struct MovieDetailView: View {
    @ObservedObject var model: AppModel
    let initialVideo: VideoItem
    @State private var loadedVideo: VideoItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPlayback: ShowPlaybackSelection?
    @State private var relatedTitles: [VideoItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    private var video: VideoItem {
        if model.showsDownloads {
            return model.downloads.cachedVideo(id: initialVideo.id) ?? loadedVideo ?? initialVideo
        }
        return loadedVideo ?? initialVideo
    }
    private var playbackSelection: ShowPlaybackSelection? {
        model.showsDownloads
            ? ShowPlaybackSelection(episodes: model.downloads.episodes(seriesID: video.id)) : showPlayback
    }
    private let pageColor = Color(white: 0.09)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MovieDetailHero(
                            video: video, client: model.client, isPreparing: model.isStartingPlayback,
                            pageColor: pageColor,
                            playTitle: video.type == "Series" ? (playbackSelection?.title ?? "Start") : nil,
                            canPlay: video.type == "Series"
                                ? playbackSelection != nil
                                : (!model.showsDownloads || model.downloads.playbackStream(for: video) != nil),
                            onPlay: {
                                if video.type == "Series" {
                                    if let playbackSelection { model.play(playbackSelection.episode) }
                                } else {
                                    model.play(video)
                                }
                            },
                            onMore: {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                    scroll.scrollTo("movieAbout", anchor: .top)
                                }
                            }, downloads: model.downloads
                        )
                        .contextMenu { WatchStatusAction(video: video, model: model) }
                        .frame(
                            height: max(500, min(900, max(geometry.size.height * 0.92, geometry.size.width * 9 / 16)))
                                * 0.9)
                        VStack(alignment: .leading, spacing: 36) {
                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if video.type == "Series" { ShowEpisodesView(model: model, series: video) }
                            MovieTrailerSection(video: video, client: model.client) { trailer in
                                if model.playback.isPlaying { model.togglePlayback() }
                                openWindow(value: trailer)
                            }
                            MovieCastSection(video: video, client: model.client, width: geometry.size.width - 80)
                            if !model.showsDownloads && !relatedTitles.isEmpty {
                                RelatedTitlesSection(model: model, titles: relatedTitles)
                            }
                            MovieAboutSection(video: video, width: geometry.size.width - 80)
                                .id("movieAbout")
                            MovieInformationSection(video: video, width: geometry.size.width - 80)
                        }
                        .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 80)
                    }
                }
                .background(pageColor)
                .overlay(alignment: .topTrailing) {
                    if isLoading { ProgressView().controlSize(.small).padding(20) }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .navigationTitle(video.name)
        .task(id: "\(initialVideo.id):\(model.playbackRevision)") {
            if model.showsDownloads {
                loadedVideo = model.downloads.cachedVideo(id: initialVideo.id)
                showPlayback = ShowPlaybackSelection(episodes: model.downloads.episodes(seriesID: initialVideo.id))
                return
            }
            guard let client = model.client else { return }
            isLoading = true
            async let related = try? client.relatedTitles(itemID: initialVideo.id)
            errorMessage = nil
            showPlayback = nil
            do {
                let result = try await client.item(id: initialVideo.id)
                try Task.checkCancellation()
                loadedVideo = result
            } catch {
                if !Task.isCancelled {
                    loadedVideo = model.downloads.cachedVideo(id: initialVideo.id)
                    if loadedVideo == nil {
                        errorMessage = "Some title details could not be loaded. You can still select a video to play."
                    }
                }
            }
            if video.type == "Series", !Task.isCancelled {
                do {
                    let episodes = try await client.showPlaybackCandidates(seriesID: initialVideo.id)
                    try Task.checkCancellation()
                    showPlayback = ShowPlaybackSelection(episodes: episodes)
                } catch {
                    if !Task.isCancelled {
                        showPlayback = ShowPlaybackSelection(
                            episodes: model.downloads.episodes(seriesID: initialVideo.id))
                        if showPlayback == nil {
                            errorMessage = "The next episode couldn’t be loaded. You can still select an episode below."
                        }
                    }
                }
            }
            let recommendations = await related
            if !Task.isCancelled {
                relatedTitles = recommendations ?? []
                isLoading = false
            }
        }
    }
}
