import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FloralMD

@Suite(.serialized)
struct CodeMirrorResourceDropTests {
    @Test @MainActor func dropPointInsertionUsesOneEditorChangeAndKeepsFocus() async throws {
        let initial = "# First\n\nSecond line"
        let insertion = "[Board](assets/Board.md)"
        let sourceOffset = 9
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var changes: [String] = []
        controller.contentDidChange = { changes.append($0) }
        controller.load(markdown: initial)

        try await waitUntilEditorReady(controller)
        controller.applyPageZoom(1.5)
        try await Task.sleep(for: .milliseconds(100))
        var visibleCoordinates: CGPoint?
        for _ in 0..<100 where visibleCoordinates == nil {
            visibleCoordinates = await editorCoordinates(at: sourceOffset, in: controller)
            if visibleCoordinates == nil {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let coordinates = try #require(visibleCoordinates)
        let appKitPoint = CGPoint(
            x: coordinates.x * 1.5,
            y: coordinates.y * 1.5
        )

        controller.insert(markdown: insertion, at: appKitPoint)

        let insertionIndex = initial.index(initial.startIndex, offsetBy: sourceOffset)
        let expected = String(initial[..<insertionIndex])
            + insertion
            + String(initial[insertionIndex...])
        var actual: String?
        for _ in 0..<100 where actual != expected {
            actual = await markdown(in: controller)
            if actual != expected {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        #expect(actual == expected)
        #expect(changes == [expected])
        let state = await editorState(in: controller)
        #expect(state.isFocused)
        #expect(state.isEditable)

        _ = await evaluate(
            "window.__mdEditor && window.__mdEditor._undoForTesting()",
            in: controller
        )
        for _ in 0..<100 where actual != initial {
            actual = await markdown(in: controller)
            if actual != initial {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        #expect(actual == initial)
        #expect(changes == [expected, initial])
    }

    @Test @MainActor func mappedDropPreservesNonemptySelectionWhileFallbackReplacesIt() async throws {
        let mapped = CodeMirrorEditorViewController()
        mapped.loadViewIfNeeded()
        mapped.view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        mapped.load(markdown: "abcdef")
        try await waitUntilEditorReady(mapped)
        _ = await evaluate("window.__mdEditor.select(1, 4)", in: mapped)
        let coordinates = try #require(await editorCoordinates(at: 5, in: mapped))
        mapped.insert(
            markdown: "X",
            at: CGPoint(x: coordinates.x, y: coordinates.y)
        )
        #expect(await waitForMarkdown("abcdeXf", in: mapped))

        let fallback = CodeMirrorEditorViewController()
        fallback.loadViewIfNeeded()
        fallback.view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        var changes: [String] = []
        fallback.contentDidChange = { changes.append($0) }
        fallback.load(markdown: "abcdef")
        try await waitUntilEditorReady(fallback)
        _ = await evaluate("window.__mdEditor.select(1, 4)", in: fallback)
        _ = await evaluate(
            "window.__mdEditor.insertAt(Number.NaN, Number.NaN, 'X')",
            in: fallback
        )
        #expect(await waitForMarkdown("aXef", in: fallback))
        #expect(changes == ["aXef"])
        _ = await evaluate(
            "window.__mdEditor._undoForTesting()",
            in: fallback
        )
        #expect(await waitForMarkdown("abcdef", in: fallback))
    }

    @Test @MainActor func imageWidgetCoordinatesAllowDropsBeforeAndAfterTheBlock() async throws {
        let initial = "before\n\n![preview](missing.png)\n\nafter"
        let insertion = "[drop]"
        for sourceOffset in [0, initial.utf16.count] {
            let controller = CodeMirrorEditorViewController()
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
            controller.load(markdown: initial)
            try await waitUntilEditorReady(controller)
            let coordinates = try #require(await editorCoordinates(
                at: sourceOffset,
                in: controller
            ))
            controller.insert(
                markdown: insertion,
                at: CGPoint(
                    x: coordinates.x,
                    y: coordinates.y
                )
            )
            let index = initial.index(initial.startIndex, offsetBy: sourceOffset)
            let expected = initial[..<index] + insertion + initial[index...]
            #expect(await waitForMarkdown(String(expected), in: controller))
        }
    }

    @Test @MainActor func sidebarProviderPublishesOnlyOneFileURLRepresentation() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/测试文档 (1).markdown")
        let provider = WorkspaceSidebarDragItemProvider.make(fileURL: fileURL)

        #expect(provider.suggestedName == nil)
        #expect(provider.registeredTypeIdentifiers == [UTType.fileURL.identifier])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        #expect(String(data: data, encoding: .utf8) == fileURL.absoluteString)
    }

    @Test @MainActor func exactFileURLPasteboardIgnoresTextAndDeduplicatesRepresentations() {
        let pasteboard = NSPasteboard(name: .init("FloralMD.ResourceDrop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/Note with spaces.md").standardizedFileURL
        let first = NSPasteboardItem()
        first.setString(fileURL.absoluteString, forType: .fileURL)
        first.setString(fileURL.path, forType: .string)
        let duplicate = NSPasteboardItem()
        duplicate.setString(fileURL.absoluteString, forType: .fileURL)
        duplicate.setString(fileURL.lastPathComponent, forType: .string)
        let textOnly = NSPasteboardItem()
        textOnly.setString("/tmp/should-not-be-decoded.md", forType: .string)
        #expect(pasteboard.writeObjects([first, duplicate, textOnly]))

        #expect(EditorResourceDropPayload.hasFileURLRepresentation(pasteboard))
        #expect(EditorResourceDropPayload.resourceURLs(from: pasteboard) == [fileURL])

        let textPasteboard = NSPasteboard(
            name: .init("FloralMD.ResourceDrop.Text.\(UUID().uuidString)")
        )
        textPasteboard.clearContents()
        #expect(textPasteboard.setString(fileURL.path, forType: .string))
        #expect(!EditorResourceDropPayload.hasFileURLRepresentation(textPasteboard))
        #expect(EditorResourceDropPayload.resourceURLs(from: textPasteboard).isEmpty)
    }

    @Test @MainActor func editorWebViewExclusivelyOwnsFileDropDestination() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.load(markdown: "# Drop target")
        try await waitUntilEditorReady(controller)

        let webView = try #require(controller.view as? EditorResourceDropWebView)
        webView.claimExclusiveResourceDropDestination()

        #expect(webView.registeredDraggedTypes.contains(.fileURL))
        #expect(webView.subviews.flatMap(\NSView.allDescendants).allSatisfy {
            $0.registeredDraggedTypes.isEmpty
        })
    }

    @Test @MainActor func windowBaseDraggingLocationReportsHandlerResult() throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        let webView = try #require(controller.view as? EditorResourceDropWebView)
        let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        webView.frame = CGRect(x: 73, y: 41, width: 500, height: 390)
        contentView.addSubview(webView)

        let local = webView.viewLocation(
            forDraggingLocation: CGPoint(x: 73 + 125, y: 41 + 96)
        )
        #expect(abs(local.x - 125) < 0.01)
        #expect(abs(local.y - (webView.bounds.height - 96)) < 0.01)

        let url = URL(fileURLWithPath: "/tmp/Drop.md")
        webView.performResourceDrop = { _, _ in false }
        #expect(!webView.handleResourceDrop([url], at: local))
        webView.performResourceDrop = { urls, point in
            urls == [url] && point == local
        }
        #expect(webView.handleResourceDrop([url], at: local))
    }

    @MainActor
    private func waitUntilEditorReady(
        _ controller: CodeMirrorEditorViewController
    ) async throws {
        for _ in 0..<100 {
            if await editorState(in: controller).isReady { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    @MainActor
    private func editorCoordinates(
        at position: Int,
        in controller: CodeMirrorEditorViewController
    ) async -> CGPoint? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(
                "window.__mdEditor && window.__mdEditor._coordsAtForTesting(\(position))"
            ) { value in
                guard let rect = value as? [String: Any],
                      let left = rect["left"] as? Double,
                      let top = rect["top"] as? Double,
                      let bottom = rect["bottom"] as? Double else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CGPoint(
                    x: left,
                    y: (top + bottom) / 2
                ))
            }
        }
    }

    @MainActor
    private func markdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private func waitForMarkdown(
        _ expected: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Bool {
        for _ in 0..<100 {
            if await markdown(in: controller) == expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
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

    @MainActor
    private func editorState(
        in controller: CodeMirrorEditorViewController
    ) async -> CodeMirrorEditorViewController.EditorState {
        await withCheckedContinuation { continuation in
            controller.inspectEditorState { continuation.resume(returning: $0) }
        }
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\NSView.allDescendants)
    }
}
