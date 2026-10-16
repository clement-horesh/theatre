import Foundation
import XCTest

@testable import JellyfinKit

final class RemoteTrailerTests: XCTestCase {
    private func video(_ trailers: String) throws -> VideoItem {
        try JSONDecoder().decode(
            VideoItem.self,
            from: Data("{\"Id\":\"movie\",\"Name\":\"Movie\",\"RemoteTrailers\":\(trailers)}".utf8))
    }

    func testJellyfinTrailerMetadataSkipsInvalidLinksAndSurvivesCaching() throws {
        let movie = try video(
            #"[{"Url":"javascript:alert(1)"},{"Url":null},{"Url":"https://www.youtube.com/watch?v=abcdefghijk","Name":"Official Trailer"}]"#
        )
        XCTAssertEqual(
            movie.remoteTrailers?.compactMap(\.webURL).first?.absoluteString,
            "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(movie.remoteTrailers?.last?.name, "Official Trailer")
        XCTAssertEqual(try JSONDecoder().decode(VideoItem.self, from: JSONEncoder().encode(movie)), movie)
        XCTAssertNil(try video("null").remoteTrailers)
        XCTAssertEqual(try video("[]").remoteTrailers, [])
        XCTAssertNil(try video(#"[{"Url":"https://user:password@example.com/trailer"}]"#).remoteTrailers?.first?.webURL)
    }

    func testYouTubeLinksIncludingKodiMetadataUseTheOfficialEmbed() throws {
        for link in [
            "https://www.youtube.com/watch?v=abcdefghijk&feature=shared", "https://youtu.be/abcdefghijk?t=4",
            "https://www.youtube.com/embed/abcdefghijk", "https://www.youtube.com/shorts/abcdefghijk",
            "plugin://plugin.video.youtube/?action=play_video&videoid=abcdefghijk",
        ] {
            let encoded = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
            let url = try XCTUnwrap(try video("[{\"Url\":\(encoded)}]").remoteTrailers?.first?.webURL)
            XCTAssertEqual(
                RemoteTrailer.youtubeEmbedURL(for: url)?.absoluteString,
                "https://www.youtube.com/embed/abcdefghijk?autoplay=1&playsinline=1")
            XCTAssertEqual(
                RemoteTrailer.youtubeThumbnailURL(for: url)?.absoluteString,
                "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
        }
        XCTAssertNil(
            RemoteTrailer.youtubeEmbedURL(for: URL(string: "https://youtube.com.evil.test/watch?v=abcdefghijk")!))
        XCTAssertNil(RemoteTrailer.youtubeEmbedURL(for: URL(string: "https://www.youtube.com/watch?v=bad")!))
    }
}
