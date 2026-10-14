import JellyfinKit
import SwiftUI

struct WatchStatusTitle: View {
    let video: VideoItem
    var progressVideo: VideoItem? = nil
    private var isInProgress: Bool { (progressVideo ?? video).isInProgress }
    var body: some View {
        HStack(spacing: 6) {
            Text(video.title).lineLimit(2)
            if isInProgress || video.isUnwatched {
                Circle().fill(isInProgress ? Color.yellow : Color.blue).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(video.title + (isInProgress ? ", In progress" : (video.isUnwatched ? ", Unwatched" : "")))
    }
}

/// Playback information over the card's blurred artwork, without a color fill.
struct WatchProgressStrip: View {
    let video: VideoItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill").font(.system(size: 13))
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.25))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.75))
                            .frame(width: geometry.size.width * video.progressFraction)
                    }
            }
            .frame(width: 34, height: 5)
            Text(video.progressLabel).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 26)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In progress, \(video.progressLabel) remaining")
    }
}
