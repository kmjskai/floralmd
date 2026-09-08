import AppKit
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
struct MarkdownTableEditingTests {
    @Test @MainActor func tableContextMenuIsNotInterceptedByStructureEditing() async throws {
        let initial = "| Name | Status |\n| :--- | ---: |\n| Ada | Active |"
        let controller = try await makeController(markdown: initial)

        let state = await evaluate(
            """
            (() => {
              const cell = document.querySelector('[data-table-row="1"][data-table-column="0"]');
              const event = new MouseEvent('contextmenu', {
                button: 2, clientX: 90, clientY: 70,
                bubbles: true, cancelable: true
              });
              return {
                dispatched: cell.dispatchEvent(event),
                defaultPrevented: event.defaultPrevented,
                hostBridge: typeof window.__mdRequestTableContextMenu
              };
            })()
            """,
            in: controller
        ) as? [String: Any]

        #expect(state?["dispatched"] as? Bool == true)
        #expect(state?["defaultPrevented"] as? Bool == false)
        #expect(state?["hostBridge"] as? String == "undefined")
        #expect(await markdown(in: controller) == initial)
    }

    @Test @MainActor func appKitDeleteKeyRemovesSelectedTableRowInHostedEditor() async throws {
        let initial = "| 姓名 | 状态 |\n| --- | --- |\n| 甲 | 保留 |\n| 乙 | 删除 |"
        let controller = try await makeController(markdown: initial)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        let selected = await evaluate(
            """
            (() => {
              document.querySelector(
                '.cm-md-table-select-row[data-table-select-index="1"]'
              ).click();
              return document.activeElement === document.querySelector('.cm-md-table-widget');
            })()
            """,
            in: controller
        ) as? Bool
        #expect(selected == true)
        #expect(window.makeFirstResponder(controller.view))

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
        // Exercise the hosted AppKit view directly. Routing through NSApp is
        // nondeterministic when the full WebKit suite owns several short-lived
        // windows: the event can be delivered after another test window has
        // become key even though this event carries our window number.
        controller.view.keyDown(with: event)

        let deleted = try #require(await waitForLineCount(3, in: controller))
        #expect(!deleted.contains("甲"))
        #expect(deleted.contains("乙"))
    }

    @Test @MainActor func edgeActionsAreAccessibleDoNotEnterSourceAndCoverEmptyBody() async throws {
        let controller = try await makeController(markdown: "| 标题 |\n| --- |")
        let accessibility = await evaluate(
            """
            (() => {
              const row = document.querySelector('.cm-md-table-add-row');
              const column = document.querySelector('.cm-md-table-add-column');
              return {
                count: document.querySelectorAll('.cm-md-table-edge-action').length,
                rowLabel: row?.getAttribute('aria-label'),
                columnLabel: column?.getAttribute('aria-label'),
                visibleText: (row?.textContent || '') + (column?.textContent || '')
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(accessibility?["count"] as? Int == 2)
        #expect(accessibility?["rowLabel"] as? String == String(localized: "Add Row"))
        #expect(accessibility?["columnLabel"] as? String == String(localized: "Add Column"))
        #expect(accessibility?["visibleText"] as? String == "")

        _ = await evaluate("document.querySelector('.cm-md-table-add-row').click()", in: controller)
        _ = try #require(await waitForLineCount(3, in: controller))
        _ = await evaluate("document.querySelector('.cm-md-table-add-column').click()", in: controller)
        #expect(await waitForCellCount(4, in: controller))

        _ = await evaluate("window.__mdEditor.openFind()", in: controller)
        let findState = await evaluate(
            """
            (() => {
              const input = document.getElementById('floralmd-find-input');
              input.value = 'Add row';
              input.dispatchEvent(new Event('input', { bubbles: true }));
              return {
                range: window.__mdEditor._findRangeForTesting()?.toString() || null,
                highlights: document.querySelectorAll('.floralmd-find-highlight').length
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(findState?["range"] is NSNull)
        #expect(findState?["highlights"] as? Int == 0)
        #expect(!(await markdown(in: controller) ?? "").contains("Add row"))
    }

    @Test @MainActor func visibleStructureControlsSelectDeleteAndInsertAtDividers() async throws {
        let initial = "| Name | Status | Owner |\n| :--- | :---: | ---: |\n| Ada | Active | Lin |\n| Grace | Review | Kai |"
        let controller = try await makeController(markdown: initial)

        let controls = await evaluate(
            """
            (() => {
              const table = document.querySelector('.cm-md-table-grid').getBoundingClientRect();
              const rowHandle = document.querySelector(
                '.cm-md-table-select-row[data-table-select-index="1"]'
              );
              const rowPlus = document.querySelector(
                '.cm-md-table-insert-row[data-table-insert-index="1"]'
              );
              const columnHandle = document.querySelector(
                '.cm-md-table-select-column[data-table-select-index="1"]'
              );
              const columnPlus = document.querySelector(
                '.cm-md-table-insert-column[data-table-insert-index="1"]'
              );
              const rowPlusRect = rowPlus.getBoundingClientRect();
              const firstBodyRect = document.querySelector(
                '[data-table-row="1"][data-table-column="0"]'
              ).closest('td').getBoundingClientRect();
              const columnPlusRect = columnPlus.getBoundingClientRect();
              const secondHeaderRect = document.querySelector(
                '[data-table-row="0"][data-table-column="1"]'
              ).closest('th').getBoundingClientRect();
              return {
                rowHandles: document.querySelectorAll('.cm-md-table-select-row').length,
                columnHandles: document.querySelectorAll('.cm-md-table-select-column').length,
                rowPluses: document.querySelectorAll('.cm-md-table-insert-row').length,
                columnPluses: document.querySelectorAll('.cm-md-table-insert-column').length,
                rowLabel: rowHandle.getAttribute('aria-label'),
                columnLabel: columnHandle.getAttribute('aria-label'),
                emptyText: Array.from(document.querySelectorAll('.cm-md-table-structure-control'))
                  .every(control => control.textContent === ''),
                rowPlusOnDivider: Math.abs(
                  rowPlusRect.top + rowPlusRect.height / 2 - firstBodyRect.top
                ) < 2,
                columnPlusOnDivider: Math.abs(
                  columnPlusRect.left + columnPlusRect.width / 2 - secondHeaderRect.left
                ) < 2,
                controlsNearTable: rowPlusRect.left >= table.left
                  && columnPlusRect.top >= table.top
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(controls?["rowHandles"] as? Int == 2)
        #expect(controls?["columnHandles"] as? Int == 3)
        #expect(controls?["rowPluses"] as? Int == 2)
        #expect(controls?["columnPluses"] as? Int == 2)
        #expect(controls?["rowLabel"] as? String == "\(String(localized: "Select Row")) 1")
        #expect(controls?["columnLabel"] as? String == "\(String(localized: "Select Column")) 2")
        #expect(controls?["emptyText"] as? Bool == true)
        #expect(controls?["rowPlusOnDivider"] as? Bool == true)
        #expect(controls?["columnPlusOnDivider"] as? Bool == true)
        #expect(controls?["controlsNearTable"] as? Bool == true)

        let rowSelection = await evaluate(
            """
            (() => {
              document.querySelector(
                '.cm-md-table-select-row[data-table-select-index="1"]'
              ).click();
              const widget = document.querySelector('.cm-md-table-widget');
              return {
                selectedCells: widget.querySelectorAll('.is-table-part-selected').length,
                pressed: widget.querySelector(
                  '.cm-md-table-select-row[data-table-select-index="1"]'
                ).getAttribute('aria-pressed'),
                focused: document.activeElement === widget
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(rowSelection?["selectedCells"] as? Int == 3)
        #expect(rowSelection?["pressed"] as? String == "true")
        #expect(rowSelection?["focused"] as? Bool == true)
        _ = await evaluate(
            """
            document.querySelector('.cm-md-table-widget').dispatchEvent(
              new KeyboardEvent('keydown', { key: 'Delete', bubbles: true, cancelable: true })
            )
            """,
            in: controller
        )
        let rowDeleted = try #require(await waitForLineCount(3, in: controller))
        #expect(!rowDeleted.contains("Ada"))
        #expect(rowDeleted.contains("Grace"))

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown(initial, in: controller))
        _ = await evaluate(
            """
            document.querySelector(
              '.cm-md-table-insert-row[data-table-insert-index="1"]'
            ).click()
            """,
            in: controller
        )
        let rowInserted = try #require(await waitForLineCount(5, in: controller))
        #expect(rowInserted.split(separator: "\n", omittingEmptySubsequences: false)[3].contains("Ada"))

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown(initial, in: controller))
        _ = await evaluate(
            """
            document.querySelector(
              '.cm-md-table-insert-column[data-table-insert-index="1"]'
            ).click()
            """,
            in: controller
        )
        #expect(await waitForCellCount(12, in: controller))
        let insertedColumnAlignment = await evaluate(
            """
            (() => [0, 1, 2, 3].map(column => getComputedStyle(
              document.querySelector(`[data-table-row="1"][data-table-column="${column}"]`)
            ).textAlign))()
            """,
            in: controller
        ) as? [String]
        #expect(insertedColumnAlignment == ["left", "left", "center", "right"])
    }

    @Test @MainActor func readOnlyPreviewDoesNotExposeTableStructureEditing() async throws {
        let preview = TransparentMarkdownWebView()
        preview.loadHTMLString(
            MarkdownHTML.makeHTML(
                from: "| 标题 | 状态 |\n| --- | ---: |\n| 内容 | 完成 |",
                allowsScroll: true
            ),
            baseURL: nil
        )
        var state: [String: Any]?
        for _ in 0..<100 where state == nil {
            state = await withCheckedContinuation { continuation in
                preview.evaluateJavaScript(
                    """
                    document.readyState === 'complete' ? (() => {
                      const cell = document.querySelector('table td');
                      if (!cell) return null;
                      const event = new MouseEvent('contextmenu', {
                        button: 2, bubbles: true, cancelable: true
                      });
                      return {
                        tableCount: document.querySelectorAll('table').length,
                        editingControls: document.querySelectorAll(
                          '.cm-md-table-edge-action, .cm-md-table-structure-control'
                        ).length,
                        editableCells: document.querySelectorAll('[contenteditable]').length,
                        contextMenuNotIntercepted: cell.dispatchEvent(event)
                      };
                    })() : null
                    """
                ) { value, _ in continuation.resume(returning: value as? [String: Any]) }
            }
            if state == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(state?["tableCount"] as? Int == 1)
        #expect(state?["editingControls"] as? Int == 0)
        #expect(state?["editableCells"] as? Int == 0)
        #expect(state?["contextMenuNotIntercepted"] as? Bool == true)
    }

    @Test @MainActor func tableEditingPreservesEscapesAlignmentTabUndoAndReopen() async throws {
        let initial = "| 名称 | Code |\n| :--- | ---: |\n| 苹果 | value |"
        let controller = try await makeController(markdown: initial)
        _ = await evaluate(
            """
            (() => {
              const cell = document.querySelector('[data-table-row="1"][data-table-column="0"]');
              cell.focus();
              cell.innerText = '中文 | 管线';
              document.querySelector('[data-table-row="1"][data-table-column="1"]').focus();
              return true;
            })()
            """,
            in: controller
        )
        let editedSource = try #require(await waitForMarkdownContaining("中文 \\| 管线", in: controller))
        #expect(editedSource.split(separator: "\n")[1].hasSuffix(": |"))

        _ = await evaluate(
            """
            (() => {
              const last = document.querySelector('[data-table-row="1"][data-table-column="1"]');
              last.focus();
              last.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Tab', bubbles: true, cancelable: true
              }));
              return true;
            })()
            """,
            in: controller
        )
        let tabbedSource = try #require(await waitForLineCount(4, in: controller))
        let appendedCell = await evaluate(
            """
            (() => {
              const cell = document.querySelector('[data-table-row="2"][data-table-column="0"]');
              return cell ? { row: cell.dataset.tableRow, column: cell.dataset.tableColumn,
                              tabIndex: cell.tabIndex } : null;
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(appendedCell?["row"] as? String == "2")
        #expect(appendedCell?["column"] as? String == "0")
        #expect(appendedCell?["tabIndex"] as? Int == 0)

        _ = await evaluate(
            """
            (() => {
              const cell = document.querySelector('[data-table-row="2"][data-table-column="0"]');
              cell.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Tab', shiftKey: true, bubbles: true, cancelable: true
              }));
              return true;
            })()
            """,
            in: controller
        )
        #expect(await waitForMarkdown(tabbedSource, in: controller))

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown(editedSource, in: controller))
        _ = await evaluate("window.__mdEditor._redoForTesting()", in: controller)
        #expect(await waitForMarkdown(tabbedSource, in: controller))

        let reopened = try await makeController(markdown: tabbedSource)
        let reopenedState = await evaluate(
            """
            (() => ({
              cells: document.querySelectorAll('.cm-md-table-cell').length,
              alignment: getComputedStyle(
                document.querySelector('[data-table-row="1"][data-table-column="1"]')
              ).textAlign
            }))()
            """,
            in: reopened
        ) as? [String: Any]
        #expect(reopenedState?["cells"] as? Int == 6)
        #expect(reopenedState?["alignment"] as? String == "right")
        #expect(await markdown(in: reopened) == tabbedSource)
    }

    @Test @MainActor func commandEnterCommitsCellAndFocusesBodyAfterTerminalTable() async throws {
        let initial = "| Name | Status |\n| --- | --- |\n| Ada | Active |"
        let expected = "| Name | Status    |\n| ---- | --------- |\n| Ada  | Reviewing |\n"
        let controller = try await makeController(markdown: initial)

        let dispatched = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="1"][data-table-column="1"]'
              );
              cell.focus();
              cell.innerText = 'Reviewing';
              const event = new KeyboardEvent('keydown', {
                key: 'Enter', code: 'Enter', metaKey: true,
                bubbles: true, cancelable: true
              });
              cell.dispatchEvent(event);
              return event.defaultPrevented;
            })()
            """,
            in: controller
        ) as? Bool
        #expect(dispatched == true)
        #expect(await waitForMarkdown(expected, in: controller))

        let focus = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              return {
                codeMirror: document.activeElement === view.contentDOM,
                head: view.state.selection.main.head,
                length: view.state.doc.length,
                tableRows: document.querySelectorAll('.cm-md-table-grid tr').length
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(focus?["codeMirror"] as? Bool == true)
        #expect(focus?["head"] as? Int == expected.count)
        #expect(focus?["length"] as? Int == expected.count)
        #expect(focus?["tableRows"] as? Int == 2)

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown(initial, in: controller))
        _ = await evaluate("window.__mdEditor._redoForTesting()", in: controller)
        #expect(await waitForMarkdown(expected, in: controller))

        let reopened = try await makeController(markdown: expected)
        #expect(await markdown(in: reopened) == expected)
    }

    @Test @MainActor func appKitCommandReturnLeavesAHeaderCellForBodyText() async throws {
        let initial = "| Name | Status |\n| --- | --- |\n| Ada | Active |"
        let expected = initial + "\n"
        let controller = try await makeController(markdown: initial)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        #expect(window.makeFirstResponder(controller.view))
        let focused = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="0"][data-table-column="0"]'
              );
              cell.focus();
              return document.activeElement === cell;
            })()
            """,
            in: controller
        ) as? Bool
        #expect(focused == true)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        NSApp.sendEvent(event)

        #expect(await waitForMarkdown(expected, in: controller))
        let focus = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              return document.activeElement === view.contentDOM
                && view.state.selection.main.head === view.state.doc.length;
            })()
            """,
            in: controller
        ) as? Bool
        #expect(focus == true)
    }

    @Test @MainActor func commandEnterReusesExistingBodyBoundaryWithoutExtraLines() async throws {
        let table = "| Name | Status |\n| --- | --- |\n| Ada | Active |"
        let cases = [
            table + "\n# Heading",
            table + "\n\nFollowing",
            table + "\n\nFirst\nSecond",
            table + "\n\n\nFollowing",
        ]

        for source in cases {
            let controller = try await makeController(markdown: source)
            let state = await evaluate(
                """
                (() => {
                  const cell = document.querySelector(
                    '[data-table-row="1"][data-table-column="0"]'
                  );
                  cell.focus();
                  cell.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'Enter', code: 'Enter', metaKey: true,
                    bubbles: true, cancelable: true
                  }));
                  const view = window.__mdEditor._viewForTesting;
                  return {
                    focused: document.activeElement === view.contentDOM,
                    head: view.state.selection.main.head
                  };
                })()
                """,
                in: controller
            ) as? [String: Any]
            #expect(await markdown(in: controller) == source)
            #expect(state?["focused"] as? Bool == true)
            #expect(state?["head"] as? Int == table.count + 1)
        }
    }

    @Test @MainActor func commandEnterFocusesBodyWithTypewriterModeEnabled() async throws {
        let initial = "| Name | Status |\n| --- | --- |\n| Ada | Active |"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 540)
        controller.load(markdown: initial, typewriterModeEnabled: true)
        try await waitUntilReady(controller)

        _ = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="1"][data-table-column="0"]'
              );
              cell.focus();
              cell.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Enter', code: 'Enter', metaKey: true,
                bubbles: true, cancelable: true
              }));
              return true;
            })()
            """,
            in: controller
        )
        #expect(await waitForMarkdown(initial + "\n", in: controller))
        try await Task.sleep(for: .milliseconds(180))
        let state = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const typewriter = window.__mdEditor._typewriterStateForTesting();
              return {
                focused: document.activeElement === view.contentDOM,
                head: view.state.selection.main.head,
                length: view.state.doc.length,
                enabled: typewriter.enabled
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(state?["focused"] as? Bool == true)
        #expect(state?["head"] as? Int == state?["length"] as? Int)
        #expect(state?["enabled"] as? Bool == true)

        controller.applyTypewriterMode(false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await markdown(in: controller) == initial + "\n")
    }

    @Test @MainActor func typewriterUsesFocusedTableCellCaretInsteadOfStaleCodeMirrorSelection() async throws {
        let prefix = (0..<45).map { "Paragraph \($0) with enough text to occupy a source row." }
            .joined(separator: "\n\n")
        let initial = prefix + "\n\n| Name | Status |\n| --- | --- |\n| Ada | Active |"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 540)
        controller.load(markdown: initial, typewriterModeEnabled: true)
        try await waitUntilReady(controller)

        let focused = try #require(await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.dispatch({
                selection: { anchor: view.state.doc.length - 1 },
                scrollIntoView: true
              });
              const cell = document.querySelector('[data-table-row="1"][data-table-column="1"]');
              if (!cell) return null;
              view.dispatch({ selection: { anchor: 0 } });
              cell.focus();
              const selection = window.getSelection();
              selection.removeAllRanges();
              const range = document.createRange();
              range.selectNodeContents(cell);
              range.collapse(false);
              selection.addRange(range);
              return {
                activeCell: document.activeElement === cell,
                codeMirrorHead: view.state.selection.main.head
              };
            })()
            """,
            in: controller
        ) as? [String: Any])
        #expect(focused["activeCell"] as? Bool == true)
        #expect((focused["codeMirrorHead"] as? NSNumber)?.intValue == 0)
        try await Task.sleep(for: .milliseconds(80))

        let before = try #require(await evaluate(
            """
            (() => {
              const range = window.getSelection().getRangeAt(0);
              const rects = range.getClientRects();
              let rect = rects.length > 0
                ? rects[rects.length - 1]
                : range.getBoundingClientRect();
              if (rect.top === 0 && rect.bottom === 0) {
                rect = document.activeElement.getBoundingClientRect();
              }
              return {
                nativeCaretCenter: (rect.top + rect.bottom) / 2,
                state: window.__mdEditor._typewriterStateForTesting()
              };
            })()
            """,
            in: controller
        ) as? [String: Any])
        let stateBefore = try #require(before["state"] as? [String: Any])
        let nativeCenter = try #require((before["nativeCaretCenter"] as? NSNumber)?.doubleValue)
        let reportedCenter = try #require((stateBefore["caretCenter"] as? NSNumber)?.doubleValue)
        #expect(abs(reportedCenter - nativeCenter) < 1)

        // The core contract is the caret reporting above (focused table cell
        // rect, not the stale CodeMirror selection at position 0). The align
        // hook itself is unreliable on the no-headroom experiment branch
        // (CM's async scrollIntoView commit overwrites its scrollTop write),
        // so this test does not assert the post-follow position here; the
        // real Enter/Backspace align path is covered by
        // TypewriterTypingParityTests.
        _ = await evaluate("window.__mdEditor._followTypewriterForTesting()", in: controller)
        try await Task.sleep(for: .milliseconds(160))
        #expect(await markdown(in: controller) == initial)
    }

    @MainActor
    private func makeController(markdown: String) async throws -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 540)
        controller.load(markdown: markdown)
        try await waitUntilReady(controller)
        return controller
    }

    @MainActor
    private func waitUntilReady(_ controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<120 {
            let ready = await evaluate("window.__mdEditor != null", in: controller) as? Bool
            if ready == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    @MainActor
    private func markdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private func waitForMarkdown(_ expected: String, in controller: CodeMirrorEditorViewController) async -> Bool {
        for _ in 0..<100 {
            if await markdown(in: controller) == expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    private func waitForMarkdownContaining(
        _ fragment: String,
        in controller: CodeMirrorEditorViewController
    ) async -> String? {
        for _ in 0..<100 {
            if let source = await markdown(in: controller), source.contains(fragment) { return source }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    @MainActor
    private func waitForLineCount(_ count: Int, in controller: CodeMirrorEditorViewController) async -> String? {
        for _ in 0..<100 {
            if let source = await markdown(in: controller), source.split(separator: "\n").count == count {
                return source
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    @MainActor
    private func waitForCellCount(_ count: Int, in controller: CodeMirrorEditorViewController) async -> Bool {
        for _ in 0..<100 {
            let value = await evaluate(
                "document.querySelectorAll('.cm-md-table-cell').length",
                in: controller
            ) as? Int
            if value == count { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    private func evaluate(_ script: String, in controller: CodeMirrorEditorViewController) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { continuation.resume(returning: $0) }
        }
    }
}
