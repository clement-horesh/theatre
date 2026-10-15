import Foundation
import JellyfinKit

/// Preserve server event order even when a slow request overlaps pause, seek, or close.
@MainActor
final class PlaybackReporter {
    private(set) var pendingTask: Task<Void, Error>?
    private var lastPosition: Double?
    private var lastPaused = false
    private var queuedProgressReports = 0

    func progress(
        client: JellyfinClient, stream: PlaybackStream, seconds: Double,
        paused: Bool
    ) -> Task<Void, Error>? {
        // Leave room for the next observed pause/position without accumulating a
        // growing backlog when the server is slower than the playback timer.
        guard seconds.isFinite, seconds >= 0, queuedProgressReports < 2 else { return nil }
        let event: PlaybackEvent
        if let lastPosition {
            guard paused != lastPaused || abs(seconds - lastPosition) >= 10 else { return nil }
            event = .progress
        } else {
            event = .started
        }
        lastPosition = seconds
        lastPaused = paused
        return send(event, client: client, stream: stream, seconds: seconds, paused: paused, countsAsProgress: true)
    }

    func stop(client: JellyfinClient, stream: PlaybackStream, seconds: Double) -> Task<Void, Error> {
        lastPosition = nil
        lastPaused = false
        return send(.stopped, client: client, stream: stream, seconds: seconds)
    }

    private func send(
        _ event: PlaybackEvent, client: JellyfinClient, stream: PlaybackStream,
        seconds: Double, paused: Bool = false, countsAsProgress: Bool = false
    ) -> Task<Void, Error> {
        let previous = pendingTask
        if countsAsProgress { queuedProgressReports += 1 }
        let task = Task { [weak self] in
            defer { if countsAsProgress { self?.queuedProgressReports -= 1 } }
            // A failed report must not prevent subsequent reports or the final stop.
            _ = try? await previous?.value
            try await client.reportPlayback(event, stream: stream, seconds: seconds, paused: paused)
        }
        pendingTask = task
        return task
    }
}
