import Foundation

/// A small, platform-independent Jellyfin API client shared by future Apple clients.
public struct JellyfinClient: Sendable {
    public let serverURL: URL
    public let deviceID: String
    public let session: JellyfinSession?
    private let transport: URLSession

    public init(address: String, deviceID: String, transport: URLSession = .shared,
                session: JellyfinSession? = nil) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw JellyfinError.invalidAddress }
        parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw JellyfinError.invalidAddress }
        serverURL = url
        self.deviceID = deviceID
        self.transport = transport
        self.session = session
    }

    public func authenticated(with session: JellyfinSession) throws -> JellyfinClient {
        try JellyfinClient(address: serverURL.absoluteString, deviceID: deviceID,
                           transport: transport, session: session)
    }

    public func authenticate(username: String, password: String) async throws -> JellyfinSession {
        let data = try await request("Users/AuthenticateByName", method: "POST",
                                     body: LoginBody(Username: username, Pw: password))
        let response: LoginResponse = try decode(data)
        guard !response.AccessToken.isEmpty, !response.User.Id.isEmpty else {
            throw JellyfinError.invalidResponse
        }
        return JellyfinSession(userID: response.User.Id, username: response.User.Name ?? username,
                               accessToken: response.AccessToken)
    }

    public func videos(startIndex: Int = 0, limit: Int = 100, search: String = "",
                       itemTypes: [String] = [], parentID: String? = nil,
                       newestFirst: Bool = false) async throws -> VideoPage {
        guard let session else { throw JellyfinError.unauthorized }
        var query = [URLQueryItem(name: "userId", value: session.userID),
                     .init(name: "recursive", value: "true"),
                     .init(name: "isMissing", value: "false"),
                     .init(name: "isPlaceHolder", value: "false"),
                     .init(name: "sortBy", value: parentID == nil ? (newestFirst ? "DateCreated" : "SortName") : "ParentIndexNumber,IndexNumber,SortName"),
                     .init(name: "sortOrder", value: newestFirst && parentID == nil ? "Descending" : "Ascending"),
                     .init(name: "enableImages", value: "true"),
                     .init(name: "enableUserData", value: "true"),
                     .init(name: "imageTypeLimit", value: "1"),
                     .init(name: "fields", value: "Overview,Genres"),
                     .init(name: "enableTotalRecordCount", value: "true"),
                     .init(name: "startIndex", value: String(startIndex)),
                     .init(name: "limit", value: String(limit))]
        if !search.isEmpty { query.append(.init(name: "searchTerm", value: search)) }
        if !itemTypes.isEmpty { query.append(.init(name: "includeItemTypes", value: itemTypes.joined(separator: ","))) }
        if !itemTypes.contains("Series") { query.append(.init(name: "mediaTypes", value: "Video")) }
        if let parentID { query.append(.init(name: "parentId", value: parentID)) }
        return try decode(await request("Items", query: query))
    }

    public func item(id: String) async throws -> VideoItem {
        guard let session else { throw JellyfinError.unauthorized }
        // Explicitly request detail collections; catalog items only contain the
        // fields selected by the library query and must not stand in for details.
        let page: VideoPage = try decode(await request("Items", query: [
            .init(name: "userId", value: session.userID), .init(name: "ids", value: id),
            .init(name: "fields", value: "Overview,Genres,People,Studios,ProductionLocations,MediaStreams,MediaSources,ChildCount"),
            .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
            .init(name: "imageTypeLimit", value: "1"), .init(name: "limit", value: "1"),
            .init(name: "enableTotalRecordCount", value: "true")
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
            let page = try await videos(startIndex: offset, limit: 100,
                                        itemTypes: ["Movie", "Series", "Episode"], newestFirst: true)
            for item in page.items {
                let titleID: String
                if item.type == "Episode" {
                    guard let seriesID = item.seriesID, !seriesID.isEmpty else { continue }
                    titleID = seriesID
                } else { titleID = item.id }
                if seen.insert(titleID).inserted { entries.append(item) }
                if entries.count == limit { break }
            }
            offset += page.items.count
            if page.items.isEmpty || offset >= page.totalCount { break }
        }
        let seriesIDs = entries.compactMap { item in item.type == "Episode" ? item.seriesID : (item.type == "Series" ? item.id : nil) }
        var shows: [String: VideoItem] = [:]
        if !seriesIDs.isEmpty {
            let page: VideoPage = try decode(await request("Items", query: [
                .init(name: "userId", value: session.userID), .init(name: "ids", value: seriesIDs.joined(separator: ",")),
                .init(name: "fields", value: "Overview,Genres,ChildCount"), .init(name: "enableUserData", value: "true"),
                .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1"),
                .init(name: "enableTotalRecordCount", value: "true"), .init(name: "limit", value: String(seriesIDs.count))
            ]))
            shows = Dictionary(page.items.filter { $0.type == "Series" }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        return try decode(await request("Shows/\(seriesID)/Seasons", query: [
            .init(name: "userId", value: session.userID), .init(name: "enableUserData", value: "true"),
            .init(name: "enableImages", value: "true"), .init(name: "imageTypeLimit", value: "1")
        ]))
    }

    public func episodes(seriesID: String, seasonID: String, startIndex: Int = 0, limit: Int = 100) async throws -> VideoPage {
        guard let session else { throw JellyfinError.unauthorized }
        return try decode(await request("Shows/\(seriesID)/Episodes", query: [
            .init(name: "userId", value: session.userID), .init(name: "seasonId", value: seasonID),
            .init(name: "sortBy", value: "IndexNumber"),
            .init(name: "startIndex", value: String(startIndex)), .init(name: "limit", value: String(limit)),
            .init(name: "isMissing", value: "false"), .init(name: "fields", value: "Overview,Genres"),
            .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
            .init(name: "imageTypeLimit", value: "1")
        ]))
    }

    public func resumeVideos(limit: Int = 100, startIndex: Int = 0, itemTypes: [String] = []) async throws -> VideoPage {
        guard let session else { throw JellyfinError.unauthorized }
        var query: [URLQueryItem] = [
            .init(name: "userId", value: session.userID), .init(name: "mediaTypes", value: "Video"),
            .init(name: "enableUserData", value: "true"), .init(name: "enableImages", value: "true"),
            .init(name: "imageTypeLimit", value: "1"), .init(name: "limit", value: String(limit)),
            .init(name: "startIndex", value: String(startIndex)),
            .init(name: "fields", value: "Overview,Genres")
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
            if let own = item.backdropImageTags?.first { tag = own }
            else { itemID = item.parentBackdropItemID ?? item.id; tag = item.parentBackdropImageTags?.first }
        case .logo:
            if let own = item.imageTags?[type.rawValue] { tag = own }
            else { itemID = item.parentLogoItemID ?? item.id; tag = item.parentLogoImageTag }
        }
        guard let tag, !tag.isEmpty else { return nil }
        var query: [URLQueryItem] = [.init(name: "tag", value: tag),
                                    .init(name: "maxWidth", value: String(max(1, min(3840, maxWidth))))]
        if type == .backdrop { query.append(.init(name: "imageIndex", value: "0")) }
        if type == .logo { query.append(.init(name: "format", value: "Png")) }
        let url = try endpoint("Items/\(itemID)/Images/\(type.rawValue)", query: query)
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    public func playback(for item: VideoItem, compatibleOnly: Bool = false) async throws -> PlaybackStream {
        guard let session else { throw JellyfinError.unauthorized }
        let body = PlaybackBody(UserId: session.userID, EnableDirectPlay: !compatibleOnly,
                                AllowVideoStreamCopy: !compatibleOnly, AllowAudioStreamCopy: !compatibleOnly)
        let response: PlaybackResponse = try decode(await request("Items/\(item.id)/PlaybackInfo",
                                                                   method: "POST", body: body))
        if let error = response.ErrorCode, !error.isEmpty { throw JellyfinError.noPlayableSource }
        // Only use server stream endpoints. A MediaSource.Path can be a path on the server's disk.
        let sources = response.MediaSources.filter { $0.RequiresOpening != true }
        // Check all source versions for direct playback before accepting conversion.
        if !compatibleOnly {
            for source in sources where source.SupportsDirectPlay == true {
                guard let container = Self.streamContainer(source.Container) else { continue }
                let url = try endpoint("Videos/\(item.id)/stream.\(container)", query: [
                    .init(name: "static", value: "true"), .init(name: "mediaSourceId", value: source.Id),
                    .init(name: "deviceId", value: deviceID),
                    .init(name: "playSessionId", value: response.PlaySessionId ?? "")
                ])
                var stream = PlaybackStream(url: try authorizeStream(url), itemID: item.id,
                                      mediaSourceID: source.Id, playSessionID: response.PlaySessionId ?? "",
                                      method: "DirectPlay")
                stream.externalSubtitles = try externalSubtitles(source: source)
                stream.videoAspectRatio = source.videoAspectRatio
                stream.resumePositionSeconds = item.resumePositionSeconds
                return stream
            }
        }
        for source in sources {
            if let path = source.TranscodingUrl, !path.isEmpty {
                let url = try resolveStream(path)
                return PlaybackStream(url: try authorizeStream(url), itemID: item.id,
                                      mediaSourceID: source.Id, playSessionID: response.PlaySessionId ?? "",
                                      method: "Transcode", videoAspectRatio: source.videoAspectRatio,
                                      resumePositionSeconds: item.resumePositionSeconds)
            }
        }
        throw JellyfinError.noPlayableSource
    }

    public func imageRequest(for person: VideoPerson, maxWidth: Int = 400) throws -> URLRequest? {
        guard session != nil else { throw JellyfinError.unauthorized }
        guard let id = person.itemID, !id.isEmpty, let tag = person.primaryImageTag, !tag.isEmpty else { return nil }
        let url = try endpoint("Items/\(id)/Images/Primary", query: [
            .init(name: "tag", value: tag), .init(name: "maxWidth", value: String(max(1, min(1200, maxWidth))))
        ])
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    private static func streamContainer(_ raw: String?) -> String? {
        let supported = Set(["mp4", "mkv", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "asf", "flv", "ogv", "ogg", "vob", "3gp"])
        let containers = (raw ?? "").lowercased().split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.map { $0 == "matroska" ? "mkv" : ($0 == "mpegts" ? "ts" : $0) }
        // FFmpeg reports MOV/MP4 using a shared list; MP4 is the useful stream extension.
        if containers.contains("mp4") { return "mp4" }
        return containers.first { supported.contains($0) }
    }

    private func externalSubtitles(source: MediaSource) throws -> [PlaybackSubtitle] {
        try (source.MediaStreams ?? []).compactMap { track in
            guard track.Type == "Subtitle", track.IsExternal == true, let delivery = track.DeliveryUrl,
                  !delivery.isEmpty else { return nil }
            return PlaybackSubtitle(id: track.Index, name: track.DisplayTitle ?? track.Title ?? track.Language ?? "Subtitle \(track.Index)",
                                    url: try authorizeStream(resolveStream(delivery)))
        }
    }

    /// Keep Jellyfin's session and transcode lifecycle informed by the native player.
    public func reportPlayback(_ event: PlaybackEvent, stream: PlaybackStream,
                               seconds: Double, paused: Bool = false) async throws {
        let safeSeconds = seconds.isFinite ? max(0, min(seconds, 1e10)) : 0
        let body = PlaybackReport(ItemId: stream.itemID, MediaSourceId: stream.mediaSourceID,
                                  PlaySessionId: stream.playSessionID, PositionTicks: Int64(safeSeconds * 10_000_000),
                                  IsPaused: paused, PlayMethod: stream.method)
        _ = try await request("Sessions/Playing\(event.suffix)", method: "POST", body: body)
    }

    public func logout() async throws { _ = try await request("Sessions/Logout", method: "POST") }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
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
        let relative = (!prefix.isEmpty && clean.hasPrefix(prefix + "/")) ? String(clean.dropFirst(prefix.count + 1)) : clean
        guard let url = URL(string: relative, relativeTo: URL(string: serverURL.absoluteString + "/")!)?.absoluteURL else {
            throw JellyfinError.invalidResponse
        }
        return url
    }

    private func authorizeStream(_ url: URL) throws -> URL {
        guard let session else { throw JellyfinError.unauthorized }
        guard url.scheme == serverURL.scheme, url.host == serverURL.host,
              effectivePort(url) == effectivePort(serverURL), url.user == nil, url.password == nil,
              serverURL.path.isEmpty || url.path.hasPrefix(serverURL.path + "/") else {
            throw JellyfinError.unsafeStreamURL
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Player engines fetch streams themselves; Jellyfin supports query authentication here.
        var query = (parts.queryItems ?? []).filter { !["api_key", "token"].contains($0.name.lowercased()) }
        query.append(.init(name: "api_key", value: session.accessToken))
        parts.queryItems = query
        return parts.url!
    }

    private func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }

    private var authorization: String {
        let token = session.map { ", Token=\"\(escape($0.accessToken))\"" } ?? ""
        return "MediaBrowser Client=\"Theatre\", Device=\"Mac\", DeviceId=\"\(escape(deviceID))\", Version=\"0.1.0\"\(token)"
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: (any Encodable)? = nil) async throws -> Data {
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
        case 401, 403: throw JellyfinError.unauthorized
        default: throw JellyfinError.serverStatus(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JellyfinError.invalidResponse }
    }
}

public enum PlaybackEvent: Sendable {
    case started, progress, stopped
    var suffix: String { switch self { case .started: return ""; case .progress: return "/Progress"; case .stopped: return "/Stopped" } }
}

private struct LoginBody: Encodable { let Username: String; let Pw: String }
private struct LoginResponse: Decodable {
    struct UserInfo: Decodable { let Id: String; let Name: String? }
    let AccessToken: String; let User: UserInfo
}
private struct PlaybackResponse: Decodable {
    let MediaSources: [MediaSource]; let PlaySessionId: String?; let ErrorCode: String?
}
private struct MediaSource: Decodable {
    let Id: String; let Container: String?; let SupportsDirectPlay: Bool?
    let RequiresOpening: Bool?; let TranscodingUrl: String?
    let MediaStreams: [MediaStream]?
    var videoAspectRatio: Double? {
        MediaStreams?.first { $0.Type == "Video" && $0.IsAttachedPic != true }?.videoAspectRatio
    }
}
private struct MediaStream: Decodable {
    let Index: Int; let `Type`: String?; let IsExternal: Bool?; let DeliveryUrl: String?
    let DisplayTitle: String?; let Title: String?; let Language: String?
    let Width: Int?; let Height: Int?; let AspectRatio: String?; let IsAttachedPic: Bool?
    var videoAspectRatio: Double? {
        if let text = AspectRatio {
            let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" })
            let ratio: Double?
            if parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), height > 0 {
                ratio = width / height
            } else { ratio = Double(text) }
            if let ratio, ratio.isFinite, ratio > 0 { return ratio }
        }
        guard let Width, let Height, Width > 0, Height > 0 else { return nil }
        return Double(Width) / Double(Height)
    }
}
private struct PlaybackBody: Encodable {
    let UserId: String
    let EnableDirectPlay: Bool
    let EnableDirectStream = true
    let EnableTranscoding = true
    let AllowVideoStreamCopy: Bool
    let AllowAudioStreamCopy: Bool
    let AutoOpenLiveStream = false
    let MaxStreamingBitrate = 200_000_000
    let MaxAudioChannels = 8
    let StartTimeTicks = 0
    let DeviceProfile = VLCDeviceProfile()
}
private struct VLCDeviceProfile: Encodable {
    let Name = "Theatre VLCKit"
    let MaxStreamingBitrate = 200_000_000
    let MaxStaticBitrate = 200_000_000
    let DirectPlayProfiles = [DirectProfile()]
    let TranscodingProfiles = [TranscodingProfile()]
    let SubtitleProfiles = [SubtitleProfile(Format: "srt", Method: "External"),
                            SubtitleProfile(Format: "subrip", Method: "External"),
                            SubtitleProfile(Format: "ass", Method: "External"),
                            SubtitleProfile(Format: "ssa", Method: "External"),
                            SubtitleProfile(Format: "vtt", Method: "External"),
                            SubtitleProfile(Format: "srt", Method: "Embed"),
                            SubtitleProfile(Format: "subrip", Method: "Embed"),
                            SubtitleProfile(Format: "ass", Method: "Embed"),
                            SubtitleProfile(Format: "ssa", Method: "Embed"),
                            SubtitleProfile(Format: "pgssub", Method: "Embed"),
                            SubtitleProfile(Format: "dvdsub", Method: "Embed")]
}
private struct DirectProfile: Encodable {
    let Container = "mp4,mkv,m4v,mov,avi,webm,ts,m2ts,mts,mpeg,mpg,wmv,asf,flv,ogv,ogg,vob,3gp"
    let `Type` = "Video"
    let VideoCodec = "h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,av1,vc1,theora,mjpeg,h263,wmv2,wmv3"
    let AudioCodec = "aac,ac3,eac3,mp3,mp2,flac,alac,dts,truehd,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,wmapro,wmav2"
}
private struct TranscodingProfile: Encodable {
    let Container = "ts"; let `Type` = "Video"; let VideoCodec = "h264"; let AudioCodec = "aac"
    let `Protocol` = "hls"; let Context = "Streaming"; let MaxAudioChannels = "2"
    let MinSegments = 2; let SegmentLength = 4; let BreakOnNonKeyFrames = false
}
private struct SubtitleProfile: Encodable { let Format: String; let Method: String }
private struct PlaybackReport: Encodable {
    let ItemId: String; let MediaSourceId: String; let PlaySessionId: String
    let PositionTicks: Int64; let IsPaused: Bool; let PlayMethod: String
    let CanSeek = true
}
