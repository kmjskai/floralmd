import Cocoa
import Testing

@testable import FloralMD

@Suite(.serialized)
struct MarkdownSemanticColorTests {
    @Test @MainActor func semanticTokensUseDistinctClassesWithoutChangingEditorState() async throws {
        let markdown = """
        # Neutral heading

        [Link](doc.md) ![Image](missing.png) `warm code` **strong**
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

        let result = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  const editor = window.__mdEditor;
                  const before = editor.getMarkdown();
                  const strong = before.indexOf('strong') + 1;
                  editor.focus();
                  editor.select(strong);
                  const style = selector => {
                    const element = document.querySelector(selector);
                    return element ? getComputedStyle(element) : null;
                  };
                  const stylesheet = Array.from(document.querySelectorAll('style'))
                    .map(element => element.textContent).join('\\n');
                  return {
                    markdown: editor.getMarkdown(),
                    headingColor: style('.cm-md-h1')?.color,
                    bodyColor: getComputedStyle(document.body).color,
                    linkColor: style('.cm-md-link')?.color,
                    imageColor: style('.cm-md-image-reference')?.color,
                    codeColor: style('.cm-md-inline-code')?.color,
                    codeBackground: style('.cm-md-inline-code')?.backgroundColor,
                    syntaxColor: style('.cm-md-syntax')?.color,
                    secondaryColor: getComputedStyle(document.documentElement)
                      .getPropertyValue('--secondary').trim(),
                    usesCompactSelection: document.querySelector('.cm-selectionLayer') !== null
                      && stylesheet.includes('#editor .cm-selectionBackground'),
                    searchLayerZ: getComputedStyle(
                      document.getElementById('floralmd-find-highlights')
                    ).zIndex
                  };
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(result?["markdown"] as? String == markdown)
        #expect(result?["headingColor"] as? String == result?["bodyColor"] as? String)
        #expect(result?["linkColor"] as? String != result?["bodyColor"] as? String)
        #expect(result?["imageColor"] as? String != result?["bodyColor"] as? String)
        #expect(result?["codeColor"] as? String != result?["bodyColor"] as? String)
        #expect(result?["codeBackground"] as? String != "rgba(0, 0, 0, 0)")
        #expect(result?["syntaxColor"] as? String != result?["bodyColor"] as? String)
        #expect(result?["usesCompactSelection"] as? Bool == true)
        #expect(result?["searchLayerZ"] as? String == "20")
    }
}
