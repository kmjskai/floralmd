//
//  EditorViewController.swift
//  md-preview
//
//  Migrated and adapted from pluk-inc/markdown-preview at
//  e364421b76df9f650012a270e4b5b6c9d799323f (MIT).
//  FloralMD owns document persistence; this controller owns only the
//  offline CodeMirror editing surface and its state bridge.
//

import Cocoa
import WebKit

nonisolated struct MarkdownImagePasteRequest: Equatable, Sendable {
    nonisolated struct Item: Equatable, Sendable {
        let data: Data
        let mimeType: String
        let suggestedName: String?
    }

    nonisolated struct Selection: Equatable, Sendable {
        let from: Int
        let to: Int
    }

    enum Error: LocalizedError, Equatable {
        case invalidPayload
        case handlerUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                "剪贴板图片数据无效。"
            case .handlerUnavailable:
                "当前文档还不能接收图片。"
            }
        }
    }

    let items: [Item]
    let selection: Selection?

    init(payload: [String: Any]) throws {
        let rawItems: [[String: Any]]
        if let batch = payload["items"] as? [[String: Any]] {
            rawItems = batch
        } else {
            rawItems = [payload]
        }
        guard !rawItems.isEmpty else {
            throw Error.invalidPayload
        }
        items = try rawItems.map { item in
            guard let encodedData = item["data"] as? String,
                  let data = Data(base64Encoded: encodedData),
                  !data.isEmpty,
                  let mimeType = item["mimeType"] as? String,
                  !mimeType.isEmpty else {
                throw Error.invalidPayload
            }
            return Item(
                data: data,
                mimeType: mimeType,
                suggestedName: item["name"] as? String
            )
        }
        if let rawSelection = payload["selection"] as? [String: Any],
           let from = rawSelection["from"] as? Int,
           let to = rawSelection["to"] as? Int,
           from >= 0,
           to >= from {
            selection = Selection(from: from, to: to)
        } else {
            selection = nil
        }
    }
}

nonisolated struct MarkdownImageOpenRequest: Equatable, Sendable {
    enum Activation: String, Equatable, Sendable {
        case doubleClick
        case commandClick
    }

    enum Error: LocalizedError, Equatable {
        case invalidPayload
        case handlerUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                "图片查看请求无效。"
            case .handlerUnavailable:
                "当前图片还不能在独立窗口中打开。"
            }
        }
    }

    let destination: String
    let sourceRange: Range<Int>
    let activation: Activation

    init(payload: [String: Any]) throws {
        guard let destination = payload["destination"] as? String,
              Self.isRelativeDestination(destination),
              let sourceFrom = payload["sourceFrom"] as? Int,
              let sourceTo = payload["sourceTo"] as? Int,
              sourceFrom >= 0,
              sourceTo >= sourceFrom,
              let rawActivation = payload["activation"] as? String,
              let activation = Activation(rawValue: rawActivation) else {
            throw Error.invalidPayload
        }
        self.destination = destination
        sourceRange = sourceFrom..<sourceTo
        self.activation = activation
    }

    private static func isRelativeDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty,
              !destination.hasPrefix("/"),
              !destination.hasPrefix("\\\\"),
              let components = URLComponents(string: destination),
              components.scheme == nil,
              components.host == nil else {
            return false
        }
        return true
    }
}

/// Inline Typora-style editor for the current document: a CodeMirror 6
/// page (Vendor/CodeMirror/mdedit.min.js) with live-preview decorations —
/// headings, emphasis, quotes and code style themselves as you type, and
/// syntax marks hide unless the cursor is inside them. The buffer is the
/// markdown source itself, so saving is byte-faithful: nothing is
/// reformatted or normalized. The page is fully self-contained (no
/// network), so edit mode works offline and inside the sandbox.
final class CodeMirrorEditorViewController: NSViewController, WKNavigationDelegate {

    /// Fired on every document change — the host debounces for autosave.
    var contentDidChange: ((String) -> Void)?
    /// Fired after CodeMirror has constructed and painted its initial document.
    /// The split view uses this to avoid replacing the preview with a blank WKWebView.
    var editorDidBecomeReady: (() -> Void)?
    /// Esc pressed in the editor — the host decides whether to confirm
    /// and discard.
    var cancelRequested: (() -> Void)?
    /// Returns Markdown only after the host has durably persisted the image.
    var imagePasteRequested: ((MarkdownImagePasteRequest) throws -> String)?
    /// Resolves workspace file URLs to one Markdown insertion. The controller
    /// performs that insertion as one CodeMirror transaction at the drop point.
    var resourceDropRequested: (([URL]) throws -> String)?
    /// Routes links through the owning workspace. Returning false preserves the
    /// existing behavior for images and drawing resources.
    var linkNavigationRequested: ((String) throws -> Bool)?
    /// Opens a local image only after this controller resolves and validates the
    /// relative Markdown destination through its active resource scope.
    var imageOpenRequested: ((MarkdownImageOpenRequest, URL) -> Void)?
    var viewportZoomDidChange: ((Double, MarkdownViewportZoomInteractionPhase) -> Void)?

    private(set) var hasChanges = false

    private var webView: WKWebView!
    private let bridge = EditorBridge()
    private let localResourceHandler = MarkdownLocalResourceSchemeHandler()
    private var hasLoadedEditorPage = false
    private var pendingNavigation: (offset: Int, sourceLine: Int?)?
    private var pendingImageRefresh: DispatchWorkItem?
    private var pendingExternalReplacement: DispatchWorkItem?
    private var externalReplacementGeneration = UUID()
    private var workspaceResourceObserver: NSObjectProtocol?
    private var typography = MarkdownTypography.default
    private var contentWidth = MarkdownContentWidthLayout.defaultPreferredWidth
    private var appliedContentWidth: Double?
    private var contentWidthScheduler: LatestFrameValueScheduler<Double>?
    private var isTypewriterModeEnabled = false
    var documentURL: URL?
    private var resourceContext: MarkdownLocalResourceContext?
    var pageZoomForTesting: Double {
        Double(webView.pageZoom)
    }
    private var resourceBaseURL: URL?

    override func loadView() {
        let config = Self.makeWebViewConfiguration(resourceHandler: localResourceHandler)
        config.userContentController.add(bridge, name: EditorBridge.name)
        let webView = EditorResourceDropWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        webView.registerForDraggedTypes([.fileURL])
        webView.canAcceptResourceURLs = { [weak self] urls in
            self?.canAttemptResourceDrop(urls) == true
        }
        webView.performResourceDrop = { [weak self] urls, location in
            self?.performResourceDrop(urls, at: location) == true
        }
        webView.viewportZoomDidChange = { [weak self] scale, phase in
            self?.viewportZoomDidChange?(scale, phase)
        }
        bridge.owner = self
        self.webView = webView
        view = webView
        workspaceResourceObserver = NotificationCenter.default.addObserver(
            forName: .slateMemoWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.workspaceResourcesDidChange()
        }
    }

    deinit {
        pendingImageRefresh?.cancel()
        pendingExternalReplacement?.cancel()
        contentWidthScheduler?.cancel()
        if let workspaceResourceObserver {
            NotificationCenter.default.removeObserver(workspaceResourceObserver)
        }
    }

    private func workspaceResourcesDidChange() {
        pendingImageRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.webView.evaluateJavaScript(
                "window.__mdEditor && window.__mdEditor.refreshImages()"
            ) { _, _ in }
        }
        pendingImageRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func setResourceContext(_ context: MarkdownLocalResourceContext?) {
        guard resourceContext != context else { return }
        resourceContext = context
        hasLoadedEditorPage = false
    }

    func load(
        markdown: String,
        typography: MarkdownTypography? = nil,
        contentWidth: Double? = nil,
        typewriterModeEnabled: Bool? = nil
    ) {
        pendingExternalReplacement?.cancel()
        externalReplacementGeneration = UUID()
        if let contentWidth {
            self.contentWidth = contentWidth.isFinite ? max(0, contentWidth) : 0
        }
        if let typography {
            if hasLoadedEditorPage {
                applyTypography(typography)
            } else {
                self.typography = typography
            }
        }
        if let typewriterModeEnabled {
            isTypewriterModeEnabled = typewriterModeEnabled
        }
        hasChanges = false
        if hasLoadedEditorPage {
            let script = "window.__mdLoadEditor && window.__mdLoadEditor(\(Self.jsStringLiteral(markdown)))"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, error != nil else { return }
                self.loadEditorPage(markdown: markdown)
            }
            scheduleContentWidthApplication()
            return
        }
        loadEditorPage(markdown: markdown)
    }

    /// Replaces disk-originated content inside the existing CodeMirror view.
    /// Selection and scroll are clamped to the new document and composition is
    /// allowed to finish before any replacement occurs.
    func replaceExternally(markdown: String) {
        pendingExternalReplacement?.cancel()
        let generation = UUID()
        externalReplacementGeneration = generation
        attemptExternalReplacement(markdown: markdown, generation: generation)
    }

    private func attemptExternalReplacement(markdown: String, generation: UUID) {
        let script = "window.__mdEditor && window.__mdEditor.replaceExternal(\(Self.jsStringLiteral(markdown)))"
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.externalReplacementGeneration == generation else { return }
            if error == nil, value as? Bool == true { return }
            let retry = DispatchWorkItem { [weak self] in
                guard let self, self.externalReplacementGeneration == generation else { return }
                self.attemptExternalReplacement(markdown: markdown, generation: generation)
            }
            self.pendingExternalReplacement = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
        }
    }

    private func loadEditorPage(markdown: String) {
        hasLoadedEditorPage = false
        contentWidthScheduler?.cancel()
        appliedContentWidth = nil
        let baseURL = localResourceHandler.register(resourceContext)
        resourceBaseURL = baseURL
        webView.loadHTMLString(
            Self.editorHTML(
                markdown: markdown,
                typography: typography,
                contentWidth: contentWidth,
                typewriterModeEnabled: isTypewriterModeEnabled
            ),
            baseURL: baseURL
        )
    }

    static func makeWebViewConfiguration(
        resourceHandler: MarkdownLocalResourceSchemeHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        MarkdownLocalResourceWebViewConfiguration.install(resourceHandler, on: configuration)
        return configuration
    }

    func applyTypography(_ typography: MarkdownTypography) {
        guard typography != self.typography else { return }
        self.typography = typography
        // Apply immediately when a DOM already exists. If navigation is still
        // in flight, the `ready` handler below replays the same latest values.
        applyCurrentTypographyToPage()
    }

    private func applyCurrentTypographyToPage() {
        let script = """
        (() => {
            const root = document.documentElement.style;
            root.setProperty('--floralmd-body-font-family', \(Self.jsStringLiteral(typography.cssFontFamily)));
            root.setProperty('--floralmd-body-font-size', \(Self.jsStringLiteral("\(typography.fontSize)px")));
            root.setProperty('--floralmd-body-line-height', \(Self.jsStringLiteral("\(typography.lineHeight)")));
            window.dispatchEvent(new Event('floralmd-typography-change'));
        })()
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    func applyContentWidth(_ width: Double) {
        let requestedWidth = width.isFinite ? max(0, width) : 0
        guard requestedWidth != contentWidth else { return }
        contentWidth = requestedWidth
        scheduleContentWidthApplication()
    }

    func applyTypewriterMode(_ isEnabled: Bool) {
        guard isEnabled != isTypewriterModeEnabled else { return }
        isTypewriterModeEnabled = isEnabled
        let value = isEnabled ? "true" : "false"
        let script = "window.__mdEditor && window.__mdEditor.setTypewriterMode(\(value))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func scheduleContentWidthApplication() {
        guard appliedContentWidth != contentWidth else {
            contentWidthScheduler?.cancel()
            return
        }
        if contentWidthScheduler == nil {
            contentWidthScheduler = LatestFrameValueScheduler<Double> { [weak self] width in
                self?.applyContentWidthToPage(width)
            }
        }
        contentWidthScheduler?.submit(contentWidth)
    }

    private func applyContentWidthToPage(_ width: Double) {
        appliedContentWidth = width
        let script = "window.__floralmdSetContentWidth && window.__floralmdSetContentWidth(\(width))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Mirror the preview's page zoom so the type size and measure don't
    /// jump when toggling edit mode. CSS pixels scale with pageZoom, so
    /// the 900px column and the body gutters track the preview exactly.
    func applyPageZoom(_ zoom: CGFloat) {
        if let webView = webView as? MarkdownMagnifyingWebView {
            webView.applyViewportZoom(Double(zoom))
        } else {
            webView.pageZoom = CGFloat(MarkdownViewportZoom.clamped(Double(zoom)))
        }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('floralmd-layout-change'))") { _, _ in }
    }

    /// Current buffer contents, or nil if the editor isn't ready.
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor ? window.__mdEditor.getMarkdown() : null") { value, _ in
            completion(value as? String)
        }
    }

    func focusEditor() {
        view.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.focus()") { _, _ in }
    }

    func navigate(toSourceOffset offset: Int, sourceLine: Int? = nil) {
        pendingNavigation = (max(0, offset), sourceLine)
        performPendingNavigationIfPossible()
    }

    private func performPendingNavigationIfPossible() {
        guard hasLoadedEditorPage, let navigation = pendingNavigation else { return }
        pendingNavigation = nil
        let script = Self.outlineNavigationJavaScript(
            toSourceOffset: navigation.offset,
            sourceLine: navigation.sourceLine
        )
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if error != nil {
                self?.pendingNavigation = navigation
            }
        }
    }

    static func outlineNavigationJavaScript(
        toSourceOffset offset: Int,
        sourceLine: Int?
    ) -> String {
        let scroll = sourceLine.map {
            "Promise.resolve(window.__mdEditor.setScrollPosition(0, \($0), 0)).then(() => window.__mdEditor.focus())"
        } ?? "window.__mdEditor.focus()"
        return "window.__mdEditor && (window.__mdEditor.select(\(max(0, offset))), \(scroll))"
    }

    struct EditorState: Equatable {
        let isReady: Bool
        let isFocused: Bool
        let isEditable: Bool
    }

    /// Observes the actual JavaScript editor state. This intentionally does
    /// not report whether Swift merely *requested* focus: a crashed WebContent
    /// process can accept that request while leaving the page blank.
    func inspectEditorState(_ completion: @escaping (EditorState) -> Void) {
        let script = """
        (() => {
            const content = document.querySelector('.cm-content');
            return {
                ready: !!window.__mdEditor && !!content,
                focused: document.activeElement === content,
                editable: content ? content.getAttribute('contenteditable') === 'true' : false
            };
        })()
        """
        webView.evaluateJavaScript(script) { value, _ in
            let dictionary = value as? [String: Any]
            completion(
                EditorState(
                    isReady: dictionary?["ready"] as? Bool ?? false,
                    isFocused: dictionary?["focused"] as? Bool ?? false,
                    isEditable: dictionary?["editable"] as? Bool ?? false
                )
            )
        }
    }

    /// Runs a focused editor diagnostic against the isolated local page.
    /// Kept internal so integration tests can verify DOM behavior that a
    /// Swift-side callback alone cannot prove.
    func evaluateEditorJavaScript(
        _ script: String,
        completion: @escaping (Any?) -> Void
    ) {
        webView.evaluateJavaScript(script) { value, _ in
            completion(value)
        }
    }

    func evaluateEditorJavaScriptWithError(
        _ script: String,
        completion: @escaping (Any?, Error?) -> Void
    ) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A WKWebView becoming visible does not automatically focus the
        // nested CodeMirror content view. CodeMirror only draws its insertion
        // cursor while that content view is focused, so request focus after
        // every full editor-page load. The `ready` bridge below covers the
        // cheaper in-page document reload path as well.
        DispatchQueue.main.async { [weak self] in
            (self?.webView as? EditorResourceDropWebView)?
                .claimExclusiveResourceDropDestination()
            self?.focusEditor()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              hasLoadedEditorPage else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func insert(markdown: String) {
        let literal = Self.jsStringLiteral(markdown)
        webView.evaluateJavaScript(
            "window.__mdEditor && window.__mdEditor.insert(\(literal))"
        ) { _, _ in }
    }

    /// Inserts FloralMD's basic Markdown table at the current selection end.
    /// The editor owns newline normalization, selection placement, and undo so
    /// callers cannot accidentally split this command across transactions.
    func insertBasicMarkdownTable() {
        webView.evaluateJavaScript(
            "window.__mdEditor && window.__mdEditor.insertBasicMarkdownTable()"
        ) { [weak self] handled, error in
            guard error == nil, handled as? Bool == true else { return }
            self?.focusEditor()
        }
    }

    func insert(markdown: String, at viewLocation: CGPoint) {
        let cssPoint = MarkdownWebViewCoordinateSpace.cssViewportPoint(
            fromViewPoint: viewLocation,
            bounds: webView.bounds,
            isFlipped: webView.isFlipped,
            pageZoom: Double(webView.pageZoom)
        )
        let script = "window.__mdEditor && window.__mdEditor.insertAt(\(cssPoint.x), \(cssPoint.y), \(Self.jsStringLiteral(markdown)))"
        webView.evaluateJavaScript(script) { [weak self] handled, error in
            guard error == nil, handled as? Bool == true else { return }
            self?.focusEditor()
        }
    }

    private func canAttemptResourceDrop(_ urls: [URL]) -> Bool {
        guard resourceDropRequested != nil, !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            url.isFileURL && ResourceKind.resolve(url: url) != nil
        }
    }

    private func performResourceDrop(_ urls: [URL], at location: CGPoint) -> Bool {
        do {
            guard let resourceDropRequested else {
                throw MarkdownResourceReferenceError.markdownDocumentRequired
            }
            let markdown = try resourceDropRequested(urls)
            insert(markdown: markdown, at: location)
            return true
        } catch {
            NSApplication.shared.presentError(error)
            return false
        }
    }

    /// Run a formatting command (bold, italic, h1, quote, …) on the
    /// current selection. Command names map to the bundle's exec() table.
    func exec(_ command: String) {
        let name = Self.jsStringLiteral(command)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.exec(\(name))") { _, _ in }
    }

    fileprivate func handle(message: Any) {
        if let message = message as? String {
            switch message {
            case "dirty":
                hasChanges = true
                fetchMarkdown { [weak self] markdown in
                    guard let self, let markdown else { return }
                    self.contentDidChange?(markdown)
                }
            case "ready":
                hasLoadedEditorPage = true
                // A settings change can arrive while the local editor page is
                // still loading. Replay the latest values once CodeMirror is
                // ready so that update is never lost to the navigation race.
                applyCurrentTypographyToPage()
                scheduleContentWidthApplication()
                focusEditor()
                performPendingNavigationIfPossible()
                editorDidBecomeReady?()
            case "cancel":
                cancelRequested?()
            case let error where error.hasPrefix("error:"):
                NSLog("Markdown editor JavaScript error: %@", error)
            default:
                break
            }
            return
        }

        if let payload = message as? [String: Any],
           let kind = payload["kind"] as? String {
            switch kind {
            case "change":
                guard let markdown = payload["markdown"] as? String else { return }
                hasChanges = true
                contentDidChange?(markdown)
            case "openLink":
                guard let destination = payload["destination"] as? String else { return }
                openLink(destination)
            case "openImage":
                openImage(payload)
            case "pasteImage":
                do {
                    let request = try MarkdownImagePasteRequest(payload: payload)
                    guard let imagePasteRequested else {
                        throw MarkdownImagePasteRequest.Error.handlerUnavailable
                    }
                    let markdown = try imagePasteRequested(request)
                    insert(markdown: markdown, replacing: request.selection)
                } catch {
                    NSApplication.shared.presentError(error)
                }
            default:
                break
            }
        }
    }

    private func insert(markdown: String, replacing selection: MarkdownImagePasteRequest.Selection?) {
        guard let selection else {
            insert(markdown: markdown)
            return
        }
        let script = "window.__mdEditor && window.__mdEditor.insertAtSelection(\(selection.from), \(selection.to), \(Self.jsStringLiteral(markdown)))"
        webView.evaluateJavaScript(script) { [weak self] handled, error in
            guard error == nil, handled as? Bool == true else { return }
            self?.focusEditor()
        }
    }

    private func openLink(_ destination: String) {
        guard !destination.isEmpty else { return }

        if let linkNavigationRequested {
            do {
                if try linkNavigationRequested(destination) { return }
            } catch {
                NSApplication.shared.presentError(error)
                return
            }
        }

        guard !destination.hasPrefix("#") else { return }

        let resolvedURL: URL?
        if let absoluteURL = URL(string: destination), absoluteURL.scheme != nil {
            resolvedURL = absoluteURL
        } else if let baseURL = documentURL?.deletingLastPathComponent() {
            resolvedURL = URL(fileURLWithPath: destination, relativeTo: baseURL).absoluteURL
        } else {
            resolvedURL = nil
        }

        guard let resolvedURL,
              resolvedURL.isFileURL
                || ["http", "https", "mailto"].contains(resolvedURL.scheme?.lowercased() ?? "")
        else { return }
        NSWorkspace.shared.open(resolvedURL)
    }

    private func openImage(_ payload: [String: Any]) {
        do {
            let request = try MarkdownImageOpenRequest(payload: payload)
            guard let imageOpenRequested else {
                throw MarkdownImageOpenRequest.Error.handlerUnavailable
            }
            guard let resourceBaseURL else {
                throw MarkdownLocalResourceError.invalidRequest
            }
            let resource = try localResourceHandler.resolvedResource(
                destination: request.destination,
                relativeTo: resourceBaseURL
            )
            imageOpenRequested(request, resource.fileURL)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    // MARK: - Page assembly

    private static func vendorResource(_ name: String, ext: String, subdir: String) -> String? {
        // Synced-folder resources are copied flat into Resources/, so try
        // the subdirectory first and fall back to the bundle root — same
        // lookup MarkdownHTML uses for its vendor files.
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static let editorJavaScript =
        vendorResource("mdedit.min", ext: "js", subdir: "Vendor/CodeMirror") ?? ""
    private static let mermaidJavaScript =
        vendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") ?? ""
    private static let katexJavaScript =
        vendorResource("katex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
    private static let katexCSS =
        vendorResource("katex.min", ext: "css", subdir: "Vendor/KaTeX") ?? ""

    private static func safeInlineScript(_ source: String) -> String {
        source.replacingOccurrences(of: "</script", with: "<\\/script")
    }

    /// JSON string literal safe for embedding in an inline <script>:
    /// `<` is escaped so `</script>` inside the document can't close the tag.
    private static func jsStringLiteral(_ string: String) -> String {
        let data = (try? JSONEncoder().encode([string])) ?? Data("[\"\"]".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func editorHTML(
        markdown: String,
        typography: MarkdownTypography,
        contentWidth: Double = MarkdownContentWidthLayout.defaultPreferredWidth,
        typewriterModeEnabled: Bool = false
    ) -> String {
        let addRowLabel = jsStringLiteral(String(localized: "Add Row", comment: "Accessible table editing control"))
        let addColumnLabel = jsStringLiteral(String(localized: "Add Column", comment: "Accessible table editing control"))
        let selectRowLabel = jsStringLiteral(String(localized: "Select Row", comment: "Table context menu item"))
        let selectColumnLabel = jsStringLiteral(String(localized: "Select Column", comment: "Table context menu item"))
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>\(katexCSS)</style>
        <style>
        /* Palette and type scale mirror MarkdownHTML.stylesheet so entering
           edit mode doesn't visually change the document. */
        :root {
            color-scheme: light dark;
            \(typography.cssVariableDeclarations)
            --floralmd-content-width: \(contentWidth)px;
            --text: #1d1d1f;
            --secondary: #6e6e73;
            --link: #0066cc;
            --semantic-image: #7655a6;
            --semantic-code: #8a4b20;
            --semantic-tag: #7655a6;
            --quote-border: #d2d2d7;
            --code-bg: #f5f5f7;
            --grid: #d2d2d7;
            /* GitHub Light — matches the preview's highlight.js theme. */
            --hl-keyword: #d73a49;
            --hl-string: #032f62;
            --hl-comment: #6a737d;
            --hl-number: #005cc5;
            --hl-type: #6f42c1;
            --hl-function: #6f42c1;
            --hl-property: #005cc5;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --text: #f5f5f7;
                --secondary: #86868b;
                --link: #2997ff;
                --semantic-image: #b69ad9;
                --semantic-code: #d0a06f;
                --semantic-tag: #c7a9e8;
                --quote-border: #6e6e73;
                --code-bg: #2A2828;
                --grid: #424245;
                /* GitHub Dark — matches the preview's highlight.js theme. */
                --hl-keyword: #ff7b72;
                --hl-string: #a5d6ff;
                --hl-comment: #8b949e;
                --hl-number: #79c0ff;
                --hl-type: #d2a8ff;
                --hl-function: #d2a8ff;
                --hl-property: #79c0ff;
            }
        }
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            overflow: hidden;
            background: transparent;
        }
        body {
            font-family: var(--floralmd-body-font-family);
            font-size: var(--floralmd-body-font-size);
            line-height: var(--floralmd-body-line-height);
            color: var(--text);
            -webkit-font-smoothing: antialiased;
        }
        #editor {
            height: 100%;
            box-sizing: border-box;
        }
        .cm-editor { height: 100%; outline: none; }
        .cm-editor.cm-focused { outline: none; }
        /* CodeMirror injects its base theme into <head> at runtime — after
           this block — and it sets .cm-scroller to monospace. Win on
           specificity (#editor), not on order. */
        #editor .cm-scroller {
            overflow: auto;
            /* Keep page gutters outside the editable content column. */
            padding-inline: \(MarkdownHTML.pagePaddingHorizontal)px;
            box-sizing: border-box;
            font-family: var(--floralmd-body-font-family) !important;
            font-size: var(--floralmd-body-font-size);
            line-height: var(--floralmd-body-line-height);
        }
        #editor .cm-content {
            width: 100%;
            max-width: var(--floralmd-content-width, \(MarkdownHTML.contentColumnWidth)px);
            min-height: 100%;
            margin: 0 auto;
            padding: var(--floralmd-editor-padding-top, \(MarkdownHTML.pagePaddingTop)px) 0
                var(--floralmd-editor-padding-bottom, \(MarkdownHTML.pagePaddingBottom)px);
            box-sizing: border-box;
            /* The native caret is hidden and CodeMirror draws its own
               .cm-cursor layer: WebKit otherwise leaves a stale native caret
               drawn at the previous position after deletions (phantom caret
               until the next repaint). */
            caret-color: transparent;
            cursor: text;
        }
        /* Match the drawn caret to the text color (base theme defaults to
           black, which would be wrong in dark mode). */
        #editor .cm-cursor {
            border-left-color: var(--text);
        }
        #editor .cm-content.cm-focused > .cm-scroller > .cm-cursorLayer .cm-cursor {
            border-left-color: var(--text);
        }
        #editor .cm-line {
            padding: 0;
        }
        /* The semantic gutter and line numbers overlay the page's 72pt
           leading whitespace, so the Markdown column remains centered. */
        #editor .cm-scroller { position: relative; }
        #editor .cm-floralmd-gutter {
            position: absolute;
            top: 0;
            width: 68px;
            color: var(--secondary);
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11px;
            user-select: none;
            pointer-events: none;
            z-index: 2;
        }
        #editor .cm-floralmd-gutter-line {
            position: absolute;
            left: 0;
            width: 68px;
            box-sizing: border-box;
            display: grid;
            grid-template-columns: 36px 32px;
            align-items: center;
        }
        #editor .cm-floralmd-line-number {
            width: 32px;
            padding: 0;
            text-align: center;
            font-variant-numeric: tabular-nums;
        }
        #editor .cm-semantic-badge {
            display: inline-flex;
            min-width: 28px;
            height: 15px;
            margin-top: 0;
            padding: 0 3px;
            box-sizing: border-box;
            align-items: center;
            justify-content: center;
            border: 1px solid color-mix(in srgb, var(--secondary) 30%, transparent);
            border-radius: 4px;
            background: color-mix(in srgb, var(--secondary) 9%, transparent);
            color: var(--secondary);
            font-size: 8px;
            font-weight: 650;
            line-height: 1;
            letter-spacing: -0.2px;
        }
        #editor .cm-semantic-code {
            color: var(--semantic-code);
            border-color: color-mix(in srgb, var(--semantic-code) 36%, transparent);
            background: color-mix(in srgb, var(--semantic-code) 10%, transparent);
        }
        #editor .cm-semantic-img {
            color: var(--semantic-image);
            border-color: color-mix(in srgb, var(--semantic-image) 36%, transparent);
            background: color-mix(in srgb, var(--semantic-image) 10%, transparent);
        }
        #editor .cm-line[dir="rtl"] { text-align: right; }
        #editor .cm-line[dir="ltr"] { text-align: left; }
        #editor .cm-selectionBackground {
            background: Highlight !important;
        }
        /* The bundle paints each logical line's selected characters in one
           measured layer; WebKit keeps the native caret. Continuous source
           DOM keeps text, hit testing, and wrapped headings synchronized. */

        /* Headings — preview's scale, padding instead of margin so
           CodeMirror's per-line height measurement stays exact.
           Every line-level rule needs the #editor prefix to outrank
           `#editor .cm-line { padding: 0 }` above. */
        #editor .cm-md-h1, #editor .cm-md-h2, #editor .cm-md-h3,
        #editor .cm-md-h4, #editor .cm-md-h5, #editor .cm-md-h6 {
            font-weight: 600;
            line-height: 1.18;
            padding-top: 1.6em;
            /* Active source starts at the normal line edge while wrapped body
               rows hang after its editable width. Inactive source is collapsed
               below and releases the indent so preview text returns to the
               normal line edge instead of leaving an empty Markdown slot. */
            padding-inline-start: var(--cm-md-heading-source-width);
            text-indent: calc(-1 * var(--cm-md-heading-source-width));
        }
        #editor .cm-md-h1 {
            --cm-md-heading-source-width: var(--cm-md-h1-source-width, 2ch);
            font-size: 2em;
            padding-top: 0.8em;
        }
        /* Mirror the preview's first-child margin reset so the document
           starts at the same height in both modes. */
        #editor .cm-content > .cm-line:first-child { padding-top: 0; }
        #editor .cm-md-h2 {
            --cm-md-heading-source-width: var(--cm-md-h2-source-width, 3ch);
            font-size: 1.88em;
            line-height: 1.06;
        }
        #editor .cm-md-h3 {
            --cm-md-heading-source-width: var(--cm-md-h3-source-width, 4ch);
            font-size: 1.65em;
            line-height: 1.07;
        }
        #editor .cm-md-h4 {
            --cm-md-heading-source-width: var(--cm-md-h4-source-width, 5ch);
            font-size: 1.41em;
            line-height: 1.08;
        }
        #editor .cm-md-h5 {
            --cm-md-heading-source-width: var(--cm-md-h5-source-width, 6ch);
            font-size: 1.29em;
            line-height: 1.09;
        }
        #editor .cm-md-h6 {
            --cm-md-heading-source-width: var(--cm-md-h6-source-width, 7ch);
            font-size: 1em;
            line-height: 1.24;
        }
        #editor .cm-md-h1 > .cm-md-syntax:first-child,
        #editor .cm-md-h2 > .cm-md-syntax:first-child,
        #editor .cm-md-h3 > .cm-md-syntax:first-child,
        #editor .cm-md-h4 > .cm-md-syntax:first-child,
        #editor .cm-md-h5 > .cm-md-syntax:first-child,
        #editor .cm-md-h6 > .cm-md-syntax:first-child,
        #editor .cm-md-h1 > .cm-md-heading-source-visible:first-child,
        #editor .cm-md-h2 > .cm-md-heading-source-visible:first-child,
        #editor .cm-md-h3 > .cm-md-heading-source-visible:first-child,
        #editor .cm-md-h4 > .cm-md-heading-source-visible:first-child,
        #editor .cm-md-h5 > .cm-md-heading-source-visible:first-child,
        #editor .cm-md-h6 > .cm-md-heading-source-visible:first-child {
            display: inline-block;
            width: var(--cm-md-heading-source-width);
            box-sizing: border-box;
            text-align: start;
            text-indent: 0;
            white-space: pre;
        }
        #editor .cm-md-h1.cm-md-heading-inactive,
        #editor .cm-md-h2.cm-md-heading-inactive,
        #editor .cm-md-h3.cm-md-heading-inactive,
        #editor .cm-md-h4.cm-md-heading-inactive,
        #editor .cm-md-h5.cm-md-heading-inactive,
        #editor .cm-md-h6.cm-md-heading-inactive {
            padding-inline-start: 0;
            text-indent: 0;
        }
        /* A visible source blank already owns the gap before the heading;
           retain the preview's small amount of extra breathing room. */
        #editor .cm-md-h1.cm-md-heading-after-blank,
        #editor .cm-md-h2.cm-md-heading-after-blank,
        #editor .cm-md-h3.cm-md-heading-after-blank,
        #editor .cm-md-h4.cm-md-heading-after-blank,
        #editor .cm-md-h5.cm-md-heading-after-blank,
        #editor .cm-md-h6.cm-md-heading-after-blank {
            padding-top: 4px;
        }
        /* The bundle marks the final blank before a block as its separator.
           Override its creation-time pixel token with current typography so
           semantic spacing follows font changes without rebuilding the editor. */
        #editor .cm-md-block-separator {
            --floralmd-block-spacing: 0.8;
            height: calc(
                var(--floralmd-body-font-size) * var(--floralmd-body-line-height)
                + var(--floralmd-body-font-size) * var(--floralmd-block-spacing)
            ) !important;
            line-height: calc(
                var(--floralmd-body-font-size) * var(--floralmd-body-line-height)
                + var(--floralmd-body-font-size) * var(--floralmd-block-spacing)
            ) !important;
        }
        #editor .cm-md-block-separator:has(+ .cm-md-quote) {
            --floralmd-block-spacing: 1.2;
        }
        /* The bundle's large-block token identifies alerts, tables, and
           Mermaid before their widgets settle into the DOM. Keep the token
           only as a category marker; the resulting height remains dynamic. */
        #editor .cm-md-block-separator[style*="height: 46.8px"] {
            --floralmd-block-spacing: 1.6;
        }
        #editor .cm-md-block-separator:has(+ .cm-md-table),
        #editor .cm-md-block-separator:has(+ .cm-md-table-widget) {
            --floralmd-block-spacing: 1.6;
        }
        /* Ordinary prose is not a visual block card: every empty source row
           before it remains exactly one body line tall, preserving the line
           number rhythm visible while editing. */
        #editor .cm-md-block-separator:has(+ .cm-line:not([class*="cm-md-"])) {
            --floralmd-block-spacing: 0;
        }
        #editor .cm-md-block-separator:has(+ .cm-line .cm-md-hr) {
            --floralmd-block-spacing: 2.35;
        }
        /* A source line whose height another element owns collapses to
           nothing: inactive code fence lines (the card transfers their
           styling to the code lines), and a single blank opening the
           document. Blank separators before other blocks resize instead —
           .cm-md-block-separator lines carry an inline height matching the
           preview margin of the block that follows. Additional blank lines
           keep their natural height in both surfaces. */
        #editor .cm-md-line-collapsed {
            height: 0;
            min-height: 0;
            line-height: 0;
            overflow: hidden;
        }

        /* Keep inactive ATX source in CodeMirror's continuous text DOM while
           collapsing it to zero inline width. Native selection, caret, and
           hit testing then share one measured text flow. */
        #editor .cm-md-heading-source-hidden {
            font-size: 0;
            letter-spacing: 0;
        }

        #editor .cm-md-quote {
            border-inline-start: 4px solid var(--quote-border);
            padding-inline-start: 1em;
            color: var(--secondary);
        }
        .cm-md-strong { font-weight: 600; }
        .cm-md-emphasis { font-style: italic; }
        .cm-md-strikethrough { text-decoration: line-through; }
        #editor .cm-md-inline-code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            background: var(--code-bg);
            color: var(--semantic-code);
            border-radius: 6px;
            padding: 0.18em 0.42em;
        }
        /* A selected inline-code construct keeps its font metrics and
           transparent padding so the source reveal does not change line
           height. The backticks remain real source text, while the preview
           card, rounding, and semantic color disappear. */
        #editor .cm-md-inline-code-source {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            color: inherit;
            background: transparent;
            border-radius: 0;
            padding: 0.18em 0.42em;
        }
        #editor .cm-md-heading-source-visible { color: inherit; }
        #editor .cm-md-link { color: var(--link); }
        .cm-md-link[data-md-href] { cursor: text; }
        #editor .cm-md-image-reference { color: var(--semantic-image); }
        #editor .cm-md-tag {
            border: 1px solid color-mix(in srgb, var(--semantic-tag) 24%, transparent);
            border-radius: 999px;
            background: color-mix(in srgb, var(--semantic-tag) 11%, transparent);
            color: var(--text);
            padding: 0.08em 0.38em;
            -webkit-box-decoration-break: clone;
            box-decoration-break: clone;
        }
        #editor .cm-md-source-selected-line .cm-md-tag,
        #editor .cm-md-tag-source-selected {
            border-color: transparent;
            background: transparent;
            color: inherit;
        }
        #editor .cm-md-syntax { color: var(--secondary); }
        /* Mirror the preview's list geometry. JavaScript adds an inline
           padding value derived from semantic list depth, rather than relying
           on proportional-font source spaces. The marker hangs inside the
           final 1.6em step, so active and inactive item text stays aligned. */
        #editor .cm-md-list-item {
            padding-inline-start: 1.6em;
            text-indent: -1.6em;
        }
        .cm-md-bullet {
            display: inline-block;
            width: 1.6em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.45em;
            box-sizing: border-box;
            color: var(--text);
        }
        /* Keep the active raw "- " marker in the same hanging box as the
           inactive bullet widget. Revealing Markdown source must not move the
           item text or make a nested item appear to change indentation. */
        .cm-md-bullet-source {
            display: inline-block;
            width: 1.6em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.45em;
            box-sizing: border-box;
            color: var(--secondary);
        }
        /* Ordered markers (`1.`) get the same fixed hanging slot as bullets,
           so item text starts at the same column as unordered lists here and
           in the read-only preview. The slot grows only for wide numerals. */
        .cm-md-ordered-marker {
            display: inline-block;
            min-width: 1.6em;
            text-indent: 0;
            color: var(--text);
        }
        .cm-md-task-checkbox {
            appearance: none;
            display: inline-grid;
            place-content: center;
            width: 1.05em;
            height: 1.05em;
            margin: 0 0.5em 0 0;
            border: 1.5px solid var(--secondary);
            border-radius: 0.28em;
            vertical-align: -0.12em;
            background: transparent;
            cursor: pointer;
            position: relative;
        }
        .cm-md-task-checkbox:checked {
            border-color: var(--link);
            background: var(--link);
        }
        /* The check mark is a centered SVG overlay, not a text glyph or grid item:
           a ✓ glyph as an inline-grid item changes the input's internal
           layout and pulls the whole checked box ~7px lower than the
           unchecked one. The absolute overlay leaves the box metrics
           untouched (checked and unchecked boxes share identical geometry)
           and centers the check on the box regardless of fonts, like the
           read-only preview's task checkboxes. */
        .cm-md-task-checkbox:checked::after {
            content: "";
            position: absolute;
            inset: 0;
            background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M4.4 8.4 L7 11 L11.6 5.4" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>');
            background-repeat: no-repeat;
            background-position: center;
            background-size: 100% 100%;
        }
        /* Preview list items after the first carry a margin-top. */
        #editor .cm-md-list-item-gap {
            padding-top: \(MarkdownHTML.listItemSpacing)px;
        }
        #editor .cm-md-source-selected-line.cm-md-quote {
            border-color: transparent;
            color: inherit;
        }
        #editor .cm-md-source-selected-line .cm-md-bullet-source {
            color: inherit;
        }
        .cm-md-hr {
            display: inline-block;
            width: 100%;
            border-top: 1px solid var(--grid);
            vertical-align: middle;
        }
        #editor .cm-md-codeblock {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            line-height: 1.45;
            position: relative;
            padding: 0 14px;
        }
        /* CodeMirror paints the selection on a z:-1 layer, below line
           backgrounds. Paint the code card on a z:-2 pseudo instead of the
           line itself: it escapes to the same stacking context, so the card
           matches the preview's opaque --code-bg while the selection tint
           still shows between card and text. */
        #editor .cm-md-codeblock::before {
            content: "";
            position: absolute;
            inset: 0;
            z-index: -2;
            background: var(--code-bg);
        }
        #editor .cm-md-source-selected-line.cm-md-codeblock::before {
            background: transparent;
        }
        #editor .cm-md-codeblock-first {
            padding-top: 10px;
        }
        #editor .cm-md-codeblock-first::before {
            border-radius: 15px 15px 0 0;
        }
        #editor .cm-md-codeblock-last {
            padding-bottom: 10px;
        }
        #editor .cm-md-codeblock-last::before {
            border-radius: 0 0 15px 15px;
        }
        #editor .cm-md-code-fence-source-hidden {
            visibility: hidden;
        }
        /* Frontmatter — a quiet metadata card above the document, echoing
           the preview's properties panel. YAML stays editable; only the
           --- delimiters are dimmed. */
        #editor .cm-md-frontmatter {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.82em;
            line-height: 1.6;
            color: var(--secondary);
            background: color-mix(in srgb, var(--code-bg) 50%, transparent);
            padding: 0 14px;
        }
        /* Outranks the `.cm-line:first-child { padding-top: 0 }` reset so
           the card keeps its inset when it opens the document. */
        #editor .cm-content > .cm-line.cm-md-frontmatter-first {
            border-radius: 15px 15px 0 0;
            padding-top: 8px;
        }
        #editor .cm-md-frontmatter-last {
            border-radius: 0 0 15px 15px;
            padding-bottom: 8px;
        }
        #editor .cm-md-source-selected-line.cm-md-frontmatter {
            color: inherit;
            background: transparent;
        }
        .cm-md-frontmatter-delim {
            opacity: 0.45;
        }
        .cm-md-fence-info { color: var(--secondary); }
        .cm-md-mermaid-preview {
            /* Outer spacing comes from the block separator lines, matching
               the preview's .mermaid-figure margin. */
            margin: 0;
            padding: 20px;
            border-radius: 15px;
            background: var(--code-bg);
            cursor: text;
            box-sizing: border-box;
        }
        .cm-md-mermaid-stage {
            display: flex;
            justify-content: center;
            min-height: 48px;
            color: var(--secondary);
        }
        .cm-md-mermaid-stage svg {
            display: block;
            max-width: 100%;
            height: auto;
        }
        .cm-md-mermaid-error {
            border: 1px solid color-mix(in srgb, #d1242f 45%, transparent);
        }
        .cm-md-image-gallery {
            display: grid;
            gap: 10px;
            width: 100%;
            min-width: 0;
            margin: 0;
            padding: 8px 0 14px;
            box-sizing: border-box;
        }
        .cm-md-image-preview {
            display: grid;
            place-items: center;
            min-width: 0;
            min-height: 52px;
            margin: 0;
            padding: 10px;
            overflow: hidden;
            border: 1px solid color-mix(in srgb, var(--grid) 72%, transparent);
            border-radius: 12px;
            background: color-mix(in srgb, var(--code-bg) 38%, transparent);
            box-sizing: border-box;
            cursor: text;
        }
        .cm-md-image-preview img {
            display: block;
            max-width: 100%;
            max-height: min(420px, 58vh);
            object-fit: contain;
        }
        .cm-md-image-status {
            margin: 0;
            color: var(--secondary);
            font-size: 0.82em;
            line-height: 1.4;
            text-align: center;
        }
        .cm-md-image-preview.is-loading img,
        .cm-md-image-preview.is-error img {
            display: none;
        }
        .cm-md-image-preview.is-loaded .cm-md-image-status {
            display: none;
        }
        .cm-md-image-preview.is-error {
            border-style: dashed;
        }
        .cm-md-math-inline {
            display: inline-block;
            padding: 0 0.12em;
            cursor: text;
        }
        .cm-md-math-display {
            display: block;
            overflow-x: auto;
            padding: 0.8em 1em;
            margin: 0;
            text-align: center;
            border-radius: 12px;
            background: color-mix(in srgb, var(--code-bg) 58%, transparent);
            cursor: text;
        }
        .cm-md-math-error {
            color: #d1242f;
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
        }
        .cm-md-table {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
        }
        .cm-md-table-widget {
            position: relative;
            width: fit-content;
            /* Outer spacing comes from the block separator lines, matching
               the preview's .md-table-scroll margin. */
            margin: 0;
            max-width: 100%;
            overflow: visible;
            font-family: var(--floralmd-body-font-family);
            font-size: var(--floralmd-body-font-size);
            line-height: var(--floralmd-body-line-height);
        }
        .cm-md-table-widget:focus {
            outline: none;
        }
        .cm-md-table-edge-action {
            position: absolute;
            z-index: 2;
            width: 24px;
            height: 24px;
            padding: 0;
            border: 1px solid color-mix(in srgb, var(--secondary) 34%, transparent);
            border-radius: 999px;
            background: color-mix(in srgb, Canvas 94%, transparent);
            color: var(--secondary);
            box-shadow: 0 2px 8px color-mix(in srgb, #000 12%, transparent);
            cursor: pointer;
            opacity: 0;
            pointer-events: none;
            transition: opacity 100ms ease, color 100ms ease, border-color 100ms ease;
        }
        .cm-md-table-edge-action::before {
            content: "+";
            display: block;
            font: 500 17px/21px -apple-system, BlinkMacSystemFont, sans-serif;
            text-align: center;
        }
        .cm-md-table-widget:hover .cm-md-table-edge-action,
        .cm-md-table-widget:focus-within .cm-md-table-edge-action,
        .cm-md-table-edge-action:focus-visible {
            opacity: 1;
            pointer-events: auto;
        }
        .cm-md-table-edge-action:hover,
        .cm-md-table-edge-action:focus-visible {
            color: #007aff;
            border-color: color-mix(in srgb, #007aff 62%, transparent);
            outline: none;
        }
        .cm-md-table-add-row {
            left: 50%;
            bottom: -12px;
            transform: translateX(-50%);
        }
        .cm-md-table-add-column {
            right: -12px;
            top: 50%;
            transform: translateY(-50%);
        }
        .cm-md-table-structure-control {
            position: absolute;
            z-index: 3;
            box-sizing: border-box;
            padding: 0;
            border: 1px solid color-mix(in srgb, var(--secondary) 25%, transparent);
            background: color-mix(in srgb, Canvas 94%, transparent);
            color: var(--secondary);
            box-shadow: 0 1px 5px color-mix(in srgb, #000 10%, transparent);
            cursor: pointer;
            opacity: 0;
            transition: opacity 100ms ease, color 100ms ease, border-color 100ms ease,
                background 100ms ease;
        }
        .cm-md-table-widget:hover .cm-md-table-structure-control,
        .cm-md-table-widget:focus-within .cm-md-table-structure-control,
        .cm-md-table-structure-control:focus-visible,
        .cm-md-table-structure-control.is-selected {
            opacity: 0.72;
        }
        .cm-md-table-structure-control:hover,
        .cm-md-table-structure-control:focus-visible,
        .cm-md-table-structure-control.is-selected {
            opacity: 1;
            color: #007aff;
            border-color: color-mix(in srgb, #007aff 62%, transparent);
            outline: none;
        }
        .cm-md-table-select-part {
            border-radius: 999px;
            transform: translate(-50%, -50%);
        }
        .cm-md-table-select-part::before {
            content: "";
            position: absolute;
            inset: 3px;
            border-radius: inherit;
            background: currentColor;
            opacity: 0.48;
        }
        .cm-md-table-select-row {
            width: 10px;
            height: 22px;
        }
        .cm-md-table-select-column {
            width: 22px;
            height: 10px;
        }
        .cm-md-table-select-part.is-selected {
            background: color-mix(in srgb, #007aff 15%, Canvas);
        }
        .cm-md-table-insert-part {
            width: 20px;
            height: 20px;
            border-radius: 999px;
            transform: translate(-50%, -50%);
            opacity: 0;
        }
        .cm-md-table-insert-part::before {
            content: "+";
            display: block;
            font: 500 15px/17px -apple-system, BlinkMacSystemFont, sans-serif;
            text-align: center;
        }
        .cm-md-table-widget:hover .cm-md-table-insert-part,
        .cm-md-table-widget:focus-within .cm-md-table-insert-part {
            opacity: 0.38;
        }
        .cm-md-table-insert-part:hover,
        .cm-md-table-insert-part:focus-visible {
            opacity: 1;
        }
        .cm-md-table-scroll {
            width: fit-content;
            max-width: 100%;
            overflow-x: auto;
        }
        .cm-md-table-grid {
            width: 100%;
            border-collapse: collapse;
            table-layout: auto;
        }
        .cm-md-table-grid th,
        .cm-md-table-grid td {
            min-width: 72px;
            padding: 0;
            border-top: 1px solid var(--grid);
            border-bottom: 1px solid var(--grid);
            text-align: left;
            vertical-align: top;
        }
        .cm-md-table-grid th {
            font-weight: 600;
            background: color-mix(in srgb, Canvas 94%, var(--grid));
        }
        .cm-md-table-cell {
            min-height: calc(var(--floralmd-body-font-size) * var(--floralmd-body-line-height));
            padding: 8px 10px;
            outline: none;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            cursor: text;
        }
        .cm-md-table-inline-image {
            display: inline-block;
            max-width: 100%;
            max-height: 2.4em;
            width: auto;
            height: auto;
            object-fit: contain;
            vertical-align: middle;
        }
        .cm-md-table-grid th .cm-md-table-cell[data-placeholder]:empty::before {
            content: attr(data-placeholder);
            color: var(--secondary);
            font-weight: 400;
            opacity: 0.72;
            pointer-events: none;
        }
        .cm-md-table-cell:focus {
            outline: 2px solid #007aff;
            outline-offset: -2px;
            background: color-mix(in srgb, #007aff 8%, transparent);
        }
        .cm-md-table-cell.is-table-part-selected {
            --table-selection-top-edge: 0 0 transparent;
            --table-selection-right-edge: 0 0 transparent;
            --table-selection-bottom-edge: 0 0 transparent;
            --table-selection-left-edge: 0 0 transparent;
            background: color-mix(in srgb, #007aff 14%, Canvas);
            box-shadow:
                var(--table-selection-top-edge),
                var(--table-selection-right-edge),
                var(--table-selection-bottom-edge),
                var(--table-selection-left-edge);
        }
        .cm-md-table-cell.is-table-selection-top {
            --table-selection-top-edge: inset 0 1px color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-right {
            --table-selection-right-edge: inset -1px 0 color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-bottom {
            --table-selection-bottom-edge: inset 0 -1px color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-left {
            --table-selection-left-edge: inset 1px 0 color-mix(in srgb, #007aff 52%, transparent);
        }
        .hl-keyword { color: var(--hl-keyword); }
        .hl-string { color: var(--hl-string); }
        .hl-comment { color: var(--hl-comment); }
        .hl-number { color: var(--hl-number); }
        .hl-type { color: var(--hl-type); }
        .hl-function { color: var(--hl-function); }
        .hl-property { color: var(--hl-property); }
        .hl-meta { color: var(--secondary); }
        #floralmd-findbar {
            position: fixed;
            top: 12px;
            right: 18px;
            z-index: 1000;
            display: flex;
            align-items: center;
            gap: 6px;
            padding: 7px;
            border: 1px solid color-mix(in srgb, var(--secondary) 32%, transparent);
            border-radius: 9px;
            background: color-mix(in srgb, Canvas 94%, transparent);
            box-shadow: 0 5px 18px color-mix(in srgb, #000 18%, transparent);
            color: var(--text);
            -webkit-backdrop-filter: blur(18px);
        }
        #floralmd-findbar[hidden] { display: none; }
        #floralmd-find-input {
            width: 190px;
            padding: 4px 7px;
            border: 1px solid color-mix(in srgb, var(--secondary) 35%, transparent);
            border-radius: 6px;
            background: Canvas;
            color: var(--text);
            font: inherit;
            font-size: 13px;
            outline: none;
        }
        #floralmd-find-input:focus { border-color: #007aff; }
        #floralmd-find-status {
            min-width: 44px;
            color: var(--secondary);
            font-size: 12px;
            text-align: center;
            white-space: nowrap;
        }
        .floralmd-find-button {
            min-width: 25px;
            height: 25px;
            padding: 0 6px;
            border: 0;
            border-radius: 5px;
            background: transparent;
            color: var(--text);
            font: inherit;
            font-size: 14px;
        }
        .floralmd-find-button:hover { background: color-mix(in srgb, var(--secondary) 15%, transparent); }
        #floralmd-find-highlights {
            position: fixed;
            inset: 0;
            z-index: 20;
            pointer-events: none;
            overflow: hidden;
        }
        .floralmd-find-highlight {
            position: fixed;
            border-radius: 2px;
            pointer-events: none;
        }
        .floralmd-find-highlight-all {
            background: color-mix(in srgb, Highlight 28%, transparent);
        }
        .floralmd-find-highlight-current {
            background: color-mix(in srgb, Highlight 78%, transparent);
        }
        </style>
        </head>
        <body>
        <div id="editor"></div>
        <div id="floralmd-find-highlights" aria-hidden="true"></div>
        <div id="floralmd-findbar" role="search" hidden>
            <input id="floralmd-find-input" type="search" placeholder="查找" autocomplete="off" spellcheck="false">
            <span id="floralmd-find-status" aria-live="polite"></span>
            <button class="floralmd-find-button" id="floralmd-find-previous" type="button" aria-label="上一个">↑</button>
            <button class="floralmd-find-button" id="floralmd-find-next" type="button" aria-label="下一个">↓</button>
            <button class="floralmd-find-button" id="floralmd-find-close" type="button" aria-label="关闭">×</button>
        </div>
        <script>\(safeInlineScript(mermaidJavaScript))</script>
        <script>\(safeInlineScript(katexJavaScript))</script>
        <script>
        if (window.mermaid) {
            window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                theme: window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default"
            });
        }
        </script>
        <script>\(editorJavaScript)</script>
        <script>
        (function () {
            const post = function (m) {
                try { window.webkit.messageHandlers.\(EditorBridge.name).postMessage(m); } catch (e) {}
            };
            window.__mdOpenLink = function (destination) {
                post({ kind: "openLink", destination: destination });
            };
            window.__mdOpenImage = function (details) {
                post({
                    kind: "openImage",
                    destination: details.destination,
                    sourceFrom: details.sourceFrom,
                    sourceTo: details.sourceTo,
                    activation: details.activation
                });
            };
            window.onerror = function (message) { post("error: " + message); };
            const findBar = document.getElementById("floralmd-findbar");
            const findInput = document.getElementById("floralmd-find-input");
            const findStatus = document.getElementById("floralmd-find-status");
            const findHighlightLayer = document.getElementById("floralmd-find-highlights");
            let findMatches = [];
            let findMatchIndex = -1;
            let currentFindRange = null;
            let findHighlightRequest = 0;
            let findHighlightFrame = null;
            let findContentObserver = null;
            let findResizeObserver = null;
            let findScrollElement = null;

            function clearFindHighlights() {
                findHighlightRequest += 1;
                currentFindRange = null;
                findHighlightLayer.replaceChildren();
            }

            function renderedFindOccurrences(query) {
                const view = editor && editor._view;
                if (!view || !query) return [];
                const needle = query.toLocaleLowerCase();
                const occurrences = [];

                view.contentDOM.querySelectorAll(".cm-line").forEach(function (line) {
                    if (line.getBoundingClientRect().height < 0.5) return;
                    const nodes = [];
                    const walker = document.createTreeWalker(
                        line,
                        NodeFilter.SHOW_TEXT,
                        {
                            acceptNode: function (node) {
                                let element = node.parentElement;
                                while (element && element !== line) {
                                    const style = getComputedStyle(element);
                                    if (style.display === "none" || style.visibility === "hidden") {
                                        return NodeFilter.FILTER_REJECT;
                                    }
                                    element = element.parentElement;
                                }
                                return node.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                            }
                        }
                    );
                    let rendered = "";
                    let node = walker.nextNode();
                    while (node) {
                        const start = rendered.length;
                        rendered += node.nodeValue;
                        nodes.push({ node: node, start: start, end: rendered.length });
                        node = walker.nextNode();
                    }
                    if (!nodes.length) return;

                    const haystack = rendered.toLocaleLowerCase();
                    let offset = 0;
                    while (offset <= haystack.length - needle.length) {
                        const match = haystack.indexOf(needle, offset);
                        if (match < 0) break;
                        const matchEnd = match + query.length;
                        const startEntry = nodes.find(function (entry) { return match < entry.end; })
                            || nodes[nodes.length - 1];
                        const endEntry = nodes.find(function (entry) { return matchEnd <= entry.end; })
                            || nodes[nodes.length - 1];
                        try {
                            const range = document.createRange();
                            range.setStart(startEntry.node, Math.max(match - startEntry.start, 0));
                            range.setEnd(
                                endEntry.node,
                                Math.min(matchEnd - endEntry.start, endEntry.node.nodeValue.length)
                            );
                            const sourceFrom = view.posAtDOM(
                                startEntry.node,
                                Math.max(match - startEntry.start, 0)
                            );
                            const sourceText = view.state.doc.sliceString(
                                sourceFrom,
                                sourceFrom + query.length
                            );
                            if (sourceText.toLocaleLowerCase() !== needle) {
                                offset = match + Math.max(query.length, 1);
                                continue;
                            }
                            occurrences.push({
                                range: range,
                                sourceFrom: sourceFrom
                            });
                        } catch (_) {}
                        offset = match + Math.max(query.length, 1);
                    }
                });
                return occurrences;
            }

            function appendFindHighlightRectangles(fragment, range, className) {
                Array.from(range.getClientRects()).forEach(function (rect) {
                    if (rect.width < 0.5 || rect.height < 0.5) return;
                    const highlight = document.createElement("div");
                    highlight.className = "floralmd-find-highlight " + className;
                    highlight.style.left = rect.left + "px";
                    highlight.style.top = rect.top + "px";
                    highlight.style.width = rect.width + "px";
                    highlight.style.height = rect.height + "px";
                    highlight.dataset.match = range.toString();
                    fragment.appendChild(highlight);
                });
            }

            function renderVisibleFindHighlights() {
                const view = editor && editor._view;
                const currentMatch = findMatches[findMatchIndex];
                const occurrences = renderedFindOccurrences(findInput.value);
                let currentOccurrence = null;
                let closestDistance = Infinity;
                if (view && currentMatch) {
                    const currentLine = view.state.doc.lineAt(currentMatch.from).number;
                    occurrences.forEach(function (occurrence) {
                        const occurrenceLine = view.state.doc.lineAt(occurrence.sourceFrom).number;
                        const distance = Math.abs(occurrence.sourceFrom - currentMatch.from);
                        if (occurrenceLine === currentLine && distance < closestDistance) {
                            currentOccurrence = occurrence;
                            closestDistance = distance;
                        }
                    });
                }
                const currentRange = currentOccurrence?.range || null;
                const allRanges = occurrences
                    .filter(function (occurrence) { return occurrence !== currentOccurrence; })
                    .map(function (occurrence) { return occurrence.range; });
                currentFindRange = currentRange;
                const fragment = document.createDocumentFragment();
                allRanges.forEach(function (range) {
                    appendFindHighlightRectangles(fragment, range, "floralmd-find-highlight-all");
                });
                if (currentRange) {
                    appendFindHighlightRectangles(
                        fragment,
                        currentRange,
                        "floralmd-find-highlight-current"
                    );
                }
                findHighlightLayer.replaceChildren(fragment);
                return currentRange;
            }

            function scheduleVisibleFindHighlights() {
                if (findBar.hidden || !findInput.value || findHighlightFrame !== null) return;
                const request = findHighlightRequest;
                findHighlightFrame = requestAnimationFrame(function () {
                    findHighlightFrame = null;
                    if (request === findHighlightRequest) renderVisibleFindHighlights();
                });
            }

            function highlightFindMatch(match) {
                clearFindHighlights();
                const request = findHighlightRequest;
                const applyHighlight = function () {
                    if (request !== findHighlightRequest) return false;
                    const range = renderVisibleFindHighlights();
                    if (!range) return false;
                    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
                        ? range.startContainer : range.startContainer.parentElement;
                    element?.closest(".cm-line")?.scrollIntoView({ block: "center", inline: "nearest" });
                    return true;
                };
                if (applyHighlight()) return;

                // CodeMirror virtualizes offscreen lines, so domAtPos can
                // initially have no rendered node. Bring the source block
                // into the viewport and create the DOM Range on the next frame.
                const view = editor && editor._view;
                if (!view) return;
                const block = view.lineBlockAt(match.from);
                const maximum = Math.max(view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight, 0);
                view.scrollDOM.scrollTop = Math.min(
                    Math.max(block.top - view.scrollDOM.clientHeight / 2, 0),
                    maximum
                );
                view.scrollDOM.dispatchEvent(new Event("scroll"));
                view.requestMeasure();
                requestAnimationFrame(applyHighlight);
            }

            function collectFindMatches(query) {
                findMatches = [];
                if (!editor || !query) return;
                const source = editor.getMarkdown();
                const haystack = source.toLocaleLowerCase();
                const needle = query.toLocaleLowerCase();
                let offset = 0;
                while (offset <= haystack.length - needle.length) {
                    const match = haystack.indexOf(needle, offset);
                    if (match < 0) break;
                    findMatches.push({ from: match, to: match + query.length });
                    offset = match + Math.max(query.length, 1);
                }
            }

            function showFindMatch(index) {
                if (!findMatches.length) {
                    findMatchIndex = -1;
                    clearFindHighlights();
                    findStatus.textContent = findInput.value ? "无结果" : "";
                    return;
                }
                findMatchIndex = (index + findMatches.length) % findMatches.length;
                const match = findMatches[findMatchIndex];
                highlightFindMatch(match);
                findStatus.textContent = (findMatchIndex + 1) + " / " + findMatches.length;
                findInput.focus();
            }

            function refreshFind(preferCurrentSelection) {
                collectFindMatches(findInput.value);
                if (!findMatches.length) {
                    showFindMatch(-1);
                    return;
                }
                const selection = editor._view.state.selection.main;
                const current = findMatches.findIndex(function (match) {
                    return match.from >= selection.from;
                });
                showFindMatch(preferCurrentSelection && current >= 0 ? current : 0);
            }

            function openFind() {
                if (!editor) return;
                findBar.hidden = false;
                const selection = editor._view.state.selection.main;
                if (!findInput.value && selection.to > selection.from && selection.to - selection.from <= 200) {
                    findInput.value = editor.getMarkdown().slice(selection.from, selection.to);
                }
                refreshFind(true);
                findInput.focus();
                findInput.select();
            }

            function closeFind() {
                findBar.hidden = true;
                findStatus.textContent = "";
                clearFindHighlights();
                if (editor) editor.focus();
            }

            function installHeadingSourceMeasurements(editor) {
                const view = editor && editor._view;
                if (!view) return function () {};
                let destroyed = false;
                let scheduledFrame = null;
                let scheduledFallback = null;

                function measure() {
                    scheduledFrame = null;
                    if (scheduledFallback !== null) clearTimeout(scheduledFallback);
                    scheduledFallback = null;
                    if (destroyed) return;
                    const headings = view.contentDOM.querySelectorAll(
                        ".cm-md-h1:not(.cm-md-heading-inactive),"
                        + ".cm-md-h2:not(.cm-md-heading-inactive),"
                        + ".cm-md-h3:not(.cm-md-heading-inactive),"
                        + ".cm-md-h4:not(.cm-md-heading-inactive),"
                        + ".cm-md-h5:not(.cm-md-heading-inactive),"
                        + ".cm-md-h6:not(.cm-md-heading-inactive)"
                    );
                    headings.forEach(function (line) {
                        const source = line.querySelector(".cm-md-syntax");
                        if (!source) return;
                        const walker = document.createTreeWalker(
                            source, NodeFilter.SHOW_TEXT
                        );
                        const textNodes = [];
                        let textNode;
                        while ((textNode = walker.nextNode())) textNodes.push(textNode);
                        if (!textNodes.length) return;
                        const range = document.createRange();
                        range.setStart(textNodes[0], 0);
                        const last = textNodes[textNodes.length - 1];
                        range.setEnd(last, last.nodeValue.length);
                        const width = range.getBoundingClientRect().width;
                        if (!(width > 0)) return;
                        const levelClass = Array.from(line.classList).find(function (name) {
                            return /^cm-md-h[1-6]$/.test(name);
                        });
                        if (!levelClass) return;
                        const level = levelClass.slice(-1);
                        const property = "--cm-md-h" + level + "-source-width";
                        const previous = parseFloat(
                            document.documentElement.style.getPropertyValue(property)
                        );
                        if (!Number.isFinite(previous) || Math.abs(previous - width) > 0.25) {
                            document.documentElement.style.setProperty(property, width + "px");
                        }
                    });
                }

                function schedule() {
                    if (destroyed || scheduledFrame !== null) return;
                    scheduledFrame = requestAnimationFrame(measure);
                    scheduledFallback = setTimeout(measure, 50);
                }

                measure();
                const observer = new MutationObserver(schedule);
                observer.observe(view.contentDOM, {
                    childList: true,
                    subtree: true,
                    characterData: true,
                    attributes: true,
                    attributeFilter: ["class"]
                });
                const interactionEvents = [
                    "focusin", "focusout", "keydown", "keyup",
                    "mousedown", "mouseup", "input"
                ];
                interactionEvents.forEach(function (name) {
                    view.contentDOM.addEventListener(name, schedule, true);
                });
                document.addEventListener("selectionchange", schedule);
                window.addEventListener("floralmd-typography-change", schedule);
                window.addEventListener("floralmd-layout-change", schedule);
                schedule();
                return function () {
                    destroyed = true;
                    if (scheduledFrame !== null) cancelAnimationFrame(scheduledFrame);
                    if (scheduledFallback !== null) clearTimeout(scheduledFallback);
                    observer.disconnect();
                    interactionEvents.forEach(function (name) {
                        view.contentDOM.removeEventListener(name, schedule, true);
                    });
                    document.removeEventListener("selectionchange", schedule);
                    window.removeEventListener("floralmd-typography-change", schedule);
                    window.removeEventListener("floralmd-layout-change", schedule);
                };
            }

            findInput.addEventListener("input", function () { refreshFind(true); });
            findInput.addEventListener("keydown", function (event) {
                if (event.key === "Enter") {
                    event.preventDefault();
                    showFindMatch(findMatchIndex + (event.shiftKey ? -1 : 1));
                } else if (event.key === "Escape") {
                    event.preventDefault();
                    event.stopPropagation();
                    closeFind();
                }
            });
            document.getElementById("floralmd-find-previous").addEventListener("click", function () {
                showFindMatch(findMatchIndex - 1);
            });
            document.getElementById("floralmd-find-next").addEventListener("click", function () {
                showFindMatch(findMatchIndex + 1);
            });
            document.getElementById("floralmd-find-close").addEventListener("click", closeFind);
            window.addEventListener("floralmd-layout-change", scheduleVisibleFindHighlights);
            function installSemanticGutter(editor) {
                const view = editor && editor._view;
                if (!view) return function () {};

                const gutter = document.createElement("div");
                gutter.className = "cm-floralmd-gutter";
                gutter.setAttribute("aria-hidden", "true");
                view.scrollDOM.appendChild(gutter);

                let cachedDocument = null;
                let cachedLabels = new Map();
                let lastSignature = "";
                let destroyed = false;
                let isScheduled = false;
                let scheduledFrame = null;
                let scheduledFallback = null;

                function labelsForDocument() {
                    const documentValue = view.state.doc;
                    if (cachedDocument === documentValue) return cachedLabels;
                    cachedDocument = documentValue;
                    const semanticRows = typeof editor.semanticLabels === "function"
                        ? editor.semanticLabels() : [];
                    cachedLabels = new Map(semanticRows.map(function (row) {
                        return [row.line, row.label];
                    }));
                    return cachedLabels;
                }

                function readGeometry() {
                    const documentValue = view.state.doc;
                    const labels = labelsForDocument();
                    const first = documentValue.lineAt(view.viewport.from).number;
                    const last = documentValue.lineAt(view.viewport.to).number;
                    const rows = [];
                    const scrollerRect = view.scrollDOM.getBoundingClientRect();
                    const contentRect = view.contentDOM.getBoundingClientRect();

                    for (let number = first; number <= last; number += 1) {
                        const line = documentValue.line(number);
                        const label = labels.get(number) || "";
                        try {
                            const position = view.domAtPos(line.from);
                            const element = position.node.nodeType === Node.ELEMENT_NODE
                                ? position.node : position.node.parentElement;
                            const sourceLine = element && element.closest(".cm-line");
                            if (!sourceLine) continue;
                            const lineRect = sourceLine.getBoundingClientRect();
                            // Live preview deliberately collapses fence source
                            // lines. They have no visual row, so
                            // showing their numbers would stack them on top of
                            // the next visible line.
                            if (lineRect.height < 0.5) continue;
                            const style = getComputedStyle(sourceLine);
                            const paddingTop = parseFloat(style.paddingTop) || 0;
                            const paddingBottom = parseFloat(style.paddingBottom) || 0;
                            const contentHeight = Math.max(
                                lineRect.height - paddingTop - paddingBottom,
                                1
                            );
                            const computedLineHeight = parseFloat(style.lineHeight);
                            // A .cm-line rect spans every visual row when one
                            // logical source line wraps. Keep exactly one
                            // gutter entry, but size it to the first CSS line
                            // box so its number and semantic badge do not
                            // drift to the middle of the wrapped block.
                            const firstVisualLineHeight = Number.isFinite(computedLineHeight)
                                && computedLineHeight > 0
                                ? Math.min(computedLineHeight, contentHeight)
                                : contentHeight;
                            rows.push({
                                number: number,
                                label: label,
                                top: lineRect.top - scrollerRect.top
                                    + view.scrollDOM.scrollTop + paddingTop,
                                height: Math.max(firstVisualLineHeight, 1)
                            });
                        } catch (_) {}
                    }
                    return {
                        left: contentRect.left - scrollerRect.left
                            + view.scrollDOM.scrollLeft - 68,
                        rows: rows
                    };
                }

                function writeGutter(model) {
                    if (destroyed) return;
                    const signature = model.left + ":" + model.rows.map(function (row) {
                        return [row.number, row.label, row.top, row.height].join("/");
                    }).join("|");
                    if (signature === lastSignature) return;
                    lastSignature = signature;
                    gutter.style.left = model.left + "px";
                    const fragment = document.createDocumentFragment();
                    model.rows.forEach(function (row) {
                        const line = document.createElement("div");
                        line.className = "cm-floralmd-gutter-line";
                        line.dataset.sourceLine = String(row.number);
                        line.style.top = row.top + "px";
                        line.style.height = row.height + "px";
                        const semantic = document.createElement("span");
                        if (row.label) {
                            semantic.className = "cm-semantic-badge cm-semantic-"
                                + row.label.toLowerCase();
                            semantic.textContent = row.label;
                        }
                        const number = document.createElement("span");
                        number.className = "cm-floralmd-line-number";
                        number.textContent = String(row.number);
                        line.append(semantic, number);
                        fragment.appendChild(line);
                    });
                    gutter.replaceChildren(fragment);
                }

                function schedule() {
                    if (destroyed || isScheduled) return;
                    isScheduled = true;
                    const render = function () {
                        if (!isScheduled) return;
                        isScheduled = false;
                        if (scheduledFrame !== null) cancelAnimationFrame(scheduledFrame);
                        if (scheduledFallback !== null) clearTimeout(scheduledFallback);
                        scheduledFrame = null;
                        scheduledFallback = null;
                        try { writeGutter(readGeometry()); }
                        catch (error) { console.error("Semantic gutter render failed", error); }
                    };
                    scheduledFrame = requestAnimationFrame(render);
                    // WKWebView can pause animation frames while a view is
                    // temporarily offscreen. Keep the gutter correct after
                    // background edits without turning scrolling into a timer loop.
                    scheduledFallback = setTimeout(render, 50);
                }
                try { writeGutter(readGeometry()); }
                catch (error) { console.error("Semantic gutter initial render failed", error); }
                const mutationObserver = new MutationObserver(schedule);
                mutationObserver.observe(view.contentDOM, {
                    childList: true,
                    subtree: true,
                    characterData: true,
                    attributes: true
                });
                const resizeObserver = new ResizeObserver(schedule);
                resizeObserver.observe(view.scrollDOM);
                // Font size and line height are CSS variables on <html>, so
                // changing them does not mutate contentDOM and may not resize
                // the scroller itself. Listen for the explicit typography
                // event to measure every visible source line again.
                window.addEventListener("floralmd-typography-change", schedule);
                window.addEventListener("floralmd-layout-change", schedule);

                return function () {
                    destroyed = true;
                    isScheduled = false;
                    if (scheduledFrame !== null) cancelAnimationFrame(scheduledFrame);
                    if (scheduledFallback !== null) clearTimeout(scheduledFallback);
                    mutationObserver.disconnect();
                    resizeObserver.disconnect();
                    window.removeEventListener("floralmd-typography-change", schedule);
                    window.removeEventListener("floralmd-layout-change", schedule);
                    gutter.remove();
                };
            }
            let editor = null;
            let removeSemanticGutter = null;
            let removeHeadingSourceMeasurements = null;
            let removeTypewriterBehavior = null;
            let currentTypewriterModeEnabled = \(typewriterModeEnabled ? "true" : "false");
            let externalCompositionActive = false;
            let pendingContentWidth = null;
            let typewriterDefaultPaddingTop = \(MarkdownHTML.pagePaddingTop);
            let typewriterDefaultPaddingBottom = \(MarkdownHTML.pagePaddingBottom);
            let typewriterTargetRatio = 0.47;
            let contentWidthMeasureFrame = null;
            let contentWidthMeasureFallback = null;
            function performContentWidthMeasure() {
                if (contentWidthMeasureFrame !== null) cancelAnimationFrame(contentWidthMeasureFrame);
                if (contentWidthMeasureFallback !== null) clearTimeout(contentWidthMeasureFallback);
                contentWidthMeasureFrame = null;
                contentWidthMeasureFallback = null;
                if (editor) editor._view.requestMeasure();
                window.dispatchEvent(new Event("floralmd-layout-change"));
            }
            function scheduleContentWidthMeasure() {
                if (contentWidthMeasureFrame !== null) return;
                contentWidthMeasureFrame = requestAnimationFrame(performContentWidthMeasure);
                // A hidden WKWebView can pause rAF; this fallback only closes
                // geometry, while the visible CSS width is already applied.
                contentWidthMeasureFallback = setTimeout(performContentWidthMeasure, 50);
            }
            function applyPendingContentWidth() {
                if (pendingContentWidth === null) return;
                if (externalCompositionActive || (editor && editor._view.composing)) return;
                const width = pendingContentWidth;
                pendingContentWidth = null;
                document.documentElement.style.setProperty(
                    "--floralmd-content-width",
                    width + "px"
                );
                scheduleContentWidthMeasure();
            }
            window.__floralmdSetContentWidth = function (width) {
                if (!Number.isFinite(width) || width < 0) return false;
                pendingContentWidth = width;
                applyPendingContentWidth();
                return true;
            };
            window.__mdLoadEditor = function (markdown) {
                externalCompositionActive = false;
                if (findContentObserver) {
                    findContentObserver.disconnect();
                    findContentObserver = null;
                }
                if (findResizeObserver) {
                    findResizeObserver.disconnect();
                    findResizeObserver = null;
                }
                if (findScrollElement) {
                    findScrollElement.removeEventListener("scroll", scheduleVisibleFindHighlights);
                    findScrollElement = null;
                }
                if (removeHeadingSourceMeasurements) removeHeadingSourceMeasurements();
                if (removeSemanticGutter) removeSemanticGutter();
                if (removeTypewriterBehavior) removeTypewriterBehavior();
                if (editor) editor.destroy();
                editor = window.MDEditor.create(
                    document.getElementById("editor"),
                    markdown,
                    {
                        onDirty: function () {
                            post({ kind: "change", markdown: editor.getMarkdown() });
                        },
                        // Preview block margins (MarkdownHTML design tokens):
                        // the bundle sizes blank-separator lines from these.
                        spacing: {
                            line: \(MarkdownHTML.sourceLineHeight),
                            paragraph: \(MarkdownHTML.paragraphSpacing),
                            quote: \(MarkdownHTML.quoteSpacing),
                            alert: \(MarkdownHTML.largeBlockSpacing),
                            table: \(MarkdownHTML.largeBlockSpacing),
                            hr: \(MarkdownHTML.hrSpacing)
                        },
                        tableLabels: {
                            addRow: \(addRowLabel),
                            addColumn: \(addColumnLabel),
                            selectRow: \(selectRowLabel),
                            selectColumn: \(selectColumnLabel)
                        }
                    }
                );
                let typewriterEnabled = false;
                let typewriterSuspendedByPointer = false;
                let typewriterCompositionActive = false;
                let typewriterKeyboardIntent = false;
                let typewriterFollowingActive = false;
                let typewriterFollowFrame = null;
                let typewriterFollowFallback = null;
                let typewriterResizeObserver = null;
                let typewriterDampedFrame = null;
                let typewriterDampedTimer = null;
                let typewriterDampedDeadline = null;
                let typewriterDampedVelocity = 0;
                let typewriterDampedLastTime = 0;
                let typewriterDampedStartedAt = 0;
                let typewriterDampedStepToken = 0;
                // Every typewriter-owned scrollTop write funnels through
                // setTypewriterScrollTop so tests can assert that typing never
                // scrolls and Enter is the only typewriter scroll.
                let typewriterScrollWriteCount = 0;
                function setTypewriterScrollTop(scroller, value) {
                    typewriterScrollWriteCount += 1;
                    scroller.scrollTop = value;
                }

                function clearTypewriterFollow() {
                    if (typewriterFollowFrame !== null) cancelAnimationFrame(typewriterFollowFrame);
                    if (typewriterFollowFallback !== null) clearTimeout(typewriterFollowFallback);
                    typewriterFollowFrame = null;
                    typewriterFollowFallback = null;
                }

                function cancelTypewriterDampedMotion() {
                    if (typewriterDampedFrame !== null) cancelAnimationFrame(typewriterDampedFrame);
                    if (typewriterDampedTimer !== null) clearTimeout(typewriterDampedTimer);
                    if (typewriterDampedDeadline !== null) clearTimeout(typewriterDampedDeadline);
                    typewriterDampedFrame = null;
                    typewriterDampedTimer = null;
                    typewriterDampedDeadline = null;
                    typewriterDampedVelocity = 0;
                    typewriterDampedLastTime = 0;
                    typewriterDampedStartedAt = 0;
                    typewriterDampedStepToken += 1;
                }

                function isTypewriterDampedMotionActive() {
                    return typewriterDampedFrame !== null || typewriterDampedTimer !== null
                        || typewriterDampedDeadline !== null;
                }

                function scheduleTypewriterDampedStep() {
                    const token = ++typewriterDampedStepToken;
                    typewriterDampedFrame = requestAnimationFrame(function () {
                        stepTypewriterDampedMotion(token);
                    });
                    typewriterDampedTimer = setTimeout(function () {
                        stepTypewriterDampedMotion(token);
                    }, 16);
                }

                function focusedTableCellCaretRect() {
                    const active = document.activeElement;
                    const cell = active?.closest?.(".cm-md-table-cell");
                    if (!cell || active !== cell) return null;
                    const selection = window.getSelection();
                    if (!selection || selection.rangeCount === 0) return null;
                    const range = selection.getRangeAt(0);
                    if (!cell.contains(range.startContainer) || !cell.contains(range.endContainer)) {
                        return null;
                    }
                    const caretRange = range.cloneRange();
                    if (!caretRange.collapsed) caretRange.collapse(false);
                    const rects = caretRange.getClientRects();
                    const rect = rects.length > 0
                        ? rects[rects.length - 1]
                        : caretRange.getBoundingClientRect();
                    if (rect && Number.isFinite(rect.top) && Number.isFinite(rect.bottom)
                        && (rect.top !== 0 || rect.bottom !== 0)) {
                        return rect;
                    }
                    const cellRect = cell.getBoundingClientRect();
                    return Number.isFinite(cellRect.top) && Number.isFinite(cellRect.bottom)
                        ? cellRect
                        : null;
                }

                function currentEditingCaretRect() {
                    const tableCaret = focusedTableCellCaretRect();
                    if (tableCaret) return tableCaret;
                    const view = editor._view;
                    const selection = view.state.selection.main;
                    return view.coordsAtPos(selection.head, selection.assoc || 1);
                }

                function typewriterScrollTarget() {
                    const view = editor._view;
                    const caret = currentEditingCaretRect();
                    if (!caret) return null;
                    const scroller = view.scrollDOM;
                    const scrollerRect = scroller.getBoundingClientRect();
                    const caretCenter = (caret.top + caret.bottom) / 2;
                    const target = scrollerRect.top + scroller.clientHeight * typewriterTargetRatio;
                    const maximum = Math.max(scroller.scrollHeight - scroller.clientHeight, 0);
                    return Math.min(Math.max(scroller.scrollTop + caretCenter - target, 0), maximum);
                }

                function interruptTypewriterScroll() {
                    cancelTypewriterDampedMotion();
                    const scroller = editor._view.scrollDOM;
                    // Reading and rewriting the same scrollTop synchronously
                    // cancels any in-flight scroll animation; scrollTo() with
                    // options can commit asynchronously and overwrite the
                    // follow's scrollTop write.
                    scroller.scrollTop = scroller.scrollTop;
                }

                function finishTypewriterDampedMotion() {
                    const scroller = editor._view.scrollDOM;
                    const nextTop = typewriterScrollTarget();
                    cancelTypewriterDampedMotion();
                    if (nextTop !== null) setTypewriterScrollTop(scroller, nextTop);
                }

                function stepTypewriterDampedMotion(token) {
                    if (token !== typewriterDampedStepToken) return;
                    if (typewriterDampedFrame !== null) cancelAnimationFrame(typewriterDampedFrame);
                    if (typewriterDampedTimer !== null) clearTimeout(typewriterDampedTimer);
                    typewriterDampedFrame = null;
                    typewriterDampedTimer = null;
                    const scroller = editor._view.scrollDOM;
                    const nextTop = typewriterScrollTarget();
                    if (nextTop === null) {
                        cancelTypewriterDampedMotion();
                        return;
                    }
                    const now = performance.now();
                    const deltaMilliseconds = typewriterDampedLastTime > 0
                        ? now - typewriterDampedLastTime
                        : 1000 / 60;
                    const deltaSeconds = Math.min(Math.max(deltaMilliseconds / 1000, 1 / 120), 0.032);
                    typewriterDampedLastTime = now;
                    const currentTop = scroller.scrollTop;
                    const displacement = nextTop - currentTop;
                    // Near-critical damping keeps line changes soft without the
                    // visible overshoot of a playful spring.
                    const acceleration = displacement * 420 - typewriterDampedVelocity * 41;
                    typewriterDampedVelocity += acceleration * deltaSeconds;
                    let updatedTop = currentTop + typewriterDampedVelocity * deltaSeconds;
                    if (displacement * (nextTop - updatedTop) < 0) {
                        updatedTop = nextTop;
                        typewriterDampedVelocity = 0;
                    }
                    setTypewriterScrollTop(scroller, updatedTop);
                    if ((Math.abs(displacement) < 0.6 && Math.abs(typewriterDampedVelocity) < 4)
                        || now - typewriterDampedStartedAt >= 260) {
                        finishTypewriterDampedMotion();
                        return;
                    }
                    scheduleTypewriterDampedStep();
                }

                function startTypewriterDampedMotion() {
                    if (isTypewriterDampedMotionActive()) return;
                    typewriterDampedVelocity = 0;
                    typewriterDampedLastTime = 0;
                    typewriterDampedStartedAt = performance.now();
                    typewriterDampedDeadline = setTimeout(finishTypewriterDampedMotion, 260);
                    scheduleTypewriterDampedStep();
                }

                function suspendTypewriterFollow() {
                    typewriterSuspendedByPointer = true;
                    typewriterFollowingActive = false;
                    typewriterKeyboardIntent = false;
                    typewriterAlignPending = false;
                    clearTypewriterFollow();
                    interruptTypewriterScroll();
                }

                function typewriterPadding() {
                    // EXPERIMENT (codex/typewriter-no-padding): the typewriter
                    // keeps the standard page padding, so the layout is
                    // identical to the typewriter-off editor. Enter realigns
                    // toward the 47% target but clamps at the scroll bounds
                    // near the first/last lines.
                    return {
                        top: typewriterDefaultPaddingTop,
                        bottom: typewriterDefaultPaddingBottom
                    };
                }

                function applyTypewriterPadding(enabled) {
                    const view = editor._view;
                    const content = view.contentDOM;
                    const previousTop = parseFloat(getComputedStyle(content).paddingTop) || 0;
                    const padding = enabled
                        ? typewriterPadding()
                        : { top: typewriterDefaultPaddingTop, bottom: typewriterDefaultPaddingBottom };
                    document.documentElement.style.setProperty(
                        "--floralmd-editor-padding-top", padding.top + "px"
                    );
                    document.documentElement.style.setProperty(
                        "--floralmd-editor-padding-bottom", padding.bottom + "px"
                    );
                    view.requestMeasure();
                    setTypewriterScrollTop(
                        view.scrollDOM,
                        Math.max(0, view.scrollDOM.scrollTop + padding.top - previousTop)
                    );
                }

                function followTypewriterCaret(behavior) {
                    clearTypewriterFollow();
                    if (!typewriterEnabled || typewriterSuspendedByPointer
                        || typewriterCompositionActive || editor._view.composing) return false;
                    const scroller = editor._view.scrollDOM;
                    const nextTop = typewriterScrollTarget();
                    if (nextTop === null) return false;
                    // CodeMirror can settle wrapped-line geometry one or two device
                    // pixels after input. Treat that as layout rounding, not a new
                    // typewriter target, or the damped follow visibly reverses it.
                    if (Math.abs(nextTop - scroller.scrollTop) < 2.5) {
                        return true;
                    }
                    if (behavior === "auto") {
                        interruptTypewriterScroll();
                        setTypewriterScrollTop(scroller, nextTop);
                    } else {
                        startTypewriterDampedMotion();
                    }
                    return true;
                }

                function performTypewriterFollow() {
                    clearTypewriterFollow();
                    if (!typewriterKeyboardIntent) return;
                    typewriterKeyboardIntent = false;
                    followTypewriterCaret("damped");
                }

                function scheduleTypewriterFollow() {
                    if (!typewriterEnabled || typewriterCompositionActive || editor._view.composing) return;
                    if (typewriterFollowFrame !== null) return;
                    typewriterFollowFrame = requestAnimationFrame(function () {
                        typewriterFollowFrame = requestAnimationFrame(performTypewriterFollow);
                    });
                    typewriterFollowFallback = setTimeout(performTypewriterFollow, 60);
                }

                function isTypewriterKeyboardEvent(event) {
                    if (event.isComposing) return false;
                    if ([
                        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                        "PageUp", "PageDown", "Home", "End",
                        "Backspace", "Delete", "Enter", "Tab"
                    ].includes(event.key)) return true;
                    return event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey;
                }

                function markTypewriterTyping() {
                    // Typing is inert: cancel any follow still in flight so
                    // character input scrolls exactly like the typewriter-off
                    // editor. Only Enter realigns.
                    clearTypewriterFollow();
                    cancelTypewriterDampedMotion();
                }

                function setTypewriterMode(enabled) {
                    const next = enabled === true;
                    currentTypewriterModeEnabled = next;
                    if (next === typewriterEnabled) return true;
                    clearTypewriterFollow();
                    interruptTypewriterScroll();
                    typewriterEnabled = next;
                    typewriterKeyboardIntent = false;
                    typewriterFollowingActive = false;
                    typewriterSuspendedByPointer = false;
                    typewriterAlignPending = false;
                    applyTypewriterPadding(next);
                    return true;
                }

                let typewriterAlignPending = false;
                function alignTypewriterAfterStructuralEdit() {
                    if (!typewriterAlignPending) return;
                    typewriterAlignPending = false;
                    if (!typewriterEnabled || typewriterSuspendedByPointer
                        || !typewriterFollowingActive || typewriterCompositionActive
                        || editor._view.composing) return;
                    // CodeMirror has processed the edit (newline, backspace
                    // merge or delete) by now; measure synchronously and pin
                    // the caret's line to the comfort target before the frame
                    // paints, so there is no visible down-then-back.
                    editor._view.measure();
                    const nextTop = typewriterScrollTarget();
                    if (nextTop === null) return;
                    const scroller = editor._view.scrollDOM;
                    if (Math.abs(nextTop - scroller.scrollTop) >= 2.5) {
                        setTypewriterScrollTop(scroller, nextTop);
                    }
                }
                editor._view.contentDOM.addEventListener("keydown", function (event) {
                    if (!typewriterEnabled || !isTypewriterKeyboardEvent(event)) return;
                    typewriterSuspendedByPointer = false;
                    typewriterFollowingActive = true;
                    typewriterKeyboardIntent = true;
                    // Structural edits (newline, or backspace/delete that
                    // merge lines or shrink a selection) realign the caret
                    // line to the comfort target; plain character edits and
                    // soft wraps never touch the scroll, so typing itself is
                    // free of alignment jitter. CodeMirror prevents default
                    // on beforeinput, so there is no input event to hook;
                    // schedule after the key event.
                    if (event.key === "Enter" || event.key === "Backspace"
                        || event.key === "Delete") {
                        typewriterAlignPending = true;
                        setTimeout(alignTypewriterAfterStructuralEdit, 0);
                        requestAnimationFrame(alignTypewriterAfterStructuralEdit);
                    } else if ([
                        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                        "PageUp", "PageDown", "Home", "End"
                    ].includes(event.key)) {
                        scheduleTypewriterFollow();
                    } else {
                        markTypewriterTyping();
                    }
                }, true);
                editor._view.scrollDOM.addEventListener("pointerdown", function () {
                    suspendTypewriterFollow();
                }, true);
                editor._view.scrollDOM.addEventListener("wheel", function () {
                    suspendTypewriterFollow();
                }, { passive: true });
                const handleTypewriterLayoutChange = function () {
                    // Layout changes (window resize, zoom, content width,
                    // composition width settle) only re-apply the headroom
                    // padding. They never scroll: like the typewriter-off
                    // editor, the caret keeps whatever viewport position the
                    // layout left it at — only Enter and movement keys align.
                    if (!typewriterEnabled) return;
                    applyTypewriterPadding(true);
                };
                typewriterResizeObserver = new ResizeObserver(function (entries) {
                    if (!typewriterEnabled) return;
                    if (entries.some(function (entry) { return entry.target === editor._view.scrollDOM; })) {
                        applyTypewriterPadding(true);
                    }
                });
                typewriterResizeObserver.observe(editor._view.scrollDOM);
                window.addEventListener("resize", handleTypewriterLayoutChange);
                window.addEventListener("floralmd-layout-change", handleTypewriterLayoutChange);
                removeTypewriterBehavior = function () {
                    clearTypewriterFollow();
                    cancelTypewriterDampedMotion();
                    typewriterAlignPending = false;
                    typewriterResizeObserver?.disconnect();
                    window.removeEventListener("resize", handleTypewriterLayoutChange);
                    window.removeEventListener("floralmd-layout-change", handleTypewriterLayoutChange);
                };
                editor._view.contentDOM.addEventListener("compositionstart", function () {
                    externalCompositionActive = true;
                    typewriterCompositionActive = true;
                    // Composition itself does not move the scroll; the caret
                    // follows candidate changes naturally like the plain
                    // editor, and alignment happens on Enter/movement keys.
                    clearTypewriterFollow();
                });
                editor._view.contentDOM.addEventListener("compositionend", function () {
                    externalCompositionActive = false;
                    typewriterCompositionActive = false;
                    applyPendingContentWidth();
                });
                setTypewriterMode(currentTypewriterModeEnabled);
                removeHeadingSourceMeasurements = installHeadingSourceMeasurements(editor);
                removeSemanticGutter = installSemanticGutter(editor);
                findContentObserver = new MutationObserver(scheduleVisibleFindHighlights);
                findContentObserver.observe(editor._view.contentDOM, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                findScrollElement = editor._view.scrollDOM;
                findScrollElement.addEventListener("scroll", scheduleVisibleFindHighlights, { passive: true });
                findResizeObserver = new ResizeObserver(scheduleVisibleFindHighlights);
                findResizeObserver.observe(editor._view.scrollDOM);
                findResizeObserver.observe(editor._view.contentDOM);
                window.__mdEditor = {
                    getMarkdown: function () { return editor.getMarkdown(); },
                    insert: function (markdown) { editor.insert(markdown); },
                    insertAtSelection: function (from, to, markdown) {
                        const view = editor._view;
                        if (!Number.isInteger(from) || !Number.isInteger(to)
                            || from < 0 || to < from || to > view.state.doc.length) {
                            return false;
                        }
                        view.dispatch({
                            changes: { from: from, to: to, insert: markdown },
                            selection: { anchor: from + markdown.length },
                            userEvent: "input.paste",
                            scrollIntoView: true
                        });
                        view.focus();
                        return true;
                    },
                    insertBasicMarkdownTable: function () {
                        const view = editor._view;
                        const insertionPoint = view.state.selection.main.to;
                        const before = insertionPoint > 0
                            ? view.state.doc.sliceString(insertionPoint - 1, insertionPoint)
                            : "";
                        const after = insertionPoint < view.state.doc.length
                            ? view.state.doc.sliceString(insertionPoint, insertionPoint + 1)
                            : "";
                        const prefix = before && before !== "\\n" ? "\\n" : "";
                        const suffix = after && after !== "\\n" ? "\\n" : "";
                        const table = "| 列 1 | 列 2 |\\n| --- | --- |\\n|  |  |";
                        const insertion = prefix + table + suffix;
                        const firstDataCell = insertionPoint + prefix.length
                            + table.lastIndexOf("|  |  |") + 2;
                        view.dispatch({
                            changes: { from: insertionPoint, insert: insertion },
                            selection: { anchor: firstDataCell },
                            userEvent: "input.paste",
                            scrollIntoView: true
                        });
                        view.focus();
                        return true;
                    },
                    insertAt: function (x, y, markdown) {
                        const view = editor._view;
                        // Capture selection when the native drop transaction reaches
                        // CodeMirror. A mapped drop inserts at the pointer without
                        // deleting an unrelated selection. If WebKit cannot map the
                        // release point, the captured selection is replaced, matching
                        // CodeMirror paste semantics instead of appending to the end.
                        const fallback = view.state.selection.main;
                        const position = Number.isFinite(x) && Number.isFinite(y)
                            ? view.posAtCoords({ x: x, y: y })
                            : null;
                        const range = position === null
                            ? { from: fallback.from, to: fallback.to }
                            : { from: position, to: position };
                        view.dispatch({
                            changes: { from: range.from, to: range.to, insert: markdown },
                            selection: { anchor: range.from + markdown.length },
                            userEvent: "input.drop",
                            scrollIntoView: true
                        });
                        view.focus();
                        return true;
                    },
                    replaceExternal: function (markdown) {
                        const view = editor._view;
                        if (externalCompositionActive || view.composing) return false;
                        suspendTypewriterFollow();
                        const selection = view.state.selection.main;
                        const scrollTop = view.scrollDOM.scrollTop;
                        const scrollLeft = view.scrollDOM.scrollLeft;
                        const hadFocus = view.hasFocus;
                        const length = markdown.length;
                        view.dispatch({
                            changes: { from: 0, to: view.state.doc.length, insert: markdown },
                            selection: {
                                anchor: Math.min(selection.anchor, length),
                                head: Math.min(selection.head, length)
                            },
                            userEvent: "input.external"
                        });
                        view.scrollDOM.scrollTop = Math.min(
                            scrollTop,
                            Math.max(view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight, 0)
                        );
                        view.scrollDOM.scrollLeft = scrollLeft;
                        if (hadFocus) view.focus();
                        return true;
                    },
                    getScrollAnchor: function () { return editor.getScrollAnchor(); },
                    focus: function () { editor.focus(); },
                    select: function (anchor, head) {
                        suspendTypewriterFollow();
                        editor.select(anchor, head);
                    },
                    setTypewriterMode: setTypewriterMode,
                    _typewriterStateForTesting: function () {
                        const view = editor._view;
                        const caret = currentEditingCaretRect();
                        const scrollerRect = view.scrollDOM.getBoundingClientRect();
                        const editorRect = view.dom.getBoundingClientRect();
                        const contentRect = view.contentDOM.getBoundingClientRect();
                        return {
                            enabled: typewriterEnabled,
                            suspendedByPointer: typewriterSuspendedByPointer,
                            composing: typewriterCompositionActive || view.composing,
                            dampedMotionActive: isTypewriterDampedMotionActive(),
                            dampedVelocity: typewriterDampedVelocity,
                            keyboardIntent: typewriterKeyboardIntent,
                            followingActive: typewriterFollowingActive,
                            paddingTop: parseFloat(getComputedStyle(view.contentDOM).paddingTop),
                            paddingBottom: parseFloat(getComputedStyle(view.contentDOM).paddingBottom),
                            scrollTop: view.scrollDOM.scrollTop,
                            scrollHeight: view.scrollDOM.scrollHeight,
                            clientHeight: view.scrollDOM.clientHeight,
                            maximumScrollTop: Math.max(
                                view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight,
                                0
                            ),
                            scrollWrites: typewriterScrollWriteCount,
                            caretTop: caret ? caret.top : null,
                            caretCenter: caret ? (caret.top + caret.bottom) / 2 : null,
                            target: scrollerRect.top + view.scrollDOM.clientHeight * typewriterTargetRatio,
                            editorBounds: {
                                top: editorRect.top,
                                width: editorRect.width,
                                height: editorRect.height
                            },
                            scrollBounds: {
                                top: scrollerRect.top,
                                width: scrollerRect.width,
                                height: scrollerRect.height
                            },
                            contentBounds: {
                                top: contentRect.top,
                                width: contentRect.width,
                                height: contentRect.height
                            },
                            viewportFrom: view.viewport.from,
                            viewportTo: view.viewport.to
                        };
                    },
                    _followTypewriterForTesting: function () {
                        typewriterFollowingActive = true;
                        typewriterKeyboardIntent = true;
                        typewriterSuspendedByPointer = false;
                        return followTypewriterCaret("auto");
                    },
                    _suspendTypewriterForTesting: function () {
                        suspendTypewriterFollow();
                    },
                    _setCompositionActiveForTesting: function (active) {
                        externalCompositionActive = active;
                        typewriterCompositionActive = active;
                        editor._setCompositionActiveForTesting(active);
                        if (active) {
                            if (typewriterEnabled) {
                                typewriterSuspendedByPointer = false;
                                typewriterFollowingActive = true;
                                typewriterKeyboardIntent = true;
                            }
                            clearTypewriterFollow();
                        } else {
                            applyPendingContentWidth();
                        }
                    },
                    refreshImages: function () { editor.refreshImages(); },
                    _coordsAtForTesting: function (position) {
                        return editor._view.coordsAtPos(position);
                    },
                    _semanticLabelsForTesting: function () {
                        return editor.semanticLabels();
                    },
                    _selectionForTesting: function () {
                        const selection = editor._view.state.selection.main;
                        return { from: selection.from, to: selection.to };
                    },
                    _viewForTesting: editor._view,
                    _undoForTesting: function () {
                        return editor._undoForTesting();
                    },
                    _redoForTesting: function () {
                        return editor._redoForTesting();
                    },
                    _findRangeForTesting: function () { return currentFindRange; },
                    setScrollPosition: function (progress, sourcePosition, sourceGap) {
                        return editor.setScrollPosition(progress, sourcePosition, sourceGap);
                    },
                    exec: function (name) { editor.exec(name); },
                    openFind: openFind
                };
                if (!findBar.hidden) refreshFind(true);
                requestAnimationFrame(function () { post("ready"); });
            };
            document.addEventListener("keydown", function (e) {
                if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "f") {
                    e.preventDefault();
                    e.stopPropagation();
                    openFind();
                    return;
                }
                if (e.key === "Escape" && !e.defaultPrevented) {
                    if (!findBar.hidden) closeFind();
                    else post("cancel");
                }
            });
            document.addEventListener("paste", function (event) {
                const clipboard = event.clipboardData;
                if (!clipboard) return;
                const candidates = Array.from(clipboard.files || []).filter(function (file) {
                    const extension = (file.name.split(".").pop() || "").toLowerCase();
                    return file.type.startsWith("image/")
                        || ["png", "jpg", "jpeg", "gif", "webp", "svg"].includes(extension);
                });
                if (!candidates.length) return;
                event.preventDefault();
                const capturedSelection = editor._view.state.selection.main;

                const mimeTypeFor = function (file) {
                    if (file.type) return file.type;
                    const extension = (file.name.split(".").pop() || "").toLowerCase();
                    if (extension === "png") return "image/png";
                    if (extension === "gif") return "image/gif";
                    if (extension === "webp") return "image/webp";
                    if (extension === "svg") return "image/svg+xml";
                    return "image/jpeg";
                };
                const readCandidate = function (file) {
                    return new Promise(function (resolve, reject) {
                        const reader = new FileReader();
                        reader.onload = function () {
                            const result = typeof reader.result === "string" ? reader.result : "";
                            const comma = result.indexOf(",");
                            if (comma < 0) {
                                reject(new Error("clipboard image read failed"));
                                return;
                            }
                            resolve({
                                name: file.name || null,
                                mimeType: mimeTypeFor(file),
                                data: result.slice(comma + 1)
                            });
                        };
                        reader.onerror = function () {
                            reject(new Error("clipboard image read failed"));
                        };
                        reader.readAsDataURL(file);
                    });
                };
                Promise.all(candidates.map(readCandidate)).then(function (items) {
                    post({
                        kind: "pasteImage",
                        items: items,
                        selection: {
                            from: capturedSelection.from,
                            to: capturedSelection.to
                        }
                    });
                }).catch(function () {
                    post("error: clipboard image read failed");
                });
            });
            window.__mdLoadEditor(\(jsStringLiteral(markdown)));
        })();
        </script>
        </body>
        </html>
        """
    }

}

private final class EditorBridge: NSObject, WKScriptMessageHandler {
    static let name = "mdEditorHost"
    weak var owner: CodeMirrorEditorViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == EditorBridge.name else { return }
        owner?.handle(message: message.body)
    }
}
