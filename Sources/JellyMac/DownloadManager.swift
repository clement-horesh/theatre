import AppKit
import Combine
import CryptoKit
import Foundation
import JellyfinKit

/// A small account-scoped catalog; large media files are transferred by URLSession.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncError: String?
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

    init(root: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) {
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
        // Persist each old-account pause before detaching its catalog.
        for task in preparations.values { task.cancel() }
        preparations.removeAll()
        let oldDirectory = directory
        for (id, transfer) in transfers {
            let folder = oldDirectory?.appendingPathComponent(id.uuidString)
            Task {
                if let data = await transfer.pause(), let folder {
                    try? data.write(to: folder.appendingPathComponent("resume.data"), options: .atomic)
                }
            }
        }
        for index in records.indices where records[index].isActive || records[index].state == .pausing {
            records[index].state = .paused
        }
        save()
        transfers.removeAll()
        syncTask?.cancel()
        syncTask = nil
        generation = UUID()
        self.client = client
        directory = next
        records = []
        catalogReadable = true
        errorMessage = nil
        syncError = nil
        ArtworkCache.shared.setLocalArtwork([:])
        guard let directory else { return }
        let manifest = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        do {
            records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
            for index in records.indices {
                if records[index].isActive || records[index].state == .pausing { records[index].state = .paused }
                if records[index].state == .complete, localFile(records[index]) == nil {
                    records[index].state = .failed
                    records[index].error = "The downloaded file was removed. Download it again."
                }
            }
            registerArtwork()
        } catch {
            catalogReadable = false
            errorMessage = "Saved downloads couldn’t be read. Your files have been kept."
        }
    }

    func record(for video: VideoItem) -> DownloadRecord? {
        records.first { $0.video.id == video.id && $0.state != .removed }
    }
    func cachedVideo(id: String) -> VideoItem? {
        if let record = records.first(where: { $0.video.id == id && $0.state != .removed }) {
            return record.displayedVideo
        }
        let group = records.filter { $0.series?.id == id && $0.state != .removed }
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
        records.filter {
            $0.state != .removed && $0.video.seriesID == seriesID
                && (!completedOnly || ($0.state == .complete && localFile($0) != nil))
        }
        .map(\.displayedVideo).sorted {
            ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name)
                < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
        }
    }
    var titles: [VideoItem] {
        var titles = records.filter { $0.video.type == "Movie" && $0.state != .removed }.map(\.displayedVideo)
        var seen = Set<String>()
        for record in records where record.video.type == "Episode" && record.state != .removed {
            let show = record.series ?? record.displayedVideo
            let key = record.video.seriesID ?? show.id
            if seen.insert(key).inserted { titles.append(cachedVideo(id: show.id) ?? show) }
        }
        return titles.sorted {
            ($0.sortName ?? $0.name).localizedStandardCompare($1.sortName ?? $1.name) == .orderedAscending
        }
    }
    var pendingSync: Task<Void, Never>? { syncTask }
    var storageURL: URL { directory ?? root }
    var usedBytes: Int64 { records.reduce(0) { $0 + $1.received } }
    var availableBytes: Int64? {
        let location =
            directory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? root.deletingLastPathComponent()
        return (try? FileManager.default.attributesOfFileSystem(forPath: location.path)[.systemFreeSize] as? NSNumber)?
            .int64Value
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
        guard catalogReadable, let client, let directory, video.type == "Movie" || video.type == "Episode" else {
            return
        }
        if let existing = record(for: video),
            existing.isActive || existing.state == .pausing || existing.state == .complete
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
            $0.state = .preparing
            $0.error = nil
        }
        let current = generation
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var excluded = directory
                try excluded.setResourceValues(values)
                if self.records.first(where: { $0.id == id })?.prepared != true {
                    try await self.prepare(id: id, video: video, client: client, generation: current)
                }
                try Task.checkCancellation()
                guard self.generation == current, let record = self.records.first(where: { $0.id == id }) else {
                    return
                }
                if let free = self.availableBytes, record.expected - record.received > free {
                    throw JellyfinDownloadError.diskSpace
                }
                let resumeURL = folder.appendingPathComponent("resume.data")
                let resumeData = try? Data(contentsOf: resumeURL)
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
                        guard let self, self.generation == current, self.transfers[id]?.id == token else { return }
                        self.transfers[id] = nil
                        switch result {
                        case .success(let url):
                            self.update(id) {
                                $0.state = .complete
                                $0.received = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                                $0.expected = $0.received
                            }
                            try? FileManager.default.removeItem(at: resumeURL)
                        case .failure(let error):
                            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                                try? data.write(to: resumeURL, options: .atomic)
                            } else {
                                try? FileManager.default.removeItem(at: resumeURL)
                            }
                            self.update(id) {
                                $0.state = .failed
                                $0.error = error.localizedDescription
                            }
                        }
                    })
                self.transfers[id] = transfer
                self.preparations[id] = nil
                self.update(id) { $0.state = .downloading }
                transfer.start()
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.preparations[id] = nil
                self.update(id) {
                    $0.state = .failed
                    $0.error = error.localizedDescription
                }
            }
        }
    }

    func pause(_ record: DownloadRecord) async {
        preparations.removeValue(forKey: record.id)?.cancel()
        let transfer = transfers.removeValue(forKey: record.id)
        let current = generation
        let resumeURL = fileURL(record, name: "resume.data")
        update(record.id) { $0.state = .pausing }
        if let data = await transfer?.pause(), let resumeURL {
            try? data.write(to: resumeURL, options: .atomic)
        }
        if generation == current, records.first(where: { $0.id == record.id })?.state == .pausing {
            update(record.id) { $0.state = .paused }
        }
    }

    func remove(_ record: DownloadRecord) async {
        preparations.removeValue(forKey: record.id)?.cancel()
        transfers.removeValue(forKey: record.id)?.cancel()
        // Cancelling without producing resume data lets URLSession discard its partial file.
        if let resume = fileURL(record, name: "resume.data"), let data = try? Data(contentsOf: resume) {
            assets.downloadTask(withResumeData: data).cancel()
        }
        guard let folder = directory?.appendingPathComponent(record.id.uuidString) else { return }
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            if records.first(where: { $0.id == record.id })?.progress?.pendingSync == true {
                update(record.id) {
                    $0.state = .removed
                    $0.received = 0
                    $0.artworks = [:]
                    $0.subtitles = []
                    $0.prepared = false
                }
            } else {
                records.removeAll { $0.id == record.id }
            }
            save()
            registerArtwork()
        } catch { errorMessage = "The download couldn’t be removed: \(error.localizedDescription)" }
    }

    func shutdown() async {
        for record in records where record.isActive { await pause(record) }
        save()
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
        update(id) {
            $0.video = detail
            $0.sourceID = source?.id ?? detail.id
            $0.videoFile = "video.\(safeExtension)"
            $0.expected = source?.size ?? 0
        }
        if let free = availableBytes, (source?.size ?? 0) > free { throw JellyfinDownloadError.diskSpace }
        if let seriesID = detail.seriesID {
            let series = try await client.item(id: seriesID)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id) { $0.series = series }
            let next = try? await client.nextEpisode(after: detail)
            let credits = try? await client.creditsStart(itemID: detail.id)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            update(id) {
                $0.nextEpisodeID = next?.id
                $0.creditsStart = credits
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
            let (temporary, response) = try await assets.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JellyfinDownloadError.invalidFile }
            let name = "subtitle-\(index).\(format)"
            guard let url = fileURL(record, name: name) else { throw CancellationError() }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
            update(id) {
                $0.subtitles.removeAll { $0.index == index }
                $0.subtitles.append(.init(index: index, name: track.label, file: name))
            }
        }
        update(id) { $0.prepared = true }
    }

    private func cacheArtwork(_ request: URLRequest, id: UUID, generation current: UUID) async throws {
        do {
            let (data, response) = try await assets.data(for: request)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil,
                let record = records.first(where: { $0.id == id })
            else { return }
            let key = ArtworkCache.localKey(request)
            let name = "art-\(Self.digest(key)).image"
            guard let url = fileURL(record, name: name) else { return }
            try data.write(to: url, options: .atomic)
            update(id) { $0.artworks[key] = name }
            registerArtwork()
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
    private func save() {
        guard catalogReadable, let directory, !records.isEmpty || FileManager.default.fileExists(atPath: directory.path)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("catalog.json")
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { errorMessage = "Downloads couldn’t be saved: \(error.localizedDescription)" }
    }
}
