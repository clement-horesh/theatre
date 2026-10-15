import AppKit
import JellyfinKit
import SwiftUI

struct FeaturedRecommendationCarousel: View {
    let videos: [VideoItem]
    let client: JellyfinClient?
    let isPreparing: Bool
    let isActive: Bool
    let onColor: (NSColor) -> Void
    let onPlay: (VideoItem) -> Void
    let onToggleWatched: (VideoItem) -> Void
    @State private var index = 0
    @State private var hovered = false
    @State private var restartClock = UUID()
    @State private var colors: [String: NSColor] = [:]
    @State private var details: [String: VideoItem] = [:]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: VideoItem? { videos.isEmpty ? nil : videos[min(index, videos.count - 1)] }
    private var currentID: String? { current?.id }
    private var rotating: Bool { isActive && scenePhase == .active && videos.count > 1 }
    private var rotationKey: String { "\(videos.map(\.id)):\(restartClock):\(rotating)" }

    var body: some View {
        ZStack {
            if let video = current {
                NavigationLink(value: video) {
                    FeaturedMediaView(
                        video: details[video.id] ?? video, client: client,
                        onColor: { color in
                            colors[video.id] = color
                            if currentID == video.id { onColor(color) }
                        })
                }
                .buttonStyle(.plain).accessibilityIdentifier("featuredMedia")
                .contextMenu {
                    Button(video.userData?.played == true ? "Mark as Unwatched" : "Mark as Watched") {
                        onToggleWatched(video)
                    }
                }
                .id(video.id)
                .transition(.opacity)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GlassPlayButton(
                            resume: video.isInProgress, disabled: isPreparing,
                            title: video.type == "Series" ? "View Show" : nil
                        ) { onPlay(video) }
                        .accessibilityIdentifier("featuredPlay")
                        .accessibilityLabel(
                            (video.type == "Series" ? "View show " : (video.isInProgress ? "Resume " : "Play "))
                                + video.title)
                    }
                    .padding(.horizontal, 30).padding(.bottom, 50)
                }
                .zIndex(1)
            }
            if videos.count > 1 {
                HStack(spacing: 0) {
                    arrow("chevron.left", label: "Previous recommendation", offset: -1)
                    Spacer()
                    arrow("chevron.right", label: "Next recommendation", offset: 1)
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hovered)
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(Array(videos.enumerated()), id: \.element.id) { position, video in
                            Button {
                                select(position)
                            } label: {
                                Capsule().fill(.white.opacity(index == position ? 1 : 0.4))
                                    .frame(width: index == position ? 12 : 6, height: 6)
                                    .frame(width: 16, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Recommendation \(position + 1): \(video.title)")
                            .accessibilityAddTraits(index == position ? .isSelected : [])
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .overlay {
            if videos.count > 1 {
                CarouselSwipeInput { move(by: $0) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.65), value: currentID)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { gesture in
                guard abs(gesture.translation.width) > max(50, abs(gesture.translation.height)) else { return }
                move(by: gesture.translation.width < 0 ? 1 : -1)
            }
        )
        .onChange(of: currentID) { id in
            if let id, let color = colors[id] { onColor(color) }
        }
        .onChange(of: videos.map(\.id)) { _ in
            index = 0
            restartClock = UUID()
        }
        .task(id: rotationKey) {
            guard rotating else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard !Task.isCancelled, rotating else { return }
                move(by: 1, resetTimer: false)
            }
        }
        .task(id: videos) {
            guard let client else { return }
            let ids = Set(videos.map(\.id))
            colors = colors.filter { ids.contains($0.key) }
            details = [:]
            for video in videos {
                guard !Task.isCancelled else { return }
                let request =
                    (try? client.imageRequest(for: video, type: .backdrop, maxWidth: 2560))
                    ?? (try? client.imageRequest(for: video, type: .primary, maxWidth: 1600))
                if let request, let image = try? await ArtworkCache.shared.image(for: request) {
                    guard !Task.isCancelled else { return }
                    let color = ArtworkColor.dominant(in: image)
                    colors[video.id] = color
                    if currentID == video.id { onColor(color) }
                }
                if let detail = try? await client.item(id: video.id) {
                    guard !Task.isCancelled else { return }
                    details[video.id] = detail
                    if let logo = try? client.imageRequest(for: detail, type: .logo, maxWidth: 700) {
                        _ = try? await ArtworkCache.shared.image(for: logo)
                    }
                }
            }
        }
    }

    private func arrow(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            move(by: offset)
        } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                .frame(width: 44).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func move(by offset: Int, resetTimer: Bool = true) {
        guard videos.count > 1 else { return }
        index = FeaturedRecommendations.nextIndex(from: index, by: offset, count: videos.count)
        if resetTimer { restartClock = UUID() }
    }

    private func select(_ position: Int) {
        index = position
        restartClock = UUID()
    }
}
