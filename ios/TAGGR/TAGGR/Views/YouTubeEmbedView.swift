// TAGGR/Views: Inline YouTube player matching the PWA's 16:9 embed.
import SwiftUI
import WebKit

struct YouTubeEmbedView: View {
    let preview: TaggrYouTubePreview

    var body: some View {
        YouTubeWebView(videoID: preview.id)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("YouTube video")
    }
}

private struct YouTubeWebView: UIViewRepresentable {
    let videoID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        context.coordinator.load(videoID: videoID, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(videoID: videoID, in: webView)
    }

    @MainActor
    final class Coordinator {
        private var loadedVideoID: String?

        func load(videoID: String, in webView: WKWebView) {
            guard loadedVideoID != videoID else { return }
            loadedVideoID = videoID
            let html = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
            <body style="margin:0;background:#000;overflow:hidden">
            <iframe src="https://www.youtube.com/embed/\(videoID)" style="border:0;width:100vw;height:100vh" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        }
    }
}
