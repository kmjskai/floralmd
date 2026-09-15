import Cocoa
import Testing

@testable import FloralMD

extension FloralMDTests {
    @Test @MainActor func wrappedLogicalLinesAnchorOneGutterRowToFirstVisualLine() async throws {
        let repeatedWords = Array(repeating: "wrapped-content", count: 12).joined(separator: " ")
        let markdown = """
        # H1 \(repeatedWords)
        ## H2 \(repeatedWords)
        ### H3 \(repeatedWords)
        #### H4 \(repeatedWords)
        ##### H5 \(repeatedWords)
        ###### H6 \(repeatedWords)
        Paragraph \(repeatedWords)
        - List item \(repeatedWords)
        [Long link \(repeatedWords)](https://example.com/a/very/long/destination)

        ```swift
        let value = "\(repeatedWords)"
        ```
        ![One](one.png) ![Two](two.png) ![Three](three.png)
        """
        let expectedLabels = [
            1: "H1", 2: "H2", 3: "H3", 4: "H4", 5: "H5", 6: "H6",
            12: "CODE", 14: "IMG",
        ]
        let expectedLines = Array(1...9) + [12, 14]
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 2_400)
        controller.load(markdown: markdown)

        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        for fontSize in [11.0, 15.0, 28.0] {
            controller.applyTypography(
                MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: 1.6)
            )
            var result: [String: Any]?
            var evaluationError: Error?
            for _ in 0..<100 {
                (result, evaluationError) = await withCheckedContinuation { continuation in
                    controller.evaluateEditorJavaScriptWithError(
                        """
                        (() => {
                          const content = document.querySelector('.cm-content');
                          const scroller = document.querySelector('.cm-scroller');
                          if (!content || !scroller) return null;
                          content.style.width = '220px';
                          content.style.maxWidth = '220px';
                          window.dispatchEvent(new Event('resize'));
                          window.dispatchEvent(new Event('floralmd-typography-change'));

                          const expectedLines = \(expectedLines);
                          const sourceRows = Array.from(content.querySelectorAll('.cm-line'))
                            .filter((source) => source.getBoundingClientRect().height >= 0.5);
                          const gutterRows = Array.from(document.querySelectorAll(
                            '.cm-floralmd-gutter-line'
                          ));
                          const measurements = expectedLines.map((lineNumber) => {
                            const rows = Array.from(document.querySelectorAll(
                              `.cm-floralmd-gutter-line[data-source-line="${lineNumber}"]`
                            ));
                            const row = rows[0];
                            const source = sourceRows[gutterRows.indexOf(row)];
                            if (!source || !row) return { lineNumber, rowCount: rows.length };
                            const sourceRect = source.getBoundingClientRect();
                            const rowRect = row.getBoundingClientRect();
                            const style = getComputedStyle(source);
                            const paddingTop = parseFloat(style.paddingTop) || 0;
                            const paddingBottom = parseFloat(style.paddingBottom) || 0;
                            const lineHeight = parseFloat(style.lineHeight);
                            const contentHeight = sourceRect.height - paddingTop - paddingBottom;
                            const firstCenter = sourceRect.top + paddingTop + lineHeight / 2;
                            const blockCenter = sourceRect.top + paddingTop + contentHeight / 2;
                            const rowCenter = rowRect.top + rowRect.height / 2;
                            return {
                              lineNumber,
                              rowCount: rows.length,
                              label: row.querySelector('.cm-semantic-badge')?.textContent.trim() || '',
                              wrapped: contentHeight > lineHeight * 1.5,
                              firstDelta: Math.abs(rowCenter - firstCenter),
                              blockDelta: Math.abs(rowCenter - blockCenter)
                            };
                          });
                          return {
                            measurements,
                            markdown: window.__mdEditor.getMarkdown(),
                            fontSize: parseFloat(getComputedStyle(scroller).fontSize)
                          };
                        })()
                        """
                    ) { value, error in
                        continuation.resume(returning: (value as? [String: Any], error))
                    }
                }
                let measurements = result?["measurements"] as? [[String: Any]] ?? []
                if measurements.count == expectedLines.count,
                   measurements.allSatisfy({ measurement in
                       (measurement["wrapped"] as? Bool) == true
                           && (measurement["firstDelta"] as? Double ?? .infinity) < 1
                   }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            let measurements = result?["measurements"] as? [[String: Any]] ?? []
            #expect(evaluationError == nil)
            #expect(result?["markdown"] as? String == markdown)
            #expect(result?["fontSize"] as? Double == fontSize)
            #expect(measurements.count == expectedLines.count)
            for measurement in measurements {
                let line = measurement["lineNumber"] as? Int
                #expect(measurement["rowCount"] as? Int == 1)
                #expect(measurement["wrapped"] as? Bool == true)
                #expect((measurement["firstDelta"] as? Double ?? .infinity) < 1)
                #expect((measurement["blockDelta"] as? Double ?? 0) > 2)
                #expect(measurement["label"] as? String == expectedLabels[line ?? -1, default: ""])
            }
        }

        let storedMarkdown = await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
        #expect(storedMarkdown == markdown)
    }

}

@Suite(.serialized)
struct MarkdownSemanticGutterTests {
    @Test @MainActor func gutterUsesSyntaxTreeForHeadingsCodeAndStandaloneImages() async throws {
        let markdown = """
        # Heading
        ![One](one.png) ![Two](two.png)
        Inline ![Image](inline.png) sentence

        ```swift
        let value = 1
        ```
        ![Broken](broken.png)
        """
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: markdown)

        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        var result: [[String: Any]] = []
        for _ in 0..<100 {
            result = await withCheckedContinuation { continuation in
                controller.evaluateEditorJavaScript(
                    """
                    Array.from(document.querySelectorAll('.cm-semantic-badge')).map(badge => ({
                      label: badge.textContent.trim(),
                      line: Number(badge.closest('.cm-floralmd-gutter-line')?.dataset.sourceLine),
                      className: badge.className,
                      color: getComputedStyle(badge).color
                    }))
                    """
                ) { value in
                    continuation.resume(returning: value as? [[String: Any]] ?? [])
                }
            }
            if result.count == 4 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let labels = result.compactMap { row -> String? in
            guard let label = row["label"] as? String,
                  let line = row["line"] as? Int else { return nil }
            return "\(line):\(label)"
        }
        #expect(labels == ["1:H1", "2:IMG", "6:CODE", "8:IMG"])
        #expect(!labels.contains("3:IMG"))
        #expect(result.first { $0["label"] as? String == "H1" }?["className"] as? String
            == "cm-semantic-badge cm-semantic-h1")
        #expect(result.first { $0["label"] as? String == "CODE" }?["className"] as? String
            == "cm-semantic-badge cm-semantic-code")
        #expect(result.first { $0["label"] as? String == "IMG" }?["className"] as? String
            == "cm-semantic-badge cm-semantic-img")
        #expect(result.first { $0["label"] as? String == "CODE" }?["color"] as? String
            != result.first { $0["label"] as? String == "H1" }?["color"] as? String)
        #expect(result.first { $0["label"] as? String == "IMG" }?["color"] as? String
            != result.first { $0["label"] as? String == "H1" }?["color"] as? String)

        let storedMarkdown = await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
        #expect(storedMarkdown == markdown)
    }
}
