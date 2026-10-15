import Foundation

/// Deterministic network responses, including delayed replies and cancellation.
final class TestURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var data = Data()
        var delay: TimeInterval = 0

        static func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, data: Data(text.utf8), delay: delay)
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private var delivery: DispatchWorkItem?

    static func session(handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        lock.withLock { self.handler = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.lock.withLock({ Self.handler }) else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            let delivery = DispatchWorkItem { [weak self] in
                guard let self, let url = self.request.url,
                    let response = HTTPURLResponse(
                        url: url, statusCode: reply.status,
                        httpVersion: nil, headerFields: nil)
                else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            self.delivery = delivery
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: delivery)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { delivery?.cancel() }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return body
    }
}
