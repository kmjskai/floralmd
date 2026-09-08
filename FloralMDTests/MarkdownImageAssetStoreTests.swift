import Foundation
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
struct MarkdownImageAssetStoreTests {
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x01])
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0xff, 0xd9])
    private let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    private let webP = Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TA8AAAAvAAAAAAcQ/Y/+ByKi/wEA")!
    private let svg = Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"><path/></svg>".utf8)

    @Test func editorBridgeDecodesClipboardImagePayload() throws {
        let request = try MarkdownImagePasteRequest(payload: [
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
            "name": "Clipboard.png"
        ])

        #expect(request.items == [MarkdownImagePasteRequest.Item(
            data: png,
            mimeType: "image/png",
            suggestedName: "Clipboard.png"
        )])
        #expect(request.selection == nil)
    }

    @Test func editorBridgeRejectsMalformedClipboardImageBeforeStorage() {
        #expect(throws: MarkdownImagePasteRequest.Error.invalidPayload) {
            try MarkdownImagePasteRequest(payload: [
                "data": "not-base64",
                "mimeType": "image/png"
            ])
        }
    }

    @Test func editorBridgeDecodesOrderedBatchAndCapturedSelection() throws {
        let request = try MarkdownImagePasteRequest(payload: [
            "items": [
                ["data": png.base64EncodedString(), "mimeType": "image/png", "name": "image.png"],
                ["data": gif.base64EncodedString(), "mimeType": "image/gif", "name": "clipboard.gif"]
            ],
            "selection": ["from": 3, "to": 7]
        ])

        #expect(request.items.map(\.mimeType) == ["image/png", "image/gif"])
        #expect(request.selection == .init(from: 3, to: 7))
    }

    @Test @MainActor func batchPasteUsesCapturedSelectionOrderAndOneUndo() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.load(markdown: "0123456789")
        try await waitUntilReady(controller)

        var receivedNames: [String?] = []
        var handlerCount = 0
        controller.imagePasteRequested = { request in
            handlerCount += 1
            receivedNames = request.items.map(\.suggestedName)
            return request.items.map { "![](\($0.suggestedName ?? "missing"))" }
                .joined(separator: "\n")
        }
        let first = png.base64EncodedString()
        let second = gif.base64EncodedString()
        _ = await evaluate(
            """
            (() => {
              const bytes = value => Uint8Array.from(atob(value), char => char.charCodeAt(0));
              const transfer = new DataTransfer();
              transfer.items.add(new File([bytes('\(first)')], 'first.png', { type: 'image/png' }));
              transfer.items.add(new File([bytes('\(second)')], 'second.gif', { type: 'image/gif' }));
              window.__mdEditor.select(2, 5);
              const event = new ClipboardEvent('paste', {
                clipboardData: transfer,
                bubbles: true,
                cancelable: true
              });
              document.dispatchEvent(event);
              window.__mdEditor.select(9);
              return event.defaultPrevented;
            })()
            """,
            in: controller
        )

        let inserted = "01![](first.png)\n![](second.gif)56789"
        try await waitForMarkdown(inserted, in: controller)
        #expect(handlerCount == 1)
        #expect(receivedNames == ["first.png", "second.gif"])

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        try await waitForMarkdown("0123456789", in: controller)
    }

    @Test func draftImageUsesSharedNotesAssetDirectoryAndDocumentRelativeLink() throws {
        try withTemporaryDirectory { root in
            let documentURL = root.appendingPathComponent("notes/projects/My Note.md")
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: documentURL)

            let result = try fixedStore().persist(
                data: png,
                mimeType: "image/png",
                suggestedName: "Screen Shot (1).png",
                in: session
            )

            #expect(result.fileURL == root.appendingPathComponent("notes/assets/images/2026-08-12-09-35-21.png"))
            #expect(result.markdownInsertion == "![](../assets/images/2026-08-12-09-35-21.png)")
            #expect(try Data(contentsOf: result.fileURL) == png)
        }
    }

    @Test func untitledDraftUsesNotesAsItsRelativeLinkBase() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let result = try fixedStore().persist(
                data: svg,
                mimeType: "image/svg+xml; charset=utf-8",
                suggestedName: "diagram.svg",
                in: session
            )

            #expect(result.fileURL == root.appendingPathComponent("notes/assets/images/2026-08-12-09-35-21.svg"))
            #expect(result.markdownInsertion == "![](assets/images/2026-08-12-09-35-21.svg)")
        }
    }

    @Test func externalMarkdownUsesSiblingAssetsDirectory() throws {
        try withTemporaryDirectory { container in
            let draftRoot = container.appendingPathComponent("Draft", isDirectory: true)
            let documentURL = container.appendingPathComponent("External/Notes/Article.md")
            let session = try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: documentURL)
            let result = try fixedStore().persist(
                data: jpeg,
                mimeType: "image/jpeg",
                suggestedName: "photo.jpeg",
                in: session
            )

            #expect(result.fileURL == container.appendingPathComponent("External/Notes/assets/images/2026-08-12-09-35-21.jpg"))
            #expect(result.markdownInsertion == "![](assets/images/2026-08-12-09-35-21.jpg)")
        }
    }

    @Test func collisionsIncrementWithoutOverwritingExistingFiles() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let store = fixedStore()

            let first = try store.persist(data: png, mimeType: "image/png", suggestedName: "image.png", in: session)
            let second = try store.persist(data: png, mimeType: "image/png", suggestedName: "image.png", in: session)
            let third = try store.persist(data: png, mimeType: "image/png", suggestedName: "image.png", in: session)

            #expect(first.fileURL.lastPathComponent == "2026-08-12-09-35-21.png")
            #expect(second.fileURL.lastPathComponent == "2026-08-12-09-35-21-2.png")
            #expect(third.fileURL.lastPathComponent == "2026-08-12-09-35-21-3.png")
            #expect(try Data(contentsOf: first.fileURL) == png)
        }
    }

    @Test func clipboardBatchKeepsOrderUsesValidatedExtensionsAndOneTimestamp() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let items = [
                MarkdownImagePasteRequest.Item(data: png, mimeType: "image/png", suggestedName: "image.png"),
                MarkdownImagePasteRequest.Item(data: jpeg, mimeType: "image/jpeg", suggestedName: "clipboard.png"),
                MarkdownImagePasteRequest.Item(data: gif, mimeType: "image/gif", suggestedName: nil),
                MarkdownImagePasteRequest.Item(data: webP, mimeType: "image/webp", suggestedName: "photo.webp"),
                MarkdownImagePasteRequest.Item(data: svg, mimeType: "image/svg+xml", suggestedName: "vector.svg")
            ]

            let assets = try fixedStore().persistClipboardItems(items, in: session)

            #expect(assets.map { $0.fileURL.lastPathComponent } == [
                "2026-08-12-09-35-21.png",
                "2026-08-12-09-35-21-2.jpg",
                "2026-08-12-09-35-21-3.gif",
                "2026-08-12-09-35-21-4.webp",
                "2026-08-12-09-35-21-5.svg"
            ])
            #expect(try assets.map { try Data(contentsOf: $0.fileURL) }
                == [png, jpeg, gif, webP, svg])
        }
    }

    @Test func clipboardCollisionChecksTheTimestampStemAcrossFormats() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let directory = DraftWorkspaceLayout(root: root).markdownImagesDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = directory.appendingPathComponent("2026-08-12-09-35-21.svg")
            try svg.write(to: existing)

            let asset = try fixedStore().persist(
                data: png,
                mimeType: "image/png",
                suggestedName: "image.png",
                in: session
            )

            #expect(asset.fileURL.lastPathComponent == "2026-08-12-09-35-21-2.png")
            #expect(try Data(contentsOf: existing) == svg)
        }
    }

    @Test func invalidLaterBatchItemWritesNothingAndReturnsNoReferences() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let items = [
                MarkdownImagePasteRequest.Item(data: png, mimeType: "image/png", suggestedName: nil),
                MarkdownImagePasteRequest.Item(data: jpeg, mimeType: "image/png", suggestedName: nil)
            ]

            #expect(throws: MarkdownImageAssetStoreError.invalidImageData) {
                try fixedStore().persistClipboardItems(items, in: session)
            }
            #expect(!FileManager.default.fileExists(
                atPath: DraftWorkspaceLayout(root: root).markdownImagesDirectory.path
            ))
        }
    }

    @Test func filesystemFailureReturnsNoDanglingMarkdownReferences() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let directory = DraftWorkspaceLayout(root: root).markdownImagesDirectory
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("blocks directory creation".utf8).write(to: directory)
            let items = [
                MarkdownImagePasteRequest.Item(data: png, mimeType: "image/png", suggestedName: nil),
                MarkdownImagePasteRequest.Item(data: gif, mimeType: "image/gif", suggestedName: nil)
            ]

            #expect(throws: (any Error).self) {
                try fixedStore().persistClipboardItems(items, in: session)
            }
            #expect(try Data(contentsOf: directory) == Data("blocks directory creation".utf8))
        }
    }

    @Test func finderFileImportPreservesSourceAndSanitizesDestinationName() throws {
        try withTemporaryDirectory { root in
            let sourceDirectory = root.appendingPathComponent("Finder", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let source = sourceDirectory.appendingPathComponent("unsafe:name.PNG")
            try png.write(to: source)
            let session = try WorkspaceResolver.resolve(
                draftRoot: root.appendingPathComponent("Draft", isDirectory: true),
                targetURL: nil
            )

            let result = try MarkdownImageAssetStore().persist(fileURL: source, in: session)

            #expect(result.fileURL.lastPathComponent == "unsafe-name.png")
            #expect(try Data(contentsOf: source) == png)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try Data(contentsOf: result.fileURL) == png)
        }
    }

    @Test func invalidAndUnsupportedPayloadsNeverCreateAnAssetOrLink() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let store = fixedStore()

            #expect(throws: MarkdownImageAssetStoreError.unsupportedMIMEType("image/bmp")) {
                try store.persist(data: Data("BM".utf8), mimeType: "image/bmp", suggestedName: "x.bmp", in: session)
            }
            #expect(throws: MarkdownImageAssetStoreError.invalidImageData) {
                try store.persist(data: Data("not png".utf8), mimeType: "image/png", suggestedName: "x.png", in: session)
            }

            let imagesDirectory = DraftWorkspaceLayout(root: root).markdownImagesDirectory
            #expect(!FileManager.default.fileExists(atPath: imagesDirectory.path))
        }
    }

    @Test func finderInputRejectsUnsupportedExtensionAndMismatchedBytes() throws {
        try withTemporaryDirectory { root in
            let sourceDirectory = root.appendingPathComponent("Finder", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let bitmap = sourceDirectory.appendingPathComponent("image.bmp")
            let invalidGIF = sourceDirectory.appendingPathComponent("image.gif")
            let fakePNG = sourceDirectory.appendingPathComponent("image.png")
            try Data("BM".utf8).write(to: bitmap)
            try Data("GIF89a".utf8).write(to: invalidGIF)
            try jpeg.write(to: fakePNG)
            let session = try WorkspaceResolver.resolve(draftRoot: root.appendingPathComponent("Draft"), targetURL: nil)
            let store = fixedStore()

            #expect(throws: MarkdownImageAssetStoreError.unsupportedFileType("bmp")) {
                try store.persist(fileURL: bitmap, in: session)
            }
            #expect(throws: MarkdownImageAssetStoreError.invalidImageData) {
                try store.persist(fileURL: invalidGIF, in: session)
            }
            #expect(throws: MarkdownImageAssetStoreError.invalidImageData) {
                try store.persist(fileURL: fakePNG, in: session)
            }
        }
    }

    @Test func gifAndWebPPersistAsOrdinaryMarkdownAssets() throws {
        try withTemporaryDirectory { root in
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)
            let store = fixedStore()

            let gifAsset = try store.persist(
                data: gif,
                mimeType: "image/gif",
                suggestedName: "animation.gif",
                in: session
            )
            let webPAsset = try store.persist(
                data: webP,
                mimeType: "image/webp",
                suggestedName: "photo.webp",
                in: session
            )

            #expect(gifAsset.markdownInsertion == "![](assets/images/2026-08-12-09-35-21.gif)")
            #expect(webPAsset.markdownInsertion == "![](assets/images/2026-08-12-09-35-21-2.webp)")
        }
    }

    @Test func externalSessionWithoutMarkdownFailsBeforeWriting() throws {
        try withTemporaryDirectory { root in
            let session = WorkspaceSession(rootURL: root, kind: .externalFolder, activeResource: nil)
            #expect(throws: MarkdownImageAssetStoreError.markdownDocumentRequired) {
                try MarkdownImageAssetStore().persist(
                    data: png,
                    mimeType: "image/png",
                    suggestedName: "image.png",
                    in: session
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/images").path))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-MarkdownImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @MainActor
    private func waitUntilReady(_ controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<100 {
            let state = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0) }
            }
            if state.isReady { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    @MainActor
    private func waitForMarkdown(
        _ expected: String,
        in controller: CodeMirrorEditorViewController
    ) async throws {
        for _ in 0..<100 {
            let markdown = await withCheckedContinuation { continuation in
                controller.fetchMarkdown { continuation.resume(returning: $0) }
            }
            if markdown == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not reach expected Markdown")
    }

    @MainActor
    private func evaluate(
        _ script: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { value in
                continuation.resume(returning: value)
            }
        }
    }

    private func fixedStore() -> MarkdownImageAssetStore {
        MarkdownImageAssetStore(
            clock: { fixedDate },
            calendar: fixedCalendar,
            timeZone: fixedTimeZone
        )
    }

    private var fixedDate: Date {
        var components = DateComponents()
        components.calendar = fixedCalendar
        components.timeZone = fixedTimeZone
        components.year = 2026
        components.month = 8
        components.day = 12
        components.hour = 9
        components.minute = 35
        components.second = 21
        return components.date!
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fixedTimeZone
        return calendar
    }

    private var fixedTimeZone: TimeZone {
        TimeZone(secondsFromGMT: 8 * 60 * 60)!
    }
}
