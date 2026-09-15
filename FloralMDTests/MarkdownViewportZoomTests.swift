import AppKit
import Testing
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct MarkdownViewportZoomTests {
    @Test func scaleClampsAndFormatsPercentages() {
        #expect(MarkdownViewportZoom.clamped(0.2) == 0.75)
        #expect(MarkdownViewportZoom.clamped(1.37) == 1.37)
        #expect(MarkdownViewportZoom.clamped(4) == 2)
        #expect(MarkdownViewportZoom.clamped(.nan) == 1)
        #expect(MarkdownViewportZoom.clamped(.infinity) == 1)
        #expect(MarkdownViewportZoom.percentage(1.374) == 137)
    }

    @Test func commandsUseTenPercentStepsAndRespectBounds() {
        #expect(MarkdownViewportZoomAdjustment.increase.apply(to: 1) == 1.1)
        #expect(MarkdownViewportZoomAdjustment.decrease.apply(to: 1) == 0.9)
        #expect(MarkdownViewportZoomAdjustment.reset.apply(to: 1.37) == 1)
        #expect(MarkdownViewportZoomAdjustment.increase.apply(to: 1.96) == 2)
        #expect(MarkdownViewportZoomAdjustment.decrease.apply(to: 0.76) == 0.75)
        #expect(!MarkdownViewportZoomAdjustment.increase.isAvailable(at: 2))
        #expect(!MarkdownViewportZoomAdjustment.decrease.isAvailable(at: 0.75))
    }

    @Test func appKitAndCSSCoordinatesRoundTripAtEverySupportedScale() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let viewPoint = CGPoint(x: 421, y: 188)

        for scale in [0.75, 1, 1.37, 2] {
            for isFlipped in [false, true] {
                let cssPoint = MarkdownWebViewCoordinateSpace.cssViewportPoint(
                    fromViewPoint: viewPoint,
                    bounds: bounds,
                    isFlipped: isFlipped,
                    pageZoom: scale
                )
                let roundTrip = MarkdownWebViewCoordinateSpace.viewPoint(
                    fromCSSViewportPoint: cssPoint,
                    bounds: bounds,
                    isFlipped: isFlipped,
                    pageZoom: scale
                )
                #expect(abs(roundTrip.x - viewPoint.x) < 0.001)
                #expect(abs(roundTrip.y - viewPoint.y) < 0.001)
            }
        }
    }

    @Test func pageZoomPreservesMarkdownAndSelection() async throws {
        let markdown = "# 缩放测试\n\n中文输入、selection 与 undo 都属于编辑器状态。"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        controller.load(markdown: markdown, contentWidth: 756)
        try await waitForEditor(in: controller)

        _ = await evaluate("window.__mdEditor.select(8, 12); true", in: controller)
        for scale in [0.75, 1, 1.37, 2] {
            controller.applyPageZoom(scale)
            #expect(abs(controller.pageZoomForTesting - scale) < 0.001)
            let state = try #require(await evaluate(
                """
                ({
                    markdown: window.__mdEditor.getMarkdown(),
                    from: window.__mdEditor._selectionForTesting().from,
                    to: window.__mdEditor._selectionForTesting().to
                })
                """,
                in: controller
            ) as? [String: Any])
            #expect(state["markdown"] as? String == markdown)
            #expect((state["from"] as? NSNumber)?.intValue == 8)
            #expect((state["to"] as? NSNumber)?.intValue == 12)
        }
    }

    @Test func viewportCommandsRemainSeparateFromBaseTypography() {
        let typography = MarkdownTypography(fontName: "", fontSize: 18, lineHeight: 1.6)
        let zoom = MarkdownViewportZoomAdjustment.increase.apply(to: 1)
        #expect(zoom == 1.1)
        #expect(typography.fontSize == 18)
        #expect(FloralMDCommandCatalog.increaseMarkdownViewportZoom.shortcut == "⌘+")
        #expect(FloralMDCommandCatalog.increaseMarkdownFontSize.shortcut == nil)
        #expect(FloralMDCommandCatalog.increaseMarkdownFontSize.title.contains("基础字号"))
    }

    private func waitForEditor(in controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<200 {
            if await evaluate("!!window.__mdEditor", in: controller) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("CodeMirror editor did not become ready")
    }

    private func evaluate(
        _ script: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { value in
                continuation.resume(returning: value)
            }
        }
    }
}
