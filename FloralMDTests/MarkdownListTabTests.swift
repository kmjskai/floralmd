import Cocoa
import Testing

@testable import FloralMD

/// Tab inside a list item must nest the item (list typography, not a code
/// block) and move the caret to the text column after the marker — for ordered
/// and unordered lists alike. A caret already past the marker keeps its
/// relative position.
@Suite(.serialized)
struct MarkdownListTabTests {
    @Test @MainActor func tabAtLineStartNestsAndMovesCaretPastMarker() async throws {
        let cases: [(name: String, markdown: String, caret: Int, expectedDoc: String, expectedHead: Int)] = [
            ("ordered", "1. item", 0, "    1. item", 7),
            ("ordered-mid-marker", "1. item", 2, "    1. item", 7),
            ("unordered", "- item", 0, "    - item", 6),
        ]
        for item in cases {
            let controller = try await makeController(markdown: item.markdown, width: 520)
            try await focusAndPlaceCaret(at: item.caret, in: controller)
            try await dispatchTab(in: controller)
            let line = try await lineSnapshot(controller)
            #expect(line["doc"] as? String == item.expectedDoc,
                    Comment(rawValue: "\(item.name) doc"))
            #expect(line["head"] as? Int == item.expectedHead,
                    Comment(rawValue: "\(item.name) head"))
            #expect((line["className"] as? String)?.contains("cm-md-list-item") == true,
                    Comment(rawValue: "\(item.name) still a list"))
            #expect((line["className"] as? String)?.contains("cm-md-list-depth-2") == true,
                    Comment(rawValue: "\(item.name) nested"))
            #expect((line["className"] as? String)?.contains("cm-md-codeblock") != true,
                    Comment(rawValue: "\(item.name) not a code block"))
        }
    }

    @Test @MainActor func tabAtLineEndKeepsRelativeCaret() async throws {
        let controller = try await makeController(markdown: "1. item", width: 520)
        try await focusAndPlaceCaret(at: 7, in: controller)
        try await dispatchTab(in: controller)
        let line = try await lineSnapshot(controller)
        #expect(line["doc"] as? String == "    1. item")
        #expect(line["head"] as? Int == 11)
        #expect((line["className"] as? String)?.contains("cm-md-list-depth-2") == true)
    }

    @Test @MainActor func tabOnSecondItemNestsOnlyThatItem() async throws {
        let controller = try await makeController(markdown: "1. alpha\n2. beta", width: 520)
        try await focusAndPlaceCaret(at: 13, in: controller)
        try await dispatchTab(in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. alpha\n    2. beta")
        let state = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const lines = [...view.contentDOM.querySelectorAll('.cm-line')];
          return {
            head: view.state.selection.main.head,
            classes: lines.map(line => line.className)
          };
        })()
        """)
        #expect(state["head"] as? Int == 16)
        let classes = state["classes"] as? [String] ?? []
        #expect(classes.count == 2)
        #expect(classes[0].contains("cm-md-list-depth-1"))
        #expect(classes[1].contains("cm-md-list-depth-2"))
    }

    @Test @MainActor func typingAfterTabStaysInNestedList() async throws {
        let controller = try await makeController(markdown: "1. item", width: 520)
        try await focusAndPlaceCaret(at: 0, in: controller)
        try await dispatchTab(in: controller)
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const pos = view.state.selection.main.head;
          view.dispatch({
            changes: { from: pos, to: pos, insert: 'x' },
            selection: { anchor: pos + 1 },
            userEvent: 'input.type'
          });
          return { inserted: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(60))
        let doc = try await markdown(in: controller)
        #expect(doc == "    1. xitem")
        let line = try await lineSnapshot(controller)
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        #expect((line["className"] as? String)?.contains("cm-md-codeblock") != true)
    }

    @MainActor
    private func dispatchTab(in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Tab', bubbles: true, cancelable: true
          }));
          return { dispatched: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(80))
    }

    @MainActor
    private func lineSnapshot(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> [String: Any] {
        try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const line = view.contentDOM.querySelector('.cm-line');
          return {
            doc: view.state.doc.toString(),
            head: view.state.selection.main.head,
            className: line?.className ?? null
          };
        })()
        """)
    }

    @MainActor
    private func makeController(markdown: String, width: CGFloat) async throws
        -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        controller.load(markdown: markdown, typewriterModeEnabled: false)
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { return controller }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
        return controller
    }

    @MainActor
    private func focusAndPlaceCaret(
        at position: Int,
        in controller: CodeMirrorEditorViewController
    ) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          view.dispatch({ selection: { anchor: \(position) }, scrollIntoView: true });
          return { ready: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(60))
    }

    @MainActor
    private func markdown(in controller: CodeMirrorEditorViewController) async throws -> String {
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError("window.__mdEditor.getMarkdown()") {
                value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
        return try #require(value as? String)
    }

    @MainActor
    private func evaluateDictionary(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> [String: Any] {
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
        return try #require(value as? [String: Any])
    }
}
