import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class MarkdownEditorCommandTarget: ObservableObject {
    @Published private(set) var isReady = false
    private weak var controller: CodeMirrorEditorViewController?
    private var connectionID: UUID?

    func connect(to controller: CodeMirrorEditorViewController) {
        let connectionID = UUID()
        self.controller = controller
        self.connectionID = connectionID
        isReady = false
        observeReadiness(of: controller, connectionID: connectionID)
    }

    func disconnect(from controller: CodeMirrorEditorViewController) {
        guard self.controller === controller else { return }
        self.controller = nil
        connectionID = nil
        isReady = false
    }

    func insertBasicMarkdownTable() {
        guard isReady else { return }
        controller?.insertBasicMarkdownTable()
    }

    private func observeReadiness(
        of controller: CodeMirrorEditorViewController,
        connectionID: UUID
    ) {
        controller.inspectEditorState { [weak self, weak controller] state in
            guard let self,
                  let controller,
                  self.connectionID == connectionID,
                  self.controller === controller else { return }
            if state.isReady && state.isEditable {
                self.isReady = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.observeReadiness(of: controller, connectionID: connectionID)
                }
            }
        }
    }
}

/// The public-API fallback leaves WebKit's native background enabled and lets
/// `NSWindow.alphaValue` composite the completed window uniformly.
enum FloralMDWebSystemCommand: Equatable {
    case toggleFullScreen
    case hideApplication
    case hideOtherApplications

    static func resolve(
        key: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> FloralMDWebSystemCommand? {
        let relevantModifiers = modifiers.intersection([.command, .control, .option, .shift])
        switch (key?.lowercased(), relevantModifiers) {
        case ("f", [.command, .control]):
            return .toggleFullScreen
        case ("h", [.command]):
            return .hideApplication
        case ("h", [.command, .option]):
            return .hideOtherApplications
        default:
            return nil
        }
    }
}

class FloralMDSystemCommandWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let command = FloralMDWebSystemCommand.resolve(
                key: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
              ) else {
            return super.performKeyEquivalent(with: event)
        }

        switch command {
        case .toggleFullScreen:
            guard let window else { return super.performKeyEquivalent(with: event) }
            window.toggleFullScreen(nil)
        case .hideApplication:
            NSApplication.shared.hide(nil)
        case .hideOtherApplications:
            NSApplication.shared.hideOtherApplications(nil)
        }
        return true
    }
}

class TransparentMarkdownWebView: FloralMDSystemCommandWebView {
    override var isOpaque: Bool { false }
}

class MarkdownMagnifyingWebView: TransparentMarkdownWebView {
    var viewportZoomDidChange: ((Double, MarkdownViewportZoomInteractionPhase) -> Void)?

    private var gestureScale: Double?
    private var gestureAnchorPoint: CGPoint?
    private var isCapturingGestureAnchor = false
    private var gestureEndedWhileCapturing = false
    private var anchorRestoreGeneration = 0

    override func magnify(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else {
            super.magnify(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if gestureScale == nil {
            gestureScale = MarkdownViewportZoom.clamped(Double(pageZoom))
            gestureAnchorPoint = point
            captureGestureAnchor(at: point)
        }

        let factor = max(0.01, 1 + Double(event.magnification))
        gestureScale = MarkdownViewportZoom.clamped((gestureScale ?? Double(pageZoom)) * factor)

        let ended = event.phase == .ended || event.phase == .cancelled
        if isCapturingGestureAnchor {
            gestureEndedWhileCapturing = gestureEndedWhileCapturing || ended
        } else {
            applyPendingGestureScale(ended: ended)
        }
    }

    func applyViewportZoom(_ scale: Double) {
        let requested = MarkdownViewportZoom.clamped(scale)
        guard abs(Double(pageZoom) - requested) > 0.000_1 else { return }
        anchorRestoreGeneration += 1
        pageZoom = CGFloat(requested)
    }

    private func captureGestureAnchor(at point: CGPoint) {
        isCapturingGestureAnchor = true
        let cssPoint = MarkdownWebViewCoordinateSpace.cssViewportPoint(
            fromViewPoint: point,
            bounds: bounds,
            isFlipped: isFlipped,
            pageZoom: Double(pageZoom)
        )
        let script = """
        (() => {
            const x = \(cssPoint.x);
            const y = \(cssPoint.y);
            const element = document.elementFromPoint(x, y);
            if (!element) {
                window.__floralmdViewportZoomAnchor = null;
                return false;
            }
            const rect = element.getBoundingClientRect();
            window.__floralmdViewportZoomAnchor = {
                element,
                ratioX: rect.width > 0 ? (x - rect.left) / rect.width : 0,
                ratioY: rect.height > 0 ? (y - rect.top) / rect.height : 0
            };
            return true;
        })()
        """
        evaluateJavaScript(script) { [weak self] _, _ in
            guard let self else { return }
            self.isCapturingGestureAnchor = false
            let ended = self.gestureEndedWhileCapturing
            self.gestureEndedWhileCapturing = false
            self.applyPendingGestureScale(ended: ended)
        }
    }

    private func applyPendingGestureScale(ended: Bool) {
        guard let scale = gestureScale else { return }
        applyPageZoom(
            scale,
            anchoredAt: gestureAnchorPoint,
            clearAnchorAfterRestore: ended
        )
        viewportZoomDidChange?(
            scale,
            ended ? .ended : .changed
        )
        if ended {
            gestureScale = nil
            gestureAnchorPoint = nil
        }
    }

    private func applyPageZoom(
        _ scale: Double,
        anchoredAt point: CGPoint?,
        clearAnchorAfterRestore: Bool
    ) {
        pageZoom = CGFloat(scale)
        guard let point else { return }
        anchorRestoreGeneration += 1
        let generation = anchorRestoreGeneration
        let cssPoint = MarkdownWebViewCoordinateSpace.cssViewportPoint(
            fromViewPoint: point,
            bounds: bounds,
            isFlipped: isFlipped,
            pageZoom: scale
        )
        let script = """
        (() => {
            const anchor = window.__floralmdViewportZoomAnchor;
            if (!anchor || !anchor.element?.isConnected) {
                \(clearAnchorAfterRestore ? "window.__floralmdViewportZoomAnchor = null;" : "")
                return false;
            }
            const rect = anchor.element.getBoundingClientRect();
            const anchoredX = rect.left + rect.width * anchor.ratioX;
            const anchoredY = rect.top + rect.height * anchor.ratioY;
            window.scrollBy(anchoredX - \(cssPoint.x), anchoredY - \(cssPoint.y));
            \(clearAnchorAfterRestore ? "window.__floralmdViewportZoomAnchor = null;" : "")
            return true;
        })()
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, self.anchorRestoreGeneration == generation else { return }
            self.evaluateJavaScript(script) { _, _ in }
        }
    }
}

final class EditorResourceDropWebView: MarkdownMagnifyingWebView {
    var canAcceptResourceURLs: (([URL]) -> Bool)?
    var performResourceDrop: (([URL], CGPoint) -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimExclusiveResourceDropDestination()
    }

    override func layout() {
        super.layout()
        claimExclusiveResourceDropDestination()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = resourceURLs(from: sender)
        return !urls.isEmpty && canAcceptResourceURLs?(urls) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = resourceURLs(from: sender)
        guard !urls.isEmpty, canAcceptResourceURLs?(urls) == true else {
            return false
        }
        let location = viewLocation(forDraggingLocation: sender.draggingLocation)
        return handleResourceDrop(urls, at: location)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // The custom resource transaction is the only file-drop consumer.
        // Calling WKWebView's implementation can insert a second URL/name.
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Do not forward rejected file drags to WKContentView.
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let urls = resourceURLs(from: sender)
        guard !urls.isEmpty, canAcceptResourceURLs?(urls) == true else { return [] }
        return .copy
    }

    private func resourceURLs(from sender: NSDraggingInfo) -> [URL] {
        EditorResourceDropPayload.resourceURLs(from: sender.draggingPasteboard)
    }

    /// `NSDraggingInfo.draggingLocation` is expressed in the destination
    /// window's base coordinates, not this view's local coordinates.
    func viewLocation(forDraggingLocation location: CGPoint) -> CGPoint {
        convert(location, from: nil)
    }

    func handleResourceDrop(_ urls: [URL], at location: CGPoint) -> Bool {
        performResourceDrop?(urls, location) == true
    }

    func claimExclusiveResourceDropDestination() {
        if !registeredDraggedTypes.contains(.fileURL) {
            registerForDraggedTypes([.fileURL])
        }
        for descendant in subviews.flatMap(\NSView.selfAndDescendants) {
            if !descendant.registeredDraggedTypes.isEmpty {
                descendant.unregisterDraggedTypes()
            }
        }
    }
}

enum EditorResourceDropPayload {
    static func hasFileURLRepresentation(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.pasteboardItems?.contains {
            $0.types.contains(.fileURL)
        } == true
    }

    static func resourceURLs(from pasteboard: NSPasteboard) -> [URL] {
        var seen = Set<URL>()
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(.fileURL),
                  let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }
}

private extension NSView {
    var selfAndDescendants: [NSView] {
        [self] + subviews.flatMap(\NSView.selfAndDescendants)
    }
}

struct CodeMirrorEditorView: NSViewControllerRepresentable {
    @Binding var markdown: String
    var contentWidth = MarkdownContentWidthLayout.defaultPreferredWidth
    var zoomScale = MarkdownViewportZoom.defaultScale
    let documentURL: URL?
    let resourceContext: MarkdownLocalResourceContext?
    let navigation: OutlineNavigation?
    let typography: MarkdownTypography
    var typewriterModeEnabled = false
    var commandTarget: MarkdownEditorCommandTarget?
    let userDidEdit: () -> Void
    let imagePasteHandler: ((MarkdownImagePasteRequest) throws -> String)?
    let imageOpenHandler: ((MarkdownImageOpenRequest, URL) -> Void)?
    let resourceDropHandler: (([URL]) throws -> String)?
    let linkNavigationHandler: ((String) throws -> Bool)?
    var zoomDidChange: (Double, MarkdownViewportZoomInteractionPhase) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            markdown: $markdown,
            documentURL: documentURL,
            resourceContext: resourceContext,
            typography: typography,
            commandTarget: commandTarget,
            userDidEdit: userDidEdit,
            imagePasteHandler: imagePasteHandler,
            imageOpenHandler: imageOpenHandler,
            resourceDropHandler: resourceDropHandler,
            linkNavigationHandler: linkNavigationHandler
        )
    }

    func makeNSViewController(context: Context) -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.documentURL = documentURL
        controller.setResourceContext(resourceContext)
        context.coordinator.connect(to: controller)
        controller.viewportZoomDidChange = zoomDidChange
        controller.applyPageZoom(zoomScale)
        controller.load(
            markdown: markdown,
            typography: typography,
            contentWidth: contentWidth,
            typewriterModeEnabled: typewriterModeEnabled
        )
        return controller
    }

    func updateNSViewController(
        _ controller: CodeMirrorEditorViewController,
        context: Context
    ) {
        context.coordinator.markdown = $markdown
        context.coordinator.userDidEdit = userDidEdit
        context.coordinator.imagePasteHandler = imagePasteHandler
        context.coordinator.imageOpenHandler = imageOpenHandler
        context.coordinator.resourceDropHandler = resourceDropHandler
        context.coordinator.linkNavigationHandler = linkNavigationHandler
        context.coordinator.commandTarget = commandTarget
        controller.viewportZoomDidChange = zoomDidChange
        context.coordinator.applyTypography(typography, to: controller)
        controller.applyContentWidth(contentWidth)
        controller.applyPageZoom(zoomScale)
        controller.applyTypewriterMode(typewriterModeEnabled)
        context.coordinator.applyExternalChange(
            markdown,
            documentURL: documentURL,
            resourceContext: resourceContext,
            to: controller
        )
        context.coordinator.applyNavigation(navigation, to: controller)
    }

    static func dismantleNSViewController(
        _ controller: CodeMirrorEditorViewController,
        coordinator: Coordinator
    ) {
        controller.fetchMarkdown { markdown in
            guard let markdown else { return }
            coordinator.acceptEditorChange(markdown)
        }
        let commandTarget = coordinator.commandTarget
        commandTarget?.disconnect(from: controller)
    }

    @MainActor
    final class Coordinator {
        var markdown: Binding<String>
        var userDidEdit: () -> Void
        var imagePasteHandler: ((MarkdownImagePasteRequest) throws -> String)?
        var imageOpenHandler: ((MarkdownImageOpenRequest, URL) -> Void)?
        var resourceDropHandler: (([URL]) throws -> String)?
        var linkNavigationHandler: ((String) throws -> Bool)?
        var commandTarget: MarkdownEditorCommandTarget?
        private var lastEditorMarkdown: String
        private var lastDocumentURL: URL?
        private var lastResourceContext: MarkdownLocalResourceContext?
        private var lastTypography: MarkdownTypography
        private var lastNavigationID: UUID?

        init(
            markdown: Binding<String>,
            documentURL: URL?,
            resourceContext: MarkdownLocalResourceContext?,
            typography: MarkdownTypography,
            commandTarget: MarkdownEditorCommandTarget?,
            userDidEdit: @escaping () -> Void,
            imagePasteHandler: ((MarkdownImagePasteRequest) throws -> String)?,
            imageOpenHandler: ((MarkdownImageOpenRequest, URL) -> Void)?,
            resourceDropHandler: (([URL]) throws -> String)?,
            linkNavigationHandler: ((String) throws -> Bool)?
        ) {
            self.markdown = markdown
            self.userDidEdit = userDidEdit
            self.imagePasteHandler = imagePasteHandler
            self.imageOpenHandler = imageOpenHandler
            self.resourceDropHandler = resourceDropHandler
            self.linkNavigationHandler = linkNavigationHandler
            self.commandTarget = commandTarget
            lastEditorMarkdown = markdown.wrappedValue
            lastDocumentURL = documentURL
            lastResourceContext = resourceContext
            lastTypography = typography
        }

        func connect(to controller: CodeMirrorEditorViewController) {
            let commandTarget = self.commandTarget
            commandTarget?.connect(to: controller)
            controller.contentDidChange = { [weak self] markdown in
                self?.userDidEdit()
                self?.acceptEditorChange(markdown)
            }
            controller.imagePasteRequested = { [weak self] request in
                guard let handler = self?.imagePasteHandler else {
                    throw MarkdownImagePasteRequest.Error.handlerUnavailable
                }
                return try handler(request)
            }
            controller.imageOpenRequested = { [weak self] request, fileURL in
                self?.imageOpenHandler?(request, fileURL)
            }
            controller.resourceDropRequested = { [weak self] urls in
                guard let handler = self?.resourceDropHandler else {
                    throw MarkdownResourceReferenceError.markdownDocumentRequired
                }
                return try handler(urls)
            }
            controller.linkNavigationRequested = { [weak self] destination in
                guard let handler = self?.linkNavigationHandler else { return false }
                return try handler(destination)
            }
        }

        func acceptEditorChange(_ newMarkdown: String) {
            lastEditorMarkdown = newMarkdown
            if markdown.wrappedValue != newMarkdown {
                markdown.wrappedValue = newMarkdown
            }
        }

        func applyExternalChange(
            _ newMarkdown: String,
            documentURL: URL?,
            resourceContext: MarkdownLocalResourceContext?,
            to controller: CodeMirrorEditorViewController
        ) {
            if documentURL != lastDocumentURL {
                lastDocumentURL = documentURL
                controller.documentURL = documentURL
            }

            let resourceContextDidChange = resourceContext != lastResourceContext
            if resourceContextDidChange {
                lastResourceContext = resourceContext
                controller.setResourceContext(resourceContext)
            }

            // The Untitled -> first-save transition changes only the URL.
            // Reloading the same source destroys and recreates CodeMirror,
            // which resets its selection and makes the insertion point jump.
            guard resourceContextDidChange
                    || Self.shouldReloadEditor(
                        newMarkdown: newMarkdown,
                        lastEditorMarkdown: lastEditorMarkdown
                    ) else { return }

            lastEditorMarkdown = newMarkdown
            if resourceContextDidChange {
                controller.load(markdown: newMarkdown)
            } else {
                controller.replaceExternally(markdown: newMarkdown)
            }
        }

        static func shouldReloadEditor(
            newMarkdown: String,
            lastEditorMarkdown: String
        ) -> Bool {
            newMarkdown != lastEditorMarkdown
        }

        func applyTypography(
            _ typography: MarkdownTypography,
            to controller: CodeMirrorEditorViewController
        ) {
            guard typography != lastTypography else { return }
            lastTypography = typography
            controller.applyTypography(typography)
        }

        func applyNavigation(
            _ navigation: OutlineNavigation?,
            to controller: CodeMirrorEditorViewController
        ) {
            guard let navigation, navigation.requestID != lastNavigationID else { return }
            lastNavigationID = navigation.requestID
            controller.navigate(
                toSourceOffset: navigation.heading.sourceOffset,
                sourceLine: navigation.heading.sourceLine
            )
        }
    }
}

struct MarkdownPreviewWebView: NSViewRepresentable {
    let markdown: String
    var contentWidth = MarkdownContentWidthLayout.defaultPreferredWidth
    var zoomScale = MarkdownViewportZoom.defaultScale
    let documentURL: URL?
    let resourceContext: MarkdownLocalResourceContext?
    let navigation: OutlineNavigation?
    let typography: MarkdownTypography
    let linkNavigationHandler: ((String) throws -> Bool)?
    var zoomDidChange: (Double, MarkdownViewportZoomInteractionPhase) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkNavigationHandler: linkNavigationHandler)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.makeWebViewConfiguration(
            resourceHandler: context.coordinator.resourceHandler,
            linkMessageHandler: context.coordinator
        )
        let webView = MarkdownMagnifyingWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.viewportZoomDidChange = zoomDidChange
        webView.applyViewportZoom(zoomScale)
        context.coordinator.display(
            markdown: markdown,
            documentURL: documentURL,
            resourceContext: resourceContext,
            typography: typography,
            in: webView
        )
        context.coordinator.applyContentWidth(contentWidth, in: webView)
        context.coordinator.applyNavigation(navigation, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkNavigationHandler = linkNavigationHandler
        if let webView = webView as? MarkdownMagnifyingWebView {
            webView.viewportZoomDidChange = zoomDidChange
            webView.applyViewportZoom(zoomScale)
        }
        context.coordinator.display(
            markdown: markdown,
            documentURL: documentURL,
            resourceContext: resourceContext,
            typography: typography,
            in: webView
        )
        context.coordinator.applyContentWidth(contentWidth, in: webView)
        context.coordinator.applyNavigation(navigation, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        fileprivate static let linkBridgeName = "slateMemoPreviewLink"
        let resourceHandler = MarkdownLocalResourceSchemeHandler()
        var linkNavigationHandler: ((String) throws -> Bool)?
        private var displayedMarkdown: String?
        private var displayedDocumentURL: URL?
        private var displayedResourceContext: MarkdownLocalResourceContext?
        private var displayedTypography: MarkdownTypography?
        private var renderGeneration = 0
        private var pageIsReady = false
        private var lastNavigationID: UUID?
        private var pendingHeadingIndex: Int?
        private var displayedBaseURL: URL?
        private var requestedContentWidth = MarkdownContentWidthLayout.defaultPreferredWidth
        private lazy var contentWidthScheduler = LatestFrameValueScheduler<(Double, WKWebView)> {
            [weak self] request in
            self?.applyContentWidthToPage(request.0, in: request.1)
        }

        init(linkNavigationHandler: ((String) throws -> Bool)?) {
            self.linkNavigationHandler = linkNavigationHandler
        }

        func display(
            markdown: String,
            documentURL: URL?,
            resourceContext: MarkdownLocalResourceContext?,
            typography: MarkdownTypography,
            in webView: WKWebView
        ) {
            guard displayedMarkdown != markdown
                    || displayedDocumentURL != documentURL
                    || displayedResourceContext != resourceContext
                    || displayedTypography != typography else {
                return
            }
            displayedMarkdown = markdown
            displayedDocumentURL = documentURL
            displayedResourceContext = resourceContext
            displayedTypography = typography
            renderGeneration += 1
            pageIsReady = false
            contentWidthScheduler.cancel()
            let generation = renderGeneration
            let baseURL = resourceHandler.register(resourceContext)
            displayedBaseURL = baseURL
            let baseHref = baseURL?.absoluteString

            Task.detached(priority: .userInitiated) {
                let html = MarkdownHTML.makeHTML(
                    from: markdown,
                    allowsScroll: true,
                    assetBaseHref: baseHref,
                    typography: typography
                )
                await MainActor.run { [weak self, weak webView] in
                    guard let self,
                          let webView,
                          self.renderGeneration == generation else { return }
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
            }
        }

        func applyNavigation(_ navigation: OutlineNavigation?, in webView: WKWebView) {
            guard let navigation, navigation.requestID != lastNavigationID else { return }
            lastNavigationID = navigation.requestID
            pendingHeadingIndex = navigation.heading.id
            performPendingNavigationIfPossible(in: webView)
        }

        func applyContentWidth(_ width: Double, in webView: WKWebView) {
            let sanitizedWidth = width.isFinite ? max(0, width) : 0
            guard sanitizedWidth != requestedContentWidth else { return }
            requestedContentWidth = sanitizedWidth
            scheduleContentWidthApplication(in: webView)
        }

        private func scheduleContentWidthApplication(in webView: WKWebView) {
            guard pageIsReady else { return }
            contentWidthScheduler.submit((requestedContentWidth, webView))
        }

        private func applyContentWidthToPage(_ width: Double, in webView: WKWebView) {
            let script = """
            (() => {
                document.documentElement.style.setProperty(
                    '--floralmd-content-width',
                    \(MarkdownHTML.javaScriptStringLiteral("\(width)px"))
                );
                window.dispatchEvent(new Event('floralmd-layout-change'));
            })()
            """
            webView.evaluateJavaScript(script) { _, _ in }
        }

        private func performPendingNavigationIfPossible(in webView: WKWebView) {
            guard pageIsReady, let index = pendingHeadingIndex else { return }
            pendingHeadingIndex = nil
            webView.evaluateJavaScript(
                "document.getElementById('md-heading-\(index)')?.scrollIntoView({behavior:'smooth',block:'start'})"
            ) { [weak self] _, error in
                if error != nil {
                    self?.pendingHeadingIndex = index
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageIsReady = true
            scheduleContentWidthApplication(in: webView)
            performPendingNavigationIfPossible(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            do {
                let destination: String
                let fallbackURL: URL?
                if isCurrentDocumentFragment(url) {
                    destination = "#" + (Self.percentEncodedFragment(of: url) ?? "")
                    fallbackURL = nil
                } else if url.scheme?.lowercased() == MarkdownLocalResourceSchemeHandler.scheme {
                    let localURL = try resourceHandler.resolvedLinkURL(for: url)
                    destination = Self.destination(
                        for: localURL,
                        fragment: Self.percentEncodedFragment(of: url)
                    )
                    fallbackURL = localURL
                } else {
                    destination = url.absoluteString
                    fallbackURL = url
                }

                if let linkNavigationHandler,
                   try linkNavigationHandler(destination) {
                    decisionHandler(.cancel)
                } else if let fallbackURL,
                          fallbackURL.isFileURL
                            || ["http", "https", "mailto"].contains(
                                fallbackURL.scheme?.lowercased() ?? ""
                            ) {
                    NSWorkspace.shared.open(fallbackURL)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            } catch {
                NSApplication.shared.presentError(error)
                decisionHandler(.cancel)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.linkBridgeName,
                  let destination = message.body as? String,
                  !destination.isEmpty else { return }
            do {
                if let linkNavigationHandler,
                   try linkNavigationHandler(destination) {
                    return
                }
                try preserveExistingBehavior(for: destination, in: message.webView)
            } catch {
                NSApplication.shared.presentError(error)
            }
        }

        private func preserveExistingBehavior(for destination: String, in webView: WKWebView?) throws {
            if destination.hasPrefix("#") {
                let literal = try JSONSerialization.data(
                    withJSONObject: destination,
                    options: [.fragmentsAllowed]
                )
                guard let json = String(data: literal, encoding: .utf8) else { return }
                webView?.evaluateJavaScript("window.location.hash = \(json)")
                return
            }
            guard let baseURL = displayedBaseURL,
                  let resolved = URL(string: destination, relativeTo: baseURL)?.absoluteURL else {
                return
            }
            let localURL = resolved.scheme?.lowercased() == MarkdownLocalResourceSchemeHandler.scheme
                ? try resourceHandler.resolvedLinkURL(for: resolved)
                : resolved
            if localURL.isFileURL
                || ["http", "https", "mailto"].contains(localURL.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(localURL)
            }
        }

        private func isCurrentDocumentFragment(_ url: URL) -> Bool {
            guard url.fragment != nil,
                  let baseURL = displayedBaseURL,
                  var candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return false
            }
            candidate.fragment = nil
            base.fragment = nil
            return candidate == base
        }

        private static func destination(for url: URL, fragment: String?) -> String {
            guard let fragment else { return url.absoluteString }
            return url.absoluteString + "#" + fragment
        }

        private static func percentEncodedFragment(of url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        }
    }

    static func makeWebViewConfiguration(
        resourceHandler: MarkdownLocalResourceSchemeHandler,
        linkMessageHandler: WKScriptMessageHandler? = nil
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        MarkdownLocalResourceWebViewConfiguration.install(resourceHandler, on: configuration)
        if let linkMessageHandler {
            configuration.userContentController.add(
                linkMessageHandler,
                name: Coordinator.linkBridgeName
            )
            configuration.userContentController.addUserScript(WKUserScript(
                source: """
                document.addEventListener('click', function (event) {
                  if (event.button !== 0) return;
                  const anchor = event.target && event.target.closest
                    ? event.target.closest('a[data-md-href]') : null;
                  if (!anchor) return;
                  const destination = anchor.getAttribute('data-md-href');
                  if (!destination) return;
                  event.preventDefault();
                  window.webkit.messageHandlers.slateMemoPreviewLink.postMessage(destination);
                }, true);
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        return configuration
    }
}
