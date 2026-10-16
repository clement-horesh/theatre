import Foundation
import JellyfinKit

struct DownloadRecord: Codable, Identifiable {
    enum State: String, Codable { case preparing, downloading, pausing, paused, failed, complete, removed }
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
    var progress: Progress?

    struct Subtitle: Codable {
        let index: Int
        let name: String
        let file: String
    }
    struct Progress: Codable, Equatable {
        var data: VideoUserData
        let updated: Date
        var paused = false
        var pendingSync = true
    }
    var isActive: Bool { state == .preparing || state == .downloading }
    var displayedVideo: VideoItem {
        var snapshot = video
        if let progress { snapshot.userData = progress.data }
        return snapshot
    }
}
