import AppKit
import Foundation
import Testing
import WebKit
@testable import FloralMD

// The typewriter must not change any scrolling behavior while typing:
// soft wraps and keep-visible scrolling behave exactly like the
// typewriter-off editor; only structural edits (Enter, Backspace, Delete)
// realign (same-frame, no down-then-back), even after the caret walked far
// out of the viewport.
@Suite(.serialized)
@MainActor
struct TypewriterTypingParityTests {
    @Test func typingNeverScrollsAndOnlyStructuralEditsRealign() async throws {
        // Typing must be fully inert: the typewriter performs zero scrollTop
        // writes while characters are typed, and the page still scrolls
        // natively (WebKit/CodeMirror keep-visible) exactly like the
        // typewriter-off editor. Enter is the only typewriter scroll, and it
        // returns the caret's line to the comfort target.
        let markdown = (1...80).map { "Plain paragraph \($0)." }.joined(separator: "\n\n")
        let offset = ((1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n") as NSString).length + 2
        for zoom in [1.0, 2.0] {
            let harness = try await makeHarness(markdown: markdown, zoom: zoom, typewriter: true)
            _ = try await harness.evaluate(
                "window.__mdEditor.select(\(offset)); window.__mdEditor._followTypewriterForTesting()",
                in: harness.webView
            )
            try await Task.sleep(for: .milliseconds(400))
            let before = try await harness.state()
            let writesBefore = number(before, "scrollWrites")
            let scrollBefore = number(before, "scrollTop")
            // Type far enough to cross many soft wraps and leave the viewport.
            for round in 0..<120 {
                try await harness.dispatchCharacter(round % 2 == 0 ? "W" : "e",
                                                    keyCode: round % 2 == 0 ? 13 : 14)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(200))
            let mid = try await harness.state()
            print("INERT zoom=\(zoom): scroll \(String(format: "%.0f", scrollBefore)) -> "
                + "\(String(format: "%.0f", number(mid, "scrollTop"))) "
                + "writes \(writesBefore) -> \(number(mid, "scrollWrites"))")
            #expect(number(mid, "scrollWrites") == writesBefore,
                    "zoom=\(zoom) typing wrote scrollTop \(number(mid, "scrollWrites") - writesBefore) times")
            // The page must still scroll natively exactly like the
            // typewriter-off editor whenever the caret walks out of the
            // viewport; if it never left the viewport there is nothing to
            // scroll and the page legitimately stays put.
            let caretMid = number(mid, "caretCenter")
            let clientHeight = number(mid, "clientHeight")
            let scrolled = abs(number(mid, "scrollTop") - scrollBefore)
            #expect(scrolled > 1 || caretMid <= clientHeight,
                    "zoom=\(zoom) typing must scroll natively like the typewriter-off editor")

            // Enter is the only typewriter scroll, and it realigns the caret.
            try await harness.dispatchEnter()
            try await Task.sleep(for: .milliseconds(200))
            let after = try await harness.state()
            #expect(number(after, "scrollWrites") == writesBefore + 1,
                    "zoom=\(zoom) Enter must be the only typewriter scroll")
            #expect(abs(number(after, "caretCenter") - number(after, "target")) < 3,
                    "zoom=\(zoom) Enter realign: caret \(String(format: "%.2f", number(after, "caretCenter"))) target \(String(format: "%.2f", number(after, "target")))")
            harness.close()
        }
    }

    @Test func backspaceRealignsTheCaretLine() async throws {
        // Backspace is a structural edit: it must realign the caret line to
        // the comfort target exactly like Enter (one typewriter scroll), even
        // when the page was scrolled away meanwhile.
        let markdown = (1...80).map { "Plain paragraph \($0)." }.joined(separator: "\n\n")
        let offset = ((1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n") as NSString).length + 2
        let harness = try await makeHarness(markdown: markdown, zoom: 1.0, typewriter: true)
        // Align through the real Enter path (the _followTypewriterForTesting
        // hook is unreliable without headroom: select()'s async scrollIntoView
        // commit overwrites its scrollTop write).
        _ = try await harness.evaluate(
            "window.__mdEditor.select(\(offset))",
            in: harness.webView
        )
        try await Task.sleep(for: .milliseconds(50))
        _ = try await harness.evaluate(
            "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))",
            in: harness.webView
        )
        try await Task.sleep(for: .milliseconds(400))
        var s = try await harness.state()
        #expect(abs(number(s, "caretCenter") - number(s, "target")) < 3, "start aligned")

        // Type a few characters so Backspace has something to delete.
        for _ in 0..<3 {
            try await harness.dispatchCharacter("W", keyCode: 13)
        }
        // Scroll the page away programmatically (no pointer/wheel, so the
        // typewriter is not suspended) — the caret line now sits far from
        // the comfort target.
        _ = try await harness.evaluate(
            "window.__mdEditor._viewForTesting.scrollDOM.scrollTop = Math.max(0, window.__mdEditor._viewForTesting.scrollDOM.scrollTop - 150)",
            in: harness.webView
        )
        try await Task.sleep(for: .milliseconds(100))
        s = try await harness.state()
        let writesBefore = number(s, "scrollWrites")
        #expect(abs(number(s, "caretCenter") - number(s, "target")) > 50,
                "caret must be displaced before Backspace: \(s)")

        // Backspace deletes one character and realigns in the same frame.
        // Tolerance is looser than Enter's: deleting a character can settle
        // wrapped-line geometry a few CSS px after the align.
        try await harness.dispatchBackspace()
        try await Task.sleep(for: .milliseconds(200))
        s = try await harness.state()
        #expect(number(s, "scrollWrites") == writesBefore + 1,
                "Backspace must perform exactly one typewriter scroll")
        #expect(abs(number(s, "caretCenter") - number(s, "target")) < 8,
                "Backspace realign: caret \(String(format: "%.2f", number(s, "caretCenter"))) target \(String(format: "%.2f", number(s, "target")))")
        harness.close()
    }

    @Test func softWrapDoesNotScrollAndEnterStillAligns() async throws {
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

            // Type enough to cross many soft wraps and leave the viewport.
            for round in 0..<120 {
                try await harness.dispatchCharacter(round % 2 == 0 ? "W" : "e",
                                                    keyCode: round % 2 == 0 ? 13 : 14)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(200))
            let mid = try await harness.state()
            let scrollMid = number(mid, "scrollTop")
            let caretMid = number(mid, "caretCenter")
            // Is the caret still measurable offscreen?
            let coords = try await harness.evaluate(
                """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const pos = view.state.selection.main.head;
                  const c = view.coordsAtPos(pos, 1);
                  return c ? {top: c.top, bottom: c.bottom} : null;
                })()
                """,
                in: harness.webView
            )
            print("SOFTWRAP zoom=\(zoom): scroll \(String(format: "%.0f", scrollBefore)) -> "
                + "\(String(format: "%.0f", scrollMid)) (delta \(String(format: "%.0f", scrollMid - scrollBefore))) "
                + "caret=\(String(format: "%.2f", caretMid)) coords=\(String(describing: coords))")

            // Enter must still realign even with the caret offscreen.
            try await harness.dispatchEnter()
            try await Task.sleep(for: .milliseconds(200))
            let after = try await harness.state()
            print("SOFTWRAP-ENTER zoom=\(zoom): caret=\(String(format: "%.2f", number(after, "caretCenter"))) "
                + "target=\(String(format: "%.2f", target)) "
                + "delta=\(String(format: "%.2f", abs(number(after, "caretCenter") - target)))")
            harness.close()
        }
    }

    private func makeHarness(markdown: String, zoom: Double, typewriter: Bool = true) async throws -> Harness {
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
        controller.load(markdown: markdown, contentWidth: 300, typewriterModeEnabled: typewriter)
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

        func dispatchBackspace() async throws {
            window.makeFirstResponder(webView)
            webView.keyDown(with: try keyEvent(.keyDown, characters: "\u{7F}", keyCode: 51))
            try await Task.sleep(for: .milliseconds(16))
            webView.keyUp(with: try keyEvent(.keyUp, characters: "\u{7F}", keyCode: 51))
        }
    }
}
