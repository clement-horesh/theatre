import Foundation

/// URLSession owns the HTTP transfer, range requests and resumable data.
final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let id: UUID
    private let destination: URL
    private let onProgress: @MainActor (Int64, Int64) -> Void
    private let onComplete: @MainActor (Result<URL, Error>) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    private var result: Result<URL, Error>?
    private var lastProgress = Date.distantPast

    init(
        id: UUID = UUID(), request: URLRequest, resumeData: Data?, destination: URL,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void,
        onComplete: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        self.id = id
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
    }

    func start() { task.resume() }
    func cancel() { session.invalidateAndCancel() }

    func pause() async -> Data? {
        await withCheckedContinuation { continuation in
            task.cancel { data in continuation.resume(returning: data) }
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard Date().timeIntervalSince(lastProgress) >= 0.25 else { return }
        lastProgress = Date()
        Task { @MainActor in onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw JellyfinDownloadError.invalidFile
            }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw JellyfinDownloadError.signIn
            case 403: throw JellyfinDownloadError.permission
            default: throw JellyfinDownloadError.http(response.statusCode)
            }
            guard !["application/json", "text/html"].contains(response.mimeType ?? ""),
                (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
            else { throw JellyfinDownloadError.invalidFile }
            try? FileManager.default.removeItem(at: destination)
            // The URLSession temporary file only exists for this delegate callback.
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            result = .success(destination)
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome =
            error.map { Result<URL, Error>.failure($0) } ?? result ?? .failure(JellyfinDownloadError.invalidFile)
        session.finishTasksAndInvalidate()
        Task { @MainActor in onComplete(outcome) }
    }

    // Downloads never follow a redirect carrying credentials to a different server.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let origin = task.originalRequest?.url
        let target = request.url
        let sameServer =
            origin?.scheme == target?.scheme && origin?.host == target?.host && origin?.port == target?.port
        completionHandler(sameServer ? request : nil)
    }
}

enum JellyfinDownloadError: LocalizedError {
    case permission, signIn, invalidFile, diskSpace
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .permission: "Downloading isn’t allowed for this Jellyfin account or title."
        case .signIn: "Your sign-in expired. Reconnect to Jellyfin, then retry the download."
        case .invalidFile: "The server didn’t return a complete video file."
        case .diskSpace: "There isn’t enough available storage for this download."
        case .http(let status): "The download failed (HTTP \(status)). Try again when the server is available."
        }
    }
}
