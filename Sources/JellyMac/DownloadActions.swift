import JellyfinKit
import SwiftUI

/// Shared by title menus, episode menus and the detail-page download button.
struct DownloadActions: View {
    @ObservedObject var downloads: DownloadManager
    let video: VideoItem

    var body: some View {
        if video.type == "Series" {
            let episodes = downloads.records.filter { $0.video.seriesID == video.id && $0.state != .removed }
            if !episodes.isEmpty {
                if episodes.contains(where: \.isActive) {
                    Button("Pause Downloads") {
                        Task { for record in episodes where record.isActive { await downloads.pause(record) } }
                    }
                }
                if episodes.contains(where: { $0.state == .paused || $0.state == .failed }) {
                    Button("Resume Downloads") {
                        for record in episodes where record.state == .paused || record.state == .failed {
                            downloads.start(record.video)
                        }
                    }
                }
                Button("Remove Downloads") { Task { for record in episodes { await downloads.remove(record) } } }
            }
        } else if video.type == "Movie" || video.type == "Episode" {
            if let record = downloads.record(for: video) {
                if record.isActive {
                    Button {
                        Task { await downloads.pause(record) }
                    } label: {
                        Label("Pause Download", systemImage: "pause.circle")
                    }
                } else if record.state == .paused || record.state == .failed {
                    Button {
                        downloads.start(video)
                    } label: {
                        Label(
                            record.state == .failed ? "Retry Download" : "Resume Download",
                            systemImage: "arrow.down.circle")
                    }
                }
                if let error = record.error { Text(error) }
                Button {
                    Task { await downloads.remove(record) }
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
                .disabled(record.state == .pausing)
            } else {
                Button {
                    downloads.start(video)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct DownloadButton: View {
    @ObservedObject var downloads: DownloadManager
    let video: VideoItem
    var body: some View {
        if video.type == "Movie" || video.type == "Episode" {
            if downloads.record(for: video) == nil {
                Button {
                    downloads.start(video)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glassSurface(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    DownloadActions(downloads: downloads, video: video)
                } label: {
                    Label(
                        downloads.record(for: video)?.state == .complete ? "Downloaded" : "Download",
                        systemImage: downloads.record(for: video)?.state == .complete
                            ? "checkmark.circle" : "arrow.down.circle"
                    )
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassSurface(in: Capsule(), interactive: true)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }
}

struct DownloadStatus: View {
    @ObservedObject var downloads: DownloadManager
    let video: VideoItem
    private var records: [DownloadRecord] {
        downloads.records.filter { $0.state != .removed && ($0.video.id == video.id || $0.video.seriesID == video.id) }
    }
    var body: some View {
        let entries = records
        if !entries.isEmpty {
            HStack(spacing: 6) {
                if entries.contains(where: \.isActive) {
                    ProgressView(
                        value: Double(entries.reduce(Int64(0)) { $0 + $1.received }),
                        total: Double(max(1, entries.reduce(Int64(0)) { $0 + $1.expected }))
                    )
                    .frame(width: 60)
                    Text("Downloading")
                } else if entries.contains(where: { $0.state == .failed }) {
                    Image(systemName: "exclamationmark.circle")
                    Text("Download failed")
                } else if entries.contains(where: { $0.state != .complete }) {
                    Image(systemName: "pause.circle")
                    Text("Paused")
                } else {
                    Image(systemName: "checkmark.circle")
                    Text(
                        video.type == "Series"
                            ? "\(entries.count) episodes"
                            : ByteCountFormatter.string(fromByteCount: entries[0].received, countStyle: .file))
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
