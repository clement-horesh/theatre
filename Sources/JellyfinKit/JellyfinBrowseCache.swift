import Foundation

/// Session-only browse data; the lock keeps invalidation ahead of in-flight replies.
final class JellyfinBrowseCache: @unchecked Sendable {
    private let responses = NSCache<NSURL, NSData>()
    private let lock = NSLock()
    private var generation = UUID()

    init() {
        responses.totalCostLimit = 16 * 1024 * 1024
        responses.countLimit = 256
    }

    func response(for url: URL) -> (data: Data?, generation: UUID) {
        lock.withLock { (responses.object(forKey: url as NSURL).map { $0 as Data }, generation) }
    }

    func store(_ data: Data, for url: URL, generation: UUID) {
        lock.withLock {
            guard self.generation == generation else { return }
            responses.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
    }

    func clear() {
        lock.withLock {
            generation = UUID()
            responses.removeAllObjects()
        }
    }
}
