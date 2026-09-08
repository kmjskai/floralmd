//
//  FloralMDTests.swift
//  FloralMDTests
//
//  Created by Yingkai Sun on 2026/8/9.
//

import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct FloralMDTests {

    @Test func periodicDocumentAutosaveUsesTheProductDelay() {
        let controller = NSDocumentController()

        DocumentAutosavePolicy.apply(to: controller)

        #expect(controller.autosavingDelay == 2)
    }

    @Test func workspaceFileStoreSupportsInPlaceAutosave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Workspace-Autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("note.md")
        try Data("before".utf8).write(to: fileURL)

        try WorkspaceFileStore().saveMarkdown("after", at: fileURL)

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "after")
    }

    @Test func firstSaveURLChangeDoesNotReloadTheEditorBuffer() {
        #expect(!CodeMirrorEditorView.Coordinator.shouldReloadEditor(
            newMarkdown: "same draft",
            lastEditorMarkdown: "same draft"
        ))
        #expect(CodeMirrorEditorView.Coordinator.shouldReloadEditor(
            newMarkdown: "changed externally",
            lastEditorMarkdown: "same draft"
        ))
    }

    @Test func windowPinningModesChooseExpectedLevels() {
        #expect(WindowPinningMode.none.windowLevel == .normal)
        #expect(WindowPinningMode.currentSpace.windowLevel == .floating)
        #expect(WindowPinningMode.allSpaces.windowLevel == .floating)
    }

    @Test func windowPinningModeTogglesInBothDirections() {
        var mode: WindowPinningMode = .none

        mode.toggle()
        #expect(mode == .currentSpace)

        mode.toggle()
        #expect(mode == .none)
    }

    @Test func onlyPinnedWindowsUseWholeWindowTransparency() {
        #expect(WindowPinningMode.none.backgroundOpacity == 1)
        #expect(WindowPinningMode.currentSpace.backgroundOpacity == 0.88)
        #expect(WindowPinningMode.allSpaces.backgroundOpacity == 0.88)
        #expect(WindowPinningMode.currentSpace.backgroundOpacity(pinnedWindowOpacity: 0.73) == 0.73)
        #expect(WindowPinningMode.none.sidebarBackgroundOpacity == 1)
        #expect(WindowPinningMode.currentSpace.sidebarBackgroundOpacity == 1)
        #expect(WindowPinningMode.allSpaces.sidebarBackgroundOpacity == 1)
    }

    @Test func allSpacesToggleUsesTheDedicatedMode() {
        var mode: WindowPinningMode = .none

        mode.toggleAllSpaces()
        #expect(mode == .allSpaces)

        mode.toggleAllSpaces()
        #expect(mode == .none)
    }

    @Test func allSpacesModeMovesTheSingleContentHierarchyIntoAnAuxiliaryPanel() {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        let bridge = WindowPinningHostingView(frame: .zero)
        root.addSubview(bridge)
        window.contentView = root

        bridge.mode = .allSpaces

        let panel = bridge.window as? AllSpacesWorkspacePanel
        #expect(panel != nil)
        #expect(panel?.level == .floating)
        #expect(panel?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        #expect(panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true)
        #expect(window.contentView !== root)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(abs((panel?.alphaValue ?? 0) - 0.88) < 0.001)

        bridge.mode = .none

        #expect(window.contentView === root)
        #expect(bridge.window === window)
        #expect(window.level == .normal)
        #expect(window.alphaValue == 1)
        #expect(!window.ignoresMouseEvents)
    }

    @Test func bridgeUsesUniformWholeWindowAlpha() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let bridge = WindowPinningHostingView()
        window.contentView = bridge

        bridge.mode = .currentSpace

        #expect(window.level == .floating)
        #expect(abs(window.alphaValue - 0.88) < 0.001)
        #expect(window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 1)
        #expect(window.contentView?.layer?.backgroundColor?.alpha == 1)

        bridge.mode = .none

        #expect(window.level == .normal)
        #expect(window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 1)
        #expect(window.contentView?.layer?.backgroundColor?.alpha == 1)
    }

    @Test func editorWebViewUsesPublicBackgroundProperties() {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()

        let webView = controller.view as? WKWebView
        #expect(webView?.isOpaque == false)
        #expect(webView?.underPageBackgroundColor?.alphaComponent == 0)
    }

    @Test @MainActor func editorDocumentLayersDoNotPaintAnOpaqueCanvas() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "# Transparent editor")

        var backgrounds: [String: String]?
        for _ in 0..<100 where backgrounds == nil {
            backgrounds = await withCheckedContinuation { continuation in
                controller.evaluateEditorJavaScript(
                    """
                    (() => {
                      const background = selector => {
                        const element = document.querySelector(selector);
                        return element ? getComputedStyle(element).backgroundColor : null;
                      };
                      return {
                        html: background('html'),
                        body: background('body'),
                        editor: background('.cm-editor'),
                        scroller: background('.cm-scroller')
                      };
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: String])
                }
            }
            if backgrounds == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let transparent = "rgba(0, 0, 0, 0)"
        #expect(backgrounds?["html"] == transparent)
        #expect(backgrounds?["body"] == transparent)
        #expect(backgrounds?["editor"] == transparent)
        #expect(backgrounds?["scroller"] == transparent)
    }

    @Test @MainActor func previewDocumentRootDoesNotPaintAnOpaqueCanvas() async throws {
        let webView = TransparentMarkdownWebView()
        webView.underPageBackgroundColor = .clear
        webView.loadHTMLString(
            MarkdownHTML.makeHTML(
                from: "# Transparent preview",
                allowsScroll: true
            ),
            baseURL: nil
        )

        var backgrounds: [String: String]?
        for _ in 0..<100 where backgrounds == nil {
            backgrounds = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(
                    """
                    document.readyState === 'complete' ? {
                      html: getComputedStyle(document.documentElement).backgroundColor,
                      body: getComputedStyle(document.body).backgroundColor
                    } : null
                    """
                ) { value, _ in
                    continuation.resume(returning: value as? [String: String])
                }
            }
            if backgrounds == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let transparent = "rgba(0, 0, 0, 0)"
        #expect(backgrounds?["html"] == transparent)
        #expect(backgrounds?["body"] == transparent)
    }

    @Test @MainActor func pinnedSwiftUIWindowUsesUniformWholeWindowAlpha() async throws {
        let expectedAlpha = PinnedWindowOpacityPreference.alpha(
            for: PinnedWindowOpacityPreference.load()
        )
        let hostingController = NSHostingController(
            rootView: ContentView(
                document: .constant(MarkdownDocument(text: "# Transparent window")),
                fileURL: nil
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.contentView?.layoutSubtreeIfNeeded()

        var descendants: [NSView] = []
        func collect(_ view: NSView) {
            descendants.append(view)
            view.subviews.forEach(collect)
        }
        if let contentView = window.contentView {
            collect(contentView)
        }

        let bridge = try #require(descendants.compactMap { $0 as? WindowPinningHostingView }.first)
        bridge.mode = .currentSpace

        #expect(abs(window.alphaValue - expectedAlpha) < 0.001)
        #expect(window.contentView?.layer?.backgroundColor?.alpha == 1)
        #expect(descendants.compactMap { $0 as? WKWebView }.allSatisfy {
            !$0.isOpaque && $0.underPageBackgroundColor?.alphaComponent == 0
        })
    }

    @Test func previewRendererCoversFirstPhaseMarkdownFeatures() {
        let markdown = """
        # First phase

        - [x] GFM task

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let answer = 42
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```

        $$E = mc^2$$
        """

        let rendered = MarkdownHTML.render(
            markdown: markdown,
            allowsScroll: true
        )

        #expect(rendered.articleHTML.contains("<table"))
        #expect(rendered.articleHTML.contains("type=\"checkbox\""))
        #expect(rendered.articleHTML.contains("mermaid"))
        #expect(rendered.containsCode)
        #expect(rendered.containsMermaid)
        #expect(rendered.containsMath)
        #expect(rendered.html.contains("katex"))
        #expect(rendered.html.contains("hljs"))
    }

    @Test func rendererUsesDocumentFolderAsLocalAssetBase() {
        let base = "file:///tmp/floralmd-document/"
        let html = MarkdownHTML.makeHTML(
            from: "![local](image.png)",
            allowsScroll: true,
            assetBaseHref: base
        )

        #expect(html.contains("<base href=\"\(base)\""))
        #expect(html.contains("src=\"image.png\""))
    }

    @Test func editingAndPreviewShareComfortableHorizontalGutters() {
        let outlineButtonTrailingEdge = DocumentOutlineLayout.controlInset + 36

        #expect(MarkdownHTML.pagePaddingHorizontal == 72)
        #expect(MarkdownHTML.pagePaddingHorizontal > outlineButtonTrailingEdge)
        #expect(
            MarkdownHTML.contentColumnWidth
                == Int(MarkdownHTML.preferredPageWidth - 2 * MarkdownHTML.pagePaddingHorizontal)
        )
    }

    @Test @MainActor func codeMirrorLoadsItsOfflineBundle() async throws {
        let expected = "# Offline editor\n\n中文输入基线"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: expected)

        var loadedMarkdown: String?
        for _ in 0..<100 where loadedMarkdown == nil {
            loadedMarkdown = await withCheckedContinuation { continuation in
                controller.fetchMarkdown { markdown in
                    continuation.resume(returning: markdown)
                }
            }
            if loadedMarkdown == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        #expect(loadedMarkdown == expected)
    }

    @Test @MainActor func codeMirrorAppliesTypographyWithoutReloadingTheDocument() async throws {
        let expected = "# Keep the cursor surface"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: expected)

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in
                    continuation.resume(returning: value)
                }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(state.isReady)

        controller.applyTypography(
            MarkdownTypography(fontName: "Avenir Next", fontSize: 19, lineHeight: 1.7)
        )

        var result: [String: Any]?
        for _ in 0..<100 {
            result = await withCheckedContinuation { continuation in
                controller.evaluateEditorJavaScript(
                    """
                    (() => {
                      const source = document.querySelector('.cm-line');
                      const row = document.querySelector('.cm-floralmd-gutter-line');
                      const sourceRect = source?.getBoundingClientRect();
                      const rowRect = row?.getBoundingClientRect();
                      const sourceStyle = source ? getComputedStyle(source) : null;
                      const paddingTop = parseFloat(sourceStyle?.paddingTop) || 0;
                      const paddingBottom = parseFloat(sourceStyle?.paddingBottom) || 0;
                      const contentHeight = sourceRect
                        ? sourceRect.height - paddingTop - paddingBottom
                        : null;
                      const lineHeight = parseFloat(sourceStyle?.lineHeight);
                      const sourceCenter = sourceRect
                        ? sourceRect.top + paddingTop
                          + Math.min(lineHeight, contentHeight) / 2
                        : null;
                      return {
                        markdown: window.__mdEditor.getMarkdown(),
                        family: document.documentElement.style.getPropertyValue('--floralmd-body-font-family'),
                        size: document.documentElement.style.getPropertyValue('--floralmd-body-font-size'),
                        lineHeight: document.documentElement.style.getPropertyValue('--floralmd-body-line-height'),
                        gutterCenterDelta: sourceCenter !== null && rowRect
                          ? Math.abs(sourceCenter - (rowRect.top + rowRect.height / 2))
                          : null
                      };
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Any])
                }
            }
            if (result?["gutterCenterDelta"] as? Double ?? .infinity) < 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect((result?["markdown"] as? String) == expected)
        #expect((result?["family"] as? String)?.contains("Avenir Next") == true)
        #expect((result?["size"] as? String) == "19.0px")
        #expect((result?["lineHeight"] as? String) == "1.7")
        #expect((result?["gutterCenterDelta"] as? Double ?? .infinity) < 1)
    }

    @Test @MainActor func editorShowsSemanticLabelsBeforeLineNumbers() async throws {
        let markdown = """
        # First
        ordinary
        ### Third
        Setext title
        ---
        ```swift
        let answer = 42
        ```
        """
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: markdown)

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in continuation.resume(returning: value) }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        var result: [String: Any]?
        for _ in 0..<100 {
            result = await withCheckedContinuation { continuation in
                controller.evaluateEditorJavaScript(
                    """
                    (() => {
                      const visibleText = (selector) => Array.from(document.querySelectorAll(selector))
                        .filter((element) => element.parentElement?.style.visibility !== 'hidden')
                        .map((element) => element.textContent.trim())
                        .filter(Boolean);
                      const alignmentDelta = (label, sourceSelector) => {
                        const badge = Array.from(document.querySelectorAll('.cm-semantic-badge'))
                          .find((element) => element.textContent.trim() === label);
                        const row = badge?.closest('.cm-floralmd-gutter-line');
                        const source = document.querySelector(sourceSelector);
                        if (!row || !source) return null;
                        const paddingTop = parseFloat(getComputedStyle(source).paddingTop) || 0;
                        return Math.abs(
                          row.getBoundingClientRect().top
                            - source.getBoundingClientRect().top - paddingTop
                        );
                      };
                      return {
                        labels: visibleText('.cm-semantic-badge'),
                        numbers: visibleText('.cm-floralmd-line-number'),
                        numberTextAlign: getComputedStyle(
                          document.querySelector('.cm-floralmd-line-number')
                        ).textAlign,
                        rowAlignItems: getComputedStyle(
                          document.querySelector('.cm-floralmd-gutter-line')
                        ).alignItems,
                        h1Delta: alignmentDelta('H1', '.cm-md-h1'),
                        h3Delta: alignmentDelta('H3', '.cm-md-h3'),
                        codeDelta: alignmentDelta('CODE', '.cm-md-codeblock-first')
                      };
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Any])
                }
            }
            if (result?["numbers"] as? [String])?.count == 5 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let labels = result?["labels"] as? [String]
        let numbers = result?["numbers"] as? [String]
        #expect(labels?.contains("H1") == true)
        #expect(labels?.contains("H2") == false)
        #expect(labels?.contains("H3") == true)
        #expect(labels?.contains("CODE") == true)
        #expect(numbers == ["1", "2", "3", "4", "5", "7"])
        #expect(result?["numberTextAlign"] as? String == "center")
        #expect(result?["rowAlignItems"] as? String == "center")
        #expect((result?["h1Delta"] as? Double ?? .infinity) < 1)
        #expect((result?["h3Delta"] as? Double ?? .infinity) < 1)
        #expect((result?["codeDelta"] as? Double ?? .infinity) < 1)
    }

    @Test @MainActor func semanticGutterDoesNotTreatListItemsAsSetextHeadings() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "- first\n- second\n- third\n-")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in continuation.resume(returning: value) }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        var result: [String: Any]?
        for _ in 0..<100 {
            result = await withCheckedContinuation { continuation in
                controller.evaluateEditorJavaScript(
                    """
                    ({
                      labels: Array.from(document.querySelectorAll('.cm-semantic-badge'))
                        .map(element => element.textContent.trim()),
                      numberCount: document.querySelectorAll('.cm-floralmd-line-number').length
                    })
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Any])
                }
            }
            if result?["numberCount"] as? Int == 4 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(result?["numberCount"] as? Int == 4)
        #expect((result?["labels"] as? [String])?.isEmpty == true)
    }

    @Test @MainActor func incompleteCodeFenceStaysVisibleUntilItIsClosed() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "```python")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in continuation.resume(returning: value) }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let incomplete = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  const firstLine = document.querySelector('.cm-line');
                  return {
                    source: window.__mdEditor?.getMarkdown(),
                    firstLineText: firstLine?.textContent,
                    firstLineHeight: firstLine?.getBoundingClientRect().height,
                    codeLines: document.querySelectorAll('.cm-md-codeblock').length,
                    hiddenFences: document.querySelectorAll('.cm-md-code-fence-source-hidden').length,
                    collapsedLines: document.querySelectorAll('.cm-md-line-collapsed').length,
                    codeLabels: Array.from(document.querySelectorAll('.cm-semantic-badge'))
                      .filter(element => element.textContent.trim() === 'CODE').length
                  };
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(incomplete?["source"] as? String == "```python")
        #expect(incomplete?["firstLineText"] as? String == "```python")
        #expect((incomplete?["firstLineHeight"] as? Double ?? 0) > 1)
        #expect(incomplete?["codeLines"] as? Int == 0)
        #expect(incomplete?["hiddenFences"] as? Int == 0)
        #expect(incomplete?["collapsedLines"] as? Int == 0)
        #expect(incomplete?["codeLabels"] as? Int == 0)

        _ = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  const editor = window.__mdEditor;
                  editor?.select(editor.getMarkdown().length);
                  editor?.insert('\\nvalue\\n```');
                  return true;
                })()
                """
            ) { value in
                continuation.resume(returning: value)
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        let closed = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                ({
                  source: window.__mdEditor?.getMarkdown(),
                  codeLines: document.querySelectorAll('.cm-md-codeblock').length,
                  codeLabels: Array.from(document.querySelectorAll('.cm-semantic-badge'))
                    .filter(element => element.textContent.trim() === 'CODE').length
                })
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(closed?["source"] as? String == "```python\nvalue\n```")
        #expect((closed?["codeLines"] as? Int ?? 0) > 0)
        #expect(closed?["codeLabels"] as? Int == 1)
    }

    @Test @MainActor func codeMirrorPushesEveryEditBackToSwift() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "start")

        var initialMarkdown: String?
        for _ in 0..<100 where initialMarkdown == nil {
            initialMarkdown = await withCheckedContinuation { continuation in
                controller.fetchMarkdown { markdown in
                    continuation.resume(returning: markdown)
                }
            }
            if initialMarkdown == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        var bridgedMarkdown: String?
        controller.contentDidChange = { markdown in
            bridgedMarkdown = markdown
        }
        controller.insert(markdown: " updated")

        for _ in 0..<100 where bridgedMarkdown == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(bridgedMarkdown == " updatedstart")
    }

    @Test @MainActor func codeMirrorIsActuallyReadyEditableAndFocused() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "# Focused editor")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where state != .init(isReady: true, isFocused: true, isEditable: true) {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { state in
                    continuation.resume(returning: state)
                }
            }
            if state != .init(isReady: true, isFocused: true, isEditable: true) {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        #expect(state.isReady)
        #expect(state.isEditable)
        #expect(state.isFocused)
    }

    @Test @MainActor func commandFShowsEditorFindAndSelectsMatchingMarkdown() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "alpha beta alpha")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in continuation.resume(returning: value) }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(state.isReady)

        let result = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  document.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'f', metaKey: true, bubbles: true, cancelable: true
                  }));
                  const input = document.getElementById('floralmd-find-input');
                  input.value = 'alpha';
                  input.dispatchEvent(new Event('input', { bubbles: true }));
                  const selection = window.__mdEditor._selectionForTesting();
                  const range = window.__mdEditor._findRangeForTesting();
                  return {
                    hidden: document.getElementById('floralmd-findbar').hidden,
                    status: document.getElementById('floralmd-find-status').textContent,
                    selectionEmpty: selection.from === selection.to,
                    highlighted: range?.toString(),
                    currentHighlightRectCount:
                      document.querySelectorAll('.floralmd-find-highlight-current').length,
                    paleHighlightRectCount:
                      document.querySelectorAll('.floralmd-find-highlight-all').length
                  };
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(result?["hidden"] as? Bool == false)
        #expect(result?["status"] as? String == "1 / 2")
        #expect(result?["selectionEmpty"] as? Bool == true)
        #expect(result?["highlighted"] as? String == "alpha")
        #expect((result?["currentHighlightRectCount"] as? Int ?? 0) > 0)
        #expect((result?["paleHighlightRectCount"] as? Int ?? 0) > 0)
    }

    @Test @MainActor func editorFindKeepsRenderedHeadingStableAndReplacesOldHighlight() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "# 2026\n\n2026")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { value in continuation.resume(returning: value) }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(state.isReady)

        let result = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  window.__mdEditor.openFind();
                  const input = document.getElementById('floralmd-find-input');
                  input.value = '2';
                  input.dispatchEvent(new Event('input', { bubbles: true }));
                  input.value = '2026';
                  input.dispatchEvent(new Event('input', { bubbles: true }));
                  const headingPrefix =
                    document.querySelector('.cm-md-heading-source-hidden');
                  const headingStayedRendered =
                    !!document.querySelector('.cm-md-h1.cm-md-heading-inactive') &&
                    headingPrefix?.getBoundingClientRect().width < 0.5 &&
                    document.querySelector('.cm-md-h1')?.textContent === '# 2026';
                  const firstRange = window.__mdEditor._findRangeForTesting();
                  document.getElementById('floralmd-find-next').click();
                  const secondRange = window.__mdEditor._findRangeForTesting();
                  const selection = window.__mdEditor._selectionForTesting();
                  const overlayMatches = Array.from(
                    document.querySelectorAll('.floralmd-find-highlight')
                  ).map(element => element.dataset.match);
                  const currentHighlightRectCount =
                    document.querySelectorAll('.floralmd-find-highlight-current').length;
                  const paleHighlightRectCount =
                    document.querySelectorAll('.floralmd-find-highlight-all').length;
                  const status = document.getElementById('floralmd-find-status').textContent;
                  document.getElementById('floralmd-find-close').click();
                  return {
                    headingStayedRendered,
                    firstText: firstRange?.toString(),
                    secondText: secondRange?.toString(),
                    rangeWasReplaced: firstRange !== secondRange,
                    selectionEmpty: selection.from === selection.to,
                    currentHighlightRectCount,
                    paleHighlightRectCount,
                    overlayMatches,
                    highlightsClearedOnClose:
                      document.getElementById('floralmd-find-highlights').childElementCount === 0,
                    selectionBackgroundCount: document.querySelectorAll('.cm-selectionBackground').length,
                    status
                  };
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(result?["headingStayedRendered"] as? Bool == true)
        #expect(result?["firstText"] as? String == "2026")
        #expect(result?["secondText"] as? String == "2026")
        #expect(result?["rangeWasReplaced"] as? Bool == true)
        #expect(result?["selectionEmpty"] as? Bool == true)
        #expect((result?["currentHighlightRectCount"] as? Int ?? 0) > 0)
        #expect((result?["paleHighlightRectCount"] as? Int ?? 0) > 0)
        #expect((result?["overlayMatches"] as? [String])?.allSatisfy { $0 == "2026" } == true)
        #expect(result?["highlightsClearedOnClose"] as? Bool == true)
        #expect(result?["selectionBackgroundCount"] as? Int == 0)
        #expect(result?["status"] as? String == "2 / 2")
    }

    @Test @MainActor func imeMarkedRangeKeepsMarkdownSourceActive() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "# ni")

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<100 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { state in
                    continuation.resume(returning: state)
                }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let result = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  try {
                    const editor = window.__mdEditor;
                    const content = document.querySelector('.cm-content');
                    if (!editor || !content) return null;
                    editor.focus();
                    editor.select(2, 4);
                    editor._setCompositionActiveForTesting(true);
                    const sourceVisibleDuringComposition =
                        !document.querySelector('.cm-md-heading-source-hidden') &&
                        document.querySelector('.cm-md-h1')?.textContent === '# ni';
                    const noInactiveOffsetDuringComposition =
                        !document.querySelector('.cm-md-heading-inactive');
                    const headingSizedDuringComposition =
                        !!document.querySelector('.cm-md-h1');
                    editor._setCompositionActiveForTesting(false);
                    const hiddenPrefix =
                        document.querySelector('.cm-md-heading-source-hidden');
                    const inactiveAfterComposition =
                        hiddenPrefix?.getBoundingClientRect().width < 0.5 &&
                        !!document.querySelector('.cm-md-heading-inactive') &&
                        document.querySelector('.cm-md-h1')?.textContent === '# ni';
                    return {
                        sourceVisibleDuringComposition,
                        noInactiveOffsetDuringComposition,
                        headingSizedDuringComposition,
                        inactiveAfterComposition
                    };
                  } catch (error) {
                    return { error: String(error) };
                  }
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(result?["error"] == nil)
        #expect(result?["sourceVisibleDuringComposition"] as? Bool == true)
        #expect(result?["noInactiveOffsetDuringComposition"] as? Bool == true)
        #expect(result?["headingSizedDuringComposition"] as? Bool == true)
        #expect(result?["inactiveAfterComposition"] as? Bool == true)
    }

    @Test @MainActor func editorLivePreviewsInteractiveMarkdownFeatures() async throws {
        let markdown = """
        Intro

        - [ ] Open task

        Inline $E = mc^2$ formula.

        $$
        \\frac{1}{2}
        $$

        ```swift
        let answer = 42
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```

        [OpenAI](https://openai.com)
        """
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: markdown)

        var state = CodeMirrorEditorViewController.EditorState(
            isReady: false,
            isFocused: false,
            isEditable: false
        )
        for _ in 0..<200 where !state.isReady {
            state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { state in
                    continuation.resume(returning: state)
                }
            }
            if !state.isReady {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let result = await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                """
                (() => {
                  try {
                    const editor = window.__mdEditor;
                    if (!editor) return null;
                    const task = document.querySelector('.cm-md-task-checkbox');
                    const source = editor.getMarkdown();
                    const codePosition = source.indexOf('let answer') + 2;
                    task?.click();
                    editor.select(codePosition);
                    return {
                      hasKaTeX: !!window.katex,
                      hasMermaid: !!window.mermaid,
                      hasTask: !!task,
                      taskUpdated: editor.getMarkdown().includes('- [x] Open task'),
                      hasInlineMath: !!document.querySelector('.cm-md-math-inline .katex'),
                      hasDisplayMath: !!document.querySelector('.cm-md-math-display .katex-display'),
                      hasMermaidPreview: !!document.querySelector('.cm-md-mermaid-preview'),
                      hasCommandLink: !!document.querySelector('.cm-md-link[data-md-href="https://openai.com"]'),
                      codeFencesVisible: document.querySelectorAll('.cm-md-line-collapsed').length === 0
                    };
                  } catch (error) {
                    return { error: String(error) };
                  }
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }

        #expect(result?["error"] == nil)
        #expect(result?["hasKaTeX"] as? Bool == true)
        #expect(result?["hasMermaid"] as? Bool == true)
        #expect(result?["hasTask"] as? Bool == true)
        #expect(result?["taskUpdated"] as? Bool == true)
        #expect(result?["hasInlineMath"] as? Bool == true)
        #expect(result?["hasDisplayMath"] as? Bool == true)
        #expect(result?["hasMermaidPreview"] as? Bool == true)
        #expect(result?["hasCommandLink"] as? Bool == true)
        #expect(result?["codeFencesVisible"] as? Bool == true)
    }

    @Test func appDeclaresItsImportedMarkdownType() throws {
        let data = try Data(contentsOf: projectFile("FloralMD-Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try #require(propertyList as? [String: Any])
        let declarations = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])

        #expect(
            declarations.contains {
                $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown"
            }
        )
    }

    @Test func quickCaptureCreatesUniqueStandardMarkdownFilesWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-QuickCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = QuickCaptureFileWriter(calendar: Calendar(identifier: .gregorian))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try writer.createEmptyDocument(in: folder, now: date)
        try Data("keep me".utf8).write(to: first)
        let second = try writer.createEmptyDocument(in: folder, now: date)

        #expect(first.pathExtension == "md")
        #expect(second.pathExtension == "md")
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "keep me")
        #expect(try Data(contentsOf: second).isEmpty)
    }

    @Test func untitledAutosaveWaitsForMeaningfulContent() {
        #expect(!UntitledDocumentAutosavePolicy.shouldSchedule(
            fileURL: nil,
            text: "随手记",
            hasUserEdited: false
        ))
        #expect(!UntitledDocumentAutosavePolicy.shouldSchedule(
            fileURL: nil,
            text: " \n\t",
            hasUserEdited: true
        ))
        #expect(UntitledDocumentAutosavePolicy.shouldSchedule(
            fileURL: nil,
            text: "随手记",
            hasUserEdited: true
        ))
        #expect(!UntitledDocumentAutosavePolicy.shouldSchedule(
            fileURL: URL(fileURLWithPath: "/tmp/already-saved.md"),
            text: "随手记",
            hasUserEdited: true
        ))
    }

    @Test func onlyBlankUntitledDocumentsClearTheirEditedState() {
        #expect(UntitledDocumentContentPolicy.shouldClearEditedState(
            fileURL: nil,
            text: " \n\t"
        ))
        #expect(!UntitledDocumentContentPolicy.shouldClearEditedState(
            fileURL: nil,
            text: "还没删完"
        ))
        #expect(!UntitledDocumentContentPolicy.shouldClearEditedState(
            fileURL: URL(fileURLWithPath: "/tmp/existing.md"),
            text: ""
        ))
        #expect(!UntitledDocumentContentPolicy.needsEditedStateReconciliation(
            fileURL: nil,
            text: "",
            documentIsEdited: false,
            windowIsEdited: false
        ))
        #expect(UntitledDocumentContentPolicy.needsEditedStateReconciliation(
            fileURL: nil,
            text: "",
            documentIsEdited: true,
            windowIsEdited: false
        ))
    }

    @Test func pristineUntitledLaunchDoesNotScheduleEditedStateReconciliation() {
        #expect(!UntitledDocumentContentPolicy.shouldScheduleEditedStateReconciliation(
            fileURL: nil,
            text: "",
            hasUserEdited: false
        ))
        #expect(UntitledDocumentContentPolicy.shouldScheduleEditedStateReconciliation(
            fileURL: nil,
            text: "",
            hasUserEdited: true
        ))
    }

    @Test func blankUntitledReconciliationClearsDocumentAndWindowFlags() {
        let document = NSDocument()
        let window = NSWindow()
        document.updateChangeCount(.changeDone)
        window.isDocumentEdited = true

        UntitledDocumentContentPolicy.clearEditedState(
            of: document,
            in: window,
            fileURL: nil,
            text: ""
        )

        #expect(!document.isDocumentEdited)
        #expect(!window.isDocumentEdited)
    }

    @Test @MainActor func deletingUntitledBackToBlankSurvivesDelayedDocumentDirtyUpdate() async throws {
        let document = NSDocument()
        let window = NSWindow()
        let windowController = NSWindowController(window: window)
        let coordinator = DocumentAutosaveBridge.Coordinator()
        document.addWindowController(windowController)
        NSDocumentController.shared.addDocument(document)
        defer {
            coordinator.stop()
            document.removeWindowController(windowController)
            NSDocumentController.shared.removeDocument(document)
        }

        coordinator.setWindow(window)
        coordinator.update(text: "# draft", fileURL: nil, hasUserEdited: true)
        document.updateChangeCount(.changeDone)
        window.isDocumentEdited = true
        coordinator.update(text: "", fileURL: nil, hasUserEdited: true)

        try await Task.sleep(for: .milliseconds(100))
        document.updateChangeCount(.changeDone)
        window.isDocumentEdited = true

        try await Task.sleep(for: .milliseconds(250))

        #expect(!document.isDocumentEdited)
        #expect(!window.isDocumentEdited)
    }

    @Test func successfulUntitledSaveClearsEditedStateOnlyWhenDiskMatches() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Save-State-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fileURL = folder.appendingPathComponent("draft.md")
        try Data("saved text".utf8).write(to: fileURL)

        let document = NSDocument()
        document.fileURL = fileURL
        document.updateChangeCount(.changeDone)
        let window = NSWindow()
        window.isDocumentEdited = true

        let clearedMismatchedState = DocumentSaveStateReconciliation.clearEditedStateIfSaved(
            document: document,
            window: window,
            destinationURL: fileURL,
            currentText: "newer edit"
        )

        #expect(!clearedMismatchedState)
        #expect(document.isDocumentEdited)
        #expect(window.isDocumentEdited)

        let clearedSavedState = DocumentSaveStateReconciliation.clearEditedStateIfSaved(
            document: document,
            window: window,
            destinationURL: fileURL,
            currentText: "saved text"
        )

        #expect(clearedSavedState)
        #expect(!document.isDocumentEdited)
        #expect(!window.isDocumentEdited)
    }

    @Test func existingDocumentAutosaveRequiresAPendingChangeThatDiffersFromDisk() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Existing-Autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fileURL = folder.appendingPathComponent("note.md")
        try Data("on disk".utf8).write(to: fileURL)

        #expect(!ExistingDocumentAutosavePolicy.shouldSchedule(
            hasPendingTextChange: false,
            currentText: "new edit",
            fileURL: fileURL
        ))
        #expect(!ExistingDocumentAutosavePolicy.shouldSchedule(
            hasPendingTextChange: true,
            currentText: "on disk",
            fileURL: fileURL
        ))
        #expect(ExistingDocumentAutosavePolicy.shouldSchedule(
            hasPendingTextChange: true,
            currentText: "new edit",
            fileURL: fileURL
        ))
    }

    @Test func launchCreatesOneUntitledWindowOnlyWithoutAnExplicitDocument() {
        #expect(FloralMDLaunchPolicy.shouldOpenUntitledDocument(
            arguments: ["FloralMD", "-NSDocumentRevisionsDebugMode", "YES"],
            hasOpenDocuments: false
        ))
        #expect(!FloralMDLaunchPolicy.shouldOpenUntitledDocument(
            arguments: ["FloralMD", "/tmp/open-me.md"],
            hasOpenDocuments: false
        ))
        #expect(!FloralMDLaunchPolicy.shouldOpenUntitledDocument(
            arguments: ["FloralMD", "/tmp/open-me.excalidraw"],
            hasOpenDocuments: false
        ))
        #expect(!FloralMDLaunchPolicy.shouldOpenUntitledDocument(
            arguments: ["FloralMD", "/tmp/open-me.png"],
            hasOpenDocuments: false
        ))
        #expect(!FloralMDLaunchPolicy.shouldOpenUntitledDocument(
            arguments: ["FloralMD"],
            hasOpenDocuments: true
        ))
    }

    @Test func fileBrowserShowsOnlyDirectoriesAndMarkdownWithFoldersFirst() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: folder.appendingPathComponent("b.markdown"))
        try Data().write(to: folder.appendingPathComponent("A.md"))
        try Data().write(to: folder.appendingPathComponent("ignored.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden.md"))

        let entries = try MarkdownFileBrowser().children(of: folder)

        #expect(entries.map(\.name) == ["Notes", "A.md", "b.markdown"])
        #expect(entries.map(\.kind) == [.directory, .markdown, .markdown])
        #expect(MarkdownFileBrowser.canOpen(folder.appendingPathComponent("UPPER.MD")))
        #expect(!MarkdownFileBrowser.canOpen(folder.appendingPathComponent("plain.txt")))
    }

    @Test func fileBrowserReportsDirectoryReadFailuresInsteadOfPretendingTheyAreEmpty() {
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Missing-\(UUID().uuidString)", isDirectory: true)
        var didThrow = false

        do {
            _ = try MarkdownFileBrowser().children(of: missingFolder)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test func nativeFileTreeCachesChildrenBetweenOutlineViewRequests() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-TreeCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data().write(to: folder.appendingPathComponent("first.md"))
        let node = MarkdownFileTreeNode(
            entry: MarkdownFileEntry(url: folder, kind: .directory)
        )
        let firstRead = node.children()

        try Data().write(to: folder.appendingPathComponent("second.md"))
        let cachedRead = node.children()

        #expect(firstRead.map(\.entry.name) == ["first.md"])
        #expect(cachedRead.map(\.entry.name) == ["first.md"])
    }

    @Test func fileSidebarInformationActionsUseTheContextItemPaths() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD Notes", isDirectory: true)
        let nestedFile = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("Plan.md")
        let information = FileSidebarItemInformation(rootURL: root, itemURL: nestedFile)

        #expect(FileSidebarInformationAction.copyFileName.clipboardText(for: information)
            == "Plan.md")
        #expect(FileSidebarInformationAction.copyRelativePath.clipboardText(for: information)
            == "Projects/Plan.md")
        #expect(FileSidebarInformationAction.copyAbsolutePath.clipboardText(for: information)
            == "/tmp/FloralMD Notes/Projects/Plan.md")
    }

    @Test func fileSidebarInformationActionsAlsoSupportFolders() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD", isDirectory: true)
        let nestedFolder = root
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
        let information = FileSidebarItemInformation(rootURL: root, itemURL: nestedFolder)

        #expect(information.fileName == "2026")
        #expect(information.relativePath == "Archive/2026")
        #expect(information.absolutePath == "/tmp/FloralMD/Archive/2026")
        #expect(FileSidebarInformationAction.allCases.map(\.title) == [
            "复制文件名",
            "复制相对路径",
            "复制绝对路径"
        ])
    }

    @Test func fileSidebarFileOperationsCreateRenameAndDuplicateWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-P3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let operations = FileSidebarFileOperations()
        let firstFile = try operations.createMarkdown(in: root, name: "Plan.md")
        try Data("content".utf8).write(to: firstFile)
        let firstCopy = try operations.duplicateMarkdown(at: firstFile)
        let secondCopy = try operations.duplicateMarkdown(at: firstFile)
        let unchangedFile = try operations.renameDestination(for: firstFile, name: "Plan.md")
        let folder = try operations.createDirectory(in: root, name: "Archive")
        let renamedFolder = try operations.renameDestination(for: folder, name: "History")
        try operations.renameItem(at: folder, to: renamedFolder)

        #expect(firstCopy.lastPathComponent == "Plan 副本.md")
        #expect(secondCopy.lastPathComponent == "Plan 副本 2.md")
        #expect(unchangedFile.standardizedFileURL == firstFile.standardizedFileURL)
        #expect(try String(contentsOf: firstCopy, encoding: .utf8) == "content")
        #expect(FileManager.default.fileExists(atPath: renamedFolder.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func fileSidebarSuggestedNamesAndPathRelocationCoverNestedDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-P3-Names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let operations = FileSidebarFileOperations()
        _ = try operations.createMarkdown(in: root, name: "未命名.md")
        _ = try operations.createDirectory(in: root, name: "新建文件夹")

        #expect(operations.suggestedMarkdownURL(in: root).lastPathComponent == "未命名 2.md")
        #expect(operations.suggestedDirectoryURL(in: root).lastPathComponent == "新建文件夹 2")

        let oldFolder = root.appendingPathComponent("Old", isDirectory: true)
        let currentDocument = oldFolder
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("Note.md")
        let newFolder = root.appendingPathComponent("New", isDirectory: true)
        let relocated = FileSidebarPathChange.relocatedURL(
            for: currentDocument,
            moving: oldFolder,
            to: newFolder
        )

        #expect(FileSidebarPathChange.contains(currentDocument, in: oldFolder))
        #expect(relocated == newFolder
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("Note.md"))
        #expect(FileSidebarPathChange.relocatedURL(
            for: currentDocument,
            moving: root.appendingPathComponent("Other", isDirectory: true),
            to: newFolder
        ) == nil)
    }

    @Test func renamingCurrentDocumentAndItsParentKeepsFutureSavesAtTheNewURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-P3-Document-\(UUID().uuidString)", isDirectory: true)
        let originalFolder = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalFile = originalFolder.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: originalFile)
        let document = P3TestDocument()
        document.fileURL = originalFile
        document.fileType = MarkdownDocument.markdownType.identifier
        document.text = "renamed file"
        let documentController = NSDocumentController()
        documentController.addDocument(document)
        defer { document.close() }

        let coordinator = FileSidebarMutationCoordinator(
            operations: FileSidebarFileOperations(),
            documentController: documentController
        )
        _ = try await coordinator.perform(
            .rename(itemURL: originalFile, name: "Renamed.md"),
            currentDocumentURL: originalFile
        )
        let renamedFile = originalFolder.appendingPathComponent("Renamed.md")

        #expect(document.fileURL?.standardizedFileURL == renamedFile.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        #expect(try String(contentsOf: renamedFile, encoding: .utf8) == "renamed file")

        let otherFile = originalFolder.appendingPathComponent("Other.md")
        try Data("other disk".utf8).write(to: otherFile)
        let otherDocument = P3TestDocument()
        otherDocument.fileURL = otherFile
        otherDocument.fileType = MarkdownDocument.markdownType.identifier
        otherDocument.text = "other open document"
        documentController.addDocument(otherDocument)
        defer { otherDocument.close() }

        document.text = "renamed parent"
        _ = try await coordinator.perform(
            .rename(itemURL: originalFolder, name: "Moved"),
            currentDocumentURL: renamedFile
        )
        let finalFile = root
            .appendingPathComponent("Moved", isDirectory: true)
            .appendingPathComponent("Renamed.md")
        let finalOtherFile = root
            .appendingPathComponent("Moved", isDirectory: true)
            .appendingPathComponent("Other.md")
        document.text = "future save"
        otherDocument.text = "other future save"
        try await saveP3TestDocument(document)
        try await saveP3TestDocument(otherDocument)

        #expect(document.fileURL?.standardizedFileURL == finalFile.standardizedFileURL)
        #expect(otherDocument.fileURL?.standardizedFileURL == finalOtherFile.standardizedFileURL)
        #expect(try String(contentsOf: finalFile, encoding: .utf8) == "future save")
        #expect(try String(contentsOf: finalOtherFile, encoding: .utf8) == "other future save")
        #expect(!FileManager.default.fileExists(atPath: renamedFile.path))
    }

    @Test func folderAuthorizationOnlyAcceptsTheRequestedFolder() {
        let requested = URL(fileURLWithPath: "/tmp/FloralMD/Notes", isDirectory: true)

        #expect(FolderAuthorization.matches(
            requestedFolder: requested,
            selectedFolder: requested.appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
        ))
        #expect(!FolderAuthorization.matches(
            requestedFolder: requested,
            selectedFolder: URL(fileURLWithPath: "/tmp/FloralMD/Other", isDirectory: true)
        ))
    }

    @Test func commandPaletteCatalogCoversEveryRequiredGlobalCommand() {
        let expectedIDs: Set<String> = [
            "mode.edit",
            "mode.preview",
            "sidebar.files",
            "sidebar.outline",
            "window.pin.none",
            "window.pin.current-space",
            "window.pin.all-spaces",
            "app.settings",
            "drawing.export-svg",
            "app.open-workspace",
            "app.new-drawing",
            "app.quick-capture",
            "app.change-default-folder",
            "app.drawing-svg-sync-settings",
            "markdown.viewport-zoom-increase",
            "markdown.viewport-zoom-decrease",
            "markdown.viewport-zoom-reset",
            "markdown.font-size-increase",
            "markdown.font-size-decrease",
            "markdown.font-size-reset",
            "markdown.typewriter-mode.toggle",
            "markdown.table.insert-basic"
        ]

        #expect(FloralMDCommandCatalog.requiredCommandIDs == expectedIDs)
        #expect(Set(FloralMDCommandCatalog.menuBackedCommands.map(\.id)) == [
            "app.open-workspace",
            "app.new-drawing",
            "app.quick-capture",
            "app.change-default-folder",
            "app.drawing-svg-sync-settings",
            "markdown.viewport-zoom-increase",
            "markdown.viewport-zoom-decrease",
            "markdown.viewport-zoom-reset",
            "markdown.font-size-increase",
            "markdown.font-size-decrease",
            "markdown.font-size-reset",
            "markdown.typewriter-mode.toggle"
        ])
        #expect(FloralMDCommandCatalog.menuBackedCommands.allSatisfy {
            !$0.title.isEmpty && !$0.systemImage.isEmpty && !$0.keywords.isEmpty
        })
        #expect(FloralMDCommandCatalog.newDrawing.shortcut == "⌘⇧D")
        #expect(FloralMDCommandCatalog.openWorkspace.shortcut == "⌃⌘O")
        #expect(FloralMDCommandCatalog.quickCapture.shortcut == "⌃⌥N")
        #expect(FloralMDCommandCatalog.changeDefaultFolder.shortcut == nil)
        #expect(FloralMDCommandCatalog.drawingSVGSyncSettings.shortcut == nil)
        #expect(FloralMDCommandCatalog.exportDrawingSVG.shortcut == nil)
        #expect(FloralMDCommandCatalog.increaseMarkdownViewportZoom.shortcut == "⌘+")
        #expect(FloralMDCommandCatalog.decreaseMarkdownViewportZoom.shortcut == "⌘−")
        #expect(FloralMDCommandCatalog.resetMarkdownViewportZoom.shortcut == "⌘0")
        #expect(FloralMDCommandCatalog.increaseMarkdownFontSize.shortcut == nil)
        #expect(FloralMDCommandCatalog.decreaseMarkdownFontSize.shortcut == nil)
        #expect(FloralMDCommandCatalog.resetMarkdownFontSize.shortcut == nil)
        #expect(FloralMDCommandCatalog.toggleMarkdownTypewriterMode.shortcut == nil)
        #expect(FloralMDCommandCatalog.insertBasicMarkdownTable.title == "插入表格")
        #expect(FloralMDCommandCatalog.insertBasicMarkdownTable.shortcut == nil)
        #expect(CommandPaletteLayout.width == 600)
        #expect(CommandPaletteLayout.height == 380)
    }

    @Test func basicMarkdownTableCommandRequiresAnEditableReadyEditor() {
        #expect(!MarkdownTableInsertionAvailability.resolve(
            activeKind: nil,
            mode: .edit,
            editorReady: true
        ))
        #expect(!MarkdownTableInsertionAvailability.resolve(
            activeKind: .drawing,
            mode: .edit,
            editorReady: true
        ))
        #expect(!MarkdownTableInsertionAvailability.resolve(
            activeKind: .markdown,
            mode: .preview,
            editorReady: true
        ))
        #expect(!MarkdownTableInsertionAvailability.resolve(
            activeKind: .markdown,
            mode: .edit,
            editorReady: false
        ))
        #expect(MarkdownTableInsertionAvailability.resolve(
            activeKind: .markdown,
            mode: .edit,
            editorReady: true
        ))
    }

    @Test func commandPaletteSearchFindsEveryMenuBackedGlobalCommand() {
        let commands = FloralMDCommandCatalog.menuBackedCommands.map {
            FloralMDCommand(descriptor: $0, action: {})
        }

        #expect(CommandPaletteSearch.filter(commands, query: "绘图").map(\.id) == [
            "app.new-drawing",
            "app.drawing-svg-sync-settings"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "快速记录").map(\.id) == [
            "app.quick-capture"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "open workspace").map(\.id) == [
            "app.open-workspace"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "默认文件夹").map(\.id) == [
            "app.change-default-folder"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "保存位置").map(\.id) == [
            "app.change-default-folder"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "SVG 自动同步").map(\.id) == [
            "app.drawing-svg-sync-settings"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "放大").map(\.id) == [
            "markdown.viewport-zoom-increase"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "默认 Markdown 基础字号").map(\.id) == [
            "markdown.font-size-reset"
        ])
        #expect(CommandPaletteSearch.filter(commands, query: "100 默认").map(\.id) == [
            "markdown.viewport-zoom-reset"
        ])
        let insertTable = FloralMDCommand(
            descriptor: FloralMDCommandCatalog.insertBasicMarkdownTable,
            action: {}
        )
        #expect(CommandPaletteSearch.filter([insertTable], query: "表格").map(\.id) == [
            "markdown.table.insert-basic"
        ])
        #expect(CommandPaletteSearch.filter([insertTable], query: "table").map(\.id) == [
            "markdown.table.insert-basic"
        ])
    }

    @Test func commandPaletteEntryStaysInViewMenuWithItsShortcut() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/FloralMDApp.swift"),
            encoding: .utf8
        )
        let nativeCommandsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/NativeMacCommands.swift"),
            encoding: .utf8
        )
        let contentViewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/ContentView.swift"),
            encoding: .utf8
        )
        let commandPaletteSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/CommandPalette.swift"),
            encoding: .utf8
        )
        let localizationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/Localizable.xcstrings"),
            encoding: .utf8
        )

        #expect(!appSource.contains("CommandMenu("))
        #expect(appSource.contains("FloralMDWorkspaceCommands()"))
        #expect(nativeCommandsSource.contains("CommandGroup(after: .toolbar)"))
        #expect(nativeCommandsSource.contains("Button(\"Command Palette…\")"))
        #expect(nativeCommandsSource.contains(".keyboardShortcut(\"p\", modifiers: [.command, .shift])"))
        #expect(nativeCommandsSource.contains("showCommandPalette?()"))
        #expect(nativeCommandsSource.contains(".keyboardShortcut(\"+\", modifiers: .command)"))
        #expect(nativeCommandsSource.contains(".keyboardShortcut(\"-\", modifiers: .command)"))
        #expect(nativeCommandsSource.contains(".keyboardShortcut(\"0\", modifiers: .command)"))
        #expect(!contentViewSource.contains(".sheet(isPresented: $isCommandPalettePresented)"))
        #expect(!contentViewSource.contains("if isCommandPalettePresented"))
        #expect(contentViewSource.contains("CommandPalettePanelController.shared.show"))
        #expect(commandPaletteSource.contains("styleMask: [.borderless, .closable]"))
        #expect(commandPaletteSource.contains("func windowDidResignKey"))
        #expect(commandPaletteSource.contains("func windowWillClose"))
        #expect(commandPaletteSource.contains("panel.makeFirstResponder(searchField)"))
        #expect(commandPaletteSource.contains("searchField.selectText(nil)"))
        #expect(!commandPaletteSource.contains(".transition("))
        #expect(!commandPaletteSource.contains(".animation("))
        // Xcode rewrites .xcstrings in its own JSON style (`"key" : "value"`)
        // while the committed file may use compact JSON — accept both.
        #expect(localizationSource.range(
            of: #""sourceLanguage"\s*:\s*"en""#, options: .regularExpression) != nil)
        #expect(localizationSource.range(
            of: #""value"\s*:\s*"命令面板…""#, options: .regularExpression) != nil)
    }

    @Test func nativeApplicationCommandsCoverStandardFileEntriesAcrossScenes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/FloralMDApp.swift"),
            encoding: .utf8
        )
        let commandsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/NativeMacCommands.swift"),
            encoding: .utf8
        )
        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("FloralMD/WorkspaceSidebar.swift"),
            encoding: .utf8
        )

        #expect(appSource.components(separatedBy: "FloralMDApplicationCommands()").count == 3)
        #expect(commandsSource.contains("CommandGroup(replacing: .newItem)"))
        #expect(commandsSource.contains(".keyboardShortcut(\"n\", modifiers: .command)"))
        #expect(commandsSource.contains(".keyboardShortcut(\"o\", modifiers: .command)"))
        #expect(commandsSource.contains("CommandGroup(before: .saveItem)"))
        #expect(!commandsSource.contains("CommandGroup(replacing: .saveItem)"))
        #expect(!commandsSource.contains(".keyboardShortcut(\"w\""))
        #expect(!commandsSource.contains(".keyboardShortcut(\"q\""))
        #expect(commandsSource.contains("@FocusedValue(\\.adjustFloralMDMarkdownViewportZoom)"))
        #expect(commandsSource.contains("@FocusedValue(\\.workspaceFileSidebarCommandAction)"))
        #expect(commandsSource.contains(".keyboardShortcut(\"x\", modifiers: .command)"))
        #expect(commandsSource.contains(".keyboardShortcut(\"c\", modifiers: .command)"))
        #expect(commandsSource.contains(".keyboardShortcut(\"v\", modifiers: .command)"))
        #expect(commandsSource.contains("if let workspaceFileAction"))
        #expect(commandsSource.contains(".keyboardShortcut(.return, modifiers: [])"))
        #expect(commandsSource.contains(".keyboardShortcut(.delete, modifiers: [])"))
        #expect(commandsSource.contains("Button(\"复制\") {}"))
        #expect(sidebarSource.contains(".focusable()\n        .focusEffectDisabled()"))
        #expect(sidebarSource.contains(".focused($isSidebarFocused)"))
        #expect(sidebarSource.contains(
            "isSidebarFocused ? WorkspaceFileSidebarCommandAction(perform: performSidebarCommand) : nil"
        ))
    }

    @Test func webViewsReserveOnlySystemWindowAndVisibilityShortcuts() {
        #expect(
            FloralMDWebSystemCommand.resolve(key: "f", modifiers: [.command, .control])
                == .toggleFullScreen
        )
        #expect(
            FloralMDWebSystemCommand.resolve(key: "h", modifiers: [.command])
                == .hideApplication
        )
        #expect(
            FloralMDWebSystemCommand.resolve(key: "h", modifiers: [.command, .option])
                == .hideOtherApplications
        )
        #expect(FloralMDWebSystemCommand.resolve(key: "f", modifiers: [.command]) == nil)
        #expect(FloralMDWebSystemCommand.resolve(key: "z", modifiers: [.command]) == nil)
    }

    @Test @MainActor func emptyWorkspaceCommandPaletteOmitsContextualResourceCommands() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Workspace-Commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let controller = try WorkspaceController(
            draftRootProvider: { workspaceRoot }
        )
        let contentView = WorkspaceContentView(controller: controller)
        let paletteCommandIDs = Set(contentView.commandPaletteCommands.map(\.id))

        #expect(paletteCommandIDs.count > 0)
        #expect(paletteCommandIDs.contains("mode.edit"))
        #expect(paletteCommandIDs.contains("mode.preview"))
        #expect(paletteCommandIDs.contains("sidebar.outline"))
        #expect(paletteCommandIDs.contains("app.change-default-folder"))
        #expect(!paletteCommandIDs.contains("drawing.export-svg"))
        #expect(
            paletteCommandIDs == FloralMDCommandCatalog.requiredCommandIDs
                .subtracting([FloralMDCommandCatalog.exportDrawingSVG.id])
                .subtracting(FloralMDCommandCatalog.markdownFontSizeCommandIDs)
                .subtracting(FloralMDCommandCatalog.markdownViewportZoomCommandIDs)
                .subtracting(FloralMDCommandCatalog.markdownEditingCommandIDs)
        )
    }

    @Test @MainActor func markdownWorkspaceCommandPaletteIncludesZoomAndBaseFontCommands() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Workspace-Font-Commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let controller = try WorkspaceController(draftRootProvider: { workspaceRoot })
        _ = try controller.createUntitledMarkdown()
        let contentView = WorkspaceContentView(controller: controller)
        let paletteCommandIDs = Set(contentView.commandPaletteCommands.map(\.id))
        let insertTable = contentView.commandPaletteCommands.first {
            $0.id == FloralMDCommandCatalog.insertBasicMarkdownTable.id
        }

        #expect(
            FloralMDCommandCatalog.markdownFontSizeCommandIDs.isSubset(of: paletteCommandIDs)
        )
        #expect(
            FloralMDCommandCatalog.markdownViewportZoomCommandIDs.isSubset(of: paletteCommandIDs)
        )
        #expect(paletteCommandIDs.contains(FloralMDCommandCatalog.insertBasicMarkdownTable.id))
        #expect(insertTable?.isEnabled == false)
        #expect(
            paletteCommandIDs == FloralMDCommandCatalog.requiredCommandIDs
                .subtracting([FloralMDCommandCatalog.exportDrawingSVG.id])
        )
    }

    @Test @MainActor func workspaceCommandPaletteAddsDrawingExportCommandOnlyForDrawingResource() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Workspace-Commands-Drawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let controller = try WorkspaceController(
            draftRootProvider: { workspaceRoot }
        )
        _ = try controller.createDrawingPlaceholder()
        let contentView = WorkspaceContentView(controller: controller)
        let paletteCommandIDs = Set(contentView.commandPaletteCommands.map(\.id))

        #expect(
            paletteCommandIDs == FloralMDCommandCatalog.requiredCommandIDs
                .subtracting(FloralMDCommandCatalog.markdownFontSizeCommandIDs)
                .subtracting(FloralMDCommandCatalog.markdownViewportZoomCommandIDs)
                .subtracting(FloralMDCommandCatalog.markdownEditingCommandIDs)
        )
    }

    @Test func markdownFontSizeAdjustmentsStepClampAndReset() {
        #expect(MarkdownFontSizeAdjustment.increase.apply(to: 15) == 16)
        #expect(MarkdownFontSizeAdjustment.decrease.apply(to: 15) == 14)
        #expect(MarkdownFontSizeAdjustment.reset.apply(to: 22) == 15)
        #expect(MarkdownFontSizeAdjustment.increase.apply(to: 28) == 28)
        #expect(MarkdownFontSizeAdjustment.decrease.apply(to: 11) == 11)
        #expect(!MarkdownFontSizeAdjustment.increase.isAvailable(at: 28))
        #expect(!MarkdownFontSizeAdjustment.decrease.isAvailable(at: 11))
        #expect(!MarkdownFontSizeAdjustment.reset.isAvailable(at: 15))
    }

    @Test func lifecycleCoordinatorKeepsTheCurrentOwnerAndCloseReason() {
        let coordinator = WorkspaceLifecycleCoordinator()
        let owner = NSObject()
        let unrelatedOwner = NSObject()
        var receivedReason: WorkspaceCloseReason?
        var receivedDecision: Bool?

        coordinator.install(owner: owner) { reason, completion in
            receivedReason = reason
            completion(false)
        }
        coordinator.uninstall(owner: unrelatedOwner)
        coordinator.request(.terminateApplication) { receivedDecision = $0 }

        #expect(receivedReason == .terminateApplication)
        #expect(receivedDecision == false)
    }

    @Test func lifecycleCoordinatorRoutesClosePerWindowAndTerminationAcrossAllWindows() {
        let coordinator = WorkspaceLifecycleCoordinator()
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        var firstReasons: [WorkspaceCloseReason] = []
        var secondReasons: [WorkspaceCloseReason] = []

        coordinator.install(owner: firstOwner) { reason, completion in
            firstReasons.append(reason)
            completion(true)
        }
        coordinator.install(owner: secondOwner) { reason, completion in
            secondReasons.append(reason)
            completion(true)
        }

        var closeDecision: Bool?
        coordinator.request(owner: secondOwner, reason: .closeWindow) { closeDecision = $0 }
        #expect(closeDecision == true)
        #expect(firstReasons.isEmpty)
        #expect(secondReasons == [.closeWindow])

        var terminateDecision: Bool?
        coordinator.requestAll(.terminateApplication) { terminateDecision = $0 }
        #expect(terminateDecision == true)
        #expect(firstReasons == [.terminateApplication])
        #expect(secondReasons == [.closeWindow, .terminateApplication])
    }

    @Test func workspaceWindowDelegateProxyDefersThenUsesTheForwardedCloseDecision() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let forwarded = TestWindowDelegate()
        let proxy = WorkspaceWindowDelegateProxy(forwardingTo: forwarded)
        var closeRequests = 0
        proxy.requestClose = { closeRequests += 1 }

        #expect(proxy.windowShouldClose(window) == false)
        #expect(closeRequests == 1)
        #expect(forwarded.closeChecks == 0)

        proxy.allowsNextClose = true
        forwarded.allowsClose = false
        #expect(proxy.windowShouldClose(window) == false)
        #expect(forwarded.closeChecks == 1)

        proxy.allowsNextClose = true
        forwarded.allowsClose = true
        #expect(proxy.windowShouldClose(window) == true)
        #expect(forwarded.closeChecks == 2)
    }

    @Test func commandPaletteSearchFindsTitlesAndKeywordsAndReportsNoMatch() {
        let commands = [
            FloralMDCommand(
                id: "preview",
                title: "切换到预览模式",
                systemImage: "doc.richtext",
                keywords: "Markdown preview",
                action: {}
            ),
            FloralMDCommand(
                id: "settings",
                title: "打开设置",
                systemImage: "gearshape",
                keywords: "偏好 settings",
                action: {}
            )
        ]

        #expect(CommandPaletteSearch.filter(commands, query: "预览").map(\.id) == ["preview"])
        #expect(CommandPaletteSearch.filter(commands, query: "SETTINGS").map(\.id) == ["settings"])
        #expect(CommandPaletteSearch.filter(commands, query: "  ").map(\.id) == ["preview", "settings"])
        #expect(CommandPaletteSearch.filter(commands, query: "不存在").isEmpty)
    }

    @Test func blankDocumentPromptOnlyAppearsForEmptyEditableMarkdown() {
        #expect(FloralMDEmptyStatePolicy.showsDocumentPrompt(markdown: "", mode: .edit))
        #expect(!FloralMDEmptyStatePolicy.showsDocumentPrompt(markdown: " \n\t", mode: .edit))
        #expect(!FloralMDEmptyStatePolicy.showsDocumentPrompt(markdown: "# 标题", mode: .edit))
        #expect(!FloralMDEmptyStatePolicy.showsDocumentPrompt(markdown: "", mode: .preview))
    }

    @Test func outlineTracksHeadingLevelsAndUTF16SourceOffsetsWhileIgnoringFences() {
        let markdown = """
        ---
        # 这是 frontmatter 注释
        title: Test
        ---
        # 总览 😀

        ```markdown
        # 代码里的假标题
        ```

        ## 第二节

        Setext 标题
        ------------
        """

        let headings = MarkdownOutline.headings(in: markdown)
        let expectedSecondOffset = (markdown as NSString).range(of: "## 第二节").location

        #expect(headings.map(\.title) == ["总览 😀", "第二节"])
        #expect(headings.map(\.level) == [1, 2])
        #expect(headings[1].sourceOffset == expectedSecondOffset)
        #expect(headings.map(\.sourceLine) == [5, 11])
        #expect(headings.map(\.id) == [0, 1])
        #expect(MarkdownOutline.headings(in: "Equals title\n====").isEmpty)
    }

    @Test func outlineDrawerReclaimsItsEntireWidthWhenCollapsed() {
        #expect(DocumentOutlineLayout.panelWidth(isVisible: false) == 0)
        #expect(DocumentOutlineLayout.panelWidth(isVisible: true)
            == DocumentOutlineLayout.expandedWidth)
    }

    @Test func previewHTMLAssignsStableOutlineTargetsInHeadingOrder() {
        let html = MarkdownHTML.makeHTML(
            from: "# First\n\n## Second\n\n### Third",
            allowsScroll: true
        )

        #expect(html.contains("id=\"md-heading-0\""))
        #expect(html.contains("id=\"md-heading-1\""))
        #expect(html.contains("id=\"md-heading-2\""))
    }

    @Test func previewTreatsSetextSourceAsParagraphRuleOrLiteralText() {
        let dashHTML = MarkdownHTML.makeHTML(from: "普通正文\n---")
        #expect(!dashHTML.contains("<h2"))
        #expect(dashHTML.contains("普通正文"))
        #expect(dashHTML.contains("<hr"))

        let equalsHTML = MarkdownHTML.makeHTML(from: "普通正文\n===")
        #expect(!equalsHTML.contains("<h1"))
        #expect(equalsHTML.contains("普通正文"))
        #expect(equalsHTML.contains("==="))
    }

    @Test func previewNeverRendersSetextInsideBlockQuotesOrCrlfFiles() {
        let quoteEquals = MarkdownHTML.makeHTML(from: "> 引用标题\n> ===")
        #expect(!quoteEquals.contains("<h1"))
        #expect(quoteEquals.contains("引用标题"))
        #expect(quoteEquals.contains("==="))

        let quoteDash = MarkdownHTML.makeHTML(from: "> 引用标题\n> ---")
        #expect(!quoteDash.contains("<h2"))
        #expect(quoteDash.contains("引用标题"))
        #expect(quoteDash.contains("<hr"))

        let crlf = MarkdownHTML.makeHTML(from: "普通正文\r\n===\r\n")
        #expect(!crlf.contains("<h1"))
        #expect(crlf.contains("普通正文"))
        #expect(crlf.contains("==="))

        let crlfQuote = MarkdownHTML.makeHTML(from: "> 引用标题\r\n> ---\r\n")
        #expect(!crlfQuote.contains("<h2"))
        #expect(crlfQuote.contains("<hr"))
    }

    @Test func previewKeepsSingleTildeLiteralAndDoubleTildeStrikethrough() {
        let single = MarkdownHTML.makeHTML(from: "H~2~O 与 ~下标~")
        #expect(!single.contains("<del"))
        #expect(single.contains("H~2~O"))
        #expect(single.contains("~下标~"))

        let double = MarkdownHTML.makeHTML(from: "~~删除~~ 与 ~~双~~")
        #expect(double.contains("<del>删除</del>"))
        #expect(double.contains("<del>双</del>"))

        let mixed = MarkdownHTML.makeHTML(from: "a~b~c 和 x~~y~~z")
        #expect(mixed.contains("a~b~c"))
        #expect(mixed.contains("<del>y</del>"))
        #expect(!mixed.contains("<del>b</del>"))
    }

    @Test func previewRendersHashtagsWithEditorTokenRules() {
        let body = MarkdownHTML.makeHTML(from: "这是 #标签 和 #path/子-标签 文本")
        #expect(body.contains("<span class=\"md-hashtag\" dir=\"auto\">#标签</span>"))
        #expect(body.contains("<span class=\"md-hashtag\" dir=\"auto\">#path/子-标签</span>"))

        let heading = MarkdownHTML.makeHTML(from: "# 标题 #tag")
        #expect(!heading.contains("class=\"md-hashtag\""))

        let link = MarkdownHTML.makeHTML(from: "[#链接](https://x.com) 和 #正文")
        #expect(link.contains("<span class=\"md-hashtag\" dir=\"auto\">#正文</span>"))
        #expect(!link.contains("class=\"md-hashtag\" dir=\"auto\">#链接"))

        let numeric = MarkdownHTML.makeHTML(from: "纯数字 #123 和 #123abc")
        #expect(numeric.contains("<span class=\"md-hashtag\" dir=\"auto\">#123abc</span>"))
        #expect(!numeric.contains("class=\"md-hashtag\" dir=\"auto\">#123<"))

        let wordAdjacent = MarkdownHTML.makeHTML(from: "词内 a#b 不渲染")
        #expect(!wordAdjacent.contains("class=\"md-hashtag\""))

        // `\#tag`（转义）显示字面 `#tag` 且不渲染胶囊；`\\#tag`（偶数
        // 反斜杠）显示 `\#tag` 且渲染胶囊（与编辑态的源码级扫描一致）；
        // 同段中的真 tag 仍渲染。
        let escaped = MarkdownHTML.makeHTML(from: "转义 \\#tag 保留 和 \\\\#tag 双重 与 #real")
        #expect(escaped.contains("转义 #tag 保留"))
        #expect(escaped.contains("\\<span class=\"md-hashtag\""))
        #expect(escaped.contains("<span class=\"md-hashtag\" dir=\"auto\">#tag</span> 双重"))
        #expect(escaped.contains("<span class=\"md-hashtag\" dir=\"auto\">#real</span>"))
        #expect(!escaped.contains("class=\"md-hashtag\" dir=\"auto\">#tag 保留"))

        // 奇数反斜杠（`\\\#tag`）是"字面反斜杠 + 转义 #"，不渲染胶囊。
        let oddEscaped = MarkdownHTML.makeHTML(from: "三重 \\\\\\#tag 保持字面")
        #expect(oddEscaped.contains("\\#tag 保持字面"))
        #expect(!oddEscaped.contains("class=\"md-hashtag\""))

        // 围栏代码与行内代码里的 `\#` 保持原样。
        let fenced = MarkdownHTML.makeHTML(from: "```text\n\\#fenced\n```")
        #expect(fenced.contains("\\#fenced"))
        #expect(!fenced.contains("class=\"md-hashtag\""))
        let inline = MarkdownHTML.makeHTML(from: "行内 `\\#code` 原样")
        #expect(inline.contains("\\#code"))
        #expect(!inline.contains("class=\"md-hashtag\""))

        let table = MarkdownHTML.makeHTML(from: "| 列一 |\n| --- |\n| #cell |")
        #expect(table.contains("<span class=\"md-hashtag\" dir=\"auto\">#cell</span>"))

        let code = MarkdownHTML.makeHTML(from: "行内 `#code` 不渲染")
        #expect(!code.contains("class=\"md-hashtag\""))
    }

    @Test func previewKeepsBareListMarkersAsOrdinaryText() {
        // A standalone bare marker is a paragraph, not a list item: no list
        // indentation, matching the editor's ordinary-text treatment.
        let standalone = MarkdownHTML.makeHTML(from: "-\n\n下一段")
        #expect(!standalone.contains("<ul"))
        #expect(standalone.contains(">-</p>"))

        // A bare marker directly after a list item keeps list membership
        // (no bullet) but sits at the body column — the CSS backs out one
        // list step, matching the editor's hanging-indent treatment.
        let inList = MarkdownHTML.makeHTML(from: "- 项目\n-")
        #expect(inList.contains("class=\"md-bare-marker\""))
        #expect(inList.contains("margin-left: -1.6em"))
        #expect(inList.contains(">项目</p>"))
        #expect(inList.contains("-</li>"))

        // Blank-line-separated markers are still the same CommonMark list,
        // so the bare marker line keeps list membership (no bullet) — the
        // CSS backs out one list step so it sits at the body column.
        let separated = MarkdownHTML.makeHTML(from: "- 项目\n\n-\n\n- 项目2")
        #expect(separated.contains("class=\"md-bare-marker\""))
        #expect(!separated.contains(">-</p>"))

        // `- `（marker 后带空白）是真实列表 marker：空列表项保留 bullet，
        // 与编辑态（有 hanging box）一致，不做裸 marker 处理。
        let spaced = MarkdownHTML.makeHTML(from: "- 项目\n- ")
        #expect(!spaced.contains("class=\"md-bare-marker\""))
        #expect(spaced.contains("></li>"))

        let ordered = MarkdownHTML.makeHTML(from: "1.\n\n下一段")
        #expect(!ordered.contains("class=\"md-bare-marker\""))

        let quote = MarkdownHTML.makeHTML(from: "> -\n> 内容")
        #expect(!quote.contains("<ul"))
        #expect(quote.contains(">-</p>"))
    }

    @Test func frontmatterOnlyRecognizesYamlDelimiters() {
        let toml = MarkdownFrontmatter.split("+++\ntitle = \"测试\"\n+++\n\n# 正文标题")
        #expect(toml.raw == nil)
        #expect(toml.body.contains("+++"))

        let yaml = MarkdownFrontmatter.split("---\ntitle: 测试\n---\n\n# 正文标题")
        #expect(yaml.raw == "title: 测试")
        #expect(!yaml.body.contains("---"))

        // The outline must not skip `+++` blocks either.
        let headings = MarkdownOutline.headings(
            in: "+++\ntitle = 测试\n+++\n# 真标题"
        )
        #expect(headings.map(\.title) == ["真标题"])
    }

    @Test func codeMirrorOutlineNavigationTargetsOffsetAndVisibleSourceLine() {
        let script = CodeMirrorEditorViewController.outlineNavigationJavaScript(
            toSourceOffset: 15,
            sourceLine: 5
        )

        #expect(script.contains("select(15)"))
        #expect(script.contains("setScrollPosition(0, 5, 0)"))
        #expect(script.contains("focus()"))
    }

    @Test func typographyClampsValuesAndEscapesTheSelectedFontForCSS() {
        let typography = MarkdownTypography(
            fontName: "Quoted \"Font\"\nName",
            fontSize: 99,
            lineHeight: 0.5
        )

        #expect(typography.fontSize == MarkdownTypography.fontSizeRange.upperBound)
        #expect(typography.lineHeight == MarkdownTypography.lineHeightRange.lowerBound)
        #expect(typography.cssFontFamily.contains(#"Quoted \"Font\" Name"#))
        #expect(typography.cssFontFamily.contains("-apple-system"))
    }

    @Test func previewTypographyOverridesBodyButKeepsCodeMonospaced() {
        let typography = MarkdownTypography(
            fontName: "Avenir Next",
            fontSize: 19,
            lineHeight: 1.7
        )
        let html = MarkdownHTML.makeHTML(
            from: "Text\n\n```swift\nlet value = 1\n```",
            typography: typography
        )

        #expect(html.contains(#"--floralmd-body-font-family: "Avenir Next""#))
        #expect(html.contains("--floralmd-body-font-size: 19px"))
        #expect(html.contains("--floralmd-body-line-height: 1.7"))
        #expect(html.contains(#"font-family: ui-monospace, "SF Mono", Menlo, monospace"#))
    }

}

@MainActor
private final class TestWindowDelegate: NSObject, NSWindowDelegate {
    var allowsClose = true
    var closeChecks = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeChecks += 1
        return allowsClose
    }
}

private func projectFile(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
}

@MainActor
private final class P3TestDocument: NSDocument {
    var text = ""

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

}

@MainActor
private func saveP3TestDocument(_ document: NSDocument) async throws {
    let fileURL = try #require(document.fileURL)
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        document.save(
            to: fileURL,
            ofType: document.fileType ?? MarkdownDocument.markdownType.identifier,
            for: .saveOperation
        ) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}
