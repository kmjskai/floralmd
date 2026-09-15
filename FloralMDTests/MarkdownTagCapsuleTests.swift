import Cocoa
import Testing

@testable import FloralMD

@Suite(.serialized)
struct MarkdownTagCapsuleTests {
    @Test @MainActor func tagsRenderAsSelectableCapsulesWithoutChangingMarkdown() async throws {
        let markdown = """
        #lineStart
        # Heading

        Valid #issue and #项目 plus #issue/bug.
        Wrapped （#wrapped） and #second.
        Adjacent abc#no and 中文#也不算.
        Bare # marker, numeric #123, and escaped \\#escaped.
        Raw URL https://example.com/#raw and <https://example.com/#angle>.
        `#inline` and [link](https://example.com/#anchor)

        ```text
        #fenced
        ```
        """
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: markdown)
        try await waitUntilReady(controller)

        let issueStart = (markdown as NSString).range(of: "#issue").location
        let result = try await evaluate(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const tags = Array.from(document.querySelectorAll('.cm-md-tag'));
          const tagTexts = tags.map(element => element.textContent);
          editor.focus();
          editor.select(\(issueStart), \(issueStart + "#issue".utf16.count));
          const selection = editor._selectionForTesting();
          const selectedTag = Array.from(document.querySelectorAll('.cm-md-tag'))
            .find(element => element.textContent === '#issue');
          const selectedStyle = selectedTag ? getComputedStyle(selectedTag) : null;
          const stylesheet = Array.from(document.querySelectorAll('style'))
            .map(element => element.textContent).join('\\n');
          return {
            tags: tagTexts,
            markdown: editor.getMarkdown(),
            selectionFrom: selection.from,
            selectionTo: selection.to,
            background: selectedStyle?.backgroundColor,
            borderRadius: selectedStyle?.borderRadius,
            color: selectedStyle?.color,
            bodyColor: getComputedStyle(document.body).color,
            hasThemeVariables: getComputedStyle(document.documentElement)
              .getPropertyValue('--semantic-tag').trim().length > 0,
            hasDarkThemeVariable: stylesheet.includes('@media (prefers-color-scheme: dark)')
              && stylesheet.includes('--semantic-tag: #c7a9e8')
          };
        })()
        """)

        #expect(result["tags"] as? [String] == [
            "#lineStart", "#issue", "#项目", "#issue/bug", "#wrapped", "#second",
        ])
        #expect(result["markdown"] as? String == markdown)
        #expect(result["selectionFrom"] as? Int == issueStart)
        #expect(result["selectionTo"] as? Int == issueStart + "#issue".utf16.count)
        #expect(result["background"] as? String == "rgba(0, 0, 0, 0)")
        #expect(result["borderRadius"] as? String != "0px")
        #expect(result["color"] as? String == result["bodyColor"] as? String)
        #expect(result["hasThemeVariables"] as? Bool == true)
        #expect(result["hasDarkThemeVariable"] as? Bool == true)
    }

    @MainActor
    private func waitUntilReady(_ controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("CodeMirror editor did not become ready")
    }

    @MainActor
    private func evaluate(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { value in
                guard let result = value as? [String: Any] else {
                    continuation.resume(throwing: EvaluationError.invalidResult)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    private enum EvaluationError: Error {
        case invalidResult
    }
}
