import AppKit
import Testing
import WebKit

@testable import FloralMD

@Suite(.serialized)
struct MarkdownSelectionClipboardTests {
    @Test @MainActor func multiLineSelectionRevealsEveryListAndTaskMarker() async throws {
        let markdown = "- first item\n  * nested item\n+ third item\n- [ ] task item\n\nTail"
        let controller = try await makeController(markdown: markdown, width: 560)
        let first = markdown.utf16Offset(of: "first item") + 2
        let task = markdown.utf16Offset(of: "task item") + 4

        for (anchor, head) in [(first, task), (task, first)] {
            try await focus(controller, anchor: anchor, head: head)
            let result = try await evaluateDictionary(controller, script: """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const lines = Array.from(document.querySelectorAll('.cm-line'))
                .slice(0, 4).map(line => line.textContent);
              const selection = view.state.selection.main;
              return {
                lines: JSON.stringify(lines),
                taskWidgets: document.querySelectorAll('.cm-md-task-checkbox').length,
                previewListLines: document.querySelectorAll('.cm-md-list-item').length,
                previewListGaps: document.querySelectorAll('.cm-md-list-item-gap').length,
                previewBullets: document.querySelectorAll('.cm-md-bullet-source').length,
                anchor: selection.anchor, head: selection.head,
                selected: view.state.sliceDoc(selection.from, selection.to)
              };
            })()
            """)
            #expect(result["lines"] as? String
                    == #"["- first item","  * nested item","+ third item","- [ ] task item"]"#)
            #expect(result["taskWidgets"] as? Int == 0)
            #expect((result["previewListLines"] as? Int ?? 0) >= 4)
            #expect((result["previewListGaps"] as? Int ?? 0) >= 1)
            #expect(result["previewBullets"] as? Int == 3)
            #expect(result["anchor"] as? Int == anchor)
            #expect(result["head"] as? Int == head)
            let expected = (markdown as NSString).substring(with: NSRange(
                location: min(anchor, head), length: abs(head - anchor)
            ))
            #expect(result["selected"] as? String == expected)
        }
    }

    @Test @MainActor func partialInlineAndCrossHeadingSelectionRevealCompleteSource() async throws {
        let markdown = "## Selected heading\n\nBefore **bold** [link](target.md) ![image](image.png) `code` ~~strike~~ after"
        let controller = try await makeController(markdown: markdown, width: 720)
        let headingBody = markdown.utf16Offset(of: "Selected") + 2
        let strikeBody = markdown.utf16Offset(of: "strike") + 3

        let baseline = try await evaluateDictionary(controller, script: """
        (() => {
          const heading = document.querySelector('.cm-md-h2');
          const inline = Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Before'));
          return {
            headingHeight: heading.getBoundingClientRect().height,
            headingFontSize: parseFloat(getComputedStyle(heading).fontSize),
            inlineHeight: inline.getBoundingClientRect().height
          };
        })()
        """)

        try await focus(controller, anchor: strikeBody, head: headingBody)
        let result = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const heading = Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Selected heading'));
          const inline = Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Before'));
          const selection = view.state.selection.main;
          const previewSelector = [
            '.cm-md-strong', '.cm-md-emphasis', '.cm-md-strikethrough',
            '.cm-md-inline-code', '.cm-md-link', '.cm-md-image-reference',
            '.cm-md-syntax'
          ].join(',');
          return {
            markdown: window.__mdEditor.getMarkdown(),
            heading: heading?.textContent,
            headingPreview: heading?.classList.contains('cm-md-h2'),
            headingSourceGeometry: heading?.querySelectorAll('.cm-md-heading-source-visible').length,
            headingPreviewChildren: heading?.querySelectorAll(previewSelector).length,
            inline: inline?.textContent,
            inlinePreviewChildren: inline?.querySelectorAll(previewSelector).length,
            inlineSourceGeometry: inline?.querySelectorAll('.cm-md-inline-code-source').length,
            headingHeight: heading?.getBoundingClientRect().height,
            headingFontSize: heading ? parseFloat(getComputedStyle(heading).fontSize) : null,
            inlineHeight: inline?.getBoundingClientRect().height,
            anchor: selection.anchor, head: selection.head
          };
        })()
        """)

        #expect(result["markdown"] as? String == markdown)
        #expect(result["heading"] as? String == "## Selected heading")
        #expect(result["headingPreview"] as? Bool == true)
        #expect(result["headingSourceGeometry"] as? Int == 1)
        #expect(result["headingPreviewChildren"] as? Int == 0)
        #expect(result["inline"] as? String
                == "Before **bold** [link](target.md) ![image](image.png) `code` ~~strike~~ after")
        #expect(result["inlinePreviewChildren"] as? Int == 0)
        #expect(result["inlineSourceGeometry"] as? Int == 1)
        #expect(abs((result["headingHeight"] as? Double ?? .infinity)
                    - (baseline["headingHeight"] as? Double ?? 0)) < 1)
        #expect(abs((result["headingFontSize"] as? Double ?? .infinity)
                    - (baseline["headingFontSize"] as? Double ?? 0)) < 0.1)
        #expect(abs((result["inlineHeight"] as? Double ?? .infinity)
                    - (baseline["inlineHeight"] as? Double ?? 0)) < 1)
        #expect(result["anchor"] as? Int == strikeBody)
        #expect(result["head"] as? Int == headingBody)
    }

    @Test @MainActor func commandARevealsSourceAndCollapseRestoresPreviewGeometry() async throws {
        let markdown = "# Heading\n\n- first\n- [x] task\n\nBefore **bold** [link](target.md) `code` after\n\n![image](image.png)"
        let controller = try await makeController(markdown: markdown, width: 520)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.view)
        defer { window.orderOut(nil) }
        _ = try await evaluate(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'a', code: 'KeyA', metaKey: true, bubbles: true, cancelable: true
          }));
          view.requestMeasure();
          return true;
        })()
        """)
        try await settle()
        try await waitForSelectionPaint(in: controller)
        let selected = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const range = view.state.selection.main;
          const rects = Array.from(document.querySelectorAll('.cm-selectionBackground'))
            .map(element => element.getBoundingClientRect());
          const visualRows = [];
          for (const rect of rects) {
            let row = visualRows.find(candidate =>
              Math.abs(candidate.top - rect.top) < 1
                && Math.abs(candidate.bottom - rect.bottom) < 1);
            if (row) row.count += 1;
            else visualRows.push({ top: rect.top, bottom: rect.bottom, count: 1 });
          }
          const imageElement = document.querySelector('.cm-md-image-preview img');
          const imageStyle = imageElement ? getComputedStyle(imageElement) : null;
          const image = imageElement?.closest('.cm-md-image-preview')
            ?.getBoundingClientRect();
          const imageSelectionOverlap = image ? rects.some(rect =>
            rect.right > image.left && rect.left < image.right
              && rect.bottom > image.top && rect.top < image.bottom) : null;
          const contentWidth = view.contentDOM.getBoundingClientRect().width;
          return {
            from: range.from, to: range.to,
            copied: view.state.sliceDoc(range.from, range.to),
            hiddenHeadings: document.querySelectorAll('.cm-md-heading-source-hidden').length,
            previewHeadings: document.querySelectorAll('.cm-md-h1,.cm-md-h2,.cm-md-h3,.cm-md-h4,.cm-md-h5,.cm-md-h6').length,
            previewInline: document.querySelectorAll('.cm-md-strong,.cm-md-emphasis,.cm-md-strikethrough,.cm-md-inline-code,.cm-md-link,.cm-md-image-reference,.cm-md-syntax').length,
            bullets: document.querySelectorAll('.cm-md-bullet').length,
            tasks: document.querySelectorAll('.cm-md-task-checkbox').length,
            widestSelection: Math.max(0, ...rects.map(rect => rect.width)),
            maxFragmentsPerVisualRow: Math.max(0, ...visualRows.map(row => row.count)),
            imagePreviewExists: image != null,
            imageSelectionOverlap,
            imageSelectionMode: imageStyle?.webkitUserSelect || imageStyle?.userSelect,
            contentWidth
          };
        })()
        """)
        #expect(selected["from"] as? Int == 0)
        #expect(selected["to"] as? Int == markdown.utf16.count)
        #expect(selected["copied"] as? String == markdown)
        #expect(selected["hiddenHeadings"] as? Int == 0)
        #expect(selected["previewHeadings"] as? Int == 1)
        #expect(selected["previewInline"] as? Int == 0)
        #expect(selected["bullets"] as? Int == 0)
        #expect(selected["tasks"] as? Int == 0)
        #expect(selected["maxFragmentsPerVisualRow"] as? Int == 1)
        #expect(selected["imagePreviewExists"] as? Bool == true)
        #expect(selected["imageSelectionOverlap"] as? Bool == false)
        #expect(selected["imageSelectionMode"] as? String == "none")
        #expect((selected["widestSelection"] as? Double ?? .infinity)
                <= (selected["contentWidth"] as? Double ?? 0) + 1)

        try await focus(controller, anchor: markdown.utf16.count, head: markdown.utf16.count)
        let collapsed = try await evaluateDictionary(controller, script: """
        (() => ({
          headingHidden: document.querySelectorAll('.cm-md-heading-source-hidden').length,
          bullets: document.querySelectorAll('.cm-md-bullet').length,
          tasks: document.querySelectorAll('.cm-md-task-checkbox').length,
          inline: Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Before'))?.textContent,
          markdown: window.__mdEditor.getMarkdown()
        }))()
        """)
        #expect(collapsed["headingHidden"] as? Int == 1)
        #expect(collapsed["bullets"] as? Int == 1)
        #expect(collapsed["tasks"] as? Int == 1)
        #expect(collapsed["inline"] as? String == "Before bold link code after")
        #expect(collapsed["markdown"] as? String == markdown)
    }

    @Test @MainActor func externalReplacementWaitsForIMEAndPreservesEditorState() async throws {
        let original = (0..<120).map { "line \($0) original" }.joined(separator: "\n")
        let replacement = (0..<120).map { "line \($0) updated!" }.joined(separator: "\n")
        let controller = try await makeController(markdown: original, width: 520)
        _ = try await evaluate(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.dispatch({ selection: { anchor: 100, head: 108 } });
          view.scrollDOM.scrollTop = 360;
          window.__mdEditor._setCompositionActiveForTesting(true);
          return true;
        })()
        """)

        controller.replaceExternally(markdown: replacement)
        try await Task.sleep(for: .milliseconds(120))
        #expect(try await markdown(in: controller) == original)

        _ = try await evaluate(
            controller,
            script: "window.__mdEditor._setCompositionActiveForTesting(false)"
        )
        for _ in 0..<40 {
            if try await markdown(in: controller) == replacement { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await markdown(in: controller) == replacement)
        let state = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const selection = window.__mdEditor._selectionForTesting();
          return { from: selection.from, to: selection.to, scrollTop: view.scrollDOM.scrollTop };
        })()
        """)
        #expect(state["from"] as? Int == 100)
        #expect(state["to"] as? Int == 108)
        #expect((state["scrollTop"] as? Double ?? 0) > 250)

        _ = try await evaluate(controller, script: "window.__mdEditor._undoForTesting()")
        try await settle()
        #expect(try await markdown(in: controller) == original)
    }

    @Test @MainActor func nativeSelectionAcrossBlankLinesAndWrappedHeadingsHasNoRowWideFill() async throws {
        let heading = "# 一个很长的标题 Mixed heading 测试测试测试测试测试测试测试测试"
        let markdown = "Alpha first line\n\nBeta middle line\nGamma last line\n\n\(heading)\n\n## 第二个长标题 Heading two 测试测试测试测试测试\n\nTail"
        let controller = try await makeController(markdown: markdown, width: 430)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.view)
        defer { window.orderOut(nil) }

        let selections = [
            (markdown.range(of: "first")!.lowerBound, markdown.range(of: "标题 Mixed")!.upperBound),
            (markdown.range(of: "Beta")!.lowerBound, markdown.range(of: "Heading two")!.upperBound)
        ].map { range -> (Int, Int) in
            (markdown.utf16.distance(from: markdown.startIndex, to: range.0),
             markdown.utf16.distance(from: markdown.startIndex, to: range.1))
        }

        for (from, to) in selections {
            for (anchor, head) in [(from, to), (to, from)] {
                _ = try await evaluate(controller, script: """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  view.focus();
                  view.dispatch({
                    selection: { anchor: \(anchor), head: \(head) },
                    userEvent: 'select.pointer', scrollIntoView: true
                  });
                  view.requestMeasure();
                  return true;
                })()
                """)
                try await settle()
                try await waitForSelectionPaint(in: controller)
                let result = try await evaluateDictionary(controller, script: """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const selection = window.getSelection();
                  const range = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
                  const nativeRects = range ? Array.from(range.getClientRects()) : [];
                  const rects = Array.from(document.querySelectorAll('.cm-selectionBackground'))
                    .map(element => element.getBoundingClientRect());
                  const content = view.contentDOM.getBoundingClientRect();
                  const startCoords = view.coordsAtPos(view.state.selection.main.from, 1);
                  const startRect = startCoords ? rects.find(rect =>
                    rect.bottom > startCoords.top && rect.top < startCoords.bottom) : null;
                  const blankLines = Array.from(document.querySelectorAll('.cm-line'))
                    .filter(line => line.textContent.length === 0)
                    .map(line => line.getBoundingClientRect());
                  const blankWidths = blankLines.map(blank => Math.max(0, ...rects
                    .filter(rect => rect.bottom > blank.top && rect.top < blank.bottom)
                    .map(rect => rect.width)));
                  const headings = Array.from(document.querySelectorAll('.cm-md-h1, .cm-md-h2'));
                  return {
                    anchor: view.state.selection.main.anchor,
                    head: view.state.selection.main.head,
                    stateText: view.state.sliceDoc(
                      view.state.selection.main.from, view.state.selection.main.to),
                    nativeRangeCount: selection?.rangeCount ?? 0,
                    nativeRectCount: nativeRects.length,
                    customLayerCount: document.querySelectorAll('.cm-selectionLayer').length,
                    customBackgroundCount: document.querySelectorAll('.cm-selectionBackground').length,
                    selectionStartDelta: startRect && startCoords
                      ? startRect.left - startCoords.left : null,
                    widestBlankRect: Math.max(0, ...blankWidths),
                    contentWidth: content.width,
                    compactDebug: JSON.stringify(window.__compactSelectionDebug ?? null),
                    wrappedHeadingCount: headings.filter(line =>
                      line.getClientRects().length > 0 && line.getBoundingClientRect().height
                        > parseFloat(getComputedStyle(line).lineHeight) * 1.5).length
                  };
                })()
                """)

                let expected = (markdown as NSString).substring(with: NSRange(
                    location: min(from, to), length: abs(to - from)
                ))
                let details = "anchor=\(result["anchor"] ?? "?") head=\(result["head"] ?? "?") "
                    + "blank=\(result["widestBlankRect"] ?? "?") content=\(result["contentWidth"] ?? "?") "
                    + "debug=\(result["compactDebug"] ?? "?")"
                #expect(result["anchor"] as? Int == anchor, Comment(rawValue: details))
                #expect(result["head"] as? Int == head, Comment(rawValue: details))
                #expect(result["stateText"] as? String == expected, Comment(rawValue: details))
                #expect((result["nativeRectCount"] as? Int ?? 0) > 0, Comment(rawValue: details))
                #expect(result["customLayerCount"] as? Int == 1, Comment(rawValue: details))
                #expect((result["customBackgroundCount"] as? Int ?? 0) > 0,
                        Comment(rawValue: details))
                #expect(abs(result["selectionStartDelta"] as? Double ?? .infinity) < 1,
                        Comment(rawValue: details))
                #expect((result["widestBlankRect"] as? Double ?? .infinity) < 3,
                        Comment(rawValue: details))
                #expect((result["wrappedHeadingCount"] as? Int ?? 0) >= 1,
                        Comment(rawValue: details))
            }
        }
    }

    @Test @MainActor func appKitKeyboardRoutingKeepsExactSelectionAndPasteUndoTransaction() async throws {
        let original = "普通段落 Alpha\n\n# 标题正文"
        let copied = "段落 Alpha\n\n# 标题"
        let insertion = "粘贴内容\n第二行"
        let controller = try await makeController(markdown: original, width: 520)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.view)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        let from = original.utf16.distance(
            from: original.startIndex, to: original.range(of: copied)!.lowerBound
        )
        let to = from + copied.utf16.count
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
        try await focus(controller, anchor: from, head: to)
        #expect(window.firstResponder != nil)
        #expect(performCommand("c", keyCode: 8, in: window, webView: controller.view as! WKWebView))
        try await settle()
        let selected = try await evaluate(controller, script: """
        (() => {
          const range = window.__mdEditor._viewForTesting.state.selection.main;
          return window.__mdEditor._viewForTesting.state.sliceDoc(range.from, range.to);
        })()
        """) as? String
        #expect(selected == copied)

        pasteboard.clearContents()
        pasteboard.setString(insertion, forType: .string)
        #expect(pasteboard.string(forType: .string) == insertion)
        try await focus(controller, anchor: original.utf16.count, head: original.utf16.count)
        _ = try await evaluate(controller, script: "window.__mdEditor.insert(\(jsString(insertion)))")
        #expect(try await markdown(in: controller) == original + insertion)
        _ = try await evaluate(controller, script: "window.__mdEditor._undoForTesting()")
        try await settle()
        #expect(try await markdown(in: controller) == original)

        #expect((controller.view as! WKWebView).responds(to: #selector(NSText.copy(_:))))
        #expect((controller.view as! WKWebView).responds(to: #selector(NSText.paste(_:))))
    }

    @MainActor
    private func performCommand(
        _ characters: String,
        keyCode: UInt16,
        in window: NSWindow,
        webView: WKWebView
    ) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        return webView.performKeyEquivalent(with: event)
    }

    @MainActor
    private func focus(
        _ controller: CodeMirrorEditorViewController,
        anchor: Int,
        head: Int
    ) async throws {
        _ = try await evaluate(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          view.dispatch({ selection: { anchor: \(anchor), head: \(head) }, scrollIntoView: true });
          return true;
        })()
        """)
        try await settle()
    }

    @MainActor
    private func makeController(markdown: String, width: CGFloat) async throws
        -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        controller.load(markdown: markdown)
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { return controller }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("CodeMirror did not become ready")
        return controller
    }

    @MainActor
    private func markdown(in controller: CodeMirrorEditorViewController) async throws -> String {
        try #require(try await evaluate(
            controller, script: "window.__mdEditor.getMarkdown()"
        ) as? String)
    }

    @MainActor
    private func evaluateDictionary(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> [String: Any] {
        try #require(try await evaluate(controller, script: script) as? [String: Any])
    }

    @MainActor
    private func evaluate(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(180))
    }

    /// Selection backgrounds paint asynchronously (CodeMirror decoration +
    /// WebKit compositing, and requestAnimationFrame is suspended in this
    /// headless test environment), so a fixed sleep can sample before the
    /// first paint. Poll until the custom selection layer appears.
    @MainActor
    private func waitForSelectionPaint(in controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<40 {
            let painted = (try await evaluate(controller, script: """
                document.querySelectorAll('.cm-selectionBackground').length > 0
                """)) as? Bool ?? false
            if painted { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("selection background never painted")
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

private struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
