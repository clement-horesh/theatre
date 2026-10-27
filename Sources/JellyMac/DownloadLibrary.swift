import Combine
import Foundation
import JellyfinKit

/// Combines the existing account catalogs without moving their files or mixing their tokens.
@MainActor
final class DownloadLibrary: ObservableObject {
    @Published private(set) var catalogRevision = 0
    private var managers: [String: DownloadManager] = [:]
    private var observations: [String: AnyCancellable] = [:]
    private let initialManager: DownloadManager
    private var usedInitialManager = false
    private var retiredManagers: [String: DownloadManager] = [:]
    private var retiredTasks: [Task<Void, Never>] = []

    init(manager: DownloadManager) { initialManager = manager }

    var accounts: [DownloadManager] { managers.keys.sorted().compactMap { managers[$0] } }
    var records: [DownloadRecord] { accounts.flatMap(\.records) }
    var titles: [VideoItem] {
        managers.values.flatMap(\.titles).sorted {
            let order = ($0.sortName ?? $0.name).localizedStandardCompare($1.sortName ?? $1.name)
            return order == .orderedSame ? $0.libraryID < $1.libraryID : order == .orderedAscending
        }
    }
    var isLoadingCatalog: Bool { managers.values.contains { $0.isLoadingCatalog } }
    var usedBytes: Int64 { managers.values.reduce(0) { $0 + $1.usedBytes } }
    var availableBytes: Int64? { managers.values.compactMap(\.availableBytes).min() }
    var storageURL: URL { initialManager.storageURL }
    var pendingSync: Task<Void, Never> {
        let tasks = managers.values.compactMap(\.pendingSync)
        return Task { for task in tasks { await task.value } }
    }

    func manager(serverID: String?) -> DownloadManager? {
        guard let serverID else { return managers.count == 1 ? managers.values.first : nil }
        return managers[serverID]
    }

    func configure(clients: [JellyfinClient]) {
        let ids = Set(clients.map(\.serverID))
        for id in managers.keys where !ids.contains(id) {
            guard let manager = managers.removeValue(forKey: id) else { continue }
            observations[id] = nil
            manager.configure(client: nil)
            retiredManagers[id] = manager
            retiredTasks.append(
                Task {
                    await manager.waitUntilReady()
                    await manager.flush()
                })
        }
        for client in clients {
            if let manager = managers[client.serverID] {
                manager.configure(client: client)
                continue
            }
            let manager =
                retiredManagers.removeValue(forKey: client.serverID)
                ?? (usedInitialManager ? initialManager.sibling() : initialManager)
            usedInitialManager = true
            managers[client.serverID] = manager
            manager.configure(client: client)
            observations[client.serverID] = manager.$catalogRevision.dropFirst().sink { [weak self] _ in
                self?.catalogRevision += 1
            }
        }
        catalogRevision += 1
    }

    func waitUntilReady() async { for manager in managers.values { await manager.waitUntilReady() } }
    func checkLocalFiles() async { for manager in managers.values { await manager.checkLocalFiles() } }
    func flush() async { for manager in managers.values { await manager.flush() } }
    func shutdown() async {
        for manager in managers.values { await manager.shutdown() }
        for task in retiredTasks { await task.value }
        retiredTasks = []
    }
    func synchronize() { for manager in managers.values { manager.synchronize() } }
    func record(for video: VideoItem) -> DownloadRecord? { manager(serverID: video.serverID)?.record(for: video) }
    func playbackStream(for video: VideoItem) -> PlaybackStream? {
        manager(serverID: video.serverID)?.playbackStream(for: video)
    }
    func cachedVideo(id: String) -> VideoItem? {
        for (serverID, manager) in managers where id.hasPrefix(serverID + "|") {
            return manager.cachedVideo(id: String(id.dropFirst(serverID.count + 1)))
        }
        return managers.count == 1 ? managers.values.first?.cachedVideo(id: id) : nil
    }
    func episodes(seriesID: String, completedOnly: Bool = true) -> [VideoItem] {
        records.filter {
            $0.state != .removed && $0.video.seriesLibraryID == seriesID && (!completedOnly || $0.state == .complete)
        }
        .map(\.displayedVideo).sorted {
            ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name)
                < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
        }
    }
    func start(_ video: VideoItem) { manager(serverID: video.serverID)?.start(video) }
    func pause(_ record: DownloadRecord) async { await manager(serverID: record.video.serverID)?.pause(record) }
    func remove(_ record: DownloadRecord) async { await manager(serverID: record.video.serverID)?.remove(record) }
    func setWatched(_ watched: Bool, video: VideoItem) {
        manager(serverID: video.serverID)?.setWatched(watched, video: video)
    }
}
