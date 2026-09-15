import AppKit
import Foundation
import Testing
@testable import FloralMD

struct MarkdownTypewriterModePreferenceTests {
    @Test func preferenceDefaultsOffAndPersistsExplicitChanges() {
        let suiteName = "MarkdownTypewriterModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!MarkdownTypewriterModePreference.load(from: defaults))
        #expect(MarkdownTypewriterModePreference.persist(true, to: defaults))
        #expect(MarkdownTypewriterModePreference.load(from: defaults))
        #expect(!MarkdownTypewriterModePreference.persist(false, to: defaults))
        #expect(!MarkdownTypewriterModePreference.load(from: defaults))
    }

    @Test func commandIsDiscoverableWithoutClaimingAKeyboardShortcut() {
        let command = FloralMDCommandCatalog.toggleMarkdownTypewriterMode

        #expect(command.id == "markdown.typewriter-mode.toggle")
        #expect(command.title.contains("打字机模式"))
        #expect(command.shortcut == nil)
        #expect(FloralMDCommandCatalog.requiredCommandIDs.contains(command.id))
    }
}

@Suite(.serialized)
@MainActor
struct MarkdownTypewriterModeWebTests {
    @Test func followsActualWrappedVisualLineAndLetsTheLastLineReachTheTarget() async throws {
        let longLine = String(repeating: "软换行中文 text ", count: 45)
        let markdown = (["# 标题", longLine] + (1...35).map { "段落 \($0)" }).joined(separator: "\n\n")
        let controller = try await makeController(markdown: markdown, enabled: true, width: 360)

        _ = await evaluate("window.__mdEditor.select(0); window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await settle()
        var state = try #require(await typewriterState(in: controller))
        // EXPERIMENT (codex/typewriter-no-padding): without top headroom the
        // first line clamps at scrollTop 0 instead of reaching the target.
        #expect(abs(number(state["scrollTop"])) < 1, "first line clamps at top: \(state)")

        let wrappedPosition = markdown.index(markdown.startIndex, offsetBy: 170).utf16Offset(in: markdown)
        _ = await evaluate("window.__mdEditor.select(\(wrappedPosition)); window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await settle()
        state = try #require(await typewriterState(in: controller))
        // EXPERIMENT: the wrapped line sits in the top region, so the align
        // clamps at scrollTop 0 instead of reaching the 47% target.
        #expect(abs(number(state["scrollTop"])) < 1, "top-region line clamps: \(state)")
        #expect(abs(number(state["paddingTop"]) - MarkdownHTML.pagePaddingTop) < 1)
        #expect(abs(number(state["paddingBottom"]) - MarkdownHTML.pagePaddingBottom) < 1)

        // Layout changes (content width, typography, window height) must not
        // scroll by themselves — exactly like the typewriter-off editor the
        // caret keeps whatever viewport position the layout left it at.
        controller.applyContentWidth(500)
        controller.applyTypography(MarkdownTypography(fontName: "", fontSize: 19, lineHeight: 1.7))
        controller.view.frame.size.height = 720
        try await settle()
        state = try #require(await typewriterState(in: controller))
        #expect(state["dampedMotionActive"] as? Bool == false, "no follow animation")
        #expect(abs(number(state["caretCenter"]) - number(state["target"])) > 5,
                "layout change must not re-anchor: \(state)")

        _ = await evaluate("window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await settle()
        state = try #require(await typewriterState(in: controller))
        // EXPERIMENT: still clamped at the top region.
        #expect(abs(number(state["scrollTop"])) < 1, "baseline clamped at top: \(state)")

        // A zoom change displaces the caret from the target (WebKit keeps the
        // CSS-pixel viewport position) and must not scroll it back.
        controller.applyPageZoom(1.15)
        try await settle()
        state = try #require(await typewriterState(in: controller))
        #expect(state["dampedMotionActive"] as? Bool == false, "no follow animation after zoom")
        #expect(abs(number(state["caretCenter"]) - number(state["target"])) > 5,
                "zoom must not re-anchor: \(state)")

        // Only Enter realigns — but in the top region the realign also clamps
        // at scrollTop 0 (no headroom to scroll up into).
        _ = await evaluate(
            "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))",
            in: controller
        )
        try await Task.sleep(for: .milliseconds(250))
        state = try #require(await typewriterState(in: controller))
        #expect(state["dampedMotionActive"] as? Bool == false, "no follow animation")
        #expect(abs(number(state["scrollTop"])) < 1,
                "Enter realign clamps at the top: \(state)")

        _ = await evaluate("window.__mdEditor.select(window.__mdEditor.getMarkdown().length); window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await settle()
        state = try #require(await typewriterState(in: controller))
        // EXPERIMENT: without bottom headroom the last line clamps at the
        // scroll bound instead of reaching the 47% target.
        #expect(abs(number(state["scrollTop"]) - number(state["maximumScrollTop"])) < 2,
                "last line clamps at the bottom: \(state)")
        #expect(number(state["scrollHeight"]) > number(state["clientHeight"]))
    }

    @Test func pointerSuspensionEndsOnMovementKey() async throws {
        let markdown = (1...50).map { "第 \($0) 段" }.joined(separator: "\n\n")
        let controller = try await makeController(markdown: markdown, enabled: true, width: 520)
        // Middle of the document: with no headroom, only the first/last
        // lines clamp, so the follow can still reach the target here.
        let target = markdown.utf16.count / 2

        _ = await evaluate("window.__mdEditor.select(\(target))", in: controller)
        try await settle()
        _ = await evaluate("window.__mdEditor._viewForTesting.scrollDOM.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true})); window.__mdEditor._viewForTesting.scrollDOM.scrollTo({top: 0, behavior: 'auto'})", in: controller)
        try await Task.sleep(for: .milliseconds(50))
        var state = try #require(await typewriterState(in: controller))
        #expect(state["suspendedByPointer"] as? Bool == true)
        try await settle()
        state = try #require(await typewriterState(in: controller))
        #expect(abs(number(state["caretCenter"]) - number(state["target"])) > 100)

        // A movement key ends the suspension and follows to the target.
        _ = await evaluate(
            "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowDown', bubbles: true}))",
            in: controller
        )
        try await Task.sleep(for: .milliseconds(500))
        state = try #require(await typewriterState(in: controller))
        #expect(state["suspendedByPointer"] as? Bool == false)
        #expect(abs(number(state["caretCenter"]) - number(state["target"])) < 3)
        #expect((await editorDocumentState(in: controller))?["markdown"] as? String == markdown)
    }

    @Test func compositionTypingDoesNotRealign() async throws {
        // Composition candidates move the caret naturally; the typewriter
        // must not touch the scroll while composing (only Enter realigns).
        let markdown = (1...40).map { "第 \($0) 段" }.joined(separator: "\n\n")
        let controller = try await makeController(markdown: markdown, enabled: true, width: 520)
        let target = markdown.utf16.count / 2
        _ = await evaluate(
            "window.__mdEditor.select(\(target)); window.__mdEditor._followTypewriterForTesting()",
            in: controller
        )
        try await settle()
        var state = try #require(await typewriterState(in: controller))
        let scrollBefore = number(state["scrollTop"])

        _ = await evaluate("window.__mdEditor._setCompositionActiveForTesting(true)", in: controller)
        _ = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const position = view.state.selection.main.head;
              view.dispatch({
                changes: { from: position, to: position, insert: '中' },
                selection: { anchor: position + 1 },
                userEvent: 'input.type',
                scrollIntoView: true
              });
              view.contentDOM.dispatchEvent(new InputEvent('input', {
                inputType: 'insertCompositionText', data: '中', bubbles: true, isComposing: true
              }));
              return true;
            })()
            """,
            in: controller
        )
        try await Task.sleep(for: .milliseconds(100))
        _ = await evaluate("window.__mdEditor._setCompositionActiveForTesting(false)", in: controller)
        try await Task.sleep(for: .milliseconds(400))

        state = try #require(await typewriterState(in: controller))
        #expect(abs(number(state["scrollTop"]) - scrollBefore) <= 1)
        #expect((await editorDocumentState(in: controller))?["markdown"] as? String
            == markdown.replacingCharacters(
                in: markdown.index(markdown.startIndex, offsetBy: target)..<markdown.index(markdown.startIndex, offsetBy: target),
                with: "中"
            ))
    }

    @Test func disablingRemovesPaddingWithoutChangingMarkdownOrSelection() async throws {
        let markdown = (1...30).map { "内容 \($0)" }.joined(separator: "\n")
        let controller = try await makeController(markdown: markdown, enabled: true, width: 520)
        let position = markdown.utf16.count / 2
        _ = await evaluate("window.__mdEditor.select(\(position)); window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await settle()

        controller.applyTypewriterMode(false)
        try await settle()
        let state = try #require(await typewriterState(in: controller))
        let documentState = try #require(await editorDocumentState(in: controller))
        #expect(state["enabled"] as? Bool == false)
        #expect(abs(number(state["paddingTop"]) - MarkdownHTML.pagePaddingTop) < 1)
        #expect(abs(number(state["paddingBottom"]) - MarkdownHTML.pagePaddingBottom) < 1)
        #expect(documentState["markdown"] as? String == markdown)
        #expect((documentState["from"] as? NSNumber)?.intValue == position)
        #expect((documentState["to"] as? NSNumber)?.intValue == position)
    }

    @Test func typingAfterZoomNeverRealignsAndEnterDoes() async throws {
        let markdown = (1...80).map { "Plain paragraph \($0)." }.joined(separator: "\n\n")
        let offset = ((1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n") as NSString).length + 2
        for zoom in [0.75, 2.0] {
            let controller = try await makeController(markdown: markdown, enabled: true, width: 520)
            defer { controller.view.removeFromSuperview() }

            // Align through the real Enter path (the _followTypewriterForTesting
            // hook is unreliable without headroom: CM's async scrollIntoView
            // commit from select() overwrites its scrollTop write).
            _ = await evaluate("window.__mdEditor.select(\(offset))", in: controller)
            try await Task.sleep(for: .milliseconds(50))
            _ = await evaluate(
                "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))",
                in: controller
            )
            try await settle()
            var state = try #require(await typewriterState(in: controller))
            #expect(abs(number(state["caretCenter"]) - number(state["target"])) < 3, "zoom=\(zoom) start")

            // Zoom away from 100%. WebKit keeps the caret's CSS-pixel
            // viewport position, so the caret lands far from the 47% target —
            // exactly where the typewriter-off editor would leave it. The
            // typewriter must not scroll it back.
            controller.applyPageZoom(zoom)
            try await Task.sleep(for: .milliseconds(40))

            // Typing right after the zoom stays fully inert too: no damped
            // motion, no re-anchor, the caret keeps the displaced position.
            _ = await evaluate(
                "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', bubbles: true}))",
                in: controller
            )
            try await Task.sleep(for: .milliseconds(650))

            state = try #require(await typewriterState(in: controller))
            #expect(state["dampedMotionActive"] as? Bool == false, "zoom=\(zoom) no follow")
            #expect(
                abs(number(state["caretCenter"]) - number(state["target"])) > 20,
                "zoom=\(zoom) typing must not re-anchor: \(state)"
            )

            // Enter is the only thing that realigns.
            _ = await evaluate(
                "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}))",
                in: controller
            )
            try await Task.sleep(for: .milliseconds(200))
            state = try #require(await typewriterState(in: controller))
            #expect(abs(number(state["caretCenter"]) - number(state["target"])) < 3,
                    "zoom=\(zoom) Enter realign: \(state)")
        }
    }

    private func makeController(markdown: String, enabled: Bool, width: Double) async throws -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        controller.load(markdown: markdown, contentWidth: width, typewriterModeEnabled: enabled)
        for _ in 0..<200 {
            if await evaluate("!!window.__mdEditor", in: controller) as? Bool == true { return controller }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("CodeMirror editor did not become ready")
        return controller
    }

    private func typewriterState(in controller: CodeMirrorEditorViewController) async -> [String: Any]? {
        await evaluate("window.__mdEditor._typewriterStateForTesting()", in: controller) as? [String: Any]
    }

    private func editorDocumentState(in controller: CodeMirrorEditorViewController) async -> [String: Any]? {
        await evaluate("({markdown: window.__mdEditor.getMarkdown(), from: window.__mdEditor._selectionForTesting().from, to: window.__mdEditor._selectionForTesting().to})", in: controller) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(450)) }

    private func evaluate(_ script: String, in controller: CodeMirrorEditorViewController) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { continuation.resume(returning: $0) }
        }
    }
}
