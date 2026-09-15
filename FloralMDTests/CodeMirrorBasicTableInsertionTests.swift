import AppKit
import Foundation
import Testing
@testable import FloralMD

@Suite(.serialized)
struct CodeMirrorBasicTableInsertionTests {
    private let table = "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |"

    @Test @MainActor func emptyDocumentInsertsOneUndoableTableAndPlacesCaretInFirstDataCell() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let commandTarget = MarkdownEditorCommandTarget()
        commandTarget.connect(to: controller)
        var changes: [String] = []
        controller.contentDidChange = { changes.append($0) }
        controller.load(markdown: "")
        try await waitUntilEditorReady(controller)
        #expect(await waitUntilCommandTargetReady(commandTarget))

        commandTarget.insertBasicMarkdownTable()

        #expect(await waitForMarkdown(table, in: controller))
        #expect(changes == [table])
        #expect(await selection(in: controller) == ["from": 30, "to": 30])

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown("", in: controller))
        #expect(changes == [table, ""])

        commandTarget.disconnect(from: controller)
        #expect(!commandTarget.isReady)
    }

    @Test @MainActor func insertionNormalizesAdjacentNewlinesWithoutCreatingBlankLines() async throws {
        let cases: [(initial: String, caret: Int, expected: String)] = [
            ("正文", 0, table + "\n正文"),
            ("正文", 2, "正文\n" + table),
            ("前后", 1, "前\n" + table + "\n后"),
            ("前\n后", 2, "前\n" + table + "\n后"),
            ("前\n\n后", 2, "前\n" + table + "\n后")
        ]

        for testCase in cases {
            let controller = try await readyController(markdown: testCase.initial)
            _ = await evaluate(
                "window.__mdEditor.select(\(testCase.caret), \(testCase.caret))",
                in: controller
            )

            controller.insertBasicMarkdownTable()

            #expect(await waitForMarkdown(testCase.expected, in: controller))
        }
    }

    @Test @MainActor func nonemptySelectionIsPreservedAndInsertionUsesSelectionEnd() async throws {
        let controller = try await readyController(markdown: "保留这段正文")
        _ = await evaluate("window.__mdEditor.select(0, 4)", in: controller)

        controller.insertBasicMarkdownTable()

        #expect(await waitForMarkdown("保留这段\n" + table + "\n正文", in: controller))
        #expect(await selection(in: controller) == ["from": 35, "to": 35])
    }

    @MainActor
    private func readyController(markdown: String) async throws -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.load(markdown: markdown)
        try await waitUntilEditorReady(controller)
        return controller
    }

    @MainActor
    private func waitUntilCommandTargetReady(
        _ target: MarkdownEditorCommandTarget
    ) async -> Bool {
        for _ in 0..<100 {
            if target.isReady { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    private func waitUntilEditorReady(
        _ controller: CodeMirrorEditorViewController
    ) async throws {
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState {
                    continuation.resume(returning: $0.isReady)
                }
            }
            if ready { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    @MainActor
    private func waitForMarkdown(
        _ expected: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Bool {
        for _ in 0..<100 {
            let markdown = await withCheckedContinuation { continuation in
                controller.fetchMarkdown { continuation.resume(returning: $0) }
            }
            if markdown == expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    private func selection(
        in controller: CodeMirrorEditorViewController
    ) async -> [String: Int]? {
        await evaluate("window.__mdEditor._selectionForTesting()", in: controller)
            as? [String: Int]
    }

    @MainActor
    private func evaluate(
        _ script: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) {
                continuation.resume(returning: $0)
            }
        }
    }
}
