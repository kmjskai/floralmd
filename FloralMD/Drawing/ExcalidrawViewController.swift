import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ExcalidrawViewController: NSViewController, WKNavigationDelegate {
    private struct PendingSceneLoad {
        let argument: String
        let requestID: UUID
    }

    static let allowedNavigationSchemes = Set([
        ExcalidrawResourceSchemeHandler.scheme,
        "about",
        "data",
        "blob"
    ])

    static func navigationPolicy(for url: URL?) -> WKNavigationActionPolicy {
        guard let scheme = url?.scheme?.lowercased(), allowedNavigationSchemes.contains(scheme) else {
            return .cancel
        }
        return .allow
    }

    var onReady: (() -> Void)?
    var onClose: (() -> Void)? { didSet { bridge.onClose = onClose } }
    var onComplete: ((Result<DrawingExportPayload, Error>) -> Void)? {
        didSet { bridge.onComplete = onComplete }
    }
    var onLoaded: ((UUID?) -> Void)?
    var onError: ((Error) -> Void)?
    var drawingName = DrawingWindowTitle.untitled

    private let bridge = ExcalidrawBridge()
    private let resourceHandler = ExcalidrawResourceSchemeHandler()
    private(set) var webView: WKWebView!
    private var theme = "light"
    private var hasLoadedPage = false
    private var isDrawingReady = false
    private var pendingCompletionRequests: [Bool] = []
    private var pendingSceneLoads: [PendingSceneLoad] = []
    private var pendingLoadRequestIDs: Set<UUID> = []
    private var pendingOriginalImageRequest: DrawingOriginalImageRequest?

    override func loadView() {
        bridge.onReady = { [weak self] in
            guard let self else { return }
            isDrawingReady = true
            let sceneLoads = pendingSceneLoads
            pendingSceneLoads.removeAll()
            if !sceneLoads.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    sceneLoads.forEach { self.dispatchLoad($0) }
                }
            }
            drainPendingCompletionRequestsIfPossible()
            onReady?()
        }
        bridge.onLoaded = { [weak self] in
            guard let self else { return }
            if pendingLoadRequestIDs.isEmpty {
                onLoaded?(nil)
                drainPendingCompletionRequestsIfPossible()
            }
        }
        bridge.onLoadCompleted = { [weak self] requestID in
            guard let self, pendingLoadRequestIDs.remove(requestID) != nil else { return }
            onLoaded?(requestID)
            drainPendingCompletionRequestsIfPossible()
        }
        bridge.onError = { [weak self] error in
            guard let self else { return }
            pendingSceneLoads.removeAll()
            pendingLoadRequestIDs.removeAll()
            onError?(error)
        }
        bridge.onImageContext = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let request):
                presentOriginalImageMenu(for: request)
            case .failure(let error):
                onError?(error)
            }
        }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            resourceHandler,
            forURLScheme: ExcalidrawResourceSchemeHandler.scheme
        )
        ExcalidrawBridge.messageNames.forEach {
            configuration.userContentController.add(bridge, name: $0)
        }
        configuration.websiteDataStore = .nonPersistent()

        let webView = FloralMDSystemCommandWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        view = webView
        loadDrawingPage()
    }

    func apply(colorScheme: NSAppearance.Name) {
        let nextTheme = colorScheme == .darkAqua ? "dark" : "light"
        guard nextTheme != theme else { return }
        theme = nextTheme
        guard hasLoadedPage else { return }
        webView.evaluateJavaScript("window.__slateMemoSetTheme?.(\"\(nextTheme)\")") { _, _ in }
    }

    func requestCompletion(includeSVG: Bool = true) {
        guard isDrawingReady,
              pendingSceneLoads.isEmpty,
              pendingLoadRequestIDs.isEmpty
        else {
            pendingCompletionRequests.append(includeSVG)
            return
        }
        dispatchCompletion(includeSVG)
    }

    private func drainPendingCompletionRequestsIfPossible() {
        guard isDrawingReady,
              pendingSceneLoads.isEmpty,
              pendingLoadRequestIDs.isEmpty
        else { return }
        let requests = pendingCompletionRequests
        pendingCompletionRequests.removeAll()
        requests.forEach { dispatchCompletion($0) }
    }

    private func dispatchCompletion(_ includeSVG: Bool, retryCount: Int = 0) {
        bridge.expectCompletion(requiresSVG: includeSVG)
        webView.evaluateJavaScript(
            """
            (() => {
                const complete = window.__slateMemoComplete;
                if (typeof complete !== "function") { return false; }
                complete({includeSVG: \(includeSVG)});
                return true;
            })()
            """
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                bridge.cancelExpectedCompletion()
                onComplete?(.failure(error))
                return
            }
            guard value as? Bool != true else { return }
            bridge.cancelExpectedCompletion()
            guard retryCount < 40 else {
                onComplete?(.failure(DrawingCompletionError.timedOut))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.dispatchCompletion(includeSVG, retryCount: retryCount + 1)
            }
        }
    }

    func load(sceneJSON: String, requestID: UUID = UUID()) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["sceneJSON": sceneJSON]),
              let argument = String(data: data, encoding: .utf8)
        else {
            onError?(DrawingScene.ValidationError.invalidJSON)
            return
        }
        pendingLoadRequestIDs.insert(requestID)
        let pendingLoad = PendingSceneLoad(argument: argument, requestID: requestID)
        guard isDrawingReady else {
            pendingSceneLoads.append(pendingLoad)
            return
        }
        dispatchLoad(pendingLoad)
    }

    private func dispatchLoad(_ pendingLoad: PendingSceneLoad, retryCount: Int = 0) {
        let script = """
        (() => {
            const loadScene = window.__slateMemoLoadScene;
            if (typeof loadScene !== "function") { return false; }
            loadScene(\(pendingLoad.argument));
            return true;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                pendingLoadRequestIDs.remove(pendingLoad.requestID)
                onError?(error)
                return
            }
            if value as? Bool == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self,
                          pendingLoadRequestIDs.remove(pendingLoad.requestID) != nil
                    else { return }
                    onLoaded?(pendingLoad.requestID)
                    drainPendingCompletionRequestsIfPossible()
                }
                return
            }
            guard retryCount < 40 else {
                pendingLoadRequestIDs.remove(pendingLoad.requestID)
                onError?(DrawingCompletionError.timedOut)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.dispatchLoad(pendingLoad, retryCount: retryCount + 1)
            }
        }
    }

    func resetScene() {
        webView.evaluateJavaScript("window.__slateMemoReset?.(); true") { [weak self] _, error in
            if let error { self?.onError?(error) }
        }
    }

    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(script) { value, _ in completion(value) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedPage = true
        webView.evaluateJavaScript("window.__slateMemoSetTheme?.(\"\(theme)\")") { _, _ in }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(Self.navigationPolicy(for: navigationAction.request.url))
    }

    private func loadDrawingPage() {
        webView.load(URLRequest(url: ExcalidrawResourceSchemeHandler.entryURL))
    }

    private func presentOriginalImageMenu(for request: DrawingOriginalImageRequest) {
        pendingOriginalImageRequest = request
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "导出原始图片…",
            action: #selector(exportOriginalImage(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        let point = NSPoint(
            x: min(max(request.clientX, 0), webView.bounds.width),
            y: min(max(webView.bounds.height - request.clientY, 0), webView.bounds.height)
        )
        menu.popUp(positioning: item, at: point, in: webView)
        pendingOriginalImageRequest = nil
    }

    @objc private func exportOriginalImage(_ sender: Any?) {
        guard let request = pendingOriginalImageRequest else { return }
        pendingOriginalImageRequest = nil
        do {
            _ = try DrawingOriginalImageExporter.export(
                request,
                drawingName: drawingName
            ) { defaultFileName, fileExtension in
                let panel = NSSavePanel()
                panel.title = "导出原始图片"
                panel.prompt = "导出"
                panel.nameFieldStringValue = defaultFileName
                if let type = UTType(filenameExtension: fileExtension) {
                    panel.allowedContentTypes = [type]
                }
                return panel.runModal() == .OK ? panel.url : nil
            }
        } catch {
            onError?(error)
        }
    }
}
