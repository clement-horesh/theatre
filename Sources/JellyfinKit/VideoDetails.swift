import Foundation

public struct VideoPerson: Decodable, Identifiable, Sendable, Equatable {
    public let itemID: String?
    public let name: String
    public let role: String?
    public let type: String?
    public let primaryImageTag: String?
    public var id: String { "\(itemID ?? name):\(type ?? ""):\(role ?? "")" }
    public var credit: String { (role?.isEmpty == false ? role : type) ?? "" }
    enum CodingKeys: String, CodingKey {
        case itemID = "Id", name = "Name", role = "Role", type = "Type", primaryImageTag = "PrimaryImageTag"
    }
}

public struct VideoStudio: Decodable, Sendable, Equatable {
    public let name: String
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

public struct VideoDetailSource: Decodable, Sendable, Equatable {
    public let mediaStreams: [VideoDetailStream]?
    enum CodingKeys: String, CodingKey { case mediaStreams = "MediaStreams" }
}

public struct VideoDetailStream: Decodable, Sendable, Equatable {
    public let type: String?
    public let language: String?
    public let displayTitle: String?
    public let title: String?
    public let codec: String?
    public let profile: String?
    public let channelLayout: String?
    public let channels: Int?
    public let width: Int?
    public let height: Int?
    public let videoRange: String?
    public let videoRangeType: String?
    public let audioSpatialFormat: String?
    public let isOriginal: Bool?
    public let isHearingImpaired: Bool?
    public let isAttachedPic: Bool?
    enum CodingKeys: String, CodingKey {
        case type = "Type", language = "Language", displayTitle = "DisplayTitle", title = "Title"
        case codec = "Codec", profile = "Profile", channelLayout = "ChannelLayout", channels = "Channels"
        case width = "Width", height = "Height", videoRange = "VideoRange", videoRangeType = "VideoRangeType"
        case audioSpatialFormat = "AudioSpatialFormat", isOriginal = "IsOriginal"
        case isHearingImpaired = "IsHearingImpaired", isAttachedPic = "IsAttachedPic"
    }
    public var languageName: String? {
        guard let language, !language.isEmpty, language != "und" else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: language)?.capitalized ?? language
    }
    public var label: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        return [languageName, title, codec?.uppercased(), channelLayout ?? channels.map { "\($0) channels" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func hasTag(_ tag: String) -> Bool {
        [title, displayTitle].compactMap { $0 }.contains {
            $0.range(of: "\\b\(tag)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
    public var hasSDH: Bool { type == "Subtitle" && (isHearingImpaired == true || hasTag("SDH")) }
    public var hasCC: Bool { type == "Subtitle" && (["eia_608", "eia_708"].contains(codec ?? "") || hasTag("CC")) }
    public var hasAudioDescription: Bool {
        type == "Audio" && (hasTag("AD") || hasTag("Audio Description") || hasTag("Descriptive"))
    }
}

public extension VideoItem {
    var detailStreams: [VideoDetailStream] {
        if let mediaStreams, !mediaStreams.isEmpty { return mediaStreams }
        return mediaSources?.first?.mediaStreams ?? []
    }
    var actors: [VideoPerson] { (people ?? []).filter { $0.type == "Actor" } }
    var directors: [VideoPerson] { (people ?? []).filter { $0.type == "Director" } }
    var runtimeLabel: String? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        let minutes = max(1, runTimeTicks / 600_000_000)
        return minutes < 60 ? "\(minutes)m" : (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m")
    }
    var mediaBadges: [String] {
        let streams = detailStreams
        var badges: [String] = []
        if let picture = streams.first(where: { $0.type == "Video" && $0.isAttachedPic != true }) {
            if (picture.width ?? 0) >= 3840 || (picture.height ?? 0) >= 2160 { badges.append("4K") }
            else if (picture.width ?? 0) >= 1280 || (picture.height ?? 0) >= 720 { badges.append("HD") }
            let range = picture.videoRangeType ?? ""
            if range.hasPrefix("DOVI"), !range.contains("Invalid") { badges.append("Dolby Vision") }
            else if picture.videoRange == "HDR" || ["HDR10", "HDR10Plus", "HLG"].contains(range) { badges.append("HDR") }
        }
        if streams.contains(where: { $0.type == "Audio" && ($0.audioSpatialFormat == "DolbyAtmos" || $0.profile?.localizedCaseInsensitiveContains("Dolby Atmos") == true) }) {
            badges.append("Dolby Atmos")
        }
        if streams.contains(where: \.hasCC) { badges.append("CC") }
        if streams.contains(where: \.hasSDH) { badges.append("SDH") }
        if streams.contains(where: \.hasAudioDescription) { badges.append("AD") }
        return badges
    }
}
