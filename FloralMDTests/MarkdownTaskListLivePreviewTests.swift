import AppKit
import Cocoa
import Testing
import WebKit

@testable import FloralMD

/// Task-list live-preview regressions:
/// - IME composition must be line-local: composing on one line only reveals
///   that line's task marker as raw `- [ ]` source; every other task list in
///   the document keeps its rendered checkbox widget.
/// - The checked checkbox's check mark must be vertically centered inside
///   its box in both states (no font-metric drift).
@Suite(.serialized)
struct MarkdownTaskListLivePreviewTests {
    // MARK: - Composition is line-local, not document-wide

    @Test @MainActor func compositionOnOneTaskLineKeepsOtherTaskLinesRendered() async throws {
        let controller = try await makeController(markdown: "- [ ] first\n- [ ] second", width: 520)
        // Caret at the end of line 2 (after the marker range [12, 18)).
        try await focusAndPlaceCaret(at: 24, in: controller)

        // Baseline: both lines render a checkbox widget.
        var counts = try await taskCheckboxCounts(controller)
        #expect(counts == [1, 1])

        // Composing on line 2 must only reveal line 2's marker: line 1's
        // checkbox stays rendered instead of reverting to raw `- [ ]` for the
        // whole document during the composition.
        try await startComposition(inserting: "n", in: controller)
        counts = try await taskCheckboxCounts(controller)
        #expect(counts == [1, 0])

        // Ending the composition restores every widget.
        try await endComposition(in: controller)
        counts = try await taskCheckboxCounts(controller)
        #expect(counts == [1, 1])
        #expect(try await markdown(in: controller) == "- [ ] first\n- [ ] secondn")
    }

    @Test @MainActor func compositionOnProseLineKeepsAllTaskCheckboxes() async throws {
        let controller = try await makeController(markdown: "plain text\n- [ ] item", width: 520)
        try await focusAndPlaceCaret(at: 2, in: controller)
        try await startComposition(inserting: "n", in: controller)
        let counts = try await taskCheckboxCounts(controller)
        #expect(counts == [0, 1])
        try await endComposition(in: controller)
        #expect(try await taskCheckboxCounts(controller) == [0, 1])
    }

    @Test @MainActor func plainTypingKeepsAllTaskCheckboxes() async throws {
        // Without an input method, typing never reveals other lines' markers.
        let controller = try await makeController(markdown: "plain\n- [ ] item", width: 520)
        try await focusAndPlaceCaret(at: 2, in: controller)
        try await type("x", in: controller)
        #expect(try await taskCheckboxCounts(controller) == [0, 1])
    }

    // MARK: - Checked-state vertical centering

    @Test @MainActor func taskCheckboxCheckIsVerticallyCenteredInBothStates() async throws {
        let controller = try await makeController(markdown: "- [ ] aa\n- [x] bb", width: 520)
        // Caret on line 2's body text at 16 (after the checked marker range
        // [9, 15)), so both widgets stay rendered.
        try await focusAndPlaceCaret(at: 16, in: controller)
        try await Task.sleep(for: .milliseconds(80))

        let metrics = try await checkboxMetrics(controller)
        #expect(metrics.boxes.count == 2)
        let textCenterY = try #require(metrics.textCenterY)
        let unchecked = metrics.boxes[0]
        let checked = metrics.boxes[1]

        // Both boxes keep the same geometry in the two states…
        #expect(
            abs(unchecked.width - checked.width) < 0.5,
            Comment(rawValue: "uncheckedW=\(unchecked.width) checkedW=\(checked.width)")
        )
        #expect(
            abs(unchecked.height - checked.height) < 0.5,
            Comment(rawValue: "uncheckedH=\(unchecked.height) checkedH=\(checked.height)")
        )
        // …each vertically centered on its own line's text. The unchecked
        // state carries the baseline `vertical-align: -0.12em` nudge, so
        // compare the two states' offsets from their own line centers — the
        // checked state must not add any extra downward shift (the old glyph
        // grid item pushed the whole box ~7px lower).
        let uncheckedOffset = unchecked.centerY - unchecked.lineCenterY
        let checkedOffset = checked.centerY - checked.lineCenterY
        #expect(
            abs(uncheckedOffset) < 1.5,
            Comment(rawValue: "uncheckedOffset=\(uncheckedOffset)")
        )
        #expect(
            abs(checkedOffset) < 1.5,
            Comment(rawValue: "checkedOffset=\(checkedOffset)")
        )
        #expect(
            abs(checkedOffset - uncheckedOffset) < 0.75,
            Comment(rawValue: "uncheckedOffset=\(uncheckedOffset) checkedOffset=\(checkedOffset)")
        )
        // …and the caret line's text center matches that line's box.
        #expect(
            abs(checked.lineCenterY - textCenterY) < 1.5,
            Comment(rawValue: "lineCenter=\(checked.lineCenterY) textCenter=\(textCenterY)")
        )

        // The checked state's check ink must be vertically centered inside its
        // box: the glyph previously sat visibly low because its ink is not
        // centered in its own line box (font metrics), unlike the box.
        let webView = try #require(controller.view as? WKWebView)
        let snapshot = try await snapshot(of: webView)
        let scale = Double(try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)).width)
            / Double(max(webView.bounds.width, 1))
        let ink = try checkInkBoundingBox(in: snapshot, cssRect: checked, scale: scale)
        let inkCenterY = (ink.top + ink.bottom) / 2
        #expect(
            abs(inkCenterY - checked.centerY) <= 0.75,
            Comment(rawValue: "inkCenter=\(inkCenterY) boxCenter=\(checked.centerY) count=\(ink.count)")
        )
        #expect(
            abs(ink.centerX - checked.centerX) <= 0.75,
            Comment(rawValue: "inkCenterX=\(ink.centerX) boxCenterX=\(checked.centerX)")
        )
    }

    // MARK: - Harness

    @MainActor
    private func type(_ character: String, in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const position = view.state.selection.main.head;
          view.dispatch({
            changes: { from: position, to: position, insert: \(jsString(character)) },
            selection: { anchor: position + \(character.utf16.count) },
            userEvent: 'input.type',
            scrollIntoView: true
          });
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
    private func endComposition(in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
          window.__mdEditor._setCompositionActiveForTesting(false);
          return { ended: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(60))
    }

    @MainActor
    private func taskCheckboxCounts(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> [Int] {
        let value = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          return Array.from(view.contentDOM.querySelectorAll('.cm-line')).map(
            (line) => line.querySelectorAll('.cm-md-task-checkbox').length
          );
        })()
        """)
        let counts = try #require(value["__return"] as? [Int])
        return counts
    }

    private struct CheckboxMetrics {
        struct Box {
            let left: Double, top: Double, right: Double, bottom: Double
            let lineCenterY: Double
            var centerY: Double { (top + bottom) / 2 }
            var centerX: Double { (left + right) / 2 }
            var width: Double { right - left }
            var height: Double { bottom - top }
        }

        let boxes: [Box]
        let textCenterY: Double?
    }

    @MainActor
    private func checkboxMetrics(
        _ controller: CodeMirrorEditorViewController
    ) async throws -> CheckboxMetrics {
        let value = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const boxes = Array.from(
            view.contentDOM.querySelectorAll('.cm-md-task-checkbox')
          ).map((box) => {
            const rect = box.getBoundingClientRect();
            const line = box.closest('.cm-line');
            const linePos = line ? view.posAtDOM(line, 0) : null;
            const caret = view.coordsAtPos(linePos, 1);
            return {
              left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
              lineCenterY: caret ? (caret.top + caret.bottom) / 2 : null
            };
          });
          const caret = view.coordsAtPos(view.state.selection.main.head, 1);
          return {
            boxes: boxes,
            caret: caret ? { top: caret.top, bottom: caret.bottom } : null
          };
        })()
        """)
        let rawBoxes = try #require(value["boxes"] as? [[String: Any]])
        let boxes = rawBoxes.map { raw in
            CheckboxMetrics.Box(
                left: number(raw["left"]),
                top: number(raw["top"]),
                right: number(raw["right"]),
                bottom: number(raw["bottom"]),
                lineCenterY: number(raw["lineCenterY"])
            )
        }
        let caret = value["caret"] as? [String: Any]
        let textCenterY = caret.map {
            (number($0["top"]) + number($0["bottom"])) / 2
        }
        return CheckboxMetrics(boxes: boxes, textCenterY: textCenterY)
    }

    private struct InkBox {
        let top: Double, bottom: Double
        let left: Double, right: Double
        let count: Int
        var centerX: Double { (left + right) / 2 }
    }

    private enum PixelProbeError: Error {
        case noImage
        case noInk
    }

    private func snapshot(of webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? PixelProbeError.noImage)
                }
            }
        }
    }

    /// Scans the snapshot pixels inside `cssRect` (CSS viewport coordinates)
    /// for the white check stroke and returns its bounding box in CSS
    /// coordinates, plus the number of ink pixels found.
    private func checkInkBoundingBox(
        in image: NSImage,
        cssRect: CheckboxMetrics.Box,
        scale: Double
    ) throws -> InkBox {
        guard scale >= 1,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw PixelProbeError.noImage }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PixelProbeError.noImage }
        // Flip so buffer row 0 is the top row, matching CSS y-down coords.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Stay inside the border ring (1.5pt) so only the blue fill and the
        // white stroke are scanned.
        let inset = 3.0 * scale
        let x0 = Int(floor(cssRect.left * scale + inset))
        let x1 = Int(ceil(cssRect.right * scale - inset))
        let y0 = Int(floor(cssRect.top * scale + inset))
        let y1 = Int(ceil(cssRect.bottom * scale - inset))
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var count = 0
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) {
                let index = (y * width + x) * 4
                let r = bytes[index]
                let g = bytes[index + 1]
                let b = bytes[index + 2]
                // Near-white: the check stroke over the blue fill. The fill's
                // blue channel stays far below 170, so antialiased edge
                // blends are excluded.
                if r > 170 && g > 170 && b > 170 {
                    count += 1
                    minX = min(minX, Double(x))
                    maxX = max(maxX, Double(x))
                    minY = min(minY, Double(y))
                    maxY = max(maxY, Double(y))
                }
            }
        }
        guard count > 0 else { throw PixelProbeError.noInk }
        return InkBox(
            top: (minY + 0.5) / scale,
            bottom: (maxY + 0.5) / scale,
            left: (minX + 0.5) / scale,
            right: (maxX + 0.5) / scale,
            count: count
        )
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
        let wrapped = "(function(){ const __result = \(script); return { __return: __result }; })()"
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError(wrapped) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
        let dictionary = try #require(value as? [String: Any])
        // `__return` may itself be a [String: Any] from a bridging dictionary,
        // or a scalar; unwrap the common cases.
        if let direct = dictionary["__return"] as? [String: Any] {
            return direct
        }
        if let scalar = dictionary["__return"] as? [Int] {
            return ["__return": scalar]
        }
        return dictionary
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
