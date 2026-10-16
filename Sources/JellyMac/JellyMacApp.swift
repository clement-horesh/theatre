import AppKit
import SwiftUI

@main
struct JellyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Theatre") {
            ContentView(model: model).onAppear { delegate.model = model }.frame(minWidth: 900, minHeight: 580)
                .preferredColorScheme(.dark)
                .modifier(PageFullscreenNavigation())
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            JellyfinCommands(model: model)
            CommandMenu("Playback") {
                Button("Play/Pause") { model.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.currentVideo == nil || !model.isPlayerWindowKey)
                Button("Back 10 Seconds") { model.playback.seek(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.currentVideo == nil || !model.isPlayerWindowKey)
                Button("Forward 10 Seconds") { model.playback.seek(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.currentVideo == nil || !model.isPlayerWindowKey)
                Divider()
                Button(model.isVideoFullscreen ? "Exit Video Full Screen" : "Enter Video Full Screen") {
                    model.toggleVideoFullscreen()
                }
                .keyboardShortcut("f", modifiers: [])
                .disabled(model.currentVideo == nil || !model.isPlayerWindowKey)
            }
        }
        Settings {
            PlaybackSettingsView(preferences: model.preferences, downloads: model.downloads).preferredColorScheme(.dark)
        }
        Window("Jellyfin Informations", id: "jellyfin-information") {
            JellyfinInformationView(model: model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        WindowGroup("Trailer", for: TrailerPresentation.self) { $trailer in
            if let trailer { TrailerView(trailer: trailer).preferredColorScheme(.dark) }
        }
        .defaultSize(width: 960, height: 540)
    }
}

private struct JellyfinCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Jellyfin Informations…") {
                openWindow(id: "jellyfin-information")
            }
            Divider()
            Button("Refresh Library") {
                Task { await model.loadVideos() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.client == nil || model.isLoading)
            Button("Sign Out") { model.signOut() }
                .disabled(model.client == nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    private var terminationTimeout: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            async let playback: Void = model.playerSession.shutdown()
            await model.downloads.shutdown()
            await playback
            finishTermination(sender)
        }
        terminationTimeout = Task {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ application: NSApplication) {
        guard terminationPending else { return }
        terminationPending = false
        terminationTimeout?.cancel()
        application.reply(toApplicationShouldTerminate: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
