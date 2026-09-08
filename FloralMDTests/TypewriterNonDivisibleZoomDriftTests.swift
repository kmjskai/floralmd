import AppKit
import Foundation
import Testing
import WebKit
@testable import FloralMD

// Typewriter semantics are enter-only: plain typing never touches the
// scroll (no alignment, no quantization drift, no jitter), and Enter
// realigns the caret to the comfort target. These tests pin that
// contract at pageZoom != 1 with mixed line heights.
@Suite(.serialized)
@MainActor
struct TypewriterNonDivisibleZoomDriftTests {
    @Test func enterRealignsCaretAtNonDivisibleZoom() async throws {
        let base = [
            "# 标题一",
            "## 标题二",
            "- 列表项 one",
            "- 列表项 two with more text",
            "> 引用块",
            "```swift",
            "let x = 1",
            "```",
            "普通段落 with some prose text here.",
        ].joined(separator: "\n\n")
        // EXPERIMENT (codex/typewriter-no-padding): without bottom headroom
        // the last lines clamp, so pad the document to keep the prose
        // paragraph out of the clamped bottom region.
        let markdown = base + "\n\n" + (1...20).map { "补充段落 \($0)" }.joined(separator: "\n\n")
        let paragraphStart = markdown.range(of: "普通段落")!.lowerBound.utf16Offset(in: markdown)
        let offset = paragraphStart + 6
        for zoom in [1.5, 2.0] {
            let harness = try await makeHarness(markdown: markdown, zoom: zoom)
            _ = try await harness.evaluate(
                "window.__mdEditor.select(\(offset)); window.__mdEditor._followTypewriterForTesting()",
                in: harness.webView
            )
            try await Task.sleep(for: .milliseconds(400))

            var maxDeviation = 0.0
            for _ in 0..<8 {
                // Plain typing then Enter: the caret moves naturally while
                // typing, then Enter must bring it back to the comfort target.
                try await harness.dispatchCharacter("W", keyCode: 13)
                try await harness.dispatchCharacter("e", keyCode: 14)
                try await harness.dispatchEnter()
                // Wait out the damped realign (260ms) plus settle.
                try await Task.sleep(for: .milliseconds(500))
                let state = try await harness.state()
                let caret = number(state, "caretCenter")
                let target = number(state, "target")
                maxDeviation = max(maxDeviation, abs(caret - target))
            }
            #expect(
                maxDeviation < 3,
                "zoom=\(zoom) caret drifted \(maxDeviation) from target after Enters"
            )
            harness.close()
        }
    }

    @Test func plainTypingDoesNotMoveScroll() async throws {
        // Typing characters (no Enter) must never write the scroll: the
        // caret moves naturally, like the plain editor. Only Enter realigns.
        let markdown = (1...80).map { "Plain paragraph \($0)." }.joined(separator: "\n\n")
        let offset = ((1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n") as NSString).length + 2
        for zoom in [1.0, 2.0] {
            let harness = try await makeHarness(markdown: markdown, zoom: zoom)
            _ = try await harness.evaluate(
                "window.__mdEditor.select(\(offset)); window.__mdEditor._followTypewriterForTesting()",
                in: harness.webView
            )
            try await Task.sleep(for: .milliseconds(400))
            let before = try await harness.state()
            let scrollBefore = number(before, "scrollTop")
            let target = number(before, "target")

            var trace: [String] = []
            for round in 0..<8 {
                try await harness.dispatchCharacter(round % 2 == 0 ? "W" : "e",
                                                    keyCode: round % 2 == 0 ? 13 : 14)
                try await Task.sleep(for: .milliseconds(16))
                let s = try await harness.state()
                trace.append(String(format: "r%d:c%.2f:s%.0f", round,
                                    number(s, "caretCenter"), number(s, "scrollTop")))
            }
            try await Task.sleep(for: .milliseconds(700))
            let after = try await harness.state()
            let scrollAfter = number(after, "scrollTop")
            let caretAfter = number(after, "caretCenter")
            print("TYPING zoom=\(zoom): before s=\(String(format: "%.0f", scrollBefore)) "
                + "seq=[\(trace.joined(separator: " "))] after s=\(String(format: "%.0f", scrollAfter))")

            if zoom == 1.0 {
                // Within-line typing never scrolls (no per-character
                // alignment, no jitter).
                #expect(
                    abs(scrollAfter - scrollBefore) <= 1,
                    "zoom=\(zoom) typing moved scroll \(scrollBefore) -> \(scrollAfter)"
                )
            } else {
                // Plain typing must never re-anchor the caret: at zoom 2 the
                // characters cross soft-wrap lines, so the caret moves
                // naturally away from the comfort target (CodeMirror's own
                // scrollIntoView may scroll to keep it visible).
                #expect(
                    abs(caretAfter - target) > 3,
                    "zoom=\(zoom) caret was re-anchored to \(target) while typing (caret \(caretAfter))"
                )
            }
            harness.close()
        }
    }

    private func makeHarness(markdown: String, zoom: Double) async throws -> Harness {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 330, height: 480))
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(origin: .zero, size: NSSize(width: 330, height: 480))
        controller.view.layoutSubtreeIfNeeded()
        controller.load(markdown: markdown, contentWidth: 300, typewriterModeEnabled: true)
        var webView: WKWebView?
        for _ in 0..<250 {
            controller.view.layoutSubtreeIfNeeded()
            webView = descendants(of: controller.view).compactMap { $0 as? WKWebView }.first
            if let webView,
               try await evaluate("!!window.__mdEditor", in: webView) as? Bool == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try #require(webView)
        controller.applyPageZoom(zoom)
        try await Task.sleep(for: .milliseconds(200))
        return Harness(controller: controller, window: window, webView: view)
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private func number(_ state: [String: Any], _ key: String) -> Double {
        (state[key] as? NSNumber)?.doubleValue ?? .nan
    }

    private struct Harness {
        let controller: CodeMirrorEditorViewController
        let window: NSWindow
        let webView: WKWebView

        func close() {
            window.contentViewController = nil
            window.close()
        }

        func state() async throws -> [String: Any] {
            try await evaluate("window.__mdEditor._typewriterStateForTesting()", in: webView)
                as? [String: Any] ?? [:]
        }

        func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
        }

        private func keyEvent(_ type: NSEvent.EventType, characters: String, keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
        }

        func dispatchCharacter(_ character: String, keyCode: UInt16) async throws {
            window.makeFirstResponder(webView)
            webView.keyDown(with: try keyEvent(.keyDown, characters: character, keyCode: keyCode))
            try await Task.sleep(for: .milliseconds(16))
            webView.keyUp(with: try keyEvent(.keyUp, characters: character, keyCode: keyCode))
        }

        func dispatchEnter() async throws {
            window.makeFirstResponder(webView)
            webView.keyDown(with: try keyEvent(.keyDown, characters: "\r", keyCode: 36))
            try await Task.sleep(for: .milliseconds(16))
            webView.keyUp(with: try keyEvent(.keyUp, characters: "\r", keyCode: 36))
        }
    }
}
