import AppKit
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

/// Finder Quick Look provider backed by FloralMD's existing preview renderer.
/// The HTML reply is self-contained for renderer assets, so the extension does
/// not need network access while displaying Markdown.
@MainActor
final class PreviewProvider: QLPreviewProvider, @preconcurrency QLPreviewingController {
    func providePreview(
        for request: QLFilePreviewRequest,
        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
    ) {
        do {
            let markdown = try String(contentsOf: request.fileURL, encoding: .utf8)
            let appearance = NSApplication.shared.effectiveAppearance
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            let colorScheme: MarkdownHTML.ColorScheme = bestMatch == .darkAqua ? .dark : .light
            let baseURL = request.fileURL.deletingLastPathComponent()
            let html = MarkdownHTML.makeHTML(
                from: markdown,
                allowsScroll: true,
                assetBaseHref: baseURL.absoluteString,
                colorScheme: colorScheme
            )
            let data = Data(html.utf8)
            let reply = QLPreviewReply(
                dataOfContentType: .html,
                contentSize: NSSize(width: MarkdownHTML.preferredPageWidth, height: 700)
            ) { _ in data }
            reply.title = request.fileURL.lastPathComponent
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
