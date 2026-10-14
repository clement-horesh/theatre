import JellyfinKit
import SwiftUI

struct MovieDetailView: View {
    @ObservedObject var model: AppModel
    let initialVideo: VideoItem
    @State private var loadedVideo: VideoItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var video: VideoItem { loadedVideo ?? initialVideo }
    private let pageColor = Color(white: 0.09)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MovieDetailHero(video: video, client: model.client, isPreparing: model.isStartingPlayback,
                            pageColor: pageColor, onPlay: { model.play(video) }, onMore: {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { scroll.scrollTo("movieAbout", anchor: .top) }
                            })
                            .frame(height: max(500, min(900, max(geometry.size.height * 0.92, geometry.size.width * 9 / 16))) * 0.9)
                        VStack(alignment: .leading, spacing: 36) {
                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if video.type == "Series" { ShowEpisodesView(model: model, series: video) }
                            MovieCastSection(video: video, client: model.client, width: geometry.size.width - 80)
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
            guard let client = model.client else { return }
            isLoading = true
            errorMessage = nil
            do {
                let result = try await client.item(id: initialVideo.id)
                try Task.checkCancellation()
                loadedVideo = result
            } catch {
                if !Task.isCancelled { errorMessage = "Some movie details could not be loaded. You can still play the video." }
            }
            isLoading = false
        }
    }
}
