import AVFoundation
import AppKit
import SwiftUI

struct PlayerPane: View {
    @ObservedObject var model: PlaybackSession
    @ObservedObject var playback: PlaybackController
    @StateObject private var chrome = PlayerChromeState()
    @State private var scrubSeconds = 0.0
    @State private var isScrubbing = false
    @State private var showsSubtitleAppearance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isActivelyPlaying: Bool {
        playback.isPlaying && !playback.hasEnded && playback.errorMessage == nil && model.playbackError == nil
    }

    var body: some View {
        ZStack {
            Color.black
            Group {
                if playback.usesApplePlayback {
                    ApplePlayerView(playback: playback.applePlayback)
                } else {
                    VLCPlayerView(playback: playback)
                }
            }
            .onTapGesture(count: 2) { model.toggleVideoFullscreen() }
            .onTapGesture { showControls() }
            playerControls
                .opacity(chrome.isVisible ? 1 : 0)
                .allowsHitTesting(chrome.isVisible)
                .accessibilityHidden(!chrome.isVisible)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chrome.isVisible)
            if model.offersNextEpisode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GlassPlayButton(resume: false, disabled: model.isStartingPlayback, title: "Next Episode") {
                            model.playNextEpisode()
                        }
                    }
                }
                .padding(.trailing, 24).padding(.bottom, 90)
            }
            if model.isStartingPlayback || playback.isPreparing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing video…").font(.callout)
                }
                .padding(20).modifier(PlayerGlass(shape: .rounded(20)))
            }
            if let error = model.playbackError ?? playback.errorMessage {
                VStack(spacing: 12) {
                    Label("Playback unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button("Try compatible stream") { model.retryCompatible() }
                }
                .padding(20).frame(maxWidth: 380).modifier(PlayerGlass(shape: .rounded(20)))
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background {
            GeometryReader { geometry in
                PlayerCursorVisibility(
                    controlsHidden: !chrome.isVisible, hidesCursor: isActivelyPlaying,
                    onActivity: { chrome.pointerEnteredWindow(isPlaying: isActivelyPlaying) },
                    onWindowExit: {
                        if !model.isVideoFullscreen { chrome.pointerExitedWindow() }
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear { showControls() }
        .onDisappear { chrome.cancel() }
        .onChange(of: playback.isPlaying) { _ in showControls() }
        .onChange(of: playback.hasEnded) { _ in showControls() }
        .onChange(of: playback.errorMessage) { _ in showControls() }
        .onChange(of: model.currentVideo?.id) { _ in showControls() }
        .onChange(of: model.isVideoFullscreen) { _ in showControls() }
        .alert(
            "Playback option unavailable",
            isPresented: Binding(
                get: { model.presentationError != nil },
                set: { if !$0 { model.presentationError = nil } }
            )
        ) {
            Button("OK") { model.presentationError = nil }
        } message: {
            Text(model.presentationError ?? "")
        }
    }

    private var playerControls: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 16) { playerControlsContent }
            } else {
                playerControlsContent
            }
        }
    }

    private var playerControlsContent: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            ).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    presentationControls
                        .padding(.top, model.isVideoFullscreen ? 28 : 0)
                    Spacer()
                    volumeControl
                }
                .padding(.top, model.isVideoFullscreen ? 0 : 28)
                Spacer(minLength: 16)
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let video = model.currentVideo, let series = video.seriesName {
                            let episode = [
                                video.parentIndexNumber.map { "S\($0)" }, video.indexNumber.map { "E\($0)" },
                            ]
                            .compactMap { $0 }.joined(separator: ", ")
                            Text(episode.isEmpty ? video.name : "\(episode) · \(video.name)")
                                .font(.caption).lineLimit(1)
                            Text(series).font(.title2.weight(.semibold)).lineLimit(2)
                        } else {
                            Text(model.currentVideo?.name ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                        }

                    }
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    Spacer(minLength: 8)
                    trackControls
                }
                .padding(.bottom, 10)
                timeline
            }
            .padding(model.isVideoFullscreen ? 14 : 12)
            HStack(spacing: 32) {
                transportButton(
                    "Back 10 seconds", symbol: "gobackward.10", diameter: 48, symbolSize: 22,
                    disabled: !playback.canSeek
                ) { playback.seek(by: -10) }
                transportButton(
                    playback.isPlaying ? "Pause" : (playback.hasEnded ? "Replay" : "Play"),
                    symbol: playback.isPlaying ? "pause.fill" : "play.fill", diameter: 72, symbolSize: 30,
                    disabled: model.isStartingPlayback || playback.isPreparing
                ) { model.togglePlayback() }
                .accessibilityIdentifier("playPause")
                transportButton(
                    "Forward 10 seconds", symbol: "goforward.10", diameter: 48, symbolSize: 22,
                    disabled: !playback.canSeek
                ) { playback.seek(by: 10) }
            }
            .onHover { chrome.setInteraction(.transport, active: $0, isPlaying: playback.isPlaying) }
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: {
                        playback.setVolume($0)
                        showControls()
                    }), in: 0...100
            )
            .frame(width: 92).controlSize(.small).accessibilityLabel("Volume")
            Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 16)).frame(width: 22)
        }
        .tint(.white).padding(.horizontal, 12).padding(.vertical, 9)
        .modifier(PlayerGlass(shape: .capsule))
        .onHover { chrome.setInteraction(.volume, active: $0, isPlaying: playback.isPlaying) }
    }

    private var presentationControls: some View {
        HStack(spacing: 3) {
            Button {
                Task { await model.togglePictureInPicture() }
            } label: {
                Image(systemName: playback.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                    .resizable().scaledToFit()
                    .frame(width: 19, height: 17).frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                model.isPreparingSystemPlayback || model.isStartingPlayback
                    || playback.applePlayback.player.isExternalPlaybackActive
            )
            .help("Picture in Picture").accessibilityLabel("Picture in Picture")
            AirPlayPicker(
                player: playback.applePlayback.player,
                onPrepare: { Task { _ = await model.prepareSystemPlayback(reportErrors: false) } },
                onTracking: { active in
                    menuTracking(active)
                    model.routePickerTracking(active)
                }
            )
            .frame(width: 30, height: 28)
            .overlay {
                Image(systemName: "airplayvideo").font(.system(size: 17))
                    .foregroundStyle(
                        playback.applePlayback.player.isExternalPlaybackActive ? Color.accentColor : .white
                    )
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .help("AirPlay")
        }
        .padding(4).modifier(PlayerGlass(shape: .capsule))
        .onHover { chrome.setInteraction(.presentation, active: $0, isPlaying: playback.isPlaying) }
    }

    private var trackControls: some View {
        HStack(spacing: 3) {
            NativePlayerMenu(
                symbol: "captions.bubble", title: "Subtitles", identifier: "subtitleMenu",
                choices: subtitleChoices, selection: Int(playback.selectedSubtitle),
                onSelect: { playback.selectSubtitle(Int32($0)) }, onTrackingChange: menuTracking,
                onAppearance: { showsSubtitleAppearance = true }
            )
            .popover(isPresented: $showsSubtitleAppearance) {
                SubtitleAppearanceView(
                    appearance: playback.subtitleAppearance,
                    onApply: playback.applySubtitleAppearance
                )
                .preferredColorScheme(.dark)
                .onAppear { menuTracking(true) }.onDisappear { menuTracking(false) }
            }
            NativePlayerMenu(
                symbol: "waveform", title: "Audio", identifier: "audioMenu",
                choices: playback.audioTracks.filter { $0.id >= 0 }.map { .init(id: Int($0.id), title: $0.name) },
                selection: Int(playback.selectedAudio), onSelect: { playback.selectAudio(Int32($0)) },
                onTrackingChange: menuTracking)
            NativePlayerMenu(
                symbol: "speedometer", title: "Playback speed", identifier: "speedMenu",
                choices: [50, 75, 100, 125, 150, 200].map {
                    .init(id: $0, title: $0 == 100 ? "Normal" : String(format: "%g×", Double($0) / 100))
                },
                selection: Int((playback.rate * 100).rounded()),
                onSelect: { playback.setRate(Double($0) / 100) }, onTrackingChange: menuTracking)
        }
        .padding(4).modifier(PlayerGlass(shape: .capsule))
        .onHover { chrome.setInteraction(.tracks, active: $0, isPlaying: playback.isPlaying) }
    }

    private var subtitleChoices: [PlayerMenuChoice] {
        [.init(id: -1, title: "Off")]
            + playback.subtitleTracks.filter { $0.id >= 0 }.map { .init(id: Int($0.id), title: $0.name) }
    }

    private var timeline: some View {
        HStack(spacing: 9) {
            Text(clock(isScrubbing ? scrubSeconds : playback.seconds)).frame(minWidth: 32, alignment: .trailing)
            Slider(
                value: Binding(get: { isScrubbing ? scrubSeconds : playback.seconds }, set: { scrubSeconds = $0 }),
                in: 0...max(1, playback.duration),
                onEditingChanged: { editing in
                    if editing {
                        scrubSeconds = playback.seconds
                        isScrubbing = true
                    } else {
                        playback.seek(to: scrubSeconds)
                        isScrubbing = false
                    }
                    chrome.setInteraction(.scrubbing, active: editing, isPlaying: playback.isPlaying)
                }
            )
            .controlSize(.small).tint(.white).disabled(!playback.canSeek).accessibilityLabel("Playback position")
            Text("−" + clock(max(0, playback.duration - (isScrubbing ? scrubSeconds : playback.seconds))))
                .frame(minWidth: 38, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 7).modifier(PlayerGlass(shape: .capsule))
        .onHover { chrome.setInteraction(.timeline, active: $0, isPlaying: playback.isPlaying) }
    }

    private func transportButton(
        _ title: String, symbol: String, diameter: CGFloat, symbolSize: CGFloat,
        disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showControls()
        } label: {
            Image(systemName: symbol).font(.system(size: symbolSize, weight: .medium))
                .frame(width: diameter, height: diameter).contentShape(Circle())
        }
        .buttonStyle(.plain).modifier(PlayerGlass(shape: .circle))
        .disabled(disabled).help(title).accessibilityLabel(title)
    }

    private func menuTracking(_ active: Bool) {
        chrome.setInteraction(.menu, active: active, isPlaying: playback.isPlaying)
    }
    private func showControls() { chrome.activity(isPlaying: isActivelyPlaying) }
    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerGlass: ViewModifier {
    enum Shape {
        case capsule, circle
        case rounded(CGFloat)
    }
    let shape: Shape
    func body(content: Content) -> some View {
        switch shape {
        case .circle: content.glassSurface(in: Circle())
        case .capsule: content.glassSurface(in: Capsule())
        case .rounded(let radius): content.glassSurface(in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

@MainActor
final class PlayerChromeState: ObservableObject {
    enum Interaction: Hashable { case transport, volume, tracks, timeline, scrubbing, menu, presentation }
    @Published private(set) var isVisible = true
    private var hideTask: Task<Void, Never>?
    private var interactions: Set<Interaction> = []
    private var pointerInWindow = true

    func activity(isPlaying: Bool, delay: Double = 3) {
        hideTask?.cancel()
        guard pointerInWindow || !interactions.isEmpty else {
            isVisible = false
            return
        }
        isVisible = true
        guard isPlaying, interactions.isEmpty else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    func pointerEnteredWindow(isPlaying: Bool) {
        pointerInWindow = true
        activity(isPlaying: isPlaying)
    }

    func pointerExitedWindow() {
        pointerInWindow = false
        hideTask?.cancel()
        hideTask = nil
        // Finish an open menu or an active scrub without interrupting its control.
        interactions.formIntersection([.menu, .scrubbing])
        isVisible = !interactions.isEmpty
    }

    func setInteraction(_ interaction: Interaction, active: Bool, isPlaying: Bool) {
        if active { interactions.insert(interaction) } else { interactions.remove(interaction) }
        activity(isPlaying: isPlaying)
    }
    func cancel() {
        hideTask?.cancel()
        hideTask = nil
        interactions.removeAll()
    }
}
