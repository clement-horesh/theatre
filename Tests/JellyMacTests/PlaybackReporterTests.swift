import Foundation
import XCTest

@testable import JellyMac
@testable import JellyfinKit

final class PlaybackReporterTests: XCTestCase {
    @MainActor
    private func client(transport: URLSession) throws -> JellyfinClient {
        let session = try JSONDecoder().decode(
            JellyfinSession.self,
            from:
                Data(#"{"userID":"user","username":"demo","accessToken":"test-only-token"}"#.utf8))
        return try JellyfinClient(
            address: "https://theatre.test", deviceID: "test",
            transport: transport, session: session)
    }

    private var stream: PlaybackStream {
        PlaybackStream(
            url: URL(string: "https://theatre.test/stream")!, itemID: "movie",
            mediaSourceID: "source", playSessionID: "play", method: "DirectPlay")
    }

    @MainActor
    func testSlowStartCannotOvertakePauseResumeOrStopReports() async throws {
        var paths: [String] = []
        var paused: [Bool] = []
        let transport = TestURLProtocol.session { request in
            paths.append(request.url!.path)
            paused.append(try TestURLProtocol.body(request)["IsPaused"] as? Bool ?? false)
            return .json("", status: 204, delay: paths.count == 1 ? 0.05 : 0)
        }
        defer { transport.invalidateAndCancel() }
        let client = try client(transport: transport)
        let reporter = PlaybackReporter()
        XCTAssertNotNil(reporter.progress(client: client, stream: stream, seconds: 0, paused: false))
        XCTAssertNil(reporter.progress(client: client, stream: stream, seconds: 1, paused: false))
        let pause = reporter.progress(client: client, stream: stream, seconds: 1, paused: true)
        XCTAssertNotNil(pause)
        try await pause?.value
        XCTAssertNotNil(reporter.progress(client: client, stream: stream, seconds: 1, paused: false))
        try await reporter.stop(client: client, stream: stream, seconds: 2).value
        XCTAssertEqual(
            paths,
            [
                "/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Progress",
                "/Sessions/Playing/Stopped",
            ])
        XCTAssertEqual(paused, [false, true, false, false])
        let next = reporter.progress(client: client, stream: stream, seconds: 0, paused: false)
        try await next?.value
        XCTAssertEqual(paths.last, "/Sessions/Playing")
    }

    @MainActor
    func testFailedReportDoesNotPreventFinalStop() async throws {
        var paths: [String] = []
        let transport = TestURLProtocol.session { request in
            paths.append(request.url!.path)
            return .json("", status: paths.count == 1 ? 503 : 204)
        }
        defer { transport.invalidateAndCancel() }
        let client = try client(transport: transport)
        let reporter = PlaybackReporter()
        _ = reporter.progress(client: client, stream: stream, seconds: 1, paused: false)
        try await reporter.stop(client: client, stream: stream, seconds: 2).value
        XCTAssertEqual(paths, ["/Sessions/Playing", "/Sessions/Playing/Stopped"])
    }

    @MainActor
    func testSlowServerDoesNotAccumulateUnboundedProgressRequests() async throws {
        var paths: [String] = []
        let transport = TestURLProtocol.session { request in
            paths.append(request.url!.path)
            return .json("", status: 204, delay: 0.02)
        }
        defer { transport.invalidateAndCancel() }
        let client = try client(transport: transport)
        let reporter = PlaybackReporter()
        for position in stride(from: 0.0, through: 500, by: 10) {
            _ = reporter.progress(client: client, stream: stream, seconds: position, paused: false)
        }
        try await reporter.stop(client: client, stream: stream, seconds: 500).value
        XCTAssertEqual(paths, ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
    }
}
