import JellyfinKit
import SwiftUI

struct ContinueMediaCard: View {
    let video: VideoItem
    let client: JellyfinClient?
    var showsPlaybackInfo = true
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showsProgress: Bool { showsPlaybackInfo && video.isInProgress }
    private var highlightsPlayback: Bool { hovered && showsPlaybackInfo }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                JellyfinArtwork(
                    request: try? client?.imageRequest(for: video, type: .backdrop, maxWidth: 1000),
                    blurHashes: video.imageBlurHashes, progressBlurHeight: showsProgress ? 84 : 0
                ) {
                    Color(white: 0.1)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(highlightsPlayback && !reduceMotion ? 1.035 : 1)
                .offset(y: highlightsPlayback && !reduceMotion ? -2 : 0)
                .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    JellyfinArtwork(
                        request: try? client?.imageRequest(for: video, type: .logo, maxWidth: 600), fit: true
                    ) {
                        Text(video.seriesName ?? video.name).font(.title3.weight(.bold)).lineLimit(2)
                    }
                    .frame(width: geometry.size.width * 0.65, height: 62, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 1)
                    .padding(.horizontal, 14)
                    if showsProgress { WatchProgressStrip(video: video) } else { Color.clear.frame(height: 14) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(highlightsPlayback ? 0.22 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold)).fixedSize()
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .padding(14).opacity(highlightsPlayback ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .foregroundStyle(.white)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(video.title)" + (showsProgress ? ", \(video.progressLabel) remaining" : ""))
    }
}
