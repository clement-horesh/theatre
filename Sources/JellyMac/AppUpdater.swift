import Combine
import Foundation
import OSLog
import Sparkle
import SwiftUI

/// Sparkle owns checking, downloading and installing; this object exposes its state to the menus.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var configurationError: String?
    var prepareForInstallation: (() async -> Void)?
    private var controller: SPUStandardUpdaterController?
    private let logger = Logger(subsystem: "local.jellymac.app", category: "Updates")

    func start() {
        guard controller == nil, configurationError == nil else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            configurationError = "Updates are available in the packaged Theatre app."
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        do {
            try controller.updater.start()
        } catch {
            configurationError = "The updater could not start. Reinstall Theatre from its GitHub release."
            logger.error("Updater startup failed (code \((error as NSError).code))")
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if choice == .skip { availableVersion = nil }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks only update the menu indicator, including during playback.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Task { @MainActor [weak self] in self?.availableVersion = version }
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let prepareForInstallation else { return false }
        Task {
            await prepareForInstallation()
            installHandler()
        }
        return true
    }
}

struct UpdateMenu: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Menu(updater.availableVersion == nil ? "Update App" : "Update App ●") {
            if let version = updater.availableVersion {
                Text("Version \(version) Available")
            }
            Button(updater.availableVersion == nil ? "Check for Updates…" : "Install Update…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Toggle(
                "Automatically Check for Updates",
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticallyChecksForUpdates)
            )
            .disabled(updater.configurationError != nil)
            if let error = updater.configurationError {
                Text(error)
            } else if let lastCheck = updater.lastCheck {
                Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}
