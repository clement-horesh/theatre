import Foundation

/// Credentials and authenticated assets must remain on their original server.
public final class JellyfinRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = JellyfinRedirectPolicy()

    public static func allowsRedirect(from origin: URL?, to target: URL?) -> Bool {
        guard let origin, let target, target.user == nil, target.password == nil,
            let scheme = origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
            scheme == target.scheme?.lowercased(),
            let host = origin.host?.lowercased(), host == target.host?.lowercased()
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (origin.port ?? defaultPort) == (target.port ?? defaultPort)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}
