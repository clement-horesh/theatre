import Foundation
import JellyfinKit

struct DownloadRecord: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, preparing, downloading, pausing, paused, failed, complete, removed
    }
    let id: UUID
    var video: VideoItem
    var series: VideoItem?
    var state = State.preparing
    var prepared = false
    var videoFile = "video.media"
    var sourceID = ""
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var artworks: [String: String] = [:]
    var subtitles: [Subtitle] = []
    var nextEpisodeID: String?
    var creditsStart: Double?
    var intro: MediaSegment?
    var progress: Progress?

    struct Subtitle: Codable, Sendable {
        let index: Int
        let name: String
        let file: String
    }
    struct Progress: Codable, Equatable, Sendable {
        var data: VideoUserData
        let updated: Date
        var paused = false
        var pendingSync = true
    }
    var isActive: Bool { state == .queued || state == .preparing || state == .downloading }
    var remainingBytes: Int64 { max(0, expected) - min(max(0, received), max(0, expected)) }
    var displayedVideo: VideoItem {
        var snapshot = video
        if let progress { snapshot.userData = progress.data }
        return snapshot
    }
}
