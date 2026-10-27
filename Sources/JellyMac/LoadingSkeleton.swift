import SwiftUI

struct LoadingPlaceholder: View {
    var body: some View {
        Color.white.opacity(0.06).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct MediaCardSkeleton: View {
    var poster = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadingPlaceholder()
                .aspectRatio(poster ? 2.0 / 3 : 16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: poster ? 10 : 14))
            if poster {
                LoadingPlaceholder().frame(height: 14).frame(maxWidth: 130)
                LoadingPlaceholder().frame(width: 48, height: 10)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PosterSkeletonGrid: View {
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24, alignment: .top)],
            alignment: .leading, spacing: 26
        ) {
            ForEach(0..<12) { _ in MediaCardSkeleton(poster: true) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading titles")
    }
}
