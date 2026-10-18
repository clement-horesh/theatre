import JellyfinKit
import SwiftUI

struct MovieTrailerSection: View {
    let video: VideoItem
    let client: JellyfinClient?
    let onPlay: (TrailerPresentation) -> Void
    @FocusState private var focusedTrailer: String?

    private var trailer: TrailerPresentation? {
        guard let first = video.remoteTrailers?.first(where: { $0.webURL != nil }), let url = first.webURL else {
            return nil
        }
        let name = first.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrailerPresentation(
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(video.name) Trailer", url: url)
    }

    var body: some View {
        if let trailer {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trailers").font(.title2.weight(.semibold))
                TrailerCard(trailer: trailer, video: video, client: client) { onPlay(trailer) }
                    .frame(width: 320, height: 226)
                    .focusable()
                    .libraryCardFocus(
                        trailer.url.absoluteString, focus: $focusedTrailer, items: [trailer.url.absoluteString]
                    ) {
                        onPlay(trailer)
                    }
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("movieTrailers")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TrailerCard: View {
    let trailer: TrailerPresentation
    let video: VideoItem
    let client: JellyfinClient?
    let onPlay: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onPlay) {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        JellyfinArtwork(
                            request: RemoteTrailer.youtubeThumbnailURL(for: trailer.url).map { URLRequest(url: $0) },
                            progressBlurHeight: 110, progressBlurRadius: 24
                        ) {
                            JellyfinArtwork(
                                request: try? client?.imageRequest(for: video, type: .backdrop, maxWidth: 900),
                                progressBlurHeight: 110, progressBlurRadius: 24
                            ) { Color(white: 0.12) }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        VStack(alignment: .leading, spacing: 12) {
                            Text(trailer.title).font(.system(size: 16, weight: .semibold))
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Label("Play", systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
                        }
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .padding(14).padding(.trailing, 24)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play trailer: \(trailer.title)")
            Menu {
                Button("Play Trailer", action: onPlay)
                Link("Open in Browser", destination: trailer.url)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 10).padding(.bottom, 14)
            .accessibilityLabel("Options for \(trailer.title)")
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
