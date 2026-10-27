import Foundation
import JellyfinKit

/// Let URLSession handle modern HTTPS while VLC keeps decoding the original video.
final class HTTPVideoStream: InputStream, @unchecked Sendable {
    private let url: URL
    private let session = URLSession(
        configuration: .ephemeral, delegate: JellyfinRedirectPolicy.shared, delegateQueue: nil)
    private let condition = NSCondition()
    private var task: URLSessionDataTask?
    private var reply: (Data?, URLResponse?, Error?)?
    private var status: Stream.Status = .notOpen
    private var failure: Error?
    private var offset: Int64 = 0
    private var length: Int64?
    private var buffer = Data()
    private var bufferOffset: Int64 = 0

    override init(url: URL) {
        self.url = url
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { condition.withLock { status } }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { streamStatus == .open }
    override func open() { condition.withLock { status = .open } }
    override func close() {
        condition.lock()
        status = .closed
        let active = task
        condition.broadcast()
        condition.unlock()
        active?.cancel()
        session.invalidateAndCancel()
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        key == .fileCurrentOffsetKey ? NSNumber(value: offset) : nil
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey, let value = property as? NSNumber, value.int64Value >= 0 else {
            return false
        }
        offset = value.int64Value
        return true
    }

    override func read(_ target: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard streamStatus == .open else { return -1 }
        if len == 0 || length.map({ offset >= $0 }) == true { return 0 }
        if offset < bufferOffset || offset >= bufferOffset + Int64(buffer.count) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("bytes=\(offset)-\(offset + 1_048_575)", forHTTPHeaderField: "Range")
            condition.lock()
            guard status == .open else {
                condition.unlock()
                return -1
            }
            reply = nil
            task = session.dataTask(with: request) { [self] data, response, error in
                condition.lock()
                reply = (data, response, error)
                condition.broadcast()
                condition.unlock()
            }
            task?.resume()
            while reply == nil && status != .closed { condition.wait() }
            let result = reply
            let closed = status == .closed
            condition.unlock()
            guard !closed else { return -1 }
            guard let result, result.2 == nil, let data = result.0,
                let response = result.1 as? HTTPURLResponse,
                response.statusCode == 206 || (response.statusCode == 200 && offset == 0)
            else {
                failure = result?.2 ?? URLError(.badServerResponse)
                condition.withLock { status = .error }
                return -1
            }
            if let range = response.value(forHTTPHeaderField: "Content-Range") {
                guard range.hasPrefix("bytes \(offset)-") else { return -1 }
                length = range.split(separator: "/").last.flatMap { Int64($0) }
            } else if response.statusCode == 200 {
                length = Int64(data.count)
            }
            buffer = data
            bufferOffset = offset
        }
        let start = Int(offset - bufferOffset)
        let count = min(len, buffer.count - start)
        buffer.copyBytes(to: target, from: start..<(start + count))
        offset += Int64(count)
        return count
    }
}
