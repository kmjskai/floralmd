import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FloralMD

@MainActor
struct WorkspaceFileInteractionTests {
    @Test func dropPlanMovesInternallyCopiesWithOptionAndImportsExternalFiles() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD Workspace", isDirectory: true)
        let source = root.appendingPathComponent("A/Note.md")
        let target = root.appendingPathComponent("B", isDirectory: true)

        #expect(WorkspaceFileDropPlan.request(
            sourceURL: source,
            targetDirectoryURL: target,
            workspaceRootURL: root,
            optionKey: false
        ) == .move(itemURL: source, destinationDirectoryURL: target))
        #expect(WorkspaceFileDropPlan.request(
            sourceURL: source,
            targetDirectoryURL: target,
            workspaceRootURL: root,
            optionKey: true
        ) == .copy(itemURL: source, destinationDirectoryURL: target))
        #expect(WorkspaceFileDropPlan.request(
            sourceURL: source,
            targetDirectoryURL: source.deletingLastPathComponent(),
            workspaceRootURL: root,
            optionKey: true
        ) == .duplicate(itemURL: source))

        let external = URL(fileURLWithPath: "/tmp/Outside/Asset.bin")
        #expect(WorkspaceFileDropPlan.request(
            sourceURL: external,
            targetDirectoryURL: target,
            workspaceRootURL: root,
            optionKey: false
        ) == .importFile(sourceURL: external, destinationDirectoryURL: target))
        #expect(WorkspaceFileDropPlan.request(
            sourceURL: external,
            targetDirectoryURL: target,
            workspaceRootURL: root,
            optionKey: true
        ) == .importFile(sourceURL: external, destinationDirectoryURL: target))
    }

    @Test func clipboardRoundTripsRealFileURLAndOperationMarker() throws {
        let pasteboard = NSPasteboard(name: .init("FloralMD.Files.\(UUID().uuidString)"))
        let fileURL = URL(fileURLWithPath: "/tmp/Files with 空格/Note.md")

        #expect(WorkspaceFileClipboard.write(url: fileURL, operation: .cut, to: pasteboard))
        let payload = try #require(WorkspaceFileClipboard.read(from: pasteboard))
        #expect(payload == WorkspaceFileClipboardPayload(
            url: fileURL.standardizedFileURL,
            operation: .cut
        ))
        #expect(pasteboard.types?.contains(.fileURL) == true)
    }

    @Test func externalImportCopiesWithoutDeletingOrOverwriting() throws {
        try withTemporaryDirectories { root, outside in
            let destination = root.appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let source = outside.appendingPathComponent("资料.dat")
            try Data("external".utf8).write(to: source)
            let service = WorkspaceFileOperationService()

            let result = try service.perform(
                .importFile(sourceURL: source, destinationDirectoryURL: destination),
                workspaceRootURL: root
            )
            let imported = destination.appendingPathComponent("资料.dat")
            #expect(result.createdURL == imported.standardizedFileURL)
            #expect(try Data(contentsOf: imported) == Data("external".utf8))
            #expect(try Data(contentsOf: source) == Data("external".utf8))

            #expect(throws: WorkspaceFileOperationError.self) {
                try service.perform(
                    .importFile(sourceURL: source, destinationDirectoryURL: destination),
                    workspaceRootURL: root
                )
            }
            #expect(try Data(contentsOf: imported) == Data("external".utf8))
        }
    }

    @Test func internalCopyPreservesSourceAndRejectsCollision() throws {
        try withTemporaryDirectories { root, _ in
            let sourceFolder = root.appendingPathComponent("A", isDirectory: true)
            let destinationFolder = root.appendingPathComponent("B", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let source = sourceFolder.appendingPathComponent("Note.md")
            try "newest".write(to: source, atomically: true, encoding: .utf8)
            let service = WorkspaceFileOperationService()

            let result = try service.perform(
                .copy(itemURL: source, destinationDirectoryURL: destinationFolder),
                workspaceRootURL: root
            )
            let copied = destinationFolder.appendingPathComponent("Note.md")
            #expect(result.createdURL == copied.standardizedFileURL)
            #expect(try String(contentsOf: source, encoding: .utf8) == "newest")
            #expect(try String(contentsOf: copied, encoding: .utf8) == "newest")
            #expect(throws: WorkspaceFileOperationError.self) {
                try service.perform(
                    .copy(itemURL: source, destinationDirectoryURL: destinationFolder),
                    workspaceRootURL: root
                )
            }
        }
    }

    @Test func crossVolumePolicyRejectsKnownMismatchWithoutGuessingUnknownVolumes() {
        #expect(WorkspaceFileVolumePolicy.allowsMove(
            sourceVolumeIdentifier: "volume-a",
            destinationVolumeIdentifier: "volume-a"
        ))
        #expect(!WorkspaceFileVolumePolicy.allowsMove(
            sourceVolumeIdentifier: "volume-a",
            destinationVolumeIdentifier: "volume-b"
        ))
        #expect(WorkspaceFileVolumePolicy.allowsMove(
            sourceVolumeIdentifier: nil,
            destinationVolumeIdentifier: "volume-b"
        ))
    }

    @Test func outboundDragUsesOnlyStandardFileURLRepresentation() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/Files/unsupported.archive")
        let provider = WorkspaceSidebarDragItemProvider.make(fileURL: fileURL)
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

    private func withTemporaryDirectories(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-WorkspaceInteractions-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Workspace", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, outside)
    }
}
