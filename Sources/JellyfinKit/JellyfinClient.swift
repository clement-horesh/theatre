import Foundation

/// A small, platform-independent Jellyfin API client shared by future Apple clients.
public struct JellyfinClient: Sendable {
    public let serverURL: URL
    public let deviceID: String
    public let session: JellyfinSession?
    private let transport: URLSession

    public init(
        address: String, deviceID: String, transport: URLSession = .shared,
        session: JellyfinSession? = nil
    ) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address),
            ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil
        else { throw JellyfinError.invalidAddress }
        parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw JellyfinError.invalidAddress }
        serverURL = url
        self.deviceID = deviceID
        self.transport = transport
        self.session = session
    }

    public func authenticated(with session: JellyfinSession) throws -> JellyfinClient {
        try JellyfinClient(
            address: serverURL.absoluteString, deviceID: deviceID,
            transport: transport, session: session)
    }

    public func authenticate(username: String, password: String) async throws -> JellyfinSession {
        let data = try await request(
            "Users/AuthenticateByName", method: "POST",
            body: LoginBody(username: username, pw: password))
        let response: LoginResponse = try decode(data)
        guard !response.accessToken.isEmpty, !response.user.id.isEmpty else {
            throw JellyfinError.invalidResponse
        }
        return JellyfinSession(
            userID: response.user.id, username: response.user.name ?? username,
            accessToken: response.accessToken)
    }

    public func videos(
        startIndex: Int = 0, limit: Int = 100, search: String = "",
        itemTypes: [String] = [], parentID: String? = nil,
        newestFirst: Bool = false, resumableOnly: Bool = false, filters: VideoFilters = VideoFilters()
    ) async throws -> VideoPage {
        guard let session else { throw JellyfinError.unauthorized }
        var query = [
            URLQueryItem(name: "userId", value: session.userID),
            .init(name: "recursive", value: "true"),
            .init(name: "isMissing", value: "false"),
            .init(name: "isPlaceHolder", value: "false"),
            .init(
                name: "sortBy",
                value: parentID == nil
                    ? (newestFirst ? "DateCreated" : "SortName")
                    : (resumableOnly
                        ? "DatePlayed,ParentIndexNumber,IndexNumber" : "ParentIndexNumber,IndexNumber,SortName")),
            .init(
                name: "sortOrder",
                value: resumableOnly
                    ? "Descending,Ascending,Ascending" : (newestFirst && parentID == nil ? "Descending" : "Ascending")
            ),
            .init(name: "enableImages", value: "true"),
            .init(name: "enableUserData", value: "true"),
            .init(name: "imageTypeLimit", value: "1"),
            .init(name: "fields", value: "Overview,Genres,SortName"),
            .init(name: "enableTotalRecordCount", value: "true"),
            .init(name: "startIndex", value: String(startIndex)),
            .init(name: "limit", value: String(limit)),
        ]
        if let status = resumableOnly ? "IsResumable" : filters.watchStatus.queryValue {
            query.append(.init(name: "filters", value: status))
        }
        if !filters.genre.isEmpty { query.append(.init(name: "genres", value: filters.genre)) }
        if let year = filters.year { query.append(.init(name: "years", value: String(year))) }
        if !search.isEmpty { query.append(.init(name: "searchTerm", value: search)) }
        if !itemTypes.isEmpty { query.append(.init(name: "includeItemTypes", value: itemTypes.joined(separator: ","))) }
        if !itemTypes.contains("Series") { query.append(.init(name: "mediaTypes", value: "Video")) }
        if let parentID { query.append(.init(name: "parentId", value: parentID)) }
        return try decode(await request("Items", query: query))
    }

    public func videoFilterOptions(itemTypes: [String]) async throws -> VideoFilterOptions {
        guard let session else { throw JellyfinError.unauthorized }
        return try decode(
            await request(
                "Items/Filters",
                query: [
                    .init(name: "userId", value: session.userID),
                    .init(name: "includeItemTypes", value: itemTypes.joined(separator: ",")),
                ]))
    }

    public func item(id: String) async throws -> VideoItem {
        guard let session else { throw JellyfinError.unauthorized }
        // Explicitly request detail collections; catalog items only contain the
        // fields selected by the library query and must not stand in for details.
        let page: VideoPage = try decode(
            await request(
                "Items",
                query: [
                    .init(name: "userId", value: session.userID), .init(name: "ids", value: id),
                    .init(
                        name: "fields",
                        value: "Overview,Genres,People,Studios,ProductionLocations,MediaStreams,MediaSources,ChildCount"
                    ),
                    .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
                    .init(name: "imageTypeLimit", value: "1"), .init(name: "limit", value: "1"),
                    .init(name: "enableTotalRecordCount", value: "true"),
                ]))
        guard let item = page.items.first(where: { $0.id == id }) else { throw JellyfinError.invalidResponse }
        return item
    }

    /// Rank whole shows by their newest episode's added date, alongside movies.
    public func recentlyAddedTitles(limit: Int = 30) async throws -> [VideoItem] {
        guard limit > 0 else { return [] }
        guard let session else { throw JellyfinError.unauthorized }
        var entries: [VideoItem] = []
        var seen = Set<String>()
        var offset = 0
        // Fetch additional pages when a season import occupies a whole raw page.
        while entries.count < limit {
            try Task.checkCancellation()
            let page = try await videos(
                startIndex: offset, limit: 100,
                itemTypes: ["Movie", "Series", "Episode"], newestFirst: true)
            for item in page.items {
                let titleID: String
                if item.type == "Episode" {
                    guard let seriesID = item.seriesID, !seriesID.isEmpty else { continue }
                    titleID = seriesID
                } else {
                    titleID = item.id
                }
                if seen.insert(titleID).inserted { entries.append(item) }
                if entries.count == limit { break }
            }
            offset += page.items.count
            if page.items.isEmpty || offset >= page.totalCount { break }
        }
        let seriesIDs = entries.compactMap { item in
            item.type == "Episode" ? item.seriesID : (item.type == "Series" ? item.id : nil)
        }
        var shows: [String: VideoItem] = [:]
        if !seriesIDs.isEmpty {
            let page: VideoPage = try decode(
                await request(
                    "Items",
                    query: [
                        .init(name: "userId", value: session.userID),
                        .init(name: "ids", value: seriesIDs.joined(separator: ",")),
                        .init(name: "fields", value: "Overview,Genres,ChildCount"),
                        .init(name: "enableUserData", value: "true"),
                        .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1"),
                        .init(name: "enableTotalRecordCount", value: "true"),
                        .init(name: "limit", value: String(seriesIDs.count)),
                    ]))
            shows = Dictionary(
                page.items.filter { $0.type == "Series" }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // Keep the order of each title's first appearance in the newest-first feed.
        return entries.compactMap { item in
            if item.type == "Episode" { return item.seriesID.flatMap { shows[$0] } }
            if item.type == "Series" { return shows[item.id] ?? item }
            return item
        }
    }

    public func seasons(seriesID: String) async throws -> VideoPage {
        guard let session else { throw JellyfinError.unauthorized }
        return try decode(
            await request(
                "Shows/\(seriesID)/Seasons",
                query: [
                    .init(name: "userId", value: session.userID), .init(name: "enableUserData", value: "true"),
                    .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1"),
                ]))
    }

    public func episodes(
        seriesID: String, seasonID: String? = nil, startIndex: Int = 0, limit: Int = 100, startItemID: String? = nil
    ) async throws
        -> VideoPage
    {
        guard let session else { throw JellyfinError.unauthorized }
        var query: [URLQueryItem] = [
            .init(name: "userId", value: session.userID), .init(name: "sortBy", value: "IndexNumber"),
            .init(name: "startIndex", value: String(startIndex)), .init(name: "limit", value: String(limit)),
            .init(name: "isMissing", value: "false"), .init(name: "fields", value: "Overview,Genres"),
            .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
            .init(name: "imageTypeLimit", value: "1"),
        ]
        if let seasonID { query.append(.init(name: "seasonId", value: seasonID)) }
        if let startItemID { query.append(.init(name: "startItemId", value: startItemID)) }
        return try decode(await request("Shows/\(seriesID)/Episodes", query: query))
    }

    /// Resolve a show action without downloading its complete episode catalog.
    public func showPlaybackCandidates(seriesID: String) async throws -> [VideoItem] {
        let resume = try await videos(limit: 1, itemTypes: ["Episode"], parentID: seriesID, resumableOnly: true)
        if let episode = resume.items.first { return [episode] }
        guard let session else { throw JellyfinError.unauthorized }
        let next: VideoPage = try decode(
            await request(
                "Shows/NextUp",
                query: [
                    .init(name: "userId", value: session.userID), .init(name: "seriesId", value: seriesID),
                    .init(name: "limit", value: "1"), .init(name: "enableUserData", value: "true"),
                    .init(name: "enableResumable", value: "true"), .init(name: "fields", value: "Overview,Genres"),
                ]))
        if let episode = next.items.first { return [episode] }
        let seasons = try await seasons(seriesID: seriesID).items
        let regular = seasons.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        let season = regular.first { ($0.indexNumber ?? 0) > 0 } ?? regular.first
        return try await episodes(seriesID: seriesID, seasonID: season?.id, limit: 1).items
    }

    public func nextEpisode(after episode: VideoItem) async throws -> VideoItem? {
        guard episode.type == "Episode", let seriesID = episode.seriesID else { return nil }
        let page = try await episodes(seriesID: seriesID, limit: 2, startItemID: episode.id)
        guard page.items.first?.id == episode.id else { return nil }
        return page.items.dropFirst().first
    }

    /// Unsupported segment APIs and absent markers leave the early next-episode button hidden.
    public func creditsStart(itemID: String) async throws -> Double? {
        do {
            let page: MediaSegmentPage = try decode(
                await request(
                    "MediaSegments/\(itemID)",
                    query: [
                        .init(name: "includeSegmentTypes", value: "Outro")
                    ]))
            return page.items.filter { $0.type == "Outro" && $0.startTicks > 0 }
                .map { Double($0.startTicks) / 10_000_000 }.min()
        } catch JellyfinError.serverStatus(404) { return nil }
    }

    public func setWatched(_ watched: Bool, itemID: String) async throws {
        guard let session else { throw JellyfinError.unauthorized }
        _ = try await request(
            "UserPlayedItems/\(itemID)", method: watched ? "POST" : "DELETE",
            query: [
                .init(name: "userId", value: session.userID)
            ])
    }

    public func stopEncoding(_ stream: PlaybackStream) async throws {
        guard stream.method == "Transcode", !stream.playSessionID.isEmpty else { return }
        _ = try await request(
            "Videos/ActiveEncodings", method: "DELETE",
            query: [
                .init(name: "deviceId", value: deviceID), .init(name: "playSessionId", value: stream.playSessionID),
            ])
    }

    public func resumeVideos(limit: Int = 100, startIndex: Int = 0, itemTypes: [String] = []) async throws -> VideoPage
    {
        guard let session else { throw JellyfinError.unauthorized }
        var query: [URLQueryItem] = [
            .init(name: "userId", value: session.userID), .init(name: "mediaTypes", value: "Video"),
            .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
            .init(name: "imageTypeLimit", value: "1"), .init(name: "limit", value: String(limit)),
            .init(name: "startIndex", value: String(startIndex)),
            .init(name: "fields", value: "Overview,Genres"),
        ]
        if !itemTypes.isEmpty { query.append(.init(name: "includeItemTypes", value: itemTypes.joined(separator: ","))) }
        return try decode(await request("UserItems/Resume", query: query))
    }

    /// Artwork uses the same server and authentication as the library. A tag
    /// versions the cache; credentials stay in the header instead of the URL.
    public func imageRequest(for item: VideoItem, type: JellyfinImageType, maxWidth: Int) throws -> URLRequest? {
        guard session != nil else { throw JellyfinError.unauthorized }
        var itemID = item.id
        let tag: String?
        switch type {
        case .primary: tag = item.imageTags?[type.rawValue]
        case .backdrop:
            if let own = item.backdropImageTags?.first {
                tag = own
            } else {
                itemID = item.parentBackdropItemID ?? item.id
                tag = item.parentBackdropImageTags?.first
            }
        case .logo:
            if let own = item.imageTags?[type.rawValue] {
                tag = own
            } else {
                itemID = item.parentLogoItemID ?? item.id
                tag = item.parentLogoImageTag
            }
        }
        guard let tag, !tag.isEmpty else { return nil }
        var query: [URLQueryItem] = [
            .init(name: "tag", value: tag),
            .init(name: "maxWidth", value: String(max(1, min(3840, maxWidth)))),
        ]
        if type == .backdrop { query.append(.init(name: "imageIndex", value: "0")) }
        if type == .logo { query.append(.init(name: "format", value: "Png")) }
        let url = try endpoint("Items/\(itemID)/Images/\(type.rawValue)", query: query)
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    public func playback(
        for item: VideoItem, compatibleOnly: Bool = false, nativePlayer: Bool = false, mediaSourceID: String? = nil,
        audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil
    ) async throws
        -> PlaybackStream
    {
        guard let session else { throw JellyfinError.unauthorized }
        let body = PlaybackBody(
            userID: session.userID, enableDirectPlay: !compatibleOnly,
            enableDirectStream: !compatibleOnly,
            allowVideoStreamCopy: !compatibleOnly, allowAudioStreamCopy: !compatibleOnly,
            deviceProfile: PlaybackDeviceProfile(nativePlayer: nativePlayer), mediaSourceID: mediaSourceID,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex)
        let response: PlaybackResponse = try decode(
            await request(
                "Items/\(item.id)/PlaybackInfo",
                method: "POST", body: body))
        if let error = response.errorCode, !error.isEmpty { throw JellyfinError.noPlayableSource }
        // Only use server stream endpoints. A MediaSource.Path can be a path on the server's disk.
        let sources = response.mediaSources.filter { $0.requiresOpening != true }
        // Check all source versions for direct playback before accepting conversion.
        if !compatibleOnly {
            for source in sources where source.supportsDirectPlay == true {
                guard let container = Self.streamContainer(source.container) else { continue }
                let url = try endpoint(
                    "Videos/\(item.id)/stream.\(container)",
                    query: [
                        .init(name: "static", value: "true"), .init(name: "mediaSourceId", value: source.id),
                        .init(name: "deviceId", value: deviceID),
                        .init(name: "playSessionId", value: response.playSessionID ?? ""),
                    ])
                var stream = PlaybackStream(
                    url: try authorizeStream(url), itemID: item.id,
                    mediaSourceID: source.id, playSessionID: response.playSessionID ?? "",
                    method: "DirectPlay")
                stream.mediaTracks = source.playbackTracks
                stream.externalSubtitles = try externalSubtitles(source: source)
                stream.videoAspectRatio = source.videoAspectRatio
                stream.resumePositionSeconds = item.resumePositionSeconds
                return stream
            }
        }
        for source in sources {
            if let path = source.transcodingURL, !path.isEmpty {
                let url = try resolveStream(path)
                var stream = PlaybackStream(
                    url: try authorizeStream(url), itemID: item.id,
                    mediaSourceID: source.id, playSessionID: response.playSessionID ?? "",
                    method: "Transcode", videoAspectRatio: source.videoAspectRatio,
                    resumePositionSeconds: item.resumePositionSeconds)
                stream.mediaTracks = source.playbackTracks
                return stream
            }
        }
        throw JellyfinError.noPlayableSource
    }

    public func imageRequest(for person: VideoPerson, maxWidth: Int = 400) throws -> URLRequest? {
        guard session != nil else { throw JellyfinError.unauthorized }
        guard let id = person.itemID, !id.isEmpty, let tag = person.primaryImageTag, !tag.isEmpty else { return nil }
        let url = try endpoint(
            "Items/\(id)/Images/Primary",
            query: [
                .init(name: "tag", value: tag), .init(name: "maxWidth", value: String(max(1, min(1200, maxWidth)))),
            ])
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    private static func streamContainer(_ raw: String?) -> String? {
        let supported = Set([
            "mp4", "mkv", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "asf", "flv", "ogv",
            "ogg", "vob", "3gp",
        ])
        let containers = (raw ?? "").lowercased().split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.map { $0 == "matroska" ? "mkv" : ($0 == "mpegts" ? "ts" : $0) }
        // FFmpeg reports MOV/MP4 using a shared list; MP4 is the useful stream extension.
        if containers.contains("mp4") { return "mp4" }
        return containers.first { supported.contains($0) }
    }

    private func externalSubtitles(source: MediaSource) throws -> [PlaybackSubtitle] {
        try (source.mediaStreams ?? []).compactMap { track in
            guard track.type == "Subtitle", track.isExternal == true, let delivery = track.deliveryURL,
                !delivery.isEmpty
            else { return nil }
            return PlaybackSubtitle(
                id: track.index, name: track.displayTitle ?? track.title ?? track.language ?? "Subtitle \(track.index)",
                url: try authorizeStream(resolveStream(delivery)))
        }
    }

    /// Keep Jellyfin's session and transcode lifecycle informed by the native player.
    public func reportPlayback(
        _ event: PlaybackEvent, stream: PlaybackStream,
        seconds: Double, paused: Bool = false
    ) async throws {
        let safeSeconds = seconds.isFinite ? max(0, min(seconds, 1e10)) : 0
        let body = PlaybackReport(
            itemID: stream.itemID, mediaSourceID: stream.mediaSourceID,
            playSessionID: stream.playSessionID, positionTicks: Int64(safeSeconds * 10_000_000),
            isPaused: paused, playMethod: stream.method)
        _ = try await request("Sessions/Playing\(event.suffix)", method: "POST", body: body)
    }

    /// The download endpoint enforces Jellyfin's per-user download permission.
    public func downloadRequest(itemID: String) throws -> URLRequest {
        guard session != nil else { throw JellyfinError.unauthorized }
        var result = URLRequest(url: try endpoint("Items/\(itemID)/Download"), timeoutInterval: 60)
        result.setValue(authorization, forHTTPHeaderField: "Authorization")
        return result
    }

    public func subtitleDownloadRequest(itemID: String, sourceID: String, index: Int, format: String) throws
        -> URLRequest
    {
        guard session != nil else { throw JellyfinError.unauthorized }
        guard ["srt", "ass", "ssa", "vtt", "sup", "sub"].contains(format) else { throw JellyfinError.invalidResponse }
        var result = URLRequest(url: try endpoint("Videos/\(itemID)/\(sourceID)/Subtitles/\(index)/Stream.\(format)"))
        result.setValue(authorization, forHTTPHeaderField: "Authorization")
        return result
    }

    public func saveOfflineProgress(itemID: String, data: VideoUserData) async throws {
        guard let session else { throw JellyfinError.unauthorized }
        _ = try await request(
            "UserItems/\(itemID)/UserData", method: "POST",
            query: [.init(name: "userId", value: session.userID)], body: data)
    }

    public func logout() async throws { _ = try await request("Sessions/Logout", method: "POST") }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var parts = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else {
            throw JellyfinError.invalidAddress
        }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw JellyfinError.invalidAddress }
        return url
    }

    // Jellyfin commonly returns /Videos/... relative to its configured base path.
    // Preserve reverse-proxy prefixes and accept a prefix already present only once.
    private func resolveStream(_ path: String) throws -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        if path.hasPrefix("//") { throw JellyfinError.unsafeStreamURL }
        let prefix = serverURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let clean = String(path.drop(while: { $0 == "/" }))
        let relative =
            (!prefix.isEmpty && clean.hasPrefix(prefix + "/")) ? String(clean.dropFirst(prefix.count + 1)) : clean
        guard let base = URL(string: serverURL.absoluteString + "/"),
            let url = URL(string: relative, relativeTo: base)?.absoluteURL
        else {
            throw JellyfinError.invalidResponse
        }
        return url
    }

    private func authorizeStream(_ url: URL) throws -> URL {
        guard let session else { throw JellyfinError.unauthorized }
        let url = url.standardized
        guard url.scheme?.lowercased() == serverURL.scheme, url.host?.lowercased() == serverURL.host?.lowercased(),
            effectivePort(url) == effectivePort(serverURL), url.user == nil, url.password == nil,
            !url.pathComponents.contains(".."),
            serverURL.path.isEmpty || url.path.hasPrefix(serverURL.path + "/")
        else {
            throw JellyfinError.unsafeStreamURL
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinError.unsafeStreamURL
        }
        // Player engines fetch streams themselves; Jellyfin supports query authentication here.
        var query = (parts.queryItems ?? []).filter { !["api_key", "token"].contains($0.name.lowercased()) }
        query.append(.init(name: "api_key", value: session.accessToken))
        parts.queryItems = query
        guard let authenticatedURL = parts.url else { throw JellyfinError.unsafeStreamURL }
        return authenticatedURL
    }

    private func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }

    private var authorization: String {
        let token = session.map { ", Token=\"\(escape($0.accessToken))\"" } ?? ""
        return
            "MediaBrowser Client=\"Theatre\", Device=\"Mac\", DeviceId=\"\(escape(deviceID))\", Version=\"0.1.0\"\(token)"
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func request(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try endpoint(path, query: query), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw JellyfinError.unauthorized
        case 403: throw JellyfinError.forbidden
        default: throw JellyfinError.serverStatus(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw JellyfinError.invalidResponse }
    }
}

public enum PlaybackEvent: Sendable {
    case started, progress, stopped
    var suffix: String {
        switch self {
        case .started: return ""
        case .progress: return "/Progress"
        case .stopped: return "/Stopped"
        }
    }
}

private struct LoginBody: Encodable {
    let username: String
    let pw: String
    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}
private struct LoginResponse: Decodable {
    struct UserInfo: Decodable {
        let id: String
        let name: String?
        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }
    let accessToken: String
    let user: UserInfo

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}
private struct PlaybackResponse: Decodable {
    let mediaSources: [MediaSource]
    let playSessionID: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}
private struct MediaSource: Decodable {
    let id: String
    let container: String?
    let supportsDirectPlay: Bool?
    let requiresOpening: Bool?
    let transcodingURL: String?
    let mediaStreams: [MediaStream]?
    var playbackTracks: [PlaybackTrack] {
        (mediaStreams ?? []).compactMap { track in
            guard let type = track.type, ["Audio", "Subtitle"].contains(type) else { return nil }
            return PlaybackTrack(
                index: track.index, type: type, language: track.language, name: track.displayTitle ?? track.title,
                isExternal: track.isExternal == true)
        }
    }
    var videoAspectRatio: Double? {
        mediaStreams?.first { $0.type == "Video" && $0.isAttachedPic != true }?.videoAspectRatio
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case requiresOpening = "RequiresOpening"
        case transcodingURL = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
    }
}
private struct MediaStream: Decodable {
    let index: Int
    let `type`: String?
    let isExternal: Bool?
    let deliveryURL: String?
    let displayTitle: String?
    let title: String?
    let language: String?
    let width: Int?
    let height: Int?
    let aspectRatio: String?
    let isAttachedPic: Bool?
    var videoAspectRatio: Double? {
        if let text = aspectRatio {
            let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" })
            let ratio: Double?
            if parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), height > 0 {
                ratio = width / height
            } else {
                ratio = Double(text)
            }
            if let ratio, ratio.isFinite, ratio > 0 { return ratio }
        }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case isExternal = "IsExternal"
        case deliveryURL = "DeliveryUrl"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case language = "Language"
        case width = "Width"
        case height = "Height"
        case aspectRatio = "AspectRatio"
        case isAttachedPic = "IsAttachedPic"
    }
}
private struct PlaybackBody: Encodable {
    let userID: String
    let enableDirectPlay: Bool
    let enableDirectStream: Bool
    let enableTranscoding = true
    let allowVideoStreamCopy: Bool
    let allowAudioStreamCopy: Bool
    let autoOpenLiveStream = false
    let maxStreamingBitrate = 200_000_000
    let maxAudioChannels = 8
    let startTimeTicks = 0
    let deviceProfile: PlaybackDeviceProfile
    let mediaSourceID: String?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxAudioChannels = "MaxAudioChannels"
        case startTimeTicks = "StartTimeTicks"
        case deviceProfile = "DeviceProfile"
        case mediaSourceID = "MediaSourceId"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}
private struct PlaybackDeviceProfile: Encodable {
    let name: String
    let maxStreamingBitrate = 200_000_000
    let maxStaticBitrate = 200_000_000
    let directPlayProfiles: [DirectProfile]
    let transcodingProfiles: [TranscodingProfile]
    let subtitleProfiles: [SubtitleProfile]

    init(nativePlayer: Bool) {
        name = nativePlayer ? "Theatre Apple Player" : "Theatre VLCKit"
        directPlayProfiles = [DirectProfile(nativePlayer: nativePlayer)]
        transcodingProfiles = [TranscodingProfile(enableSubtitlesInManifest: nativePlayer)]
        subtitleProfiles = nativePlayer ? [SubtitleProfile(format: "vtt", method: "Hls")] : Self.vlcSubtitles
    }

    private static let vlcSubtitles = [
        SubtitleProfile(format: "srt", method: "External"),
        SubtitleProfile(format: "subrip", method: "External"),
        SubtitleProfile(format: "ass", method: "External"),
        SubtitleProfile(format: "ssa", method: "External"),
        SubtitleProfile(format: "vtt", method: "External"),
        SubtitleProfile(format: "srt", method: "Embed"),
        SubtitleProfile(format: "subrip", method: "Embed"),
        SubtitleProfile(format: "ass", method: "Embed"),
        SubtitleProfile(format: "ssa", method: "Embed"),
        SubtitleProfile(format: "pgssub", method: "Embed"),
        SubtitleProfile(format: "dvdsub", method: "Embed"),
    ]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }
}
private struct DirectProfile: Encodable {
    let container: String
    let `type` = "Video"
    let videoCodec: String
    let audioCodec: String

    init(nativePlayer: Bool) {
        container =
            nativePlayer ? "mp4,m4v,mov" : "mp4,mkv,m4v,mov,avi,webm,ts,m2ts,mts,mpeg,mpg,wmv,asf,flv,ogv,ogg,vob,3gp"
        videoCodec =
            nativePlayer
            ? "h264,hevc" : "h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,av1,vc1,theora,mjpeg,h263,wmv2,wmv3"
        audioCodec =
            nativePlayer
            ? "aac,alac,mp3,ac3,eac3"
            : "aac,ac3,eac3,mp3,mp2,flac,alac,dts,truehd,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,wmapro,wmav2"
    }

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
    }
}
private struct TranscodingProfile: Encodable {
    let container = "ts"
    let `type` = "Video"
    let videoCodec = "h264"
    let audioCodec = "aac"
    let `streamProtocol` = "hls"
    let context = "Streaming"
    let maxAudioChannels = "2"
    let minSegments = 2
    let segmentLength = 4
    let breakOnNonKeyFrames = false
    let enableSubtitlesInManifest: Bool

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case streamProtocol = "Protocol"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
    }
}
private struct SubtitleProfile: Encodable {
    let format: String
    let method: String
    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}
private struct PlaybackReport: Encodable {
    let itemID: String
    let mediaSourceID: String
    let playSessionID: String
    let positionTicks: Int64
    let isPaused: Bool
    let playMethod: String
    let canSeek = true

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
        case canSeek = "CanSeek"
    }
}

private struct MediaSegmentPage: Decodable {
    let items: [MediaSegment]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}
private struct MediaSegment: Decodable {
    let type: String
    let startTicks: Int64
    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case startTicks = "StartTicks"
    }
}
