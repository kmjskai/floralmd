import Cocoa
import Testing

@testable import FloralMD

/// Probe: compare the drawn .cm-cursor screen rect against the expected caret
/// screen position (scrollDOM rect + coordsAtPos) across lines and scrolling.
@Suite(.serialized)
struct MarkdownDrawnCaretPositionTests {
    @Test @MainActor func drawnCaretTracksViewportCoordinatesAcrossScrolling() async throws {
        let longDoc = (1...80).map { "line \($0) content" }.joined(separator: "\n")
        let controller = try await makeController(markdown: longDoc, width: 520)
        let cases: [(name: String, pos: Int, scroll: Double)] = [
            ("top", 1, 0),
            ("mid-unscrolled", 400, 0),
            ("mid-scrolled", 400, 300),
            ("bottom-scrolled", 1100, 1200),
        ]
        for item in cases {
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.focus();
              view.dom.classList.add('cm-focused');
              view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              view.dispatch({ selection: { anchor: \(item.pos) }, scrollIntoView: true });
              view.scrollDOM.scrollTop = \(item.scroll);
              view.scrollDOM.dispatchEvent(new Event('scroll'));
              view.requestMeasure();
              return { done: true };
            })()
            """)
            try await Task.sleep(for: .milliseconds(100))
            var snap = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const cursor = view.scrollDOM.querySelector('.cm-cursor');
              const head = view.state.selection.main.head;
              const coords = view.coordsAtPos(head, 1);
              const scrollRect = view.scrollDOM.getBoundingClientRect();
              const cursorRect = cursor ? cursor.getBoundingClientRect() : null;
              return {
                head,
                scrollTop: view.scrollDOM.scrollTop,
                scrollRectLeft: scrollRect.left,
                scrollRectTop: scrollRect.top,
                coordsLeft: coords?.left,
                coordsTop: coords?.top,
                cursorLeft: cursorRect?.left,
                cursorTop: cursorRect?.top,
                cursorWidth: cursorRect?.width,
                cursorHeight: cursorRect?.height,
                cursorCSSLeft: cursor?.style.left,
                cursorCSSTop: cursor?.style.top,
                cursorDisplay: cursor ? getComputedStyle(cursor).display : null
              };
            })()
            """)
            snap["name"] = item.name
            // The drawn caret's screen rect must match the caret's viewport
            // coordinates (coordsAtPos), whether or not the scroller moved.
            let cursorLeft = try #require(snap["cursorLeft"] as? Double)
            let cursorTop = try #require(snap["cursorTop"] as? Double)
            let coordsLeft = try #require(snap["coordsLeft"] as? Double)
            let coordsTop = try #require(snap["coordsTop"] as? Double)
            #expect(abs(cursorLeft - coordsLeft) < 2,
                    Comment(rawValue: "\(item.name) cursorLeft \(cursorLeft) vs \(coordsLeft)"))
            #expect(abs(cursorTop - coordsTop) < 2,
                    Comment(rawValue: "\(item.name) cursorTop \(cursorTop) vs \(coordsTop)"))
            #expect((snap["cursorDisplay"] as? String) == "block")
        }
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

extension MarkdownDrawnCaretPositionTests {
    @Test @MainActor func drawnCaretTracksCaretInTypewriterMode() async throws {
        let longDoc = (1...80).map { "line \($0) content" }.joined(separator: "\n")
        let controller = try await makeController(markdown: longDoc, width: 520)
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          window.__mdEditor._followTypewriterForTesting();
          view.dispatch({ selection: { anchor: 400 }, scrollIntoView: true });
          view.scrollDOM.dispatchEvent(new Event('scroll'));
          view.requestMeasure();
          return { done: true };
        })()
        """)
        for _ in 0..<6 {
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              window.__mdEditor._viewForTesting.requestMeasure();
              return { ok: true };
            })()
            """)
            try await Task.sleep(for: .milliseconds(100))
        }
        let snap = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const all = [...document.getElementsByClassName('cm-cursor')];
          const cursor = all[0] ?? null;
          const layer = view.scrollDOM.querySelector('.cm-cursorLayer');
          const head = view.state.selection.main.head;
          const coords = view.coordsAtPos(head, 1);
          const rect = cursor ? cursor.getBoundingClientRect() : null;
          return {
            scrollTop: view.scrollDOM.scrollTop,
            head,
            coordsLeft: coords?.left,
            coordsTop: coords?.top,
            cursorLeft: rect?.left,
            cursorTop: rect?.top,
            cursorCount: all.length,
            layerExists: !!layer
          };
        })()
        """)
        print("TYPEWRITER-CURSOR:", snap)
        #expect((snap["scrollTop"] as? Double ?? 0) > 100)
        #expect(snap["cursorCount"] as? Int == 1)
        let cursorLeft = try #require(snap["cursorLeft"] as? Double)
        let cursorTop = try #require(snap["cursorTop"] as? Double)
        let coordsLeft = try #require(snap["coordsLeft"] as? Double)
        let coordsTop = try #require(snap["coordsTop"] as? Double)
        #expect(abs(cursorLeft - coordsLeft) < 2)
        #expect(abs(cursorTop - coordsTop) < 2)
    }
}
