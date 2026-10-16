import JellyfinKit
import SwiftUI
import WebKit

struct TrailerPresentation: Codable, Hashable {
    let title: String
    let url: URL
}

struct TrailerView: View {
    let trailer: TrailerPresentation

    var body: some View {
        TrailerWebView(url: trailer.url)
            .frame(minWidth: 640, minHeight: 360)
            .navigationTitle("\(trailer.title) — Trailer")
            .toolbar {
                Link(destination: trailer.url) {
                    Label("Open in Browser", systemImage: "safari")
                }
                .help("Open in your browser if the trailer provider prevents playback here")
            }
    }
}

private struct TrailerWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        var request = URLRequest(url: RemoteTrailer.youtubeEmbedURL(for: url) ?? url)
        // YouTube requires the app's identity as Referer in desktop WebViews.
        let appID = (Bundle.main.bundleIdentifier ?? "local.jellymac.app").lowercased()
        request.setValue("https://\(appID)", forHTTPHeaderField: "Referer")
        view.load(request)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
    }
}
