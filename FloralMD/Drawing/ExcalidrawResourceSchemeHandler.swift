import Foundation
import WebKit

final class ExcalidrawResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "floralmd-drawing"
    static let entryURL = URL(string: "\(scheme)://local/index.html")!

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let filename = requestURL.lastPathComponent
        let fileURL = Bundle.main.url(
            forResource: (filename as NSString).deletingPathExtension,
            withExtension: (filename as NSString).pathExtension,
            subdirectory: "Vendor/Excalidraw"
        ) ?? Bundle.main.url(
            forResource: (filename as NSString).deletingPathExtension,
            withExtension: (filename as NSString).pathExtension
        )

        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: Self.mimeType(for: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: Self.isText(fileURL.pathExtension) ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func isText(_ fileExtension: String) -> Bool {
        ["html", "js", "css", "txt"].contains(fileExtension.lowercased())
    }

    private static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": "text/html"
        case "js": "text/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
