import CryptoKit
import Foundation
import Network

/// Loopback-only Jellyfin fixture for integration tests; never included in the app.
final class PlaybackFixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "JellyMac.local-demo")
    private let token = UUID().uuidString
    let mediaDirectory: URL
    private let allowsDownloads: Bool
    private let chunkDelay: TimeInterval
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]  // Used only on queue.
    @MainActor private(set) var address: URL?

    init(mediaDirectory: URL, allowsDownloads: Bool = true, chunkDelay: TimeInterval = 0) {
        self.mediaDirectory = mediaDirectory
        self.allowsDownloads = allowsDownloads
        self.chunkDelay = chunkDelay
    }

    private func catalog() -> [DemoVideo] {
        let root = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        let subtitleExtensions = Set(["srt", "ass", "ssa", "vtt", "sub"])
        return files.filter { DemoVideo.extensions.contains($0.pathExtension.lowercased()) }.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), let size = values.fileSize, size > 0 else {
                return nil
            }
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            let digest = SHA256.hash(data: Data(relativePath.utf8)).map { String(format: "%02x", $0) }.joined()
            let stem = file.deletingPathExtension().lastPathComponent
            let subtitles = files.filter { candidate in
                candidate.deletingLastPathComponent() == file.deletingLastPathComponent()
                    && subtitleExtensions.contains(candidate.pathExtension.lowercased())
                    && (candidate.deletingPathExtension().lastPathComponent == stem
                        || candidate.lastPathComponent.hasPrefix(stem + "."))
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }.enumerated().map { offset, subtitle in
                DemoSubtitle(index: 100 + offset, url: subtitle)
            }
            return DemoVideo(
                id: String(digest.prefix(32)), url: file, size: size,
                subtitles: subtitles)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor
    func start(port: UInt16? = nil) async throws -> URL {
        if let address { return address }
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard !resolved else { return }
                    switch state {
                    case .ready:
                        resolved = true
                        guard let port = listener.port,
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)")
                        else {
                            continuation.resume(throwing: DemoError.failedToStart)
                            return
                        }
                        self?.address = url
                        continuation.resume(returning: url)
                    case .failed(let error):
                        resolved = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        resolved = true
                        continuation.resume(throwing: DemoError.failedToStart)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    @MainActor
    func stop() {
        listener?.cancel()
        listener = nil
        address = nil
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 128 * 1024 else {
                self.send(Response(status: 400), connection: connection, id: id)
                return
            }
            if let request = Request.parse(buffer) {
                self.send(self.route(request), connection: connection, id: id, headOnly: request.method == "HEAD")
            } else if complete {
                self.send(Response(status: 400), connection: connection, id: id)
            } else {
                self.receive(connection, id: id, buffer: buffer)
            }
        }
    }

    private func route(_ request: Request) -> Response {
        if request.path == "/System/Info/Public" {
            return .json(["ServerName": "Theatre Local Demo", "Version": "10.11.0", "Id": "local-demo"])
        }
        if request.path == "/Users/AuthenticateByName", request.method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            guard body?["Username"] as? String == "demo", body?["Pw"] as? String == "demo" else {
                return Response(status: 401)
            }
            return .json([
                "User": ["Id": "00000000000000000000000000000001", "Name": "demo"],
                "AccessToken": token, "ServerId": "local-demo",
            ])
        }
        let authorized =
            request.headers["authorization"]?.contains("Token=\"\(token)\"") == true
            || request.query["api_key"] == token
        guard authorized else { return Response(status: 401) }
        if request.path == "/Items", request.method == "GET" {
            let search = request.query["searchTerm"] ?? ""
            let ids = Set((request.query["ids"] ?? "").split(separator: ",").map(String.init))
            let items = catalog().filter {
                (ids.isEmpty || ids.contains($0.id))
                    && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            }
            let start = max(0, Int(request.query["startIndex"] ?? "0") ?? 0)
            let limit = max(0, min(100, Int(request.query["limit"] ?? "100") ?? 100))
            return .json([
                "Items": Array(items.dropFirst(start).prefix(limit)).map(\.json),
                "TotalRecordCount": items.count, "StartIndex": start,
            ])
        }
        let segments = request.path.split(separator: "/").map(String.init)
        if segments.count == 3, segments[0] == "Items", segments[2] == "Download",
            let video = catalog().first(where: { $0.id == segments[1] })
        {
            guard allowsDownloads else { return Response(status: 403) }
            return fileResponse(
                video.url, size: video.size, contentType: video.contentType, range: request.headers["range"])
        }
        if segments.count == 6, segments[0] == "Videos", segments[3] == "Subtitles",
            let index = Int(segments[4]), let video = catalog().first(where: { $0.id == segments[1] }),
            let subtitle = video.subtitles.first(where: { $0.index == index }),
            let size = try? subtitle.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            return fileResponse(subtitle.url, size: size, contentType: "text/plain", range: request.headers["range"])
        }
        if segments.count == 3, segments[0] == "Items", segments[2] == "PlaybackInfo", request.method == "POST",
            let video = catalog().first(where: { $0.id == segments[1] })
        {
            let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let tracks: [[String: Any]] = video.subtitles.map { subtitle in
                [
                    "Index": subtitle.index, "Type": "Subtitle", "IsExternal": true,
                    "DisplayTitle": subtitle.url.lastPathComponent,
                    "DeliveryUrl": "/Videos/\(video.id)/subtitles/\(subtitle.index)",
                ]
            }
            return .json([
                "MediaSources": [
                    [
                        "Id": video.id, "Container": video.url.pathExtension.lowercased(),
                        "SupportsDirectPlay": true, "SupportsDirectStream": true,
                        "SupportsTranscoding": false, "RequiresOpening": false, "MediaStreams": tracks,
                    ]
                ],
                "PlaySessionId": sessionID,
            ])
        }
        if ["GET", "HEAD"].contains(request.method), segments.count >= 3, segments[0] == "Videos",
            let video = catalog().first(where: { $0.id == segments[1] })
        {
            if segments.count == 3, segments[2].hasPrefix("stream") {
                return fileResponse(
                    video.url, size: video.size, contentType: video.contentType, range: request.headers["range"])
            }
            if segments.count == 4, segments[2] == "subtitles", let index = Int(segments[3]),
                let subtitle = video.subtitles.first(where: { $0.index == index }),
                let size = try? subtitle.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            {
                return fileResponse(
                    subtitle.url, size: size, contentType: "text/plain; charset=utf-8", range: request.headers["range"])
            }
        }
        if request.method == "POST",
            ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped", "/Sessions/Logout"]
                .contains(request.path)
        {
            return Response(status: 204)
        }
        return Response(status: 404)
    }

    static func byteRange(_ value: String, length: Int) -> Range<Int>? {
        guard value.hasPrefix("bytes="), length > 0 else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { return nil }
        if parts[1].isEmpty { return start..<length }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, length - 1) + 1)
    }

    private func fileResponse(_ url: URL, size: Int, contentType: String, range: String?) -> Response {
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes", "ETag": "\"fixture-\(size)\""]
        if let range {
            guard let bounds = Self.byteRange(range, length: size) else {
                return Response(status: 416, headers: ["Content-Range": "bytes */\(size)"])
            }
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(size)"
            return Response(status: 206, headers: headers, fileURL: url, fileRange: bounds)
        }
        return Response(status: 200, headers: headers, fileURL: url, fileRange: 0..<size)
    }

    private func finish(_ connection: NWConnection, id: UUID, file: FileHandle? = nil) {
        try? file?.close()
        connection.cancel()
        connections[id] = nil
    }

    private func send(_ response: Response, connection: NWConnection, id: UUID, headOnly: Bool = false) {
        let reason =
            [
                200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
                404: "Not Found", 416: "Range Not Satisfiable",
            ][response.status] ?? "Error"
        var headers = response.headers
        headers["Content-Length"] = String(response.fileRange?.count ?? response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var result = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
        for (name, value) in headers { result.append(Data("\(name): \(value)\r\n".utf8)) }
        result.append(Data("\r\n".utf8))
        if !headOnly && response.fileURL == nil { result.append(response.body) }
        connection.send(
            content: result,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard error == nil, !headOnly, let url = response.fileURL, let range = response.fileRange,
                    url.resolvingSymlinksInPath().path.hasPrefix(
                        self.mediaDirectory.resolvingSymlinksInPath().path + "/"),
                    let file = try? FileHandle(forReadingFrom: url)
                else {
                    self.finish(connection, id: id)
                    return
                }
                do { try file.seek(toOffset: UInt64(range.lowerBound)) } catch {
                    self.finish(connection, id: id, file: file)
                    return
                }
                self.sendChunk(file, remaining: range.count, connection: connection, id: id)
            })
    }

    private func sendChunk(_ file: FileHandle, remaining: Int, connection: NWConnection, id: UUID) {
        guard remaining > 0, let data = try? file.read(upToCount: min(256 * 1024, remaining)), !data.isEmpty else {
            finish(connection, id: id, file: file)
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    try? file.close()
                    connection.cancel()
                    return
                }
                if error != nil {
                    self.finish(connection, id: id, file: file)
                } else {
                    self.queue.asyncAfter(deadline: .now() + self.chunkDelay) {
                        self.sendChunk(file, remaining: remaining - data.count, connection: connection, id: id)
                    }
                }
            })
    }

    private struct Request {
        let method: String, path: String
        let query: [String: String], headers: [String: String]
        let body: Data

        static func parse(_ data: Data) -> Request? {
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
                let text = String(data: data[..<separator.lowerBound], encoding: .utf8)
            else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, let url = URLComponents(string: String(first[1])) else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
            guard data.count - separator.upperBound >= length else { return nil }
            let body = data.subdata(in: separator.upperBound..<(separator.upperBound + length))
            let query = (url.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
            return Request(method: String(first[0]), path: url.path, query: query, headers: headers, body: body)
        }
    }

    private struct Response {
        let status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var fileURL: URL?
        var fileRange: Range<Int>?
        static func json(_ object: Any) -> Response {
            Response(
                status: 200, headers: ["Content-Type": "application/json"],
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }
}

private enum DemoError: LocalizedError {
    case failedToStart
    var errorDescription: String? { "The demo server could not open a local port." }
}

private struct DemoSubtitle {
    let index: Int
    let url: URL
}

private struct DemoVideo {
    let id: String
    let url: URL
    let size: Int
    let subtitles: [DemoSubtitle]
    static let extensions = Set([
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "asf", "flv", "ogv",
        "ogg", "vob", "3gp",
    ])
    var name: String { url.lastPathComponent }
    var contentType: String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts", "mts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }
    var json: [String: Any] {
        [
            "Id": id, "Name": name, "Type": "Movie", "RunTimeTicks": 80_000_000,
            "UserData": ["Played": false, "PlaybackPositionTicks": 0],
            "MediaSources": [
                [
                    "Id": id, "Container": url.pathExtension, "Size": size,
                    "MediaStreams": subtitles.map {
                        [
                            "Index": $0.index, "Type": "Subtitle", "IsExternal": true,
                            "Codec": "srt", "DisplayTitle": $0.url.lastPathComponent,
                        ]
                    },
                ]
            ],
        ]
    }
}
