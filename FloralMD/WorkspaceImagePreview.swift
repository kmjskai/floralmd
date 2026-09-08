import AppKit
import Combine
import SwiftUI
import WebKit

enum WorkspaceImageZoom {
    static let minimumScale = 0.05
    static let maximumScale = 32.0
    static let buttonStep = 1.25

    static func clampedScale(_ value: Double) -> Double {
        min(max(value, minimumScale), maximumScale)
    }

    static func percentage(scale: Double) -> Int {
        Int((max(scale, 0.0001) * 100).rounded())
    }

    static func panDistance(delta: Double, hasPreciseDeltas: Bool) -> Double {
        hasPreciseDeltas ? delta : delta * 16
    }

    static func commandWheelFactor(deltaY: Double, hasPreciseDeltas: Bool) -> Double {
        let sensitivity = hasPreciseDeltas ? 0.012 : 0.12
        return exp(deltaY * sensitivity)
    }
}

struct WorkspaceVectorRedrawBudget: Equatable {
    static let minimumMemoryBudgetBytes = 192 * 1024 * 1024
    static let maximumMemoryBudgetBytes = 512 * 1024 * 1024
    static let physicalMemoryDivisor: UInt64 = 16
    static let estimatedPeakBytesPerPhysicalPixel = 8.0
    static let viewportDimensionMultiplier = 24.0
    static let maximumLayoutDimension = 16_384.0

    let memoryBudgetBytes: Int

    static var current: Self {
        let proportional = ProcessInfo.processInfo.physicalMemory / physicalMemoryDivisor
        let bounded = min(
            UInt64(maximumMemoryBudgetBytes),
            max(UInt64(minimumMemoryBudgetBytes), proportional)
        )
        return Self(memoryBudgetBytes: Int(bounded))
    }
}

struct WorkspaceImagePreview: View {
    let url: URL
    let revealInFinder: (() -> Void)?
    let pinningMode: WindowPinningMode?
    let togglePinning: (() -> Void)?

    @StateObject private var controller: WorkspaceImagePreviewController

    @MainActor
    init(
        url: URL,
        controller: WorkspaceImagePreviewController? = nil,
        revealInFinder: (() -> Void)? = nil,
        pinningMode: WindowPinningMode? = nil,
        togglePinning: (() -> Void)? = nil
    ) {
        self.url = url
        self.revealInFinder = revealInFinder
        self.pinningMode = pinningMode
        self.togglePinning = togglePinning
        _controller = StateObject(
            wrappedValue: controller ?? WorkspaceImagePreviewController()
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WorkspaceImageWebView(url: url, controller: controller)

            HStack(spacing: 5) {
                previewButton("minus", help: "缩小") {
                    controller.zoom(by: 1 / WorkspaceImageZoom.buttonStep)
                }

                Text("\(controller.zoomPercentage)%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .frame(minWidth: 48)
                    .accessibilityLabel("当前缩放 \(controller.zoomPercentage)%")

                previewButton("plus", help: "放大") {
                    controller.zoom(by: WorkspaceImageZoom.buttonStep)
                }

                Divider()
                    .frame(height: 16)

                Button("适应") {
                    controller.fit()
                }
                .buttonStyle(.borderless)
                .help("适应窗口")

                Button("1:1") {
                    controller.actualSize()
                }
                .buttonStyle(.borderless)
                .help("按图片原始尺寸显示")

                if let revealInFinder {
                    Divider()
                        .frame(height: 16)

                    previewButton("folder", help: "在 Finder 中显示", action: revealInFinder)
                        .accessibilityLabel("在 Finder 中显示")
                }

                if let pinningMode, let togglePinning {
                    Divider()
                        .frame(height: 16)

                    previewButton(
                        pinningMode.symbolName,
                        help: pinningMode.actionTitle,
                        action: togglePinning
                    )
                    .accessibilityLabel(pinningMode.actionTitle)
                    .accessibilityValue(pinningMode == .currentSpace ? "已置顶" : "未置顶")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
            }
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func previewButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

@MainActor
final class WorkspaceImagePreviewController: ObservableObject {
    @Published private(set) var zoomPercentage = 100

    private weak var webView: WorkspaceZoomingImageWebView?
    var isWebViewAttached: Bool { webView != nil }

    func attach(_ webView: WorkspaceZoomingImageWebView?) {
        self.webView = webView
    }

    func prepareForNewResource() {
        zoomPercentage = 100
    }

    func updateScale(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        zoomPercentage = WorkspaceImageZoom.percentage(scale: value)
    }

    func zoom(by factor: Double) {
        webView?.zoom(by: factor)
    }

    func fit() {
        webView?.performViewerCommand("fit")
    }

    func actualSize() {
        webView?.performViewerCommand("actualSize")
    }
}

private struct WorkspaceImageWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var controller: WorkspaceImagePreviewController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WorkspaceZoomingImageWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.resourceHandler,
            forURLScheme: WorkspaceImageResourceSchemeHandler.scheme
        )
        configuration.userContentController.add(
            context.coordinator,
            name: WorkspaceImagePreviewHTML.messageHandlerName
        )

        let webView = WorkspaceZoomingImageWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        controller.attach(webView)
        context.coordinator.display(url: url, in: webView)
        return webView
    }

    func updateNSView(_ webView: WorkspaceZoomingImageWebView, context: Context) {
        context.coordinator.controller = controller
        controller.attach(webView)
        context.coordinator.display(url: url, in: webView)
    }

    static func dismantleNSView(
        _ webView: WorkspaceZoomingImageWebView,
        coordinator: Coordinator
    ) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WorkspaceImagePreviewHTML.messageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.resourceHandler.removeAll()
        coordinator.controller.attach(nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var controller: WorkspaceImagePreviewController
        let resourceHandler = WorkspaceImageResourceSchemeHandler()
        private var presentedURL: URL?
        private var displayStates: [URL: WorkspaceImageDisplayState] = [:]
        private var pendingDisplayState: WorkspaceImageDisplayState?

        init(controller: WorkspaceImagePreviewController) {
            self.controller = controller
        }

        func display(url: URL, in webView: WorkspaceZoomingImageWebView) {
            let nextURL = url.standardizedFileURL
            guard presentedURL != nextURL else { return }

            presentedURL = nextURL
            pendingDisplayState = displayStates[nextURL]
            controller.prepareForNewResource()
            let resourceURL = resourceHandler.register(nextURL)
            let renderingMode = WorkspaceImageRenderingMode(fileURL: nextURL)
            webView.loadHTMLString(
                WorkspaceImagePreviewHTML.make(
                    resourceURL: resourceURL,
                    displayName: nextURL.lastPathComponent,
                    renderingMode: renderingMode
                ),
                baseURL: nil
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let webView = webView as? WorkspaceZoomingImageWebView else { return }
            guard let pendingDisplayState else { return }
            self.pendingDisplayState = nil
            webView.restore(pendingDisplayState)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WorkspaceImagePreviewHTML.messageHandlerName,
                  let body = message.body as? [String: Any],
                  body["event"] as? String == "state",
                  let scale = (body["scale"] as? NSNumber)?.doubleValue,
                  let offsetX = (body["offsetX"] as? NSNumber)?.doubleValue,
                  let offsetY = (body["offsetY"] as? NSNumber)?.doubleValue else {
                return
            }
            let state = WorkspaceImageDisplayState(
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY
            )
            if let presentedURL {
                displayStates[presentedURL] = state
            }
            controller.updateScale(scale)
        }
    }
}

struct WorkspaceImageResourceLoadFailure: Error, Equatable {
    enum Stage: String, Equatable {
        case missingRequestURL
        case unresolvedResource
        case dataRead
    }

    let stage: Stage
    let requestURL: URL?
    let fileURL: URL?
    let errorDomain: String
    let errorCode: Int

    var webKitError: NSError {
        NSError(
            domain: errorDomain,
            code: errorCode,
            userInfo: fileURL.map { [NSURLErrorKey: $0] } ?? [:]
        )
    }
}

struct WorkspaceImageResourcePayload: Equatable {
    let requestURL: URL
    let fileURL: URL
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

final class WorkspaceImageResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "floralmd-image"
    typealias DataReader = (URL) throws -> Data
    typealias DiagnosticHandler = (WorkspaceImageResourceLoadFailure) -> Void

    private let resourcesLock = NSLock()
    private var resources: [String: URL] = [:]
    private let dataReader: DataReader
    private let diagnosticHandler: DiagnosticHandler?

    init(
        dataReader: @escaping DataReader = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        },
        diagnosticHandler: DiagnosticHandler? = nil
    ) {
        self.dataReader = dataReader
        self.diagnosticHandler = diagnosticHandler
    }

    func register(_ fileURL: URL) -> URL {
        let identifier = UUID().uuidString.lowercased()
        resourcesLock.lock()
        resources[identifier] = fileURL.standardizedFileURL
        resourcesLock.unlock()
        return URL(string: "\(Self.scheme)://resource/\(identifier)")!
    }

    func resolvedFileURL(for requestURL: URL) -> URL? {
        guard requestURL.scheme == Self.scheme else { return nil }
        resourcesLock.lock()
        defer { resourcesLock.unlock() }
        return resources[requestURL.lastPathComponent]
    }

    func removeAll() {
        resourcesLock.lock()
        resources.removeAll()
        resourcesLock.unlock()
    }

    func loadResource(for requestURL: URL?) -> Result<WorkspaceImageResourcePayload, WorkspaceImageResourceLoadFailure> {
        guard let requestURL else {
            return fail(
                stage: .missingRequestURL,
                requestURL: nil,
                fileURL: nil,
                error: URLError(.badURL)
            )
        }
        guard let fileURL = resolvedFileURL(for: requestURL) else {
            return fail(
                stage: .unresolvedResource,
                requestURL: requestURL,
                fileURL: nil,
                error: URLError(.fileDoesNotExist)
            )
        }
        do {
            return .success(WorkspaceImageResourcePayload(
                requestURL: requestURL,
                fileURL: fileURL,
                data: try dataReader(fileURL),
                mimeType: Self.mimeType(for: fileURL.pathExtension),
                textEncodingName: fileURL.pathExtension.lowercased() == "svg" ? "utf-8" : nil
            ))
        } catch {
            return fail(
                stage: .dataRead,
                requestURL: requestURL,
                fileURL: fileURL,
                error: error
            )
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        switch loadResource(for: urlSchemeTask.request.url) {
        case .success(let payload):
            let response = URLResponse(
                url: payload.requestURL,
                mimeType: payload.mimeType,
                expectedContentLength: payload.data.count,
                textEncodingName: payload.textEncodingName
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(payload.data)
            urlSchemeTask.didFinish()
        case .failure(let failure):
            urlSchemeTask.didFailWithError(failure.webKitError)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(
        stage: WorkspaceImageResourceLoadFailure.Stage,
        requestURL: URL?,
        fileURL: URL?,
        error: Error
    ) -> Result<WorkspaceImageResourcePayload, WorkspaceImageResourceLoadFailure> {
        let nsError = error as NSError
        let failure = WorkspaceImageResourceLoadFailure(
            stage: stage,
            requestURL: requestURL,
            fileURL: fileURL,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
        diagnosticHandler?(failure)
        return .failure(failure)
    }

    static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }
}

fileprivate struct WorkspaceImageDisplayState {
    let scale: Double
    let offsetX: Double
    let offsetY: Double
}

enum WorkspaceImageRenderingMode: String {
    case raster
    case vector

    init(fileURL: URL) {
        self = fileURL.pathExtension.lowercased() == "svg" ? .vector : .raster
    }
}

@MainActor
final class WorkspaceZoomingImageWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 {
            zoom(
                by: WorkspaceImageZoom.commandWheelFactor(
                    deltaY: Double(event.scrollingDeltaY),
                    hasPreciseDeltas: event.hasPreciseScrollingDeltas
                ),
                centeredAt: convert(event.locationInWindow, from: nil)
            )
            return
        }

        pan(
            byX: WorkspaceImageZoom.panDistance(
                delta: Double(event.scrollingDeltaX),
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            ),
            y: WorkspaceImageZoom.panDistance(
                delta: Double(event.scrollingDeltaY),
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            )
        )
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(
            by: max(0.01, 1 + event.magnification),
            centeredAt: point
        )
    }

    func zoom(by factor: Double, centeredAt point: CGPoint? = nil) {
        let center = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        evaluateJavaScript(
            "window.slateImagePreview?.zoomBy(\(factor), \(center.x), \(bounds.height - center.y))"
        )
    }

    func pan(byX deltaX: Double, y deltaY: Double) {
        evaluateJavaScript(
            "window.slateImagePreview?.panBy(\(deltaX), \(deltaY))"
        )
    }

    fileprivate func restore(_ state: WorkspaceImageDisplayState) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "scale": state.scale,
            "offsetX": state.offsetX,
            "offsetY": state.offsetY
        ]), let json = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.slateImagePreview?.restore(\(json))")
    }

    func performViewerCommand(_ command: String) {
        evaluateJavaScript("window.slateImagePreview?.\(command)()")
    }
}

enum WorkspaceImagePreviewHTML {
    static let messageHandlerName = "workspaceImagePreview"

    static func make(
        resourceURL: URL,
        displayName: String,
        renderingMode: WorkspaceImageRenderingMode = .raster,
        vectorRedrawBudget: WorkspaceVectorRedrawBudget = .current
    ) -> String {
        let source = escapedAttribute(resourceURL.absoluteString)
        let alternativeText = escapedAttribute(displayName)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(WorkspaceImageResourceSchemeHandler.scheme): data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light dark; }
            html, body {
              width: 100%; height: 100%; margin: 0; overflow: hidden;
              background: transparent;
            }
            body {
              cursor: grab; touch-action: none;
              user-select: none; -webkit-user-select: none;
              -webkit-tap-highlight-color: transparent;
            }
            body.dragging { cursor: grabbing; }
            ::selection { background: transparent; }
            img {
              display: block; position: absolute; left: 0; top: 0;
              max-width: none; max-height: none;
              transform-origin: 0 0;
              user-select: none; -webkit-user-drag: none;
              pointer-events: none;
            }
            #error {
              display: none; position: absolute; inset: 0;
              place-items: center; color: #c0392b; font: 13px -apple-system;
            }
          </style>
        </head>
        <body data-rendering-mode="\(renderingMode.rawValue)">
          <img id="preview" src="\(source)" alt="\(alternativeText)">
          <p id="error">无法显示这张图片。</p>
          <script>
            const image = document.getElementById('preview');
            const error = document.getElementById('error');
            const redrawsVector = document.body.dataset.renderingMode === 'vector';
            const minimumScale = \(WorkspaceImageZoom.minimumScale);
            const maximumScale = \(WorkspaceImageZoom.maximumScale);
            const vectorMemoryBudgetBytes = \(vectorRedrawBudget.memoryBudgetBytes);
            const estimatedPeakBytesPerPhysicalPixel = \(WorkspaceVectorRedrawBudget.estimatedPeakBytesPerPhysicalPixel);
            const viewportDimensionMultiplier = \(WorkspaceVectorRedrawBudget.viewportDimensionMultiplier);
            const maximumVectorLayoutDimension = \(WorkspaceVectorRedrawBudget.maximumLayoutDimension);
            let intrinsicWidth = 0;
            let intrinsicHeight = 0;
            let scale = 1;
            let fitScale = 1;
            let offsetX = 0;
            let offsetY = 0;
            let pointer = null;
            let pendingRestore = null;
            let publishFrame = null;

            function clampScale(value) {
              return Math.min(maximumScale, Math.max(minimumScale, value));
            }
            function centerImage() {
              offsetX = (innerWidth - intrinsicWidth * scale) / 2;
              offsetY = (innerHeight - intrinsicHeight * scale) / 2;
            }
            function publishState() {
              if (publishFrame !== null) return;
              publishFrame = requestAnimationFrame(() => {
                publishFrame = null;
                window.webkit.messageHandlers.\(messageHandlerName).postMessage({
                  event: 'state', scale, offsetX, offsetY
                });
              });
            }
            function vectorPaintBudget(requestedScale) {
              const safeDPR = Math.max(1, Number(devicePixelRatio) || 1);
              const intrinsicArea = Math.max(1, intrinsicWidth * intrinsicHeight);
              const maximumAreaScale = Math.sqrt(
                vectorMemoryBudgetBytes
                  / estimatedPeakBytesPerPhysicalPixel
                  / (safeDPR * safeDPR)
                  / intrinsicArea
              );
              const longestIntrinsicSide = Math.max(intrinsicWidth, intrinsicHeight, 1);
              const viewportLimit = Math.max(innerWidth, innerHeight, 1)
                * viewportDimensionMultiplier;
              const dimensionLimit = Math.min(
                maximumVectorLayoutDimension,
                Math.max(
                  viewportLimit,
                  Math.min(longestIntrinsicSide, maximumVectorLayoutDimension)
                )
              );
              const maximumDimensionScale = dimensionLimit / longestIntrinsicSide;
              const paintScale = Math.max(
                0.01,
                Math.min(requestedScale, maximumAreaScale, maximumDimensionScale)
              );
              return {
                paintScale,
                compositeScale: requestedScale / paintScale,
                estimatedPeakBytes: intrinsicArea
                  * paintScale * paintScale
                  * safeDPR * safeDPR
                  * estimatedPeakBytesPerPhysicalPixel,
                memoryBudgetBytes: vectorMemoryBudgetBytes,
                devicePixelRatio: safeDPR,
                viewportLimit,
                maximumAreaScale,
                maximumDimensionScale
              };
            }
            function render() {
              if (redrawsVector) {
                const budget = vectorPaintBudget(scale);
                const paintScale = budget.paintScale;
                const compositeScale = budget.compositeScale;
                image.style.width = `${intrinsicWidth * paintScale}px`;
                image.style.height = `${intrinsicHeight * paintScale}px`;
                if (Math.abs(compositeScale - 1) < 0.000001) {
                  image.style.left = `${offsetX}px`;
                  image.style.top = `${offsetY}px`;
                  image.style.transform = 'none';
                } else {
                  image.style.left = '0px';
                  image.style.top = '0px';
                  image.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${compositeScale})`;
                }
              } else {
                image.style.left = '0px';
                image.style.top = '0px';
                image.style.width = `${intrinsicWidth}px`;
                image.style.height = `${intrinsicHeight}px`;
                image.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
              }
              publishState();
            }
            function calculateFitScale() {
              const horizontal = Math.max(1, innerWidth - 32) / intrinsicWidth;
              const vertical = Math.max(1, innerHeight - 32) / intrinsicHeight;
              return clampScale(Math.min(1, horizontal, vertical));
            }
            function setZoom(nextScale, anchorX = innerWidth / 2, anchorY = innerHeight / 2) {
              const oldScale = scale;
              nextScale = clampScale(nextScale);
              const imageX = (anchorX - offsetX) / oldScale;
              const imageY = (anchorY - offsetY) / oldScale;
              scale = nextScale;
              offsetX = anchorX - imageX * scale;
              offsetY = anchorY - imageY * scale;
              render();
            }
            function applyFit() {
              fitScale = calculateFitScale();
              scale = fitScale;
              centerImage();
              render();
            }
            function restore(state) {
              if (!image.complete || !image.naturalWidth) {
                pendingRestore = state;
                return;
              }
              scale = clampScale(Number(state.scale) || fitScale);
              offsetX = Number(state.offsetX) || 0;
              offsetY = Number(state.offsetY) || 0;
              render();
            }

            window.slateImagePreview = {
              zoomBy(factor, x, y) { setZoom(scale * factor, x, y); },
              panBy(deltaX, deltaY) {
                offsetX += deltaX; offsetY += deltaY; render();
              },
              fit() { applyFit(); },
              actualSize() { setZoom(1); },
              restore,
              plan(requestedScale) {
                const plannedScale = clampScale(Number(requestedScale) || fitScale);
                const budget = redrawsVector ? vectorPaintBudget(plannedScale) : null;
                const paintScale = budget?.paintScale ?? 1;
                const compositeScale = budget?.compositeScale ?? plannedScale;
                return {
                  naturalWidth: image.naturalWidth,
                  naturalHeight: image.naturalHeight,
                  offsetWidth: Math.round(intrinsicWidth * paintScale),
                  offsetHeight: Math.round(intrinsicHeight * paintScale),
                  rectWidth: intrinsicWidth * plannedScale,
                  rectHeight: intrinsicHeight * plannedScale,
                  transform: Math.abs(compositeScale - 1) < 0.000001 ? 'none' : 'planned-transform',
                  scale: plannedScale,
                  paintScale,
                  compositeScale,
                  estimatedPeakBytes: budget?.estimatedPeakBytes ?? 0,
                  memoryBudgetBytes: budget?.memoryBudgetBytes ?? 0,
                  devicePixelRatio: budget?.devicePixelRatio ?? Math.max(1, devicePixelRatio || 1),
                  viewportLimit: budget?.viewportLimit ?? 0,
                  maximumAreaScale: budget?.maximumAreaScale ?? 0,
                  maximumDimensionScale: budget?.maximumDimensionScale ?? 0
                };
              },
              metrics() {
                const rect = image.getBoundingClientRect();
                const budget = redrawsVector ? vectorPaintBudget(scale) : null;
                return {
                  naturalWidth: image.naturalWidth,
                  naturalHeight: image.naturalHeight,
                  offsetWidth: image.offsetWidth,
                  offsetHeight: image.offsetHeight,
                  rectWidth: rect.width,
                  rectHeight: rect.height,
                  transform: getComputedStyle(image).transform,
                  scale,
                  paintScale: budget?.paintScale ?? 1,
                  compositeScale: budget?.compositeScale ?? scale,
                  estimatedPeakBytes: budget?.estimatedPeakBytes ?? 0,
                  memoryBudgetBytes: budget?.memoryBudgetBytes ?? 0,
                  devicePixelRatio: budget?.devicePixelRatio ?? Math.max(1, devicePixelRatio || 1),
                  viewportLimit: budget?.viewportLimit ?? 0,
                  maximumAreaScale: budget?.maximumAreaScale ?? 0,
                  maximumDimensionScale: budget?.maximumDimensionScale ?? 0
                };
              }
            };

            image.addEventListener('load', () => {
              intrinsicWidth = image.naturalWidth;
              intrinsicHeight = image.naturalHeight;
              fitScale = calculateFitScale();
              if (pendingRestore) {
                const state = pendingRestore; pendingRestore = null; restore(state);
              } else {
                applyFit();
              }
            });
            image.addEventListener('error', () => {
              image.style.display = 'none'; error.style.display = 'grid';
            });
            addEventListener('pointerdown', event => {
              if (event.button !== 0) return;
              event.preventDefault();
              pointer = { id: event.pointerId, x: event.clientX, y: event.clientY };
              document.body.classList.add('dragging');
              document.body.setPointerCapture(event.pointerId);
            });
            addEventListener('pointermove', event => {
              if (!pointer || pointer.id !== event.pointerId) return;
              offsetX += event.clientX - pointer.x;
              offsetY += event.clientY - pointer.y;
              pointer.x = event.clientX; pointer.y = event.clientY;
              render();
            });
            function finishPointer(event) {
              if (!pointer || pointer.id !== event.pointerId) return;
              pointer = null; document.body.classList.remove('dragging');
            }
            addEventListener('pointerup', finishPointer);
            addEventListener('pointercancel', finishPointer);
            addEventListener('dblclick', event => {
              event.preventDefault();
              getSelection()?.removeAllRanges();
              Math.abs(scale - fitScale) < 0.001 ? setZoom(1) : applyFit();
            });
            addEventListener('resize', () => {
              const wasFit = Math.abs(scale - fitScale) < 0.001;
              fitScale = calculateFitScale();
              if (wasFit) applyFit(); else render();
            });
          </script>
        </body>
        </html>
        """
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
