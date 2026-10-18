import AppKit
import Sparkle

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let adapter = AppUpdater()
    let driver = SmokeDriver()
    var engine: SPUUpdater?
    let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "TheatreSmokeRoot") as! String)
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("prepared").path) else { exit(6) }
            try! Data("Installed and relaunched version 2".utf8).write(to: root.appendingPathComponent("success"))
            exit(0)
        }
        adapter.prepareForInstallation = { [root] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            try! Data("Prepared before installation".utf8).write(to: root.appendingPathComponent("prepared"))
        }
        driver.onFound = { [weak self] item in
            guard self?.adapter.availableVersion == "2.0" else { exit(5) }
            NSLog("SMOKE: Adapter reports available version %@", item!.displayVersionString)
        }
        let updater = SPUUpdater(
            hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: driver, delegate: adapter)
        engine = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            NSLog("SMOKE START ERROR: %@", String(describing: error))
            exit(7)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(8) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

@main enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
