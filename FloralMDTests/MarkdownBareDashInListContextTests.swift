import Cocoa
import Testing

@testable import FloralMD

/// A bare "-" line inside a list context (lazy continuation after a list
/// item) must keep its list typography but must NOT receive the fixed-width
/// hanging box: a box adjacent to the input-method caret is what makes WebKit
/// present the macOS candidate window vertically.
@Suite(.serialized)
struct MarkdownBareDashInListContextTests {
    @Test @MainActor func bareDashAfterListItemHasNoHangingBox() async throws {
        let controller = try await makeController(markdown: "- item 1\n-", width: 520)
        try await focusAndPlaceCaret(at: 9, in: controller)

        let line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "-")
        // The line stays visually part of the list…
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        // …but the hanging box and bullet widget must not be emitted, so the
        // composition caret never sits next to a replaced inline-block.
        #expect(line["bulletSource"] as? Bool == false)
        #expect(line["bulletPreview"] as? Bool == false)
        #expect(line["widgetBufferCount"] as? Int == 0)
    }

    @Test @MainActor func dashSpaceAfterListItemStillRendersMarker() async throws {
        let controller = try await makeController(markdown: "- item 1\n- ", width: 520)
        try await focusAndPlaceCaret(at: 10, in: controller)

        let line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "-")
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        // "- " is a real marker and keeps the hanging box.
        #expect(line["bulletSource"] as? Bool == true)
    }

    @Test @MainActor func bareDashAfterParagraphStaysPlain() async throws {
        let controller = try await makeController(markdown: "hello\n-", width: 520)
        try await focusAndPlaceCaret(at: 6, in: controller)

        let line = try await lineSnapshot(controller)
        #expect((line["className"] as? String)?.contains("cm-md-list-item") != true)
        #expect(line["bulletSource"] as? Bool == false)
        #expect(line["widgetBufferCount"] as? Int == 0)
    }

    @MainActor
    private func lineSnapshot(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> [String: Any] {
        try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const line = view.contentDOM.querySelectorAll('.cm-line')[1];
          return {
            text: line?.textContent,
            className: line?.className,
            bulletSource: !!line?.querySelector('.cm-md-bullet-source'),
            bulletPreview: !!line?.querySelector('.cm-md-bullet'),
            widgetBufferCount: line?.querySelectorAll('.cm-widgetBuffer').length ?? 0
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
