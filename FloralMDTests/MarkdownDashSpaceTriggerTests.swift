import Cocoa
import Testing
import WebKit

@testable import FloralMD

/// A bare "-" (or "*" / "+") at the start of a line must stay plain editable
/// text until a space follows; only "- " enters the rendered list state.
/// While an input method composes next to a rendered list marker, the marker
/// must be a plain inline text run so WebKit does not present the macOS
/// candidate window vertically.
@Suite(.serialized)
struct MarkdownDashSpaceTriggerTests {
    // MARK: - Bare marker stays plain

    @Test @MainActor func bareDashStaysPlainUntilSpaceFollows() async throws {
        let controller = try await makeController(markdown: "", width: 520)
        try await focusAndPlaceCaret(at: 0, in: controller)
        try await type("-", in: controller)

        var line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "-")
        #expect((line["className"] as? String)?.contains("cm-md-list-item") != true)
        #expect(line["bulletSource"] as? Bool == false)
        #expect(line["bulletPreview"] as? Bool == false)
        #expect(line["composing"] as? Bool == false)

        try await type(" ", in: controller)
        line = try await lineSnapshot(controller)
        // The active caret line hides the separator space behind the marker,
        // so the visible text is the marker itself.
        #expect(line["text"] as? String == "-")
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        #expect(line["bulletSource"] as? Bool == true)
        #expect(line["bulletPreview"] as? Bool == false)
        #expect(line["composing"] as? Bool == false)
        #expect(try await markdown(in: controller) == "- ")
    }

    @Test @MainActor func bareMarkersStayPlainAcrossVariants() async throws {
        let cases: [(marker: String, expectedRender: Bool)] = [
            ("-", false),
            ("- ", true),
            ("-x", false),
            ("*", false),
            ("* ", true),
            ("+", false),
            ("+ ", true),
        ]
        for item in cases {
            let controller = try await makeController(markdown: item.marker, width: 520)
            try await focusAndPlaceCaret(at: item.marker.utf16.count, in: controller)
            let line = try await lineSnapshot(controller)
            let rendered = (line["className"] as? String)?.contains("cm-md-list-item") == true
            #expect(
                rendered == item.expectedRender,
                Comment(rawValue: "marker \(item.marker.debugDescription): rendered=\(rendered)")
            )
        }
    }

    // MARK: - Composition next to a marker

    @Test @MainActor func compositionAfterDashSpaceKeepsStableBoxAndColumn() async throws {
        let controller = try await makeController(markdown: "- ", width: 520)
        try await focusAndPlaceCaret(at: 2, in: controller)

        // Baseline: the active caret line shows the hanging box and hides the
        // separator space behind a zero-width replacement widget.
        var line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "-")
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        #expect(line["bulletSource"] as? Bool == true)
        #expect(line["composing"] as? Bool == false)
        #expect(line["spaceHiddenAsMark"] as? Bool == false)
        #expect((line["widgetBufferCount"] as? Int ?? 0) >= 1)
        let baselineMarkerLeft = try #require(number(line["markerLeft"]))
        let fontSize = try #require(number(line["lineFontSize"]))

        // Composition must not swap the marker decoration, and the separator
        // must stop being a replacement widget: WebKit rebuilds cm-widgetBuffer
        // nodes around the composition range on every keystroke, which breaks
        // IME input (swallowed characters, caret artifacts, occasional
        // vertical candidate windows). A zero-font mark keeps the exact same
        // geometry without being a widget.
        try await startComposition(inserting: "n", in: controller)
        line = try await lineSnapshot(controller)
        // The separator space stays in the DOM as a zero-font mark (invisible,
        // no width), so the composed text starts right at the box end.
        #expect(line["text"] as? String == "- n")
        #expect(line["composing"] as? Bool == false)
        #expect((line["className"] as? String)?.contains("cm-md-list-item") == true)
        #expect(line["bulletSource"] as? Bool == true)
        #expect(line["spaceHiddenAsMark"] as? Bool == true)
        #expect(line["widgetBufferCount"] as? Int == 0)
        #expect(line["composedTextInMarker"] as? Bool == false)
        #expect(try await markdown(in: controller) == "- n")

        // The composed text starts at the item body column (box end) and stays
        // exactly there while pinyin grows, character by character.
        let bodyTarget = baselineMarkerLeft + fontSize * 1.6
        var previousLeft = try #require(number(line["composedTextLeft"]))
        #expect(
            abs(previousLeft - bodyTarget) < 1,
            Comment(rawValue: "composedLeft=\(previousLeft) target=\(bodyTarget)")
        )
        for ch in ["i", "h", "a", "o"] {
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.contentDOM.dispatchEvent(new CompositionEvent('compositionupdate', {
                data: \(jsString(ch)), bubbles: true
              }));
              const pos = view.state.selection.main.head;
              view.dispatch({
                changes: { from: pos, to: pos, insert: \(jsString(ch)) },
                selection: { anchor: pos + 1 },
                userEvent: 'input.type',
                scrollIntoView: true
              });
              view.contentDOM.dispatchEvent(new InputEvent('input', {
                inputType: 'insertCompositionText', data: \(jsString(ch)), bubbles: true,
                isComposing: true
              }));
              return { inserted: \(jsString(ch)) };
            })()
            """)
            try await Task.sleep(for: .milliseconds(24))
            line = try await lineSnapshot(controller)
            #expect(line["bulletSource"] as? Bool == true)
            #expect(line["composing"] as? Bool == false)
            let left = try #require(number(line["composedTextLeft"]))
            #expect(
                abs(left - previousLeft) < 0.5,
                Comment(rawValue: "bounce after \(ch): left=\(left) previous=\(previousLeft)")
            )
            previousLeft = left
        }
        #expect(try await markdown(in: controller) == "- nihao")
    }

    @Test @MainActor func compositionAfterTaskMarkerSuppressesCheckboxWidget() async throws {
        let controller = try await makeController(markdown: "- [ ] x", width: 520)
        try await focusAndPlaceCaret(at: 7, in: controller)

        // Baseline: the task checkbox replacement widget is present.
        var line = try await lineSnapshot(controller)
        #expect((line["taskCheckboxCount"] as? Int ?? 0) == 1)

        // While composing, the checkbox widget must not be emitted at all
        // (WebKit rebuilds widgets around composition and breaks IME input).
        try await startComposition(inserting: "n", in: controller)
        line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "- [ ] xn")
        #expect(line["taskCheckboxCount"] as? Int == 0)
        #expect(line["widgetBufferCount"] as? Int == 0)
        #expect(try await markdown(in: controller) == "- [ ] xn")
    }

    @Test @MainActor func compositionAfterBareDashStaysPlainParagraph() async throws {
        let controller = try await makeController(markdown: "-", width: 520)
        try await focusAndPlaceCaret(at: 1, in: controller)
        try await startComposition(inserting: "ni", in: controller)

        let line = try await lineSnapshot(controller)
        #expect(line["text"] as? String == "-ni")
        #expect((line["className"] as? String)?.contains("cm-md-list-item") != true)
        #expect(line["bulletSource"] as? Bool == false)
        #expect(line["composing"] as? Bool == false)
        #expect(line["composingMarkerText"] as? String == nil)
        #expect(try await markdown(in: controller) == "-ni")
    }

    // MARK: - Enter continuation

    @Test @MainActor func dashSpaceEnterContinuesListButBareDashDoesNot() async throws {
        // A non-empty item continues with a fresh "- " marker on Enter.
        let continued = try await makeController(markdown: "- abc", width: 520)
        try await focusAndPlaceCaret(at: 5, in: continued)
        let (continuedWebView, continuedWindow) = try await hostInWindow(continued)
        defer { continuedWindow.close() }
        try await dispatchEnter(in: continuedWebView)
        let continuedText = try await markdown(in: continued)
        #expect(
            continuedText == "- abc\n- ",
            Comment(rawValue: "expected list continuation, got \(continuedText.debugDescription)")
        )

        // A bare "-" is a plain paragraph: Enter just splits the line.
        let plain = try await makeController(markdown: "-", width: 520)
        try await focusAndPlaceCaret(at: 1, in: plain)
        let (plainWebView, plainWindow) = try await hostInWindow(plain)
        defer { plainWindow.close() }
        try await dispatchEnter(in: plainWebView)
        let plainText = try await markdown(in: plain)
        #expect(
            plainText == "-\n",
            Comment(rawValue: "expected a plain newline, got \(plainText.debugDescription)")
        )
    }

    // MARK: - Harness

    @MainActor
    private func type(_ character: String, in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const position = view.state.selection.main.head;
          view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
            key: \(jsString(character)), bubbles: true, isComposing: false
          }));
          view.dispatch({
            changes: { from: position, to: position, insert: \(jsString(character)) },
            selection: { anchor: position + \(character.utf16.count) },
            userEvent: 'input.type',
            scrollIntoView: true
          });
          view.contentDOM.dispatchEvent(new InputEvent('input', {
            inputType: 'insertText', data: \(jsString(character)), bubbles: true,
            isComposing: false
          }));
          return { typed: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(40))
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
        try await Task.sleep(for: .milliseconds(40))
    }

    @MainActor
    private func startComposition(
        inserting text: String,
        in controller: CodeMirrorEditorViewController
    ) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          window.__mdEditor._setCompositionActiveForTesting(true);
          view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
          const position = view.state.selection.main.head;
          view.dispatch({
            changes: { from: position, to: position, insert: \(jsString(text)) },
            selection: { anchor: position + \(text.utf16.count) },
            userEvent: 'input.type',
            scrollIntoView: true
          });
          return { composing: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(60))
    }

    @MainActor
    private func lineSnapshot(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> [String: Any] {
        try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const line = view.contentDOM.querySelector('.cm-line');
          const composingMarker = line?.querySelector('.cm-md-bullet-composing');
          const marker = composingMarker ?? line?.querySelector('.cm-md-bullet-source');
          const caret = view.coordsAtPos(view.state.selection.main.head, 1);
          const bodyLeft = caret?.left;
          let composedTextInMarker = false;
          let composedTextLeft = null;
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node = walker.nextNode();
          while (node) {
            const text = node.textContent;
            const insideBox = node.parentElement?.closest('.cm-md-bullet-source') != null;
            if (text && text.trim().length > 0 && !insideBox) {
              composedTextInMarker =
                node.parentElement?.closest('.cm-md-bullet-composing') != null;
              const first = text.search(/\\S/);
              if (first >= 0) {
                const range = document.createRange();
                range.setStart(node, first);
                range.setEnd(node, text.length);
                composedTextLeft = range.getBoundingClientRect().left;
              }
              break;
            }
            node = walker.nextNode();
          }
          return {
            text: line?.textContent,
            className: line?.className,
            bulletSource: !!line?.querySelector('.cm-md-bullet-source'),
            bulletPreview: !!line?.querySelector('.cm-md-bullet'),
            composing: !!composingMarker,
            composingMarkerText: composingMarker?.textContent ?? null,
            composingDisplay: composingMarker ? getComputedStyle(composingMarker).display : null,
            spaceHiddenAsMark: !!line?.querySelector('.cm-md-bullet-space-hidden'),
            taskCheckboxCount: line?.querySelectorAll('.cm-md-task-checkbox').length ?? 0,
            widgetBufferCount: line?.querySelectorAll('.cm-widgetBuffer').length ?? 0,
            composedTextInMarker,
            bodyLeft,
            composedTextLeft,
            markerLeft: marker?.getBoundingClientRect().left ?? null,
            markerRight: marker?.getBoundingClientRect().right ?? null,
            lineFontSize: line ? parseFloat(getComputedStyle(line).fontSize) : null,
            caretHead: view.state.selection.main.head
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
    private func hostInWindow(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> (WKWebView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (try #require(controller.view as? WKWebView), window)
    }

    @MainActor
    private func dispatchEnter(in webView: WKWebView) async throws {
        let window = try #require(webView.window)
        window.makeFirstResponder(webView)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        webView.keyDown(with: event)
        try await Task.sleep(for: .milliseconds(120))
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

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? .nan
    }

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
