import Cocoa
import Testing

@testable import FloralMD

/// Probe: after a Backspace/delete, does CodeMirror's own cursor layer leave
/// a stale .cm-cursor element behind? (A stale element would render as a
/// fixed phantom caret until the next redraw.)
@Suite(.serialized)
struct MarkdownCaretResidueTests {
    @Test @MainActor func drawnCaretStaysSingleAndFollowsCaretAfterDelete() async throws {
        let cases: [(name: String, markdown: String, from: Int, to: Int)] = [
            ("delete-range-paragraph", "abcdef", 2, 4),
            ("backspace-char-list", "- item", 6, 6),
            ("delete-range-list", "- item", 2, 4),
            ("delete-range-code", "    - item", 6, 8),
        ]
        for item in cases {
            let controller = try await makeController(markdown: item.markdown, width: 520)
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.focus();
              view.dom.classList.add('cm-focused');
              view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              view.dispatch({
                selection: { anchor: \(item.from), head: \(item.to) },
                scrollIntoView: true
              });
              return { ready: true };
            })()
            """)
            try await Task.sleep(for: .milliseconds(60))

            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const head = view.state.selection.main.head;
              view.dispatch({
                changes: { from: \(item.from), to: \(item.to), insert: '' },
                selection: { anchor: \(item.from) },
                userEvent: 'delete.backward'
              });
              return { head: \(item.from) };
            })()
            """)

            // Manually force a measure pass to see whether the cursor layer
            // draws at all.
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const head = view.state.selection.main.head;
              const coords = view.coordsAtPos(head, 1);
              window.__probeCoords = coords ? { left: coords.left, top: coords.top,
                right: coords.right, bottom: coords.bottom } : null;
              view.requestMeasure();
              return { coords: window.__probeCoords };
            })()
            """)
            try await Task.sleep(for: .milliseconds(80))
            let manualProbe = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const cursors = [...view.scrollDOM.querySelectorAll('.cm-cursorLayer .cm-cursor')];
              return {
                coords: window.__probeCoords,
                cursorCount: cursors.length,
                layerHTML: view.scrollDOM.querySelector('.cm-cursorLayer')?.innerHTML ?? null
              };
            })()
            """)

            var snaps: [[String: Any]] = []
            snaps.append(["manual": manualProbe])
            for (label, delay) in [("t0", 0), ("t16", 16), ("t64", 64), ("t300", 300)] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                let snap = try await evaluateDictionary(controller, script: """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const cursors = [...view.scrollDOM.querySelectorAll('.cm-cursorLayer .cm-cursor')];
                  const layer = view.scrollDOM.querySelector('.cm-cursorLayer');
                  return {
                    label: \(jsString(label)),
                    doc: view.state.doc.toString(),
                    head: view.state.selection.main.head,
                    cursorCount: cursors.length,
                    cursorPositions: cursors.map(c => {
                      const r = c.getBoundingClientRect();
                      return { left: r.left, top: r.top, width: r.width, height: r.height, display: getComputedStyle(c).display };
                    }),
                    layerDisplay: layer ? getComputedStyle(layer).display : null
                  };
                })()
                """)
                snaps.append(snap)
            }
            // The drawn caret must exist exactly once, at the caret position,
            // at every sampled frame after the delete.
            let manual = try #require(snaps.first?["manual"] as? [String: Any])
            #expect((manual["cursorCount"] as? Int) == 1,
                    Comment(rawValue: "\(item.name) manual cursorCount"))
            let coords = try #require(manual["coords"] as? [String: Any])
            let expectedLeft = try #require(coords["left"] as? Double)
            #expect((manual["layerHTML"] as? String)?.contains("cm-cursor") == true)
            for snap in snaps.dropFirst() {
                let count = snap["cursorCount"] as? Int ?? -1
                #expect(count == 1, Comment(rawValue: "\(item.name) \(snap["label"] ?? "") count \(count)"))
                let positions = snap["cursorPositions"] as? [[String: Any]] ?? []
                if let position = positions.first, let left = position["left"] as? Double {
                    #expect(
                        abs(left - expectedLeft) < 2,
                        Comment(rawValue: "\(item.name) \(snap["label"] ?? "") left \(left) vs \(expectedLeft)")
                    )
                }
            }
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

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
