import JellyfinKit
import SwiftUI

struct MovieDetailHero: View {
    let video: VideoItem
    let client: JellyfinClient?
    let isPreparing: Bool
    let pageColor: Color
    var playTitle: String? = nil
    var canPlay = true
    let onPlay: () -> Void
    let onMore: () -> Void
    var downloads: DownloadLibrary? = nil

    private var category: String {
        [video.type, video.genres?.prefix(2).joined(separator: " · "), video.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var yearAndRuntime: String {
        [video.productionYear.map(String.init), video.runtimeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                JellyfinArtwork(
                    request: (try? client?.imageRequest(for: video, type: .backdrop, maxWidth: 2560))
                        ?? (try? client?.imageRequest(for: video, type: .primary, maxWidth: 1600)),
                    blurHashes: video.imageBlurHashes
                ) { pageColor }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .accessibilityHidden(true)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(width: min(geometry.size.width * 0.75, 820), height: min(geometry.size.height * 0.8, 420))
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
                HStack(alignment: .bottom, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        JellyfinArtwork(
                            request: try? client?.imageRequest(for: video, type: .logo, maxWidth: 900), fit: true
                        ) {
                            Text(video.title).font(.system(size: 36, weight: .bold)).lineLimit(2).minimumScaleFactor(
                                0.7)
                        }
                        .frame(width: min(geometry.size.width * 0.36, 360), height: 90, alignment: .bottomLeading)
                        .accessibilityLabel(video.title).accessibilityIdentifier("movieLogo")
                        if !category.isEmpty {
                            Text(category).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                        }
                        if let overview = video.overview, !overview.isEmpty {
                            HStack(alignment: .bottom, spacing: 8) {
                                Text(overview).font(.system(size: 14)).lineLimit(2).lineSpacing(2)
                                    .foregroundStyle(.white.opacity(0.8))
                                Button(action: onMore) {
                                    Text("More").font(.system(size: 11, weight: .semibold))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(.white.opacity(0.15), in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Read the full description")
                            }
                            .frame(maxWidth: 470 * 0.7, alignment: .leading)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                if !yearAndRuntime.isEmpty {
                                    Text(yearAndRuntime).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                                }
                                ForEach(video.mediaBadges, id: \.self) { badge in MovieMediaBadge(text: badge) }
                            }
                        }
                        .frame(height: 22)
                        HStack(spacing: 12) {
                            GlassPlayButton(
                                resume: video.isInProgress, disabled: isPreparing || !canPlay,
                                title: playTitle
                                    ?? (video.userData?.played == true && !video.isInProgress ? "Play Again" : nil),
                                action: onPlay
                            )
                            .accessibilityIdentifier("detailPlay")
                            if let downloads { DownloadButton(downloads: downloads, video: video) }
                            if isPreparing { ProgressView().controlSize(.small) }
                        }
                        .padding(.top, 8)
                    }
                    .frame(width: min(geometry.size.width * 0.58, 620), alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 6) {
                        if !video.actors.isEmpty {
                            Text("Starring " + video.actors.prefix(3).map(\.name).joined(separator: ", "))
                        }
                        if !video.directors.isEmpty {
                            Text("Director " + video.directors.map(\.name).joined(separator: ", "))
                        }
                    }
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: 280, alignment: .leading)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                }
                .padding(.horizontal, 40).padding(.bottom, 36)
            }
            .clipped()
        }
    }
}

struct MovieMediaBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(.white.opacity(0.8))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
    }
}
