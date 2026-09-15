import Cocoa
import Testing

@testable import FloralMD

/// Deleting an ordered-list item must renumber the surviving items to a
/// complete sequence starting at 1 — folded into the same transaction, so a
/// single Undo restores the pre-delete document. The rule fires whenever a
/// delete transaction (Backspace/Delete/cut) fully removes an item's marker
/// line; deletions that only touch text inside an item never trigger it.
@Suite(.serialized)
struct MarkdownOrderedListRenumberTests {
    @Test @MainActor func deleteMiddleItemRenumbers() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteLine(2, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. c")
    }

    @Test @MainActor func deleteFirstItemRenumbersFromOne() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteLine(1, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. b\n2. c")
    }

    @Test @MainActor func deleteFirstItemOfNonOneStartListRenumbersFromOne() async throws {
        let controller = try await makeController(markdown: "3. a\n4. b\n5. c", width: 520)
        try await deleteLine(1, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. b\n2. c")
    }

    @Test @MainActor func deleteFromAlreadyBrokenListRepairsSequence() async throws {
        let controller = try await makeController(markdown: "1. a\n3. b\n4. c", width: 520)
        try await deleteLine(2, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. c")
    }

    @Test @MainActor func deleteLastItemKeepsSequence() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteLine(3, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. b")
    }

    @Test @MainActor func deleteTaskListItemRenumbers() async throws {
        let controller = try await makeController(markdown: "1. [ ] a\n2. [x] b\n3. c", width: 520)
        try await deleteLine(2, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. [ ] a\n2. c")
    }

    @Test @MainActor func deleteNestedItemRenumbersOnlyNestedList() async throws {
        let controller = try await makeController(
            markdown: "1. a\n2. b\n   1. x\n   2. y\n   3. z\n3. c", width: 520)
        try await deleteLine(4, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. b\n   1. x\n   2. z\n3. c")
    }

    @Test @MainActor func deleteTextInsideItemDoesNotRenumber() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteRange(8, 9, in: controller) // the "b" of "2. b"
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. \n3. c")
    }

    @Test @MainActor func deleteMarkerDigitsOnlyDoesNotRenumber() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteRange(5, 6, in: controller) // the "2" of "2. b"
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n. b\n3. c")
    }

    @Test @MainActor func deleteAcrossListsMergesAndRenumbers() async throws {
        let controller = try await makeController(
            markdown: "1. a\n2. b\n\n3. c\n4. d", width: 520)
        try await deleteRange(5, 16, in: controller) // item 2 + blank + item "3. c"
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. d")
    }

    @Test @MainActor func deleteWholeListLeavesNoList() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteRange(0, 14, in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "")
    }

    @Test @MainActor func cutUserEventRenumbers() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteLine(2, userEvent: "delete.cut", in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. c")
    }

    @Test @MainActor func undoRestoresDocumentInOneStep() async throws {
        let controller = try await makeController(markdown: "1. a\n2. b\n3. c", width: 520)
        try await deleteLine(2, in: controller)
        #expect(try await markdown(in: controller) == "1. a\n2. c")
        try await dispatchUndo(in: controller)
        let doc = try await markdown(in: controller)
        #expect(doc == "1. a\n2. b\n3. c")
    }

    // MARK: - helpers

    @MainActor
    private func deleteLine(
        _ lineNo: Int,
        userEvent: String = "delete.backward",
        in controller: CodeMirrorEditorViewController
    ) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const line = view.state.doc.line(\(lineNo));
          let from = line.from, to = line.to;
          if (line.number === view.state.doc.lines) {
            from = Math.max(0, from - 1);
            to = view.state.doc.length;
          } else {
            to = to + 1;
          }
          view.dispatch({ changes: { from, to }, userEvent: '\(userEvent)' });
          return { from, to };
        })()
        """)
        try await Task.sleep(for: .milliseconds(80))
    }

    @MainActor
    private func deleteRange(
        _ from: Int,
        _ to: Int,
        userEvent: String = "delete.backward",
        in controller: CodeMirrorEditorViewController
    ) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.dispatch({ changes: { from: \(from), to: \(to) }, userEvent: '\(userEvent)' });
          return { deleted: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(80))
    }

    @MainActor
    private func dispatchUndo(in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluateDictionary(controller, script: """
        (() => {
          window.__mdEditor._undoForTesting();
          return { dispatched: true };
        })()
        """)
        try await Task.sleep(for: .milliseconds(80))
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
    private func markdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
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
}
