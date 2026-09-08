import Cocoa
import Testing

@testable import FloralMD

@Suite(.serialized)
struct MarkdownParagraphGeometryTests {
    @Test @MainActor func blankRowsBeforeParagraphsKeepTheBodyLineHeight() async throws {
        let longParagraph = String(repeating: "普通正文与软换行保持相同的基础行高。", count: 8)
        let markdown = "前文\n\n\n\n\(longParagraph)\n下一段"
        let controller = try await makeController(markdown: markdown)

        for fontSize in [11.0, 15.0, 28.0] {
            controller.applyTypography(
                MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: 1.6)
            )
            try await Task.sleep(for: .milliseconds(100))

            let rows = try #require(await lineRows(in: controller))
            #expect(rows.count == 6)
            let bodyHeight = number(rows[0]["height"])
            #expect(bodyHeight > 0)
            for blankIndex in 1...3 {
                #expect(abs(number(rows[blankIndex]["height"]) - bodyHeight) < 1)
            }
            #expect(number(rows[4]["height"]) > bodyHeight * 1.5)
            #expect(abs(number(rows[5]["height"]) - bodyHeight) < 1)
        }
        #expect(await currentMarkdown(in: controller) == markdown)
    }

    @Test @MainActor func semanticBlockSpacingScalesWithTypography() async throws {
        let markdown = """
        开头

        - 列表

        > 引用

        > [!NOTE]
        > 告警内容

        ```swift
        let value = 1
        ```

        ```mermaid
        graph TD
          A --> B
        ```

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ---
        """
        let controller = try await makeController(markdown: markdown)
        let spacingMultipliers = [0.8, 1.2, 1.6, 0.8, 1.6, 1.6, 2.35]

        for fontSize in [11.0, 28.0] {
            let lineHeight = 1.6
            controller.applyTypography(
                MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: lineHeight)
            )
            try await Task.sleep(for: .milliseconds(100))

            let heights = try #require(await separatorHeights(in: controller))
            #expect(heights.count == spacingMultipliers.count)
            for (height, multiplier) in zip(heights, spacingMultipliers) {
                let expected = fontSize * (lineHeight + multiplier)
                #expect(abs(height - expected) < 1)
            }
        }
        #expect(await currentMarkdown(in: controller) == markdown)
    }

    @Test @MainActor func orderedAndUnorderedItemTextShareTheSameColumn() async throws {
        let markdown = "- 无序项目\n1. 有序项目\n10. 第十项"
        let controller = try await makeController(markdown: markdown)
        try await Task.sleep(for: .milliseconds(100))

        let rows = try #require(await bodyTextColumns(in: controller))
        #expect(rows.count == 3)
        let unordered = number(rows[0]["left"])
        let ordered = number(rows[1]["left"])
        let wide = number(rows[2]["left"])
        #expect(abs(unordered - ordered) < 1)
        #expect(abs(unordered - wide) < 1)

        // Ordered markers stay real, editable source text inside the fixed
        // hanging slot (the bundle marks them, it does not replace them).
        let markers = try #require(await orderedMarkerCount(in: controller))
        #expect(markers == 2)
        #expect(await currentMarkdown(in: controller) == markdown)
    }

    @MainActor
    private func makeController(markdown: String) async throws -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 540, height: 700)
        controller.load(markdown: markdown)
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { return controller }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror editor did not become ready")
        return controller
    }

    @MainActor
    private func lineRows(in controller: CodeMirrorEditorViewController) async -> [[String: Any]]? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                Array.from(document.querySelectorAll('.cm-line')).map((line) => ({
                  text: line.textContent,
                  height: line.getBoundingClientRect().height
                }))
                """
            ) { continuation.resume(returning: $0 as? [[String: Any]]) }
        }
    }

    @MainActor
    private func bodyTextColumns(in controller: CodeMirrorEditorViewController) async -> [[String: Any]]? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                Array.from(document.querySelectorAll('.cm-line')).map((line) => {
                  const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                  let node;
                  while ((node = walker.nextNode())
                    && !(node.nodeValue.includes('项目') || node.nodeValue.includes('第十项'))) {}
                  const text = node ? node.nodeValue : '';
                  const index = text.indexOf(text.trim()[0]);
                  const range = document.createRange();
                  range.setStart(node, index);
                  range.setEnd(node, index + 1);
                  return { left: range.getBoundingClientRect().left };
                })
                """
            ) { continuation.resume(returning: $0 as? [[String: Any]]) }
        }
    }

    @MainActor
    private func orderedMarkerCount(in controller: CodeMirrorEditorViewController) async -> Int? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                "document.querySelectorAll('.cm-md-ordered-marker').length"
            ) { continuation.resume(returning: $0 as? Int) }
        }
    }

    @MainActor
    private func separatorHeights(in controller: CodeMirrorEditorViewController) async -> [Double]? {
        let value: Any? = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                Array.from(document.querySelectorAll('.cm-md-block-separator'))
                  .map((line) => line.getBoundingClientRect().height)
                """
            ) { continuation.resume(returning: $0) }
        }
        return (value as? [NSNumber])?.map(\.doubleValue)
    }

    @MainActor
    private func currentMarkdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
    }

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? .nan
    }
}
