import AppKit
import SwiftUI

@main
struct JellyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Theatre") {
            ContentView(model: model).frame(minWidth: 900, minHeight: 580)
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
        Window("Jellyfin Informations", id: "jellyfin-information") {
            JellyfinInformationView(model: model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

private struct JellyfinCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Jellyfin Informations…") {
                openWindow(id: "jellyfin-information")
            }
            .keyboardShortcut(",", modifiers: .command)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
