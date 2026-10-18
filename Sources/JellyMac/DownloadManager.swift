import AppKit
import Combine
import CryptoKit
import Foundation
import JellyfinKit
import OSLog

/// A small account-scoped catalog; large media files are transferred by URLSession.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncError: String?
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var catalogRevision = 0
    private(set) var titles: [VideoItem] = []
    private(set) var directory: URL?
    private var client: JellyfinClient?
    private let root: URL
    private let configuration: URLSessionConfiguration
    private let assets: URLSession
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var transfers: [UUID: DownloadTransfer] = [:]
    private var syncTask: Task<Void, Never>?
    private var generation = UUID()
    private var catalogReadable = true
    private let availableSpace: (() -> Int64?)?
    @Published private var freeBytes: Int64?
    private let files = DownloadFileIO()
    private var catalogTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var fileOperations: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var pendingSaves: [URL: [DownloadRecord]] = [:]
    private var queued: [UUID] = []
    private var activeDownloads = Set<UUID>()
    private var isShuttingDown = false
    private let maximumConcurrentDownloads: Int
    private var recordsByVideo: [String: Int] = [:]
    private var recordsBySeries: [String: [DownloadRecord]] = [:]
    private let logger = Logger(subsystem: "local.jellymac.app", category: "Downloads")

    init(
        root: URL? = nil, configuration: URLSessionConfiguration = .ephemeral,
        availableSpace: (() -> Int64?)? = nil, maximumConcurrentDownloads: Int = 2
    ) {
        self.availableSpace = availableSpace
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theatre/Downloads", isDirectory: true)
        self.configuration = configuration
        self.configuration.httpMaximumConnectionsPerHost = 2
        self.configuration.waitsForConnectivity = true
        assets = URLSession(configuration: configuration)
    }

    deinit {
        for task in preparations.values { task.cancel() }
        for transfer in transfers.values { transfer.cancel() }
        syncTask?.cancel()
        catalogTask?.cancel()
        assets.invalidateAndCancel()
    }

    static func accountKey(_ client: JellyfinClient) -> String {
        digest("\(client.serverURL.absoluteString)|\(client.session?.userID ?? "")")
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func configure(client: JellyfinClient?) {
        let next = client.map { root.appendingPathComponent(Self.accountKey($0), isDirectory: true) }
        guard directory != next else {
            self.client = client
            return
        }
        // Finish old-account writes and native pause data before loading another catalog.
        let previousCatalog = catalogTask
        previousCatalog?.cancel()
        for task in preparations.values { task.cancel() }
        preparations.removeAll()
        let oldDirectory = directory
        let oldTransfers = transfers
        let oldOperations = fileOperations.values.map(\.task)
        fileOperations.removeAll()
        for index in records.indices where records[index].isActive || records[index].state == .pausing {
            records[index].state = .paused
        }
        save()
        let previousSave = saveTask
        transfers.removeAll()
        queued.removeAll()
        activeDownloads.removeAll()
        syncTask?.cancel()
        syncTask = nil
        generation = UUID()
        let current = generation
        self.client = client
        directory = next
        records = []
        rebuildCatalog()
        catalogReadable = true
        errorMessage = nil
        syncError = nil
        freeBytes = nil
        isShuttingDown = false
        ArtworkCache.shared.setLocalArtwork([:])
        isLoadingCatalog = next != nil
        let files = files
        catalogTask = Task { [weak self] in
            await previousCatalog?.value
            await previousSave?.value
            for operation in oldOperations { await operation.value }
            for (id, transfer) in oldTransfers {
                if let data = await transfer.pause(), let oldDirectory {
                    let url = oldDirectory.appendingPathComponent(id.uuidString).appendingPathComponent("resume.data")
                    try? await files.perform { try data.write(to: url, options: .atomic) }
                }
            }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            defer {
                if self.generation == current {
                    self.isLoadingCatalog = false
                    self.rebuildCatalog()
                }
            }
            guard let next else { return }
            do {
                let loaded = try await files.perform {
                    let manifest = next.appendingPathComponent("catalog.json")
                    guard FileManager.default.fileExists(atPath: manifest.path) else { return [DownloadRecord]() }
                    return try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
                }
                guard self.generation == current, !Task.isCancelled else { return }
                self.records = loaded.map { record in
                    var record = record
                    if record.isActive || record.state == .pausing { record.state = .paused }
                    return record
                }
                self.rebuildCatalog()
                await self.checkLocalFiles()
                guard self.generation == current, !Task.isCancelled else { return }
                self.registerArtwork()
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.catalogReadable = false
                self.errorMessage = "Saved downloads couldn’t be read. Your files have been kept."
            }
        }
    }

    func waitUntilReady() async {
        while let task = catalogTask {
            let current = generation
            await task.value
            if generation == current { return }
        }
    }

    func flush() async {
        while let task = saveTask { await task.value }
    }

    func record(for video: VideoItem) -> DownloadRecord? {
        recordsByVideo[video.id].map { records[$0] }
    }
    func cachedVideo(id: String) -> VideoItem? {
        if let index = recordsByVideo[id] {
            return records[index].displayedVideo
        }
        let group = recordsBySeries[id] ?? []
        guard var show = (group.first(where: \.prepared) ?? group.first)?.series else {
            return nil
        }
        let episodes = episodes(seriesID: id)
        if !episodes.isEmpty {
            show.userData = VideoUserData(
                played: episodes.allSatisfy { $0.userData?.played == true }, seconds: 0,
                lastPlayedDate: "", unplayedItemCount: episodes.filter { $0.userData?.played != true }.count)
        }
        return show
    }
    func episodes(seriesID: String, completedOnly: Bool = true) -> [VideoItem] {
        (recordsBySeries[seriesID] ?? []).filter {
            !completedOnly || $0.state == .complete
        }
        .map(\.displayedVideo).sorted {
            ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name)
                < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
        }
    }
    var pendingSync: Task<Void, Never>? { syncTask }
    var storageURL: URL { directory ?? root }
    var usedBytes: Int64 { records.reduce(0) { $0 + $1.received } }
    var availableBytes: Int64? { availableSpace?() ?? freeBytes }

    func checkLocalFiles() async {
        let current = generation
        let revision = catalogRevision
        let candidates = records.filter { $0.state == .complete }.map { ($0.id, fileURL($0, name: $0.videoFile)) }
        let location = directory ?? root
        let result = try? await files.perform {
            let missing = Set(
                candidates.compactMap { id, url in
                    url.map { FileManager.default.fileExists(atPath: $0.path) } == true ? nil : id
                })
            var existing = location
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            let free =
                (try? FileManager.default.attributesOfFileSystem(forPath: existing.path)[.systemFreeSize] as? NSNumber)?
                .int64Value
            return (missing, free)
        }
        guard generation == current, !Task.isCancelled, let (missing, free) = result else { return }
        freeBytes = free
        // A removal or replacement during the disk check invalidates its missing-file snapshot.
        guard catalogRevision == revision else { return }
        var changed = false
        for index in records.indices where records[index].state == .complete && missing.contains(records[index].id) {
            records[index].state = .failed
            records[index].error = "The downloaded file was removed. Download it again."
            records[index].received = 0
            changed = true
        }
        if changed { save() }
    }

    private func checkStorage(for record: DownloadRecord) throws {
        guard let free = availableBytes else { return }
        let reserved = records.filter { $0.id != record.id && ($0.state == .preparing || $0.state == .downloading) }
            .reduce(Int64(0)) {
                let sum = $0.addingReportingOverflow($1.remainingBytes)
                return sum.overflow ? Int64.max : sum.partialValue
            }
        if record.remainingBytes > max(0, free - min(max(0, free), reserved)) {
            throw JellyfinDownloadError.diskSpace
        }
    }

    func playbackStream(for video: VideoItem) -> PlaybackStream? {
        guard let record = record(for: video), let file = localFile(record), record.state == .complete else {
            return nil
        }
        var stream = PlaybackStream(
            url: file, itemID: video.id, mediaSourceID: record.sourceID,
            playSessionID: "", method: "DirectPlay")
        let localDate =
            record.progress?.updated ?? Self.watchedDate(record.video.userData?.lastPlayedDate) ?? .distantPast
        let remoteDate = Self.watchedDate(video.userData?.lastPlayedDate) ?? .distantPast
        stream.resumePositionSeconds =
            remoteDate > localDate
            ? video.resumePositionSeconds : record.displayedVideo.resumePositionSeconds
        stream.externalSubtitles = record.subtitles.compactMap {
            guard let url = fileURL(record, name: $0.file), FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return PlaybackSubtitle(id: $0.index, name: $0.name, url: url)
        }
        return stream
    }

    func start(_ video: VideoItem) {
        guard !isShuttingDown else { return }
        if isLoadingCatalog {
            let current = generation
            Task { [weak self] in
                await self?.waitUntilReady()
                guard let self, self.generation == current else { return }
                self.start(video)
            }
            return
        }
        guard catalogReadable, client != nil, directory != nil, video.type == "Movie" || video.type == "Episode" else {
            return
        }
        if let existing = record(for: video),
            existing.isActive || existing.state == .pausing
                || (existing.state == .complete && localFile(existing) != nil)
        {
            return
        }
        let existing = records.first { $0.video.id == video.id }
        let id = existing?.id ?? UUID()
        if existing == nil {
            let series = video.seriesID.map {
                cachedVideo(id: $0) ?? VideoItem(id: $0, name: video.seriesName ?? "Show", type: "Series")
            }
            records.append(DownloadRecord(id: id, video: video, series: series))
        }
        update(id) {
            $0.state = .queued
            $0.error = nil
        }
        queued.append(id)
        drainQueue()
    }

    private func drainQueue() {
        guard !isShuttingDown, !isLoadingCatalog, let client, let directory else { return }
        while activeDownloads.count < maximumConcurrentDownloads, !queued.isEmpty {
            guard let index = queued.firstIndex(where: { !activeDownloads.contains($0) && fileOperations[$0] == nil })
            else {
                return
            }
            let id = queued.remove(at: index)
            guard let record = records.first(where: { $0.id == id && $0.state == .queued }) else { continue }
            activeDownloads.insert(id)
            launch(record.video, id: id, client: client, directory: directory)
        }
    }

    private func launch(_ video: VideoItem, id: UUID, client: JellyfinClient, directory: URL) {
        update(id) { $0.state = .preparing }
        let current = generation
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
                try await self.files.perform {
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    var excluded = directory
                    try excluded.setResourceValues(values)
                }
                try Task.checkCancellation()
                guard self.generation == current else { return }
                await self.checkLocalFiles()
                if self.records.first(where: { $0.id == id })?.prepared != true {
                    try await self.prepare(id: id, video: video, client: client, generation: current)
                }
                try Task.checkCancellation()
                guard self.generation == current, let record = self.records.first(where: { $0.id == id }) else {
                    return
                }
                let resumeURL = folder.appendingPathComponent("resume.data")
                let resumeData = try await self.files.perform { try? Data(contentsOf: resumeURL) }
                try Task.checkCancellation()
                guard self.generation == current else { return }
                if resumeData == nil { self.update(id, persist: false) { $0.received = 0 } }
                await self.checkLocalFiles()
                try Task.checkCancellation()
                guard self.generation == current else { return }
                if let currentRecord = self.records.first(where: { $0.id == id }) {
                    try self.checkStorage(for: currentRecord)
                }
                let token = UUID()
                let transfer = DownloadTransfer(
                    id: token, request: try client.downloadRequest(itemID: video.id), resumeData: resumeData,
                    destination: folder.appendingPathComponent(record.videoFile), configuration: self.configuration,
                    onProgress: { [weak self] received, expected in
                        guard let self, self.generation == current, self.transfers[id]?.id == token else { return }
                        self.update(id, persist: false) {
                            $0.received = received
                            $0.expected = max(expected, $0.expected)
                        }
                    },
                    onComplete: { [weak self] result in
                        Task { [weak self] in
                            await self?.complete(
                                result, id: id, token: token, generation: current,
                                resumeURL: resumeURL, wasResumed: resumeData != nil)
                        }
                    })
                self.transfers[id] = transfer
                self.preparations[id] = nil
                self.update(id) { $0.state = .downloading }
                self.registerArtwork()
                transfer.start()
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.preparations[id] = nil
                self.activeDownloads.remove(id)
                self.update(id) {
                    $0.state = .failed
                    $0.error = JellyfinDownloadError.message(for: error)
                }
                self.drainQueue()
            }
        }
    }

    private func complete(
        _ result: Result<Int64, Error>, id: UUID, token: UUID,
        generation current: UUID, resumeURL: URL, wasResumed: Bool
    ) async {
        guard generation == current, transfers[id]?.id == token else { return }
        // Keep the slot occupied until completion bookkeeping finishes.
        defer {
            if generation == current {
                transfers[id] = nil
                activeDownloads.remove(id)
                drainQueue()
            }
        }
        switch result {
        case .success(let size):
            update(id) {
                $0.state = .complete
                $0.received = size
                $0.expected = size
            }
            try? await files.perform { try FileManager.default.removeItem(at: resumeURL) }
        case .failure(let error):
            let nativeError = error as NSError
            let retryFresh =
                wasResumed
                && ((nativeError.domain == NSURLErrorDomain
                    && [NSURLErrorCannotOpenFile, NSURLErrorFileDoesNotExist, NSURLErrorUnknown].contains(
                        nativeError.code))
                    || (error as? JellyfinDownloadError) == .signIn)
            let data = retryFresh ? nil : nativeError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            try? await files.perform {
                if let data {
                    try data.write(to: resumeURL, options: .atomic)
                } else if FileManager.default.fileExists(atPath: resumeURL.path) {
                    try FileManager.default.removeItem(at: resumeURL)
                }
            }
            guard generation == current, transfers[id]?.id == token else { return }
            update(id) {
                $0.state = retryFresh ? .paused : .failed
                $0.error = retryFresh ? nil : JellyfinDownloadError.message(for: error)
                if retryFresh { $0.received = 0 }
            }
            if retryFresh {
                update(id) { $0.state = .queued }
                queued.append(id)
            }
        }
    }

    func pause(_ record: DownloadRecord) async {
        let current = generation
        if let operation = fileOperations[record.id] {
            await operation.task.value
            guard generation == current else { return }
            if fileOperations[record.id]?.token == operation.token { fileOperations[record.id] = nil }
        }
        guard records.contains(where: { $0.id == record.id && $0.isActive }) else { return }
        queued.removeAll { $0 == record.id }
        let preparation = preparations.removeValue(forKey: record.id)
        preparation?.cancel()
        let transfer = transfers.removeValue(forKey: record.id)
        let resumeURL = fileURL(record, name: "resume.data")
        update(record.id) { $0.state = .pausing }
        let token = UUID()
        let operation = Task {
            await preparation?.value
            if let data = await transfer?.pause(), let resumeURL {
                try? await files.perform { try data.write(to: resumeURL, options: .atomic) }
            }
            guard generation == current else { return }
            activeDownloads.remove(record.id)
            if records.first(where: { $0.id == record.id })?.state == .pausing {
                update(record.id) { $0.state = .paused }
                registerArtwork()
            }
            drainQueue()
        }
        fileOperations[record.id] = (token, operation)
        await operation.value
        if fileOperations[record.id]?.token == token {
            fileOperations[record.id] = nil
            drainQueue()
        }
    }

    func remove(_ record: DownloadRecord) async {
        guard let original = records.first(where: { $0.id == record.id }), original.state != .removed else { return }
        queued.removeAll { $0 == record.id }
        let preparation = preparations.removeValue(forKey: record.id)
        preparation?.cancel()
        transfers.removeValue(forKey: record.id)?.cancel()
        let current = generation
        let resumeURL = fileURL(record, name: "resume.data")
        guard let folder = directory?.appendingPathComponent(record.id.uuidString) else { return }
        // Persist the removal before deleting files. An account switch during I/O
        // must not restore this record or discard pending watch progress.
        if original.progress?.pendingSync == true {
            update(record.id) {
                $0.state = .removed
                $0.received = 0
                $0.artworks = [:]
                $0.subtitles = []
                $0.prepared = false
            }
        } else {
            records.removeAll { $0.id == record.id }
            save()
        }
        registerArtwork()
        let previous = fileOperations[record.id]?.task
        let token = UUID()
        let operation = Task {
            defer {
                if generation == current {
                    activeDownloads.remove(record.id)
                    drainQueue()
                }
            }
            await previous?.value
            await preparation?.value
            await flush()
            do {
                let data = try await files.perform {
                    let data = resumeURL.flatMap { try? Data(contentsOf: $0) }
                    if FileManager.default.fileExists(atPath: folder.path) {
                        try FileManager.default.removeItem(at: folder)
                    }
                    return data
                }
                if let data { assets.downloadTask(withResumeData: data).cancel() }
            } catch {
                guard generation == current else { return }
                if self.record(for: original.video) == nil {
                    var restored = records.first(where: { $0.id == record.id }) ?? original
                    restored.state = .failed
                    records.removeAll { $0.id == record.id }
                    records.append(restored)
                    save()
                    registerArtwork()
                }
                errorMessage = "The download couldn’t be removed: \(error.localizedDescription)"
            }
        }
        fileOperations[record.id] = (token, operation)
        await operation.value
        if fileOperations[record.id]?.token == token {
            fileOperations[record.id] = nil
            drainQueue()
        }
    }

    func shutdown() async {
        isShuttingDown = true
        await waitUntilReady()
        let finishing = fileOperations.values.map(\.task)
        for operation in finishing { await operation.value }
        for record in records where record.isActive { await pause(record) }
        save()
        await flush()
    }

    func saveProgress(
        itemID: String, seconds: Double, duration: Double, paused: Bool, finished: Bool = false, force: Bool = false
    ) {
        guard seconds.isFinite, seconds >= 0, let record = records.first(where: { $0.video.id == itemID }) else {
            return
        }
        if let previous = record.progress, !force, !finished, previous.paused == paused,
            abs(seconds - Double(previous.data.playbackPositionTicks ?? 0) / 10_000_000) < 10
        {
            return
        }
        let now = Date()
        let position = duration.isFinite && duration > 0 ? min(seconds, duration) : seconds
        let data = VideoUserData(
            played: finished || record.displayedVideo.userData?.played == true,
            seconds: finished ? 0 : position, lastPlayedDate: ISO8601DateFormatter().string(from: now))
        update(record.id) { $0.progress = .init(data: data, updated: now, paused: paused) }
    }

    func setWatched(_ watched: Bool, video: VideoItem) {
        let targets = video.type == "Series" ? episodes(seriesID: video.id, completedOnly: false) : [video]
        for item in targets {
            guard let record = record(for: item) else { continue }
            let now = Date()
            let data = VideoUserData(
                played: watched, seconds: 0, lastPlayedDate: ISO8601DateFormatter().string(from: now))
            update(record.id) { $0.progress = .init(data: data, updated: now) }
        }
        synchronize()
    }

    func synchronize() {
        guard syncTask == nil, let client, records.contains(where: { $0.progress?.pendingSync == true }) else { return }
        let current = generation
        let pending = records.filter { $0.progress?.pendingSync == true }
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.syncTask = nil } }
            for record in pending {
                guard let progress = record.progress, self.generation == current, !Task.isCancelled else { return }
                do {
                    let remote = try await client.item(id: record.video.id)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    // Preserve a newer viewing session from another device.
                    let date = Self.watchedDate(remote.userData?.lastPlayedDate)
                    let newer = date.map { $0 > progress.updated } == true
                    if !newer { try await client.saveOfflineProgress(itemID: record.video.id, data: progress.data) }
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.update(record.id) {
                        guard $0.progress == progress else { return }
                        if newer { $0.progress?.data = remote.userData ?? progress.data }
                        $0.progress?.pendingSync = false
                    }
                    self.records.removeAll { $0.state == .removed && $0.progress?.pendingSync != true }
                    self.save()
                    self.syncError = nil
                } catch {
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.syncError =
                        "Offline watch progress is saved on this Mac and will sync when Jellyfin is available."
                    return
                }
            }
        }
    }

    private func prepare(id: UUID, video: VideoItem, client: JellyfinClient, generation current: UUID) async throws {
        let detail = try await client.item(id: video.id)
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let source = detail.mediaSources?.first
        let ext = (source?.container ?? "media").components(separatedBy: ",").first ?? "media"
        let safeExtension =
            ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && ext.count <= 12 ? ext : "media"
        update(id, persist: false) {
            $0.video = detail
            $0.sourceID = source?.id ?? detail.id
            $0.videoFile = "video.\(safeExtension)"
            $0.expected = source?.size ?? 0
        }
        if let record = records.first(where: { $0.id == id }) { try checkStorage(for: record) }
        if let seriesID = detail.seriesID {
            let series = try await client.item(id: seriesID)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id, persist: false) { $0.series = series }
            let next = try? await client.nextEpisode(after: detail)
            let markers = (try? await client.mediaSegments(itemID: detail.id)) ?? []
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id, persist: false) {
                $0.nextEpisodeID = next?.id
                $0.creditsStart = markers.filter { $0.type == "Outro" && $0.startTicks > 0 }.map(\.startSeconds).min()
                $0.intro = markers.filter { $0.type == "Intro" && $0.isSkippable }.min { $0.startTicks < $1.startTicks }
            }
        }
        guard let record = records.first(where: { $0.id == id }) else { throw CancellationError() }
        for item in [record.video, record.series].compactMap({ $0 }) {
            for type in [JellyfinImageType.primary, .backdrop, .logo] {
                if let request = try client.imageRequest(
                    for: item, type: type, maxWidth: type == .backdrop ? 2560 : 900)
                {
                    try await cacheArtwork(request, id: id, generation: current)
                }
            }
            for person in (item.people ?? []).prefix(16) {
                if let request = try client.imageRequest(for: person, maxWidth: 400) {
                    try await cacheArtwork(request, id: id, generation: current)
                }
            }
        }
        for track in detail.detailStreams where track.type == "Subtitle" && track.isExternal == true {
            guard let index = track.index else { continue }
            let format: String
            switch track.codec?.lowercased() {
            case "ass", "ssa": format = "ass"
            case "pgssub", "hdmv_pgs_subtitle", "pgs", "sup": format = "sup"
            case "dvdsub", "dvd_subtitle", "vobsub": format = "sub"
            default: format = "srt"
            }
            let request = try client.subtitleDownloadRequest(
                itemID: detail.id, sourceID: source?.id ?? detail.id, index: index, format: format)
            let (temporary, response) = try await assets.download(for: request, delegate: JellyfinRedirectPolicy.shared)
            guard !Task.isCancelled, generation == current,
                (response as? HTTPURLResponse)?.statusCode == 200
            else {
                try? await files.perform { try FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                throw JellyfinDownloadError.invalidFile
            }
            let name = "subtitle-\(index).\(format)"
            guard let url = fileURL(record, name: name) else { throw CancellationError() }
            try await files.perform {
                defer { try? FileManager.default.removeItem(at: temporary) }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id, persist: false) {
                $0.subtitles.removeAll { $0.index == index }
                $0.subtitles.append(.init(index: index, name: track.label, file: name))
            }
        }
        update(id, persist: false) { $0.prepared = true }
    }

    private func cacheArtwork(_ request: URLRequest, id: UUID, generation current: UUID) async throws {
        do {
            let (data, response) = try await assets.data(for: request, delegate: JellyfinRedirectPolicy.shared)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil,
                let record = records.first(where: { $0.id == id })
            else { return }
            let key = ArtworkCache.localKey(request)
            let name = "art-\(Self.digest(key)).image"
            guard let url = fileURL(record, name: name) else { return }
            try await files.perform { try data.write(to: url, options: .atomic) }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id, persist: false) { $0.artworks[key] = name }
        } catch {
            try Task.checkCancellation()
            // Missing artwork doesn't prevent downloading a playable video.
        }
    }

    private static func watchedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func localFile(_ record: DownloadRecord) -> URL? {
        guard let file = fileURL(record, name: record.videoFile), FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }
    private func fileURL(_ record: DownloadRecord, name: String) -> URL? {
        guard !name.isEmpty, (name as NSString).lastPathComponent == name else { return nil }
        return directory?.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(name)
    }
    private func update(_ id: UUID, persist: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if persist { save() }
    }
    private func registerArtwork() {
        var files: [String: URL] = [:]
        for record in records {
            for (key, name) in record.artworks {
                if let url = fileURL(record, name: name) { files[key] = url }
            }
        }
        ArtworkCache.shared.setLocalArtwork(files)
    }
    private func rebuildCatalog() {
        recordsByVideo = [:]
        recordsBySeries = [:]
        var nextTitles: [VideoItem] = []
        for (index, record) in records.enumerated() where record.state != .removed {
            recordsByVideo[record.video.id] = index
            if let seriesID = record.video.seriesID {
                recordsBySeries[seriesID, default: []].append(record)
            }
            if record.video.type == "Movie" { nextTitles.append(record.displayedVideo) }
        }
        for group in recordsBySeries.values {
            guard let first = group.first else { continue }
            let show = (group.first(where: \.prepared) ?? first).series ?? first.displayedVideo
            nextTitles.append(cachedVideo(id: show.id) ?? show)
        }
        titles = nextTitles.sorted {
            ($0.sortName ?? $0.name).localizedStandardCompare($1.sortName ?? $1.name) == .orderedAscending
        }
        catalogRevision += 1
    }

    private func save() {
        rebuildCatalog()
        guard catalogReadable, !isLoadingCatalog, let directory else { return }
        pendingSaves[directory] = records
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.saveTask = nil }
            while let (directory, snapshot) = self.pendingSaves.first {
                self.pendingSaves[directory] = nil
                do {
                    try await self.files.perform {
                        guard !snapshot.isEmpty || FileManager.default.fileExists(atPath: directory.path) else {
                            return
                        }
                        try FileManager.default.createDirectory(
                            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let file = directory.appendingPathComponent("catalog.json")
                        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                } catch {
                    let failure = error as NSError
                    self.logger.error(
                        "Catalog write failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                    if self.directory == directory {
                        self.errorMessage = "Downloads couldn’t be saved: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
