import AppKit
import SwiftUI
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct MarkdownKeystrokeStabilityTests {
    @Test func ordinaryTypingDoesNotMoveCaretDownAndThenBack() async throws {
        let trace = try await traceOneCharacterInput(typewriterModeEnabled: false)

        #expect(trace.markdownHasExpectedEdit)
        #expect(trace.maximumDownwardMovement <= 2.0, Comment(rawValue: trace.description))
        #expect(!trace.hasDownThenBackMovement, Comment(rawValue: trace.description))
        #expect(!trace.hasScrollReversal, Comment(rawValue: trace.description))
    }












    private func traceOneCharacterInput(
        typewriterModeEnabled: Bool,
        compositionUpdateCount: Int = 0,
        cancelsComposition: Bool = false,
        pressesEnter: Bool = false,
        pressesBackspace: Bool = false,
        resizedContentSize: NSSize? = nil,
        resizeStepCount: Int = 1,
        resizeSettleDelay: Duration = .milliseconds(120),
        usesNativeCharacterEvent: Bool = false,
        nativeCharacterCount: Int = 1,
        inputCharacter: String = "x",
        inputKeyCode: UInt16 = 7,
        usesSoftWrapBoundaryAfterResize: Bool = false,
        preservesCaretThroughResizeToSoftWrapBoundary: Bool = false,
        performsMiniaturizeRestore: Bool = false,
        focusesTableCell: Bool = false,
        caretLocation: KeystrokeCaretLocation = .fixtureDefault,
        fixture: KeystrokeFixture = .longSoftWrappedParagraphs
    ) async throws -> KeystrokeTrace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Keystroke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = fixture.markdown
        let note = root.appendingPathComponent("Long.md")
        try markdown.write(to: note, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let preferenceKey = AppPreferenceKey.markdownTypewriterModeEnabled
        let previousPreference = defaults.object(forKey: preferenceKey)
        defaults.set(typewriterModeEnabled, forKey: preferenceKey)
        defer {
            if let previousPreference {
                defaults.set(previousPreference, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }

        let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })
        let hostingController = NSHostingController(
            rootView: KeystrokeEditorHost(
                controller: controller,
                typewriterModeEnabled: typewriterModeEnabled
            )
            .frame(
                minWidth: 1,
                maxWidth: .infinity,
                minHeight: 1,
                maxHeight: .infinity
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.makeKeyAndOrderFront(nil)
        let host = hostingController.view
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        defer {
            window.contentViewController = nil
            window.close()
        }

        let webView = try await waitForEditor(in: host)
        try await installKeystrokeTimeline(in: webView)
        var insertionOffset = pressesBackspace
            ? fixture.backspaceOffset
            : caretLocation.offset(in: fixture)
        if preservesCaretThroughResizeToSoftWrapBoundary, let resizedContentSize {
            let originalSize = window.contentLayoutRect.size
            window.setContentSize(resizedContentSize)
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            insertionOffset = try await softWrapBackspaceOffset(in: webView) - 1
            window.setContentSize(originalSize)
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        _ = try await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              window.__mdEditor.select(\(insertionOffset));
              view.focus();
              return true;
            })()
            """,
            in: webView
        )
        try await Task.sleep(for: .milliseconds(80))
        if pressesBackspace && fixture == .softWrappedLine {
            let softWrapOffset = try await softWrapBackspaceOffset(in: webView)
            _ = try await evaluate(
                "window.__mdEditor.select(\(softWrapOffset))",
                in: webView
            )
            try await Task.sleep(for: .milliseconds(40))
        }
        if typewriterModeEnabled {
            _ = try await evaluate("window.__mdEditor._followTypewriterForTesting()", in: webView)
            try await Task.sleep(for: .milliseconds(80))
        }
        if let resizedContentSize {
            let originalSize = window.contentLayoutRect.size
            for step in 1...max(1, resizeStepCount) {
                let progress = CGFloat(step) / CGFloat(max(1, resizeStepCount))
                window.setContentSize(NSSize(
                    width: originalSize.width + (resizedContentSize.width - originalSize.width) * progress,
                    height: originalSize.height + (resizedContentSize.height - originalSize.height) * progress
                ))
                host.frame = window.contentLayoutRect
                host.layoutSubtreeIfNeeded()
                if resizeStepCount > 1 { try await Task.sleep(for: .milliseconds(8)) }
            }
            if resizeSettleDelay > .zero { try await Task.sleep(for: resizeSettleDelay) }
        }
        if usesSoftWrapBoundaryAfterResize {
            let boundary = try await softWrapBackspaceOffset(in: webView)
            _ = try await evaluate(
                "window.__mdEditor.select(\(boundary - 1))",
                in: webView
            )
            _ = try await evaluate("window.__mdEditor._followTypewriterForTesting()", in: webView)
            try await Task.sleep(for: .milliseconds(160))
        }
        if performsMiniaturizeRestore {
            window.miniaturize(nil)
            try await Task.sleep(for: .milliseconds(120))
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(160))
        }
        if focusesTableCell {
            let focused = try await evaluate(
                """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  view.dispatch({
                    selection: { anchor: view.state.doc.length - 1 },
                    scrollIntoView: true
                  });
                  const cell = document.querySelector(
                    '[data-table-row="1"][data-table-column="1"]'
                  );
                  if (!cell) return false;
                  view.dispatch({ selection: { anchor: 0 } });
                  cell.focus();
                  const selection = window.getSelection();
                  selection.removeAllRanges();
                  const range = document.createRange();
                  range.selectNodeContents(cell);
                  range.collapse(false);
                  selection.addRange(range);
                  return document.activeElement === cell;
                })()
                """,
                in: webView
            ) as? Bool
            #expect(focused == true)
            _ = try await evaluate("window.__mdEditor._followTypewriterForTesting()", in: webView)
            try await Task.sleep(for: .milliseconds(160))
        }

        var samples: [KeystrokeSample] = []
        samples.append(try await sample(label: "before", webView: webView, host: host))
        if compositionUpdateCount == 0 {
            _ = try await evaluate(
                """
                (() => {
                  window.__keystrokeFrameTrace = [];
                  let remaining = 13;
                  const scheduleCapture = () => {
                    let captured = false;
                    const captureOnce = () => {
                      if (captured) return;
                      captured = true;
                      capture();
                    };
                    requestAnimationFrame(captureOnce);
                    setTimeout(captureOnce, 16);
                  };
                  const capture = () => {
                    window.__keystrokeFrameTrace.push(
                      window.__mdEditor._typewriterStateForTesting()
                    );
                    remaining -= 1;
                    if (remaining > 0) scheduleCapture();
                  };
                  capture();
                  return true;
                })()
                """,
                in: webView
            )
        }
        if compositionUpdateCount > 0 {
            _ = try await evaluate("window.__mdEditor._setCompositionActiveForTesting(true)", in: webView)
            for update in 1...compositionUpdateCount {
                _ = try await evaluate(
                    "window.__mdEditor._viewForTesting.contentDOM.dispatchEvent("
                        + "new CompositionEvent('compositionupdate', {data: 'x', bubbles: true}))",
                    in: webView
                )
                if !cancelsComposition {
                    try await dispatchInput(character: inputCharacter, composing: true, in: webView)
                }
                try await Task.sleep(for: .milliseconds(32))
                samples.append(try await sample(
                    label: "composition-\(update)",
                    webView: webView,
                    host: host
                ))
            }
            _ = try await evaluate("window.__mdEditor._setCompositionActiveForTesting(false)", in: webView)
            for (label, delay) in [("composition-end", 0), ("end-32ms", 32),
                                   ("end-96ms", 64), ("end-224ms", 128), ("end-420ms", 196)] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                samples.append(try await sample(label: label, webView: webView, host: host))
            }
        } else {
            if pressesEnter {
                try await dispatchEnter(in: webView)
            } else if pressesBackspace {
                try await dispatchBackspace(in: webView)
            } else if usesNativeCharacterEvent {
                for index in 0..<nativeCharacterCount {
                    try await dispatchCharacter(inputCharacter, keyCode: inputKeyCode, in: webView)
                    if index + 1 < nativeCharacterCount {
                        try await Task.sleep(for: .milliseconds(24))
                    }
                }
            } else {
                try await dispatchInput(character: inputCharacter, composing: false, in: webView)
            }
            for (label, delay) in [("24ms", 24), ("48ms", 24), ("80ms", 32),
                                   ("144ms", 64), ("272ms", 128), ("420ms", 148)] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                host.layoutSubtreeIfNeeded()
                samples.append(try await sample(label: label, webView: webView, host: host))
            }
        }

        if focusesTableCell {
            _ = try await evaluate("document.activeElement?.blur(); true", in: webView)
            for _ in 0..<80 where controller.markdownText == markdown {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        return KeystrokeTrace(
            samples: compositionUpdateCount == 0
                ? try await frameSamples(webView: webView, host: host)
                : samples,
            markdownHasExpectedEdit: focusesTableCell
                ? controller.markdownText != markdown
                : controller.markdownText.utf16.count
                    == markdown.utf16.count + (
                        pressesBackspace ? -1
                            : (cancelsComposition
                                ? 0 : max(nativeCharacterCount, compositionUpdateCount))
                    ),
            timeline: (try await evaluate("window.__keystrokeTimeline", in: webView) as? [String]) ?? [],
            markdownTail: String(controller.markdownText.suffix(160))
        )
    }

    private func installKeystrokeTimeline(in webView: WKWebView) async throws {
        _ = try await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const startedAt = performance.now();
              window.__keystrokeTimeline = [];
              const record = (name) => window.__keystrokeTimeline.push(
                `${(performance.now() - startedAt).toFixed(2)}ms:${name}`
              );
              const resizeObserver = new ResizeObserver((entries) => {
                record(`resize-observer:${entries.map((entry) =>
                  entry.target === view.scrollDOM ? 'scroll' : 'content').join(',')}`);
                view.requestMeasure({ read: () => record('measure-read') });
              });
              resizeObserver.observe(view.scrollDOM);
              resizeObserver.observe(view.contentDOM);
              const mutationObserver = new MutationObserver(() => record('content-mutation'));
              mutationObserver.observe(view.contentDOM, {
                childList: true, subtree: true, characterData: true, attributes: true
              });
              window.addEventListener('resize', () => record('window-resize'));
              for (const name of [
                'keydown', 'beforeinput', 'input',
                'compositionstart', 'compositionupdate', 'compositionend'
              ]) {
                view.contentDOM.addEventListener(name, () => record(name), true);
              }
              window.__keystrokeObservers = [resizeObserver, mutationObserver];
              record('installed');
              return true;
            })()
            """,
            in: webView
        )
    }

    private func dispatchInput(character: String, composing: Bool, in webView: WKWebView) async throws {
        _ = try await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const position = view.state.selection.main.head;
              view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
                key: '\(character)', bubbles: true, isComposing: \(composing)
              }));
              view.dispatch({
                changes: { from: position, to: position, insert: '\(character)' },
                selection: { anchor: position + 1 },
                userEvent: 'input.type',
                scrollIntoView: true
              });
              view.contentDOM.dispatchEvent(new InputEvent('input', {
                inputType: 'insertCompositionText', data: '\(character)', bubbles: true,
                isComposing: \(composing)
              }));
              return true;
            })()
            """,
            in: webView
        )
    }

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
        try await Task.sleep(for: .milliseconds(16))
        webView.keyUp(with: try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )))
    }

    private func dispatchBackspace(in webView: WKWebView) async throws {
        let window = try #require(webView.window)
        window.makeFirstResponder(webView)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 51
        ))
        webView.keyDown(with: event)
        try await Task.sleep(for: .milliseconds(16))
        webView.keyUp(with: try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 51
        )))
    }

    private func dispatchCharacter(_ character: String, keyCode: UInt16, in webView: WKWebView) async throws {
        let window = try #require(webView.window)
        window.makeFirstResponder(webView)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
        webView.keyDown(with: event)
        try await Task.sleep(for: .milliseconds(16))
        webView.keyUp(with: try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )))
    }

    private func softWrapBackspaceOffset(in webView: WKWebView) async throws -> Int {
        let value = try await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const head = view.state.selection.main.head;
              for (let radius = 0; radius <= 600; radius += 1) {
                for (const candidate of [head - radius, head + radius]) {
                  if (candidate <= 0 || candidate > view.state.doc.length) continue;
                  const before = view.coordsAtPos(candidate - 1, -1);
                  const after = view.coordsAtPos(candidate, 1);
                  if (before && after && Math.abs(after.top - before.top) > 5) return candidate;
                }
              }
              return null;
            })()
            """,
            in: webView
        ) as? NSNumber
        return try #require(value).intValue
    }

    private func frameSamples(webView: WKWebView, host: NSView) async throws -> [KeystrokeSample] {
        var values: [[String: Any]]?
        for _ in 0..<80 {
            values = try await evaluate("window.__keystrokeFrameTrace", in: webView) as? [[String: Any]]
            if values?.count == 13 { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        let frames = try #require(values)
        #expect(frames.count >= 12, "frame trace stopped at \(frames.count) samples")
        let webOrigin = webView.convert(NSPoint.zero, to: host)
        let webBounds = webView.bounds
        return frames.enumerated().map { index, state in
            let editorBounds = state["editorBounds"] as? [String: Any]
            let scrollBounds = state["scrollBounds"] as? [String: Any]
            let contentBounds = state["contentBounds"] as? [String: Any]
            return KeystrokeSample(
                label: "frame-\(index)",
                windowCaretY: webOrigin.y + ((state["caretCenter"] as? NSNumber)?.doubleValue ?? .nan),
                caretTop: (state["caretTop"] as? NSNumber)?.doubleValue ?? .nan,
                target: (state["target"] as? NSNumber)?.doubleValue ?? .nan,
                scrollTop: (state["scrollTop"] as? NSNumber)?.doubleValue ?? .nan,
                scrollHeight: (state["scrollHeight"] as? NSNumber)?.doubleValue ?? .nan,
                maximumScrollTop: (state["maximumScrollTop"] as? NSNumber)?.doubleValue ?? .nan,
                webViewOriginY: webOrigin.y,
                clientHeight: (state["clientHeight"] as? NSNumber)?.doubleValue ?? .nan,
                webViewWidth: webBounds.width,
                webViewHeight: webBounds.height,
                editorWidth: (editorBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
                editorHeight: (editorBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
                scrollWidth: (scrollBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
                scrollHeightBounds: (scrollBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
                contentWidth: (contentBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
                contentHeight: (contentBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
                dampedMotionActive: state["dampedMotionActive"] as? Bool ?? false,
                dampedVelocity: (state["dampedVelocity"] as? NSNumber)?.doubleValue ?? .nan,
                inputScrollProtectionActive: state["inputScrollProtectionActive"] as? Bool ?? false,
                protectedScrollTop: (state["protectedScrollTop"] as? NSNumber)?.doubleValue,
                viewportFrom: (state["viewportFrom"] as? NSNumber)?.intValue ?? -1,
                viewportTo: (state["viewportTo"] as? NSNumber)?.intValue ?? -1
            )
        }
    }

    private func waitForEditor(in host: NSView) async throws -> WKWebView {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            for webView in descendants(of: host).compactMap({ $0 as? WKWebView }) {
                if try await evaluate("!!window.__mdEditor", in: webView) as? Bool == true {
                    return webView
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Workspace CodeMirror editor did not become ready")
        throw KeystrokeHarnessError.editorUnavailable
    }

    private func sample(label: String, webView: WKWebView, host: NSView) async throws -> KeystrokeSample {
        let value = try await evaluate(
            """
            (() => {
              return window.__mdEditor._typewriterStateForTesting();
            })()
            """,
            in: webView
        ) as? [String: Any]
        let state = try #require(value)
        let webOrigin = webView.convert(NSPoint.zero, to: host)
        let editorBounds = state["editorBounds"] as? [String: Any]
        let scrollBounds = state["scrollBounds"] as? [String: Any]
        let contentBounds = state["contentBounds"] as? [String: Any]
        return KeystrokeSample(
            label: label,
            windowCaretY: webOrigin.y + ((state["caretCenter"] as? NSNumber)?.doubleValue ?? .nan),
            caretTop: (state["caretTop"] as? NSNumber)?.doubleValue ?? .nan,
            target: (state["target"] as? NSNumber)?.doubleValue ?? .nan,
            scrollTop: (state["scrollTop"] as? NSNumber)?.doubleValue ?? .nan,
            scrollHeight: (state["scrollHeight"] as? NSNumber)?.doubleValue ?? .nan,
            maximumScrollTop: (state["maximumScrollTop"] as? NSNumber)?.doubleValue ?? .nan,
            webViewOriginY: webOrigin.y,
            clientHeight: (state["clientHeight"] as? NSNumber)?.doubleValue ?? .nan,
            webViewWidth: webView.bounds.width,
            webViewHeight: webView.bounds.height,
            editorWidth: (editorBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
            editorHeight: (editorBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
            scrollWidth: (scrollBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
            scrollHeightBounds: (scrollBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
            contentWidth: (contentBounds?["width"] as? NSNumber)?.doubleValue ?? .nan,
            contentHeight: (contentBounds?["height"] as? NSNumber)?.doubleValue ?? .nan,
            dampedMotionActive: state["dampedMotionActive"] as? Bool ?? false,
            dampedVelocity: (state["dampedVelocity"] as? NSNumber)?.doubleValue ?? .nan,
            inputScrollProtectionActive: state["inputScrollProtectionActive"] as? Bool ?? false,
            protectedScrollTop: (state["protectedScrollTop"] as? NSNumber)?.doubleValue,
            viewportFrom: (state["viewportFrom"] as? NSNumber)?.intValue ?? -1,
            viewportTo: (state["viewportTo"] as? NSNumber)?.intValue ?? -1
        )
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
}

private struct KeystrokeEditorHost: View {
    @ObservedObject var controller: WorkspaceController
    let typewriterModeEnabled: Bool

    var body: some View {
        CodeMirrorEditorView(
            markdown: Binding(
                get: { controller.markdownText },
                set: { controller.markdownText = $0 }
            ),
            contentWidth: 520,
            documentURL: controller.activeResource?.url,
            resourceContext: MarkdownLocalResourceContext(
                session: controller.session,
                documentURL: controller.activeResource?.url
            ),
            navigation: nil,
            typography: .default,
            typewriterModeEnabled: typewriterModeEnabled,
            userDidEdit: {},
            imagePasteHandler: nil,
            imageOpenHandler: nil,
            resourceDropHandler: nil,
            linkNavigationHandler: nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum KeystrokeHarnessError: Error {
    case editorUnavailable
}

private enum KeystrokeCaretLocation {
    case fixtureDefault
    case top
    case middle
    case bottom

    func offset(in fixture: KeystrokeFixture) -> Int {
        switch self {
        case .fixtureDefault:
            fixture.insertionOffset
        case .top:
            min(8, fixture.markdown.utf16.count)
        case .middle:
            fixture.markdown.utf16.count / 2
        case .bottom:
            fixture.markdown.utf16.count
        }
    }
}

private enum KeystrokeFixture: CaseIterable {
    case shortPlainParagraph
    case longPlainParagraphs
    case softWrappedLine
    case softWrappedCharacters
    case unorderedList
    case table
    case longSoftWrappedParagraphs

    static let matrixCases: [Self] = [
        .shortPlainParagraph,
        .longPlainParagraphs,
        .softWrappedLine,
    ]

    static let backspaceCases: [Self] = [
        .shortPlainParagraph,
        .longPlainParagraphs,
        .softWrappedLine,
    ]

    var name: String {
        switch self {
        case .shortPlainParagraph: "short plain paragraph"
        case .longPlainParagraphs: "long plain paragraphs"
        case .softWrappedLine: "soft-wrapped line"
        case .softWrappedCharacters: "soft-wrapped characters"
        case .unorderedList: "unordered list"
        case .table: "table"
        case .longSoftWrappedParagraphs: "long soft-wrapped paragraphs"
        }
    }

    var markdown: String {
        switch self {
        case .shortPlainParagraph:
            "Short paragraph for stable typing."
        case .longPlainParagraphs:
            (1...80).map { "Plain paragraph \($0)." }.joined(separator: "\n\n")
        case .softWrappedLine:
            String(repeating: "soft wrap segment ", count: 180)
        case .softWrappedCharacters:
            String(repeating: "W", count: 4_000)
        case .unorderedList:
            (1...80).map { "- List item \($0) with enough prose to wrap at minimum width." }
                .joined(separator: "\n")
        case .table:
            (0..<45).map { "Paragraph \($0) with enough text to occupy a source row." }
                .joined(separator: "\n\n")
                + "\n\n| Name | Status |\n| --- | --- |\n| Ada | Active |"
        case .longSoftWrappedParagraphs:
            (1...80).map { index in
                "第 \(index) 段用于验证普通输入、软换行和滚动位置。"
                    + String(repeating: " 延伸文本", count: 7)
            }.joined(separator: "\n\n")
        }
    }

    var insertionOffset: Int {
        switch self {
        case .shortPlainParagraph:
            markdown.utf16.count
        case .longPlainParagraphs:
            (1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n").utf16.count + 2
        case .softWrappedLine, .softWrappedCharacters, .unorderedList, .table:
            markdown.utf16.count / 2
        case .longSoftWrappedParagraphs:
            ((1...39).map { index in
                "第 \(index) 段用于验证普通输入、软换行和滚动位置。"
                    + String(repeating: " 延伸文本", count: 7)
            }.joined(separator: "\n\n") + "\n\n第 40 段").utf16.count
        }
    }

    var backspaceOffset: Int {
        switch self {
        case .shortPlainParagraph:
            markdown.utf16.count
        case .longPlainParagraphs:
            (1...39).map { "Plain paragraph \($0)." }.joined(separator: "\n\n").utf16.count + 2
        case .softWrappedLine, .softWrappedCharacters, .unorderedList, .table,
             .longSoftWrappedParagraphs:
            insertionOffset
        }
    }
}

private struct KeystrokeSample {
    let label: String
    let windowCaretY: Double
    let caretTop: Double
    let target: Double
    let scrollTop: Double
    let scrollHeight: Double
    let maximumScrollTop: Double
    let webViewOriginY: Double
    let clientHeight: Double
    let webViewWidth: Double
    let webViewHeight: Double
    let editorWidth: Double
    let editorHeight: Double
    let scrollWidth: Double
    let scrollHeightBounds: Double
    let contentWidth: Double
    let contentHeight: Double
    let dampedMotionActive: Bool
    let dampedVelocity: Double
    let inputScrollProtectionActive: Bool
    let protectedScrollTop: Double?
    let viewportFrom: Int
    let viewportTo: Int
}

private struct KeystrokeTrace: CustomStringConvertible {
    // WKWebView rounds scroll offsets to whole device pixels during an edit. A
    // one-pixel out-and-back is sampling noise; the reported regression moves
    // the caret by one full CodeMirror line (about 23 px at the minimum size).
    private static let visibleReversalThreshold = 2.0

    let samples: [KeystrokeSample]
    let markdownHasExpectedEdit: Bool
    let timeline: [String]
    let markdownTail: String

    var hasDownThenBackMovement: Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        let direction = samples.map { $0.windowCaretY - first.windowCaretY }
        let peak = direction.max() ?? 0
        return peak > Self.visibleReversalThreshold
            && peak - (last.windowCaretY - first.windowCaretY) > Self.visibleReversalThreshold
    }

    var maximumDownwardMovement: Double {
        guard let first = samples.first else { return 0 }
        return samples.map { $0.windowCaretY - first.windowCaretY }.max() ?? 0
    }

    var hasScrollReversal: Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        let direction = samples.map { $0.scrollTop - first.scrollTop }
        let minimum = direction.min() ?? 0
        let maximum = direction.max() ?? 0
        let final = last.scrollTop - first.scrollTop
        return (minimum < -Self.visibleReversalThreshold
                    && final - minimum > Self.visibleReversalThreshold)
            || (maximum > Self.visibleReversalThreshold
                    && maximum - final > Self.visibleReversalThreshold)
    }

    var compositionAccumulatesVerticalDisplacement: Bool {
        guard let first = samples.first else { return false }
        let composition = samples.filter { $0.label.hasPrefix("composition-") }
        guard let last = composition.last else { return false }
        return abs(last.windowCaretY - first.windowCaretY) > 0.5
    }

    var maximumCompositionCaretDisplacement: Double {
        guard let first = samples.first else { return 0 }
        return samples
            .filter { $0.label.hasPrefix("composition-") }
            .map { abs($0.windowCaretY - first.windowCaretY) }
            .max() ?? 0
    }

    var compositionAccumulatesScrollDisplacement: Bool {
        guard let first = samples.first else { return false }
        let composition = samples.filter { $0.label.hasPrefix("composition-") }
        guard let last = composition.last else { return false }
        return abs(last.scrollTop - first.scrollTop) > 0.5
    }

    var compositionEndDirectionChanges: Int {
        let values = samples.filter {
            $0.label == "composition-end" || $0.label.hasPrefix("end-")
        }.map(\.windowCaretY)
        let directions = zip(values, values.dropFirst()).compactMap { before, after -> Int? in
            let delta = after - before
            guard abs(delta) > 0.25 else { return nil }
            return delta > 0 ? 1 : -1
        }
        return zip(directions, directions.dropFirst()).filter { $0.0 != $0.1 }.count
    }

    var maximumCaretDisplacement: Double {
        guard let first = samples.first else { return 0 }
        return samples.map { abs($0.windowCaretY - first.windowCaretY) }.max() ?? 0
    }

    var description: String {
        let frames = samples.map {
            "\($0.label): caretTop=\($0.caretTop), caretY=\($0.windowCaretY), target=\($0.target), "
                + "scroll=\($0.scrollTop)/\($0.maximumScrollTop), contentScrollHeight=\($0.scrollHeight), "
                + "clientHeight=\($0.clientHeight), web=\($0.webViewWidth)x\($0.webViewHeight), "
                + "editor=\($0.editorWidth)x\($0.editorHeight), scrollDOM=\($0.scrollWidth)x\($0.scrollHeightBounds), "
                + "content=\($0.contentWidth)x\($0.contentHeight), damping=\($0.dampedMotionActive), "
                + "velocity=\($0.dampedVelocity), protection=\($0.inputScrollProtectionActive), "
                + "protectedTop=\(String(describing: $0.protectedScrollTop)), "
                + "viewport=\($0.viewportFrom)..<\($0.viewportTo)"
        }.joined(separator: "; ")
        return frames + "; timeline=" + timeline.joined(separator: ",")
            + "; markdownTail=" + markdownTail
    }
}
