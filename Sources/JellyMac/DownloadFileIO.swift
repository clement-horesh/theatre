import Foundation

/// Serializes catalog and asset operations without blocking UI or playback.
final class DownloadFileIO: Sendable {
    // The immutable queue is the only stored state; operations execute serially.
    private let queue = DispatchQueue(label: "Theatre.download-files", qos: .utility)

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
