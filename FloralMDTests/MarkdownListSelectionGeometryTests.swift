import Cocoa
import Testing

@testable import FloralMD

@Suite(.serialized)
struct MarkdownListSelectionGeometryTests {
    @Test @MainActor func selectingListBodyDoesNotMoveItsTextColumn() async throws {
        let markdown = "- Alpha beta"
        let controller = try await makeController(markdown: markdown, width: 520)
        let bodyFrom = markdown.utf16Offset(of: "Alpha")
        let bodyTo = bodyFrom + "Alpha".utf16.count

        let setup = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          return { ready: true };
        })()
        """)
        #expect(setup["ready"] as? Bool == true)

        var samples = [try await sample(controller, label: "caret", position: bodyFrom)]
        samples.append(try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.dispatch({
            selection: { anchor: \(bodyFrom), head: \(bodyTo) },
            userEvent: 'select.pointer'
          });
          return window.__mdListGeometrySample('selection-dispatch', \(bodyFrom));
        })()
        """))
        try await Task.sleep(for: .milliseconds(20))
        samples.append(try await sample(controller, label: "selection-frame-1", position: bodyFrom))
        try await Task.sleep(for: .milliseconds(20))
        samples.append(try await sample(controller, label: "selection-frame-2", position: bodyFrom))
        samples.append(try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.dispatch({ selection: { anchor: \(bodyTo) }, userEvent: 'select.pointer' });
          return window.__mdListGeometrySample('collapse-dispatch', \(bodyFrom));
        })()
        """))
        try await Task.sleep(for: .milliseconds(20))
        samples.append(try await sample(controller, label: "collapse-frame-1", position: bodyFrom))

        let baseline = try #require(samples.first)
        let baselineLeft = number(baseline["textLeft"])
        let detailsData = try JSONSerialization.data(withJSONObject: samples)
        let details = String(decoding: detailsData, as: UTF8.self)

        for sample in samples.dropFirst() {
            #expect(
                abs(number(sample["textLeft"]) - baselineLeft) < 0.5,
                Comment(rawValue: details)
            )
            #expect(number(sample["scrollLeft"]) == 0, Comment(rawValue: details))
        }
    }

    @Test @MainActor func listSelectionGeometryMatrixKeepsBodyAndViewportStable() async throws {
        let cases: [(name: String, markdown: String, body: String, anchor: Int, head: Int,
                     width: CGFloat, typewriter: Bool, expectsMarker: Bool)] = [
            ("paragraph", "Alpha beta", "Alpha", 0, 5, 520, false, false),
            ("dash", "- Alpha beta", "Alpha", 3, 8, 520, false, true),
            ("asterisk-reverse", "* Alpha beta", "Alpha", 8, 3, 520, false, true),
            ("plus-cross-marker", "+ Alpha beta", "Alpha", 0, 8, 520, false, true),
            ("multiple-items", "- Alpha\n- Beta\n- Gamma", "Alpha", 3, 22, 520, false, true),
            ("nested-chinese-reverse", "- Parent\n  * 嵌套中文项目", "嵌套", 19, 13, 520, false, true),
            ("command-a", "- Alpha\n- Beta", "Alpha", 0, 14, 520, false, true),
            ("soft-wrap-chinese", "- 很长的中文内容用于验证软换行时正文列与后续视觉行都不发生位移。很长的中文内容继续。",
             "很长", 3, 35, 240, false, true),
            ("typewriter-forward", "- Alpha beta", "Alpha", 3, 8, 520, true, true),
            ("typewriter-reverse", "+ 中文选择内容", "中文", 8, 2, 520, true, true),
        ]

        for item in cases {
            let controller = try await makeController(
                markdown: item.markdown,
                width: item.width,
                typewriterModeEnabled: item.typewriter
            )
            let bodyPosition = item.markdown.utf16Offset(of: item.body)
            _ = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.focus();
              view.dom.classList.add('cm-focused');
              view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              view.dispatch({ selection: { anchor: \(bodyPosition) } });
              return { ready: true };
            })()
            """)
            try await Task.sleep(for: .milliseconds(20))
            let baseline = try await sample(
                controller, label: "\(item.name)-caret", position: bodyPosition
            )
            let selected = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.dispatch({
                selection: { anchor: \(item.anchor), head: \(item.head) },
                userEvent: 'select.pointer'
              });
              return window.__mdListGeometrySample('\(item.name)-dispatch', \(bodyPosition));
            })()
            """)
            try await Task.sleep(for: .milliseconds(20))
            let settled = try await sample(
                controller, label: "\(item.name)-frame", position: bodyPosition
            )
            let details = "\(item.name): baseline=\(baseline), selected=\(selected), settled=\(settled)"

            for result in [selected, settled] {
                #expect(
                    abs(number(result["textLeft"]) - number(baseline["textLeft"])) < 0.5,
                    Comment(rawValue: details)
                )
                #expect(
                    abs(number(result["textTop"]) - number(baseline["textTop"])) < 0.5,
                    Comment(rawValue: details)
                )
                #expect(number(result["scrollLeft"]) == 0, Comment(rawValue: details))
                #expect(number(result["lineWidth"]) == number(baseline["lineWidth"]),
                        Comment(rawValue: details))
            }
            if item.expectsMarker {
                #expect(selected["sourceMarkerCount"] as? Int == 1, Comment(rawValue: details))
                #expect((selected["markerText"] as? String)?.hasSuffix(" ") == true,
                        Comment(rawValue: details))
            } else {
                #expect(selected["sourceMarkerCount"] as? Int == 0, Comment(rawValue: details))
            }
            #expect(try await markdown(in: controller) == item.markdown)
        }
    }

    @MainActor
    private func sample(
        _ controller: CodeMirrorEditorViewController,
        label: String,
        position: Int
    ) async throws -> [String: Any] {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          window.__mdListGeometrySample = (label, position) => {
            const view = window.__mdEditor._viewForTesting;
            const positionDOM = view.domAtPos(position).node;
            const positionElement = positionDOM.nodeType === Node.ELEMENT_NODE
              ? positionDOM : positionDOM.parentElement;
            const line = positionElement?.closest('.cm-line');
            const marker = line?.querySelector('.cm-md-bullet, .cm-md-bullet-source');
            const text = view.coordsAtPos(position, 1);
            const lineRect = line?.getBoundingClientRect();
            const markerRect = marker?.getBoundingClientRect();
            return {
              label,
              textLeft: text?.left,
              textRight: text?.right,
              textTop: text?.top,
              markerLeft: markerRect?.left,
              markerRight: markerRect?.right,
              markerWidth: markerRect?.width,
              markerText: marker?.textContent,
              lineLeft: lineRect?.left,
              lineRight: lineRect?.right,
              lineWidth: lineRect?.width,
              scrollLeft: view.scrollDOM.scrollLeft,
              scrollTop: view.scrollDOM.scrollTop,
              sourceMarkerCount: line?.querySelectorAll('.cm-md-bullet-source').length ?? 0,
              previewMarkerCount: line?.querySelectorAll('.cm-md-bullet').length ?? 0,
              textContent: line?.textContent
            };
          };
          return { installed: true };
        })()
        """)
        return try await evaluateDictionary(
            controller,
            script: "window.__mdListGeometrySample(\(jsString(label)), \(position))"
        )
    }

    @MainActor
    private func makeController(
        markdown: String,
        width: CGFloat,
        typewriterModeEnabled: Bool = false
    ) async throws
        -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        controller.load(markdown: markdown, typewriterModeEnabled: typewriterModeEnabled)
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

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? .nan
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

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

private extension String {
    func utf16Offset(of needle: String) -> Int {
        let range = range(of: needle)!
        return utf16.distance(from: utf16.startIndex, to: range.lowerBound.samePosition(in: utf16)!)
    }
}
