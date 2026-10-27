import JellyfinKit
import SwiftUI

struct EpisodeMediaCard: View {
    @ObservedObject var model: AppModel
    let episode: VideoItem
    let client: JellyfinClient?
    let isPreparing: Bool
    let onPlay: (_ fromBeginning: Bool) -> Void

    private var canPlay: Bool {
        !isPreparing && model.canPlay(episode)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                onPlay(false)
            } label: {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        JellyfinArtwork(
                            request: (try? client?.imageRequest(for: episode, type: .primary, maxWidth: 900))
                                ?? (try? client?.imageRequest(for: episode, type: .backdrop, maxWidth: 900)),
                            blurHashes: episode.imageBlurHashes, progressBlurHeight: 215, progressBlurRadius: 24
                        ) {
                            Color(white: 0.12)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(episode.indexNumber.map { "EPISODE \($0)" } ?? "EPISODE")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                            HStack(spacing: 6) {
                                Text(episode.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                if episode.isInProgress || episode.isUnwatched {
                                    Circle().fill(episode.isInProgress ? Color.yellow : Color.blue).frame(
                                        width: 5, height: 5)
                                }
                            }
                            Text(episode.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "No description available.")
                                .font(.system(size: 13)).foregroundStyle(.white)
                                .lineLimit(2, reservesSpace: true).truncationMode(.tail)
                                .lineSpacing(1).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 7) {
                                Image(systemName: "play.fill").font(.system(size: 10))
                                if episode.isInProgress {
                                    Capsule().fill(.white.opacity(0.3))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(.white.opacity(0.8))
                                                .frame(width: 28 * episode.progressFraction)
                                        }
                                        .frame(width: 28, height: 4)
                                }
                                Text(
                                    episode.isInProgress ? episode.remainingTimeLabel : (episode.runtimeLabel ?? "Play")
                                )
                                .font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 26)
                            }
                            .padding(.top, 5).frame(height: 24)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .padding(14)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain).disabled(!canPlay)
            .accessibilityLabel((episode.isInProgress ? "Resume " : "Play ") + episode.title)
            .accessibilityValue(episode.accessibleWatchStatus)
            Menu {
                Button(episode.isInProgress ? "Resume" : "Play") { onPlay(false) }.disabled(!canPlay)
                if episode.isInProgress { Button("Play from Beginning") { onPlay(true) }.disabled(!canPlay) }
                Divider()
                WatchStatusAction(video: episode, model: model)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(isPreparing).padding(.trailing, 10).padding(.bottom, 14)
            .accessibilityLabel("Playback options for \(episode.name)")
        }
        .contextMenu { WatchStatusAction(video: episode, model: model) }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
