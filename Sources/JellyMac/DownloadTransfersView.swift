import JellyfinKit
import SwiftUI

struct DownloadTransfersView: View {
    @ObservedObject var downloads: DownloadLibrary

    var body: some View {
        ForEach(downloads.accounts, id: \.directory) { account in
            DownloadAccountTransfersView(downloads: account, library: downloads)
        }
    }
}

private struct DownloadAccountTransfersView: View {
    @ObservedObject var downloads: DownloadManager
    let library: DownloadLibrary
    private var transfers: [DownloadRecord] {
        downloads.records.filter { $0.state != .complete && $0.state != .removed }
    }

    var body: some View {
        if downloads.isLoadingCatalog { ProgressView("Loading downloads…") }
        if let error = downloads.errorMessage { Text(error).foregroundStyle(.red) }
        if let warning = downloads.syncError {
            HStack {
                Text(warning).foregroundStyle(.secondary)
                Button("Sync Now") { downloads.synchronize() }
            }
        }
        if !transfers.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transfers").font(.title3.weight(.semibold))
                ForEach(transfers) { record in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.video.title).font(.body.weight(.medium)).lineLimit(1)
                            if let error = record.error {
                                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(
                                    horizontal: false, vertical: true)
                            } else {
                                Text(transferLabel(record.state))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if record.expected > 0 {
                                ProgressView(
                                    value: Double(min(record.received, record.expected)), total: Double(record.expected)
                                )
                                .accessibilityLabel("Download progress for \(record.video.title)")
                                Text(
                                    "\(ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: record.expected, countStyle: .file))"
                                )
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if record.isActive {
                            Button("Pause") { Task { await downloads.pause(record) } }
                        } else if record.state != .pausing {
                            Button(record.state == .failed ? "Retry" : "Resume") { downloads.start(record.video) }
                        }
                        Menu {
                            DownloadActions(downloads: library, video: record.video)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden).fixedSize().accessibilityLabel(
                            "Download options for \(record.video.title)")
                    }
                    .padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func transferLabel(_ state: DownloadRecord.State) -> String {
        switch state {
        case .queued: "Queued"
        case .preparing: "Preparing…"
        case .paused: "Paused"
        case .pausing: "Pausing…"
        case .failed: "Download failed"
        default: "Downloading…"
        }
    }

}

struct LibraryConnectionIssue: View {
    @ObservedObject var model: AppModel
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Retry") { Task { await model.loadVideos() } }
                if !model.downloads.titles.isEmpty {
                    Button("View Downloads") {
                        model.search = ""
                        model.libraryFilters = VideoFilters()
                        model.showsDownloads = true
                    }
                }
            }
        }
    }
}
