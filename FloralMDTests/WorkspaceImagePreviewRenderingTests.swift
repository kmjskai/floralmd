import AppKit
import Foundation
import Testing
import WebKit

@testable import FloralMD

@Suite(.serialized)
struct WorkspaceImagePreviewRenderingTests {
    @Test @MainActor func svgUsesRealLayoutGrowthWhileRasterKeepsBitmapTransform() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let svgURL = directory.appendingPathComponent("vector.svg")
        try svg(
            width: "128",
            height: "128",
            viewBox: "0 0 128 128",
            embeddedPNGBase64: try makePNG(width: 1, height: 1).base64EncodedString()
        ).write(to: svgURL, atomically: true, encoding: .utf8)
        let pngURL = directory.appendingPathComponent("bitmap.png")
        try makePNG(width: 128, height: 128).write(to: pngURL)

        let harness = PreviewHarness(frame: CGRect(x: 0, y: 0, width: 512, height: 512))
        defer { harness.shutdown() }
        try await harness.load(fileURL: svgURL, renderingMode: .vector)

        for scale in [1.0, 3.4, 4.0, 8.0] {
            let metrics = try await harness.restoreAndMeasure(scale: scale)
            if scale == 1 {
                #expect(metrics.naturalWidth == 128)
                #expect(metrics.naturalHeight == 128)
            }
            #expect(abs(Double(metrics.offsetWidth) - 128 * scale) < 1)
            #expect(abs(Double(metrics.offsetHeight) - 128 * scale) < 1)
            #expect(abs(metrics.rectWidth - 128 * scale) < 0.02)
            #expect(abs(metrics.rectHeight - 128 * scale) < 0.02)
            #expect(metrics.transform == "none")
        }

        let vectorSnapshot = try await harness.snapshot()
        #expect(vectorSnapshot.size.width >= 512)
        #expect(vectorSnapshot.size.height >= 512)
        #expect(vectorSnapshot.tiffRepresentation?.isEmpty == false)

        try await harness.load(fileURL: pngURL, renderingMode: .raster)
        for scale in [1.0, 3.4, 4.0, 8.0] {
            let metrics = try await harness.restoreAndMeasure(scale: scale)
            #expect(metrics.naturalWidth == 128)
            #expect(metrics.naturalHeight == 128)
            #expect(metrics.offsetWidth == 128)
            #expect(metrics.offsetHeight == 128)
            #expect(abs(metrics.rectWidth - 128 * scale) < 0.01)
            #expect(abs(metrics.rectHeight - 128 * scale) < 0.01)
            if scale == 1 {
                #expect(metrics.transform == "matrix(1, 0, 0, 1, 0, 0)")
            } else {
                #expect(metrics.transform != "none")
            }
        }
    }

    @Test @MainActor func filteredSampleUsesFullLayoutAtEightHundredPercent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedSampleURL = URL(
            fileURLWithPath: "/Users/yingkai/Documents/FloralMD-draft/notes/Markdown 笔记的文表图表达模型/assets/images/文表图表达模型.svg"
        )
        let fileURL: URL
        if FileManager.default.fileExists(atPath: requestedSampleURL.path) {
            fileURL = requestedSampleURL
        } else {
            fileURL = directory.appendingPathComponent("filtered-sample.svg")
            try filteredSampleSVG.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let fullBudget = WorkspaceVectorRedrawBudget(
            memoryBudgetBytes: WorkspaceVectorRedrawBudget.maximumMemoryBudgetBytes
        )
        // Keep the pixel comparison below the known WKWebView snapshot-process ceiling while
        // preserving the sample's 5:3 aspect ratio and filtered card geometry. The original
        // 1200x720 asset above still exercises the full 9600x5760 layout at 800%.
        let pixelFixtureURL = directory.appendingPathComponent("filtered-pixel-fixture.svg")
        try compactFilteredSampleSVG.write(to: pixelFixtureURL, atomically: true, encoding: .utf8)
        let harness = PreviewHarness(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        defer { harness.shutdown() }
        try await harness.load(
            fileURL: pixelFixtureURL,
            renderingMode: .vector,
            vectorRedrawBudget: fullBudget
        )
        _ = try await harness.restoreAndMeasure(scale: 8, simulatedDPR: 1)

        let sharpSnapshot = try await harness.snapshot(
            scale: 8,
            offsetX: -103 * 8,
            offsetY: -117 * 8
        )
        let sharpness = try meanAbsoluteLaplacian(of: sharpSnapshot)

        let legacyBudget = WorkspaceVectorRedrawBudget(memoryBudgetBytes: 64 * 1024 * 1024)
        try await harness.load(
            fileURL: pixelFixtureURL,
            renderingMode: .vector,
            vectorRedrawBudget: legacyBudget
        )
        let legacyMetrics = try await harness.restoreAndMeasure(scale: 8, simulatedDPR: 1)
        #expect(legacyMetrics.offsetWidth < 4_250)
        #expect(legacyMetrics.compositeScale > 1.5)
        let legacySnapshot = try await harness.snapshot(
            scale: 8,
            offsetX: -103 * 8,
            offsetY: -117 * 8
        )
        let legacySharpness = try meanAbsoluteLaplacian(of: legacySnapshot)

        // This repeatable WKWebView edge metric replaces the external OpenCV blur score.
        print("filtered-title edge mean: dynamic=\(sharpness), legacy4096=\(legacySharpness)")
        #expect(sharpness > 1.4)
        #expect(sharpness > legacySharpness * 1.3)

        try await harness.load(
            fileURL: pixelFixtureURL,
            renderingMode: .vector,
            vectorRedrawBudget: fullBudget
        )
        let retinaBudget = try await harness.restoreAndMeasure(scale: 8, simulatedDPR: 2)
        #expect(retinaBudget.paintScale > 6)
        #expect(retinaBudget.paintScale < 7)
        #expect(retinaBudget.compositeScale > 1)
        #expect(retinaBudget.estimatedPeakBytes <= retinaBudget.memoryBudgetBytes + 1)
        print(
            "fixture DPR2 scale=8 paintScale=\(retinaBudget.paintScale) "
                + "layout=\(retinaBudget.offsetWidth)x\(retinaBudget.offsetHeight) "
                + "composite=\(retinaBudget.compositeScale)"
        )
        // Exercise the exact requested asset last so the test never allocates a second filtered
        // backing store while WebKit is releasing its 4800x2880 400% representation. The 800%
        // plan is then verified without forcing the test runner to snapshot a 440 MiB layer.
        try await harness.load(
            fileURL: fileURL,
            renderingMode: .vector,
            vectorRedrawBudget: fullBudget
        )
        for scale in [1.0, 3.4, 4.0] {
            let metrics = try await harness.restoreAndMeasure(scale: scale, simulatedDPR: 1)
            #expect(abs(Double(metrics.offsetWidth) - 1200 * scale) < 1)
            #expect(abs(Double(metrics.offsetHeight) - 720 * scale) < 1)
            #expect(abs(metrics.rectWidth - 1200 * scale) < 0.02)
            #expect(abs(metrics.rectHeight - 720 * scale) < 0.02)
            #expect(abs(metrics.paintScale - scale) < 0.000_001)
            #expect(abs(metrics.compositeScale - 1) < 0.000_001)
            #expect(metrics.estimatedPeakBytes <= metrics.memoryBudgetBytes + 1)
            #expect(metrics.transform == "none")
            print(
                "DPR1 scale=\(scale) layout=\(metrics.offsetWidth)x\(metrics.offsetHeight) "
                    + "rect=\(metrics.rectWidth)x\(metrics.rectHeight) "
                + "composite=\(metrics.compositeScale)"
            )
        }
        let eightHundredPercent = try await harness.planAndMeasure(scale: 8, simulatedDPR: 1)
        #expect(eightHundredPercent.offsetWidth == 9_600)
        #expect(eightHundredPercent.offsetHeight == 5_760)
        #expect(abs(eightHundredPercent.rectWidth - 9_600) < 0.02)
        #expect(abs(eightHundredPercent.rectHeight - 5_760) < 0.02)
        #expect(abs(eightHundredPercent.paintScale - 8) < 0.000_001)
        #expect(eightHundredPercent.transform == "none")
        print(
            "DPR1 scale=8 plannedLayout=\(eightHundredPercent.offsetWidth)x\(eightHundredPercent.offsetHeight) "
                + "rect=\(eightHundredPercent.rectWidth)x\(eightHundredPercent.rectHeight) "
                + "composite=\(eightHundredPercent.compositeScale)"
        )
        let retinaPlan = try await harness.planAndMeasure(scale: 8, simulatedDPR: 2)
        #expect(retinaPlan.paintScale > 4)
        #expect(retinaPlan.paintScale < 5)
        #expect(retinaPlan.compositeScale > 1.8)
        #expect(retinaPlan.estimatedPeakBytes <= retinaPlan.memoryBudgetBytes + 1)
        print(
            "sample DPR2 scale=8 paintScale=\(retinaPlan.paintScale) "
                + "plannedLayout=\(retinaPlan.offsetWidth)x\(retinaPlan.offsetHeight) "
                + "composite=\(retinaPlan.compositeScale)"
        )
        let released = try await harness.restoreAndMeasure(scale: 1, simulatedDPR: 1)
        #expect(released.offsetWidth == 1_200)
        #expect(released.offsetHeight == 720)
        #expect(released.estimatedPeakBytes < 8 * 1024 * 1024)
    }

    @Test @MainActor func gaussianBlurAndPlainVectorFixturesFollowTheSameBudget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = PreviewHarness(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        defer { harness.shutdown() }
        let budget = WorkspaceVectorRedrawBudget(
            memoryBudgetBytes: WorkspaceVectorRedrawBudget.maximumMemoryBudgetBytes
        )
        let cases = [
            ("plain", plainVectorSVG),
            ("gaussian", gaussianBlurSVG)
        ]

        for (name, source) in cases {
            let fileURL = directory.appendingPathComponent("\(name).svg")
            try source.write(to: fileURL, atomically: true, encoding: .utf8)
            try await harness.load(
                fileURL: fileURL,
                renderingMode: .vector,
                vectorRedrawBudget: budget
            )
            let metrics = try await harness.restoreAndMeasure(scale: 8, simulatedDPR: 1)
            #expect(metrics.offsetWidth == 6_400, Comment(rawValue: name))
            #expect(metrics.offsetHeight == 3_200, Comment(rawValue: name))
            #expect(abs(metrics.paintScale - 8) < 0.000_001, Comment(rawValue: name))
            #expect(metrics.transform == "none", Comment(rawValue: name))
            let snapshot = try await harness.snapshot(
                scale: 8,
                offsetX: name == "plain" ? -300 : -100,
                offsetY: name == "plain" ? -100 : -80
            )
            #expect(snapshot.tiffRepresentation?.isEmpty == false, Comment(rawValue: name))
        }
    }

    @Test @MainActor func extremeSVGAndDPRTwoDegradeWithinPeakMemoryBudgetAndReleaseOnShrink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("extreme.svg")
        try svg(width: "12000", height: "8000", viewBox: "0 0 12000 8000")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let budget = WorkspaceVectorRedrawBudget(
            memoryBudgetBytes: WorkspaceVectorRedrawBudget.minimumMemoryBudgetBytes
        )
        let harness = PreviewHarness(frame: CGRect(x: 0, y: 0, width: 760, height: 540))
        defer { harness.shutdown() }
        try await harness.load(
            fileURL: fileURL,
            renderingMode: .vector,
            vectorRedrawBudget: budget
        )

        let extreme = try await harness.restoreAndMeasure(scale: 32, simulatedDPR: 2)
        #expect(extreme.paintScale < 0.3)
        #expect(extreme.compositeScale > 100)
        #expect(extreme.offsetWidth < 3_200)
        #expect(extreme.offsetHeight < 2_200)
        #expect(extreme.estimatedPeakBytes <= extreme.memoryBudgetBytes + 1)
        #expect(max(extreme.offsetWidth, extreme.offsetHeight) <= 16_384)

        let shrunk = try await harness.restoreAndMeasure(scale: 1, simulatedDPR: 2)
        #expect(shrunk.offsetWidth == extreme.offsetWidth)
        #expect(shrunk.offsetHeight == extreme.offsetHeight)
        #expect(shrunk.compositeScale < extreme.compositeScale)
    }

    @Test @MainActor func svgActualSizeUsesWebKitIntrinsicViewportAcrossDeclarationMatrix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = PreviewHarness(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        defer { harness.shutdown() }

        let cases: [(String, String, Int, Int)] = [
            ("viewBox-only", svg(width: nil, height: nil, viewBox: "0 0 400 100"), 400, 100),
            ("size-only", svg(width: "640", height: "360", viewBox: nil), 640, 360),
            ("size-and-viewBox", svg(width: "640", height: "360", viewBox: "0 0 1280 720"), 640, 360),
            ("percentage-with-viewBox", svg(width: "100%", height: "50%", viewBox: "0 0 400 100"), 400, 100),
            ("percentage-only", svg(width: "100%", height: "50%", viewBox: nil), 300, 150),
            ("huge", svg(width: "2048", height: "1024", viewBox: "0 0 2048 1024"), 2048, 1024),
            ("tiny", svg(width: "1", height: "1", viewBox: "0 0 1 1"), 1, 1)
        ]

        for (name, source, expectedWidth, expectedHeight) in cases {
            let fileURL = directory.appendingPathComponent("\(name).svg")
            try source.write(to: fileURL, atomically: true, encoding: .utf8)
            try await harness.load(fileURL: fileURL, renderingMode: .vector)

            let actualSize = try await harness.restoreAndMeasure(scale: 1)
            #expect(actualSize.naturalWidth == expectedWidth, Comment(rawValue: name))
            #expect(actualSize.naturalHeight == expectedHeight, Comment(rawValue: name))
            #expect(actualSize.offsetWidth == expectedWidth, Comment(rawValue: name))
            #expect(actualSize.offsetHeight == expectedHeight, Comment(rawValue: name))

            let eightHundredPercent = try await harness.restoreAndMeasure(
                scale: 8,
                simulatedDPR: 1
            )
            #expect(
                abs(
                    Double(eightHundredPercent.offsetWidth)
                        - Double(expectedWidth) * eightHundredPercent.paintScale
                ) < 1,
                Comment(rawValue: name)
            )
            #expect(
                abs(
                    Double(eightHundredPercent.offsetHeight)
                        - Double(expectedHeight) * eightHundredPercent.paintScale
                ) < 1,
                Comment(rawValue: name)
            )
            #expect(
                abs(eightHundredPercent.rectWidth - Double(expectedWidth * 8)) < 0.05,
                Comment(rawValue: name)
            )
            #expect(
                abs(eightHundredPercent.rectHeight - Double(expectedHeight * 8)) < 0.05,
                Comment(rawValue: name)
            )
            #expect(
                eightHundredPercent.estimatedPeakBytes
                    <= eightHundredPercent.memoryBudgetBytes + 1,
                Comment(rawValue: name)
            )
            #expect(max(eightHundredPercent.offsetWidth, eightHundredPercent.offsetHeight) <= 16_384)
            if abs(eightHundredPercent.paintScale - 8) < 0.000_001 {
                #expect(eightHundredPercent.transform == "none", Comment(rawValue: name))
            } else {
                #expect(eightHundredPercent.transform != "none", Comment(rawValue: name))
                #expect(eightHundredPercent.offsetWidth > expectedWidth, Comment(rawValue: name))
            }
        }
    }

    @MainActor
    private final class PreviewHarness {
        private let messageHandler = IgnoringMessageHandler()
        private let resourceHandler = WorkspaceImageResourceSchemeHandler()
        private let webView: WKWebView

        init(frame: CGRect) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(
                resourceHandler,
                forURLScheme: WorkspaceImageResourceSchemeHandler.scheme
            )
            configuration.userContentController.add(
                messageHandler,
                name: WorkspaceImagePreviewHTML.messageHandlerName
            )
            webView = WKWebView(frame: frame, configuration: configuration)
        }

        func load(
            fileURL: URL,
            renderingMode: WorkspaceImageRenderingMode
        ) async throws {
            try await load(
                fileURL: fileURL,
                renderingMode: renderingMode,
                vectorRedrawBudget: WorkspaceVectorRedrawBudget(
                    memoryBudgetBytes: WorkspaceVectorRedrawBudget.maximumMemoryBudgetBytes
                )
            )
        }

        func load(
            fileURL: URL,
            renderingMode: WorkspaceImageRenderingMode,
            vectorRedrawBudget: WorkspaceVectorRedrawBudget
        ) async throws {
            let resourceURL = resourceHandler.register(fileURL)
            webView.loadHTMLString(
                WorkspaceImagePreviewHTML.make(
                    resourceURL: resourceURL,
                    displayName: fileURL.lastPathComponent,
                    renderingMode: renderingMode,
                    vectorRedrawBudget: vectorRedrawBudget
                ),
                baseURL: nil
            )

            let displayNameJSON = String(
                data: try JSONSerialization.data(
                    withJSONObject: fileURL.lastPathComponent,
                    options: .fragmentsAllowed
                ),
                encoding: .utf8
            ) ?? "\"\""

            for _ in 0..<200 {
                let ready = try await evaluate(
                    """
                    (() => {
                      const image = document.getElementById('preview');
                      return document.readyState === 'complete'
                        && image?.alt === \(displayNameJSON)
                        && image?.complete === true
                        && image.naturalWidth > 0
                        && (document.body.dataset.renderingMode !== 'vector'
                          || window.slateImagePreview?.metrics().memoryBudgetBytes
                            === \(vectorRedrawBudget.memoryBudgetBytes));
                    })()
                    """
                ) as? Bool
                if ready == true { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw PreviewTestError.timedOut(fileURL.lastPathComponent)
        }

        func restoreAndMeasure(scale: Double, simulatedDPR: Double? = nil) async throws -> Metrics {
            let dprOverride = simulatedDPR.map {
                "Object.defineProperty(window, 'devicePixelRatio', { value: \($0), configurable: true });"
            } ?? ""
            let value = try await evaluate(
                """
                (() => {
                  \(dprOverride)
                  window.slateImagePreview.restore({scale: \(scale), offsetX: 0, offsetY: 0});
                  return window.slateImagePreview.metrics();
                })()
                """
            )
            let dictionary = try #require(value as? [String: Any])
            return try Metrics(dictionary: dictionary)
        }

        func planAndMeasure(scale: Double, simulatedDPR: Double? = nil) async throws -> Metrics {
            let dprOverride = simulatedDPR.map {
                "Object.defineProperty(window, 'devicePixelRatio', { value: \($0), configurable: true });"
            } ?? ""
            let value = try await evaluate(
                "(() => { \(dprOverride) return window.slateImagePreview.plan(\(scale)); })()"
            )
            let dictionary = try #require(value as? [String: Any])
            return try Metrics(dictionary: dictionary)
        }

        func snapshot() async throws -> NSImage {
            try await withCheckedThrowingContinuation { continuation in
                var completed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard !completed else { return }
                    completed = true
                    continuation.resume(throwing: PreviewTestError.timedOut("snapshot"))
                }
                webView.takeSnapshot(with: nil) { image, error in
                    guard !completed else { return }
                    completed = true
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? PreviewTestError.snapshotFailed)
                    }
                }
            }
        }

        func snapshot(scale: Double, offsetX: Double, offsetY: Double) async throws -> NSImage {
            _ = try await evaluate(
                "window.slateImagePreview.restore({scale: \(scale), offsetX: \(offsetX), offsetY: \(offsetY)})"
            )
            try await Task.sleep(for: .milliseconds(150))
            return try await snapshot()
        }

        func shutdown() {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WorkspaceImagePreviewHTML.messageHandlerName
            )
            webView.navigationDelegate = nil
        }

        private func evaluate(_ script: String) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                var completed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard !completed else { return }
                    completed = true
                    continuation.resume(throwing: PreviewTestError.timedOut("JavaScript"))
                }
                webView.evaluateJavaScript(script) { value, error in
                    guard !completed else { return }
                    completed = true
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
        }
    }

    private final class IgnoringMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {}
    }

    private struct Metrics {
        let naturalWidth: Int
        let naturalHeight: Int
        let offsetWidth: Int
        let offsetHeight: Int
        let rectWidth: Double
        let rectHeight: Double
        let transform: String
        let paintScale: Double
        let compositeScale: Double
        let estimatedPeakBytes: Double
        let memoryBudgetBytes: Double

        init(dictionary: [String: Any]) throws {
            naturalWidth = try Self.int("naturalWidth", in: dictionary)
            naturalHeight = try Self.int("naturalHeight", in: dictionary)
            offsetWidth = try Self.int("offsetWidth", in: dictionary)
            offsetHeight = try Self.int("offsetHeight", in: dictionary)
            rectWidth = try Self.double("rectWidth", in: dictionary)
            rectHeight = try Self.double("rectHeight", in: dictionary)
            transform = try #require(dictionary["transform"] as? String)
            paintScale = try Self.double("paintScale", in: dictionary)
            compositeScale = try Self.double("compositeScale", in: dictionary)
            estimatedPeakBytes = try Self.double("estimatedPeakBytes", in: dictionary)
            memoryBudgetBytes = try Self.double("memoryBudgetBytes", in: dictionary)
        }

        private static func int(_ key: String, in dictionary: [String: Any]) throws -> Int {
            Int(try double(key, in: dictionary))
        }

        private static func double(_ key: String, in dictionary: [String: Any]) throws -> Double {
            try #require((dictionary[key] as? NSNumber)?.doubleValue)
        }
    }

    private func meanAbsoluteLaplacian(of image: NSImage) throws -> Double {
        let representation = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: representation))
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var grayscale = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                grayscale[y * width + x] = 255 * (
                    0.2126 * color.redComponent
                        + 0.7152 * color.greenComponent
                        + 0.0722 * color.blueComponent
                )
            }
        }
        var total = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                total += abs(
                    grayscale[index - 1] + grayscale[index + 1]
                        + grayscale[index - width] + grayscale[index + width]
                        - 4 * grayscale[index]
                )
                count += 1
            }
        }
        return total / Double(max(count, 1))
    }

    private var plainVectorSVG: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="800" height="400" viewBox="0 0 800 400">
          <rect width="800" height="400" fill="white"/>
          <path d="M40 350 C180 20 620 20 760 350" fill="none" stroke="#111827" stroke-width="3"/>
          <text x="400" y="210" text-anchor="middle" font-family="-apple-system" font-size="32">FloralMD vector</text>
        </svg>
        """
    }

    private var gaussianBlurSVG: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="800" height="400" viewBox="0 0 800 400">
          <defs><filter id="blur"><feGaussianBlur stdDeviation="12"/></filter></defs>
          <rect width="800" height="400" fill="white"/>
          <rect x="100" y="80" width="600" height="240" rx="30" fill="#cbd5e1" filter="url(#blur)"/>
          <text x="400" y="215" text-anchor="middle" font-family="-apple-system" font-size="32">Gaussian filter</text>
        </svg>
        """
    }

    private var filteredSampleSVG: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="720" viewBox="0 0 1200 720">
          <defs>
            <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
              <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#0f172a" flood-opacity="0.12"/>
            </filter>
          </defs>
          <rect width="1200" height="720" rx="28" fill="#f8fafc"/>
          <text x="600" y="70" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="34" font-weight="700">Markdown 笔记的文 · 表 · 图</text>
          <path d="M515 330 C455 300 420 270 370 250" fill="none" stroke="#64748b" stroke-width="3"/>
          <g filter="url(#shadow)">
            <rect x="100" y="155" width="300" height="190" rx="24" fill="white" stroke="#bfdbfe" stroke-width="2"/>
            <text x="205" y="208" font-family="-apple-system, sans-serif" font-size="23" font-weight="700">展开意义</text>
            <text x="135" y="265" font-family="-apple-system, sans-serif" font-size="17">解释 · 叙事 · 因果 · 判断</text>
          </g>
        </svg>
        """
    }

    private var compactFilteredSampleSVG: String {
        filteredSampleSVG.replacingOccurrences(
            of: "width=\"1200\" height=\"720\"",
            with: "width=\"800\" height=\"480\""
        )
    }

    private enum PreviewTestError: Error {
        case timedOut(String)
        case snapshotFailed
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-ImagePreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func svg(
        width: String?,
        height: String?,
        viewBox: String?,
        embeddedPNGBase64: String? = nil
    ) -> String {
        let widthAttribute = width.map { " width=\"\($0)\"" } ?? ""
        let heightAttribute = height.map { " height=\"\($0)\"" } ?? ""
        let viewBoxAttribute = viewBox.map { " viewBox=\"\($0)\"" } ?? ""
        let embeddedImage = embeddedPNGBase64.map {
            """
            <image x="1" y="1" width="1" height="1"
              href="data:image/png;base64,\($0)"/>
            """
        } ?? ""
        return """
        <svg xmlns="http://www.w3.org/2000/svg"\(widthAttribute)\(heightAttribute)\(viewBoxAttribute)>
          <rect width="100%" height="100%" fill="white"/>
          <path d="M0 0 L100 100" stroke="black" stroke-width="1"/>
          <text x="50%" y="50%" font-family="system-ui" font-size="12">FloralMD</text>
          \(embeddedImage)
        </svg>
        """
    }
}
