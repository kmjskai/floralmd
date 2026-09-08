import Foundation
import Testing
@testable import FloralMD

@MainActor
struct WorkspaceFileOperationTests {
    @Test func createsMarkdownAndDirectoryWithoutOverwriting() throws {
        try withTemporaryDirectory { root in
            let service = WorkspaceFileOperationService()
            let folderResult = try service.perform(
                .createDirectory(parentURL: root, name: "资料"),
                workspaceRootURL: root
            )
            let folder = try #require(folderResult.createdURL)
            let markdownResult = try service.perform(
                .createMarkdown(parentURL: folder, name: "笔记.markdown"),
                workspaceRootURL: root
            )
            let markdown = try #require(markdownResult.createdURL)

            #expect(FileManager.default.fileExists(atPath: folder.path))
            #expect(FileManager.default.fileExists(atPath: markdown.path))
            #expect(throws: WorkspaceFileOperationError.self) {
                try service.perform(
                    .createMarkdown(parentURL: folder, name: "笔记.markdown"),
                    workspaceRootURL: root
                )
            }
        }
    }

    @Test func movesAcrossDirectoriesAndRejectsCollisionAndCycles() throws {
        try withTemporaryDirectory { root in
            let sourceFolder = root.appendingPathComponent("A", isDirectory: true)
            let destinationFolder = root.appendingPathComponent("B", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let note = sourceFolder.appendingPathComponent("Note.md")
            try "safe".write(to: note, atomically: true, encoding: .utf8)
            let service = WorkspaceFileOperationService()

            let result = try service.perform(
                .move(itemURL: note, destinationDirectoryURL: destinationFolder),
                workspaceRootURL: root
            )
            let moved = destinationFolder.appendingPathComponent("Note.md")
            #expect(result.relocatedItem?.to == moved.standardizedFileURL)
            #expect(try String(contentsOf: moved, encoding: .utf8) == "safe")

            let other = sourceFolder.appendingPathComponent("Note.md")
            try "other".write(to: other, atomically: true, encoding: .utf8)
            #expect(throws: WorkspaceFileOperationError.self) {
                try service.perform(
                    .move(itemURL: other, destinationDirectoryURL: destinationFolder),
                    workspaceRootURL: root
                )
            }
            #expect(try String(contentsOf: other, encoding: .utf8) == "other")
            #expect(try String(contentsOf: moved, encoding: .utf8) == "safe")

            let child = sourceFolder.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            #expect(throws: WorkspaceFileOperationError.self) {
                try service.perform(
                    .move(itemURL: sourceFolder, destinationDirectoryURL: child),
                    workspaceRootURL: root
                )
            }
        }
    }

    @Test func caseOnlyRenameAndParentRenameUpdateActiveMarkdownPath() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let note = folder.appendingPathComponent("Note.md")
            try "before".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })
            let service = WorkspaceFileOperationService()

            let caseResult = try service.perform(
                .rename(itemURL: note, name: "note.md"),
                workspaceRootURL: root
            )
            let lowercased = folder.appendingPathComponent("note.md")
            controller.applyWorkspaceRelocation(
                from: caseResult.relocatedItem!.from,
                to: caseResult.relocatedItem!.to
            )
            #expect(controller.activeResource?.url == lowercased.standardizedFileURL)

            controller.markdownText = "after"
            try controller.prepareForWorkspaceMutation(affecting: folder)
            let parentResult = try service.perform(
                .rename(itemURL: folder, name: "Renamed"),
                workspaceRootURL: root
            )
            controller.applyWorkspaceRelocation(
                from: parentResult.relocatedItem!.from,
                to: parentResult.relocatedItem!.to
            )
            let finalURL = root.appendingPathComponent("Renamed/note.md")
            #expect(controller.activeResource?.url == finalURL.standardizedFileURL)
            #expect(try String(contentsOf: finalURL, encoding: .utf8) == "after")
        }
    }

    @Test func duplicateUsesUniqueNameAndDrawingSVGStayIndependent() throws {
        try withTemporaryDirectory { root in
            let drawing = root.appendingPathComponent("Sketch.excalidraw")
            let svg = root.appendingPathComponent("Sketch.svg")
            try "drawing".write(to: drawing, atomically: true, encoding: .utf8)
            try "svg".write(to: svg, atomically: true, encoding: .utf8)
            let service = WorkspaceFileOperationService()

            let duplicate = try #require(try service.perform(
                .duplicate(itemURL: drawing),
                workspaceRootURL: root
            ).createdURL)
            #expect(duplicate.lastPathComponent == "Sketch 副本.excalidraw")
            let renamedResult = try service.perform(
                .rename(itemURL: drawing, name: "Board.excalidraw"),
                workspaceRootURL: root
            )
            #expect(renamedResult.relocatedItem?.to.lastPathComponent == "Board.excalidraw")
            #expect(try String(contentsOf: svg, encoding: .utf8) == "svg")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Board.svg").path))
        }
    }

    @Test func trashUsesRecoverableBoundaryAndControllerClearsSelection() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Note.md")
            try "safe".write(to: note, atomically: true, encoding: .utf8)
            var receivedTrashURL: URL?
            let service = WorkspaceFileOperationService(trashAction: { receivedTrashURL = $0 })
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })

            try controller.prepareForWorkspaceMutation(affecting: note)
            let result = try service.perform(.trash(itemURL: note), workspaceRootURL: root)
            controller.applyWorkspaceRemoval(of: note)

            #expect(receivedTrashURL == note.standardizedFileURL)
            #expect(result.removedItemURL == note.standardizedFileURL)
            #expect(controller.activeResource == nil)
            #expect(FileManager.default.fileExists(atPath: note.path))
        }
    }

    @Test func activeDrawingMutationIsExplicitlyBlocked() throws {
        try withTemporaryDirectory { root in
            let drawing = root.appendingPathComponent("Sketch.excalidraw")
            try "{}".write(to: drawing, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: drawing, draftRootProvider: { root })

            #expect(throws: WorkspaceFileOperationError.activeDrawingRequiresSave) {
                try controller.prepareForWorkspaceMutation(affecting: drawing)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-WorkspaceOperations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
