import Foundation
import Testing
@testable import FloralMD

@Suite(.serialized)
struct MarkdownResourceReferenceTests {
    @Test func draftImagesAreRelativeToTheCurrentMarkdownDirectory() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/A.md")
            let image = root.appendingPathComponent("notes/assets/images/photo.png")
            try write("", to: document)
            try write("png", to: image)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)

            let result = try MarkdownResourceReferenceResolver().resolve(
                sourceURL: image,
                in: session
            )

            #expect(result.markdown == "![photo.png](assets/images/photo.png)")
            #expect(result.referencedURL == image.standardizedFileURL)
        }
    }

    @Test func untitledDraftUsesTheFutureNotesDirectory() throws {
        try withTemporaryDirectory { root in
            let image = root.appendingPathComponent("notes/assets/images/photo.png")
            try write("png", to: image)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: nil)

            let result = try MarkdownResourceReferenceResolver().resolve(
                sourceURL: image,
                in: session
            )

            #expect(result.markdown == "![photo.png](assets/images/photo.png)")
        }
    }

    @Test func markdownUsesFrontmatterTitleThenFirstHeadingThenFilename() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/A.md")
            try write("", to: document)
            let frontmatter = root.appendingPathComponent("notes/Frontmatter.md")
            let heading = root.appendingPathComponent("notes/Heading.md")
            let fallback = root.appendingPathComponent("notes/Fallback.md")
            try write("---\ntitle: Stable [Title]\n---\n# Ignored", to: frontmatter)
            try write("## First Heading\nBody", to: heading)
            try write("Body only", to: fallback)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)
            let resolver = MarkdownResourceReferenceResolver()

            #expect(try resolver.resolve(sourceURL: frontmatter, in: session).markdown
                == "[Stable \\[Title\\]](Frontmatter.md)")
            #expect(try resolver.resolve(sourceURL: heading, in: session).markdown
                == "[First Heading](Heading.md)")
            #expect(try resolver.resolve(sourceURL: fallback, in: session).markdown
                == "[Fallback](Fallback.md)")
        }
    }

    @Test func everyMarkdownExtensionUsesOneEncodedRelativeLinkAcrossWorkspaceLayouts() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("Draft/notes/current/Editing.md")
            let md = root.appendingPathComponent("Draft/notes/current/Same.md")
            let markdown = root.appendingPathComponent("Draft/notes/子 目录/Paren (1).markdown")
            let mdown = root.appendingPathComponent("Draft/notes/上级文档.mdown")
            try write("", to: document)
            try write("# Same title", to: md)
            try write("---\ntitle: 中文标题\n---", to: markdown)
            try write("No heading", to: mdown)
            let draftSession = WorkspaceSession(
                rootURL: root.appendingPathComponent("Draft"),
                kind: .draft,
                activeResource: ActiveResource(url: document)
            )
            let resolver = MarkdownResourceReferenceResolver()

            #expect(try resolver.markdownInsertion(
                for: [md, markdown, mdown],
                in: draftSession
            ) == "[Same title](Same.md)\n[中文标题](../%E5%AD%90%20%E7%9B%AE%E5%BD%95/Paren%20%281%29.markdown)\n[上级文档](../%E4%B8%8A%E7%BA%A7%E6%96%87%E6%A1%A3.mdown)")

            let externalDocument = root.appendingPathComponent("External/current/Editing.md")
            let externalSource = root.appendingPathComponent("External/references/External.markdown")
            try write("", to: externalDocument)
            try write("## External title", to: externalSource)
            let externalSession = WorkspaceSession(
                rootURL: root.appendingPathComponent("External"),
                kind: .externalFolder,
                activeResource: ActiveResource(url: externalDocument)
            )

            #expect(try resolver.resolve(
                sourceURL: externalSource,
                in: externalSession
            ).markdown == "[External title](../references/External.markdown)")
        }
    }

    @Test func specialCharactersAreEncodedPerPathComponent() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/项目/A.md")
            let image = root.appendingPathComponent("notes/assets/images/图 (1)#50%\\版.png")
            try write("", to: document)
            try write("png", to: image)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)

            let result = try MarkdownResourceReferenceResolver().resolve(
                sourceURL: image,
                in: session
            )

            #expect(result.markdown == "![图 (1)#50%\\\\版.png](../assets/images/%E5%9B%BE%20%281%29%2350%25%5C%E7%89%88.png)")
        }
    }

    @Test func draftDrawingReferencesOnlyItsExistingStandardExport() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/A.md")
            let drawing = root.appendingPathComponent("drawings/Board.excalidraw")
            let export = root.appendingPathComponent("drawings/exports/Board.svg")
            try write("", to: document)
            try write("{}", to: drawing)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)
            let resolver = MarkdownResourceReferenceResolver()

            #expect(throws: MarkdownResourceReferenceError.drawingExportMissing(export.standardizedFileURL)) {
                try resolver.resolve(sourceURL: drawing, in: session)
            }

            try write("<svg/>", to: export)
            let result = try resolver.resolve(sourceURL: drawing, in: session)
            #expect(result.markdown == "![Board](../drawings/exports/Board.svg)")
            #expect(result.referencedURL == export.standardizedFileURL)
        }
    }

    @Test func drawingReferenceRejectsAStandardExportOlderThanItsSource() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/A.md")
            let drawing = root.appendingPathComponent("notes/Project/drawings/Board.excalidraw")
            let export = root.appendingPathComponent("notes/Project/drawings/exports/Board.svg")
            try write("", to: document)
            try write("<svg/>", to: export)
            try write("{}", to: drawing)
            let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
            let newDate = oldDate.addingTimeInterval(10)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: export.path)
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: drawing.path)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)

            #expect(throws: MarkdownResourceReferenceError.drawingExportOutdated(
                export.standardizedFileURL
            )) {
                try MarkdownResourceReferenceResolver().resolve(
                    sourceURL: drawing,
                    in: session
                )
            }
        }
    }

    @Test func externalDrawingUsesTheSiblingExportsRule() throws {
        try withTemporaryDirectory { root in
            let draft = root.appendingPathComponent("Draft", isDirectory: true)
            let document = root.appendingPathComponent("External/notes/A.md")
            let drawing = root.appendingPathComponent("External/drawings/Board.excalidraw")
            let export = root.appendingPathComponent("External/drawings/exports/Board.svg")
            try write("", to: document)
            try write("{}", to: drawing)
            try write("<svg/>", to: export)
            let session = WorkspaceSession(
                rootURL: root.appendingPathComponent("External"),
                kind: .externalFolder,
                activeResource: ActiveResource(url: document)
            )

            let result = try MarkdownResourceReferenceResolver().resolve(
                sourceURL: drawing,
                in: session
            )

            #expect(result.markdown == "![Board](../drawings/exports/Board.svg)")
            #expect(!WorkspaceResolver.contains(document, in: draft))
        }
    }

    @Test func noteLocalDrawingExportEncodesSpecialPathComponents() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/项目/当前.md")
            let drawing = root.appendingPathComponent("notes/项目/drawings/图 (1)#50%.excalidraw")
            let export = root.appendingPathComponent("notes/项目/drawings/exports/图 (1)#50%.svg")
            try write("", to: document)
            try write("{}", to: drawing)
            try write("<svg/>", to: export)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)

            let result = try MarkdownResourceReferenceResolver().resolve(
                sourceURL: drawing,
                in: session
            )

            #expect(result.referencedURL == export.standardizedFileURL)
            #expect(result.markdown
                == "![图 (1)#50%](drawings/exports/%E5%9B%BE%20%281%29%2350%25.svg)")
        }
    }

    @Test func multipleResourcesPreserveOrderInOneLineSeparatedInsertion() throws {
        try withTemporaryDirectory { root in
            let document = root.appendingPathComponent("notes/A.md")
            let first = root.appendingPathComponent("notes/First.md")
            let second = root.appendingPathComponent("notes/assets/images/Second.png")
            try write("", to: document)
            try write("# First title", to: first)
            try write("png", to: second)
            let session = try WorkspaceResolver.resolve(draftRoot: root, targetURL: document)

            let insertion = try MarkdownResourceReferenceResolver().markdownInsertion(
                for: [first, second],
                in: session
            )

            #expect(insertion == "[First title](First.md)\n![Second.png](assets/images/Second.png)")
        }
    }

    @Test func directoriesUnsupportedTypesAndWorkspaceEscapesAreRejected() throws {
        try withTemporaryDirectory { root in
            let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
            let document = workspace.appendingPathComponent("notes/A.md")
            let directory = workspace.appendingPathComponent("assets", isDirectory: true)
            let unsupported = workspace.appendingPathComponent("plain.txt")
            let outside = root.appendingPathComponent("Outside.png")
            try write("", to: document)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write("text", to: unsupported)
            try write("png", to: outside)
            let session = WorkspaceSession(
                rootURL: workspace,
                kind: .externalFolder,
                activeResource: ActiveResource(url: document)
            )
            let resolver = MarkdownResourceReferenceResolver()

            #expect(throws: MarkdownResourceReferenceError.directoryUnsupported(directory.standardizedFileURL)) {
                try resolver.resolve(sourceURL: directory, in: session)
            }
            #expect(throws: MarkdownResourceReferenceError.unsupportedResource(unsupported.standardizedFileURL)) {
                try resolver.resolve(sourceURL: unsupported, in: session)
            }
            #expect(throws: MarkdownResourceReferenceError.resourceOutsideWorkspace(outside.standardizedFileURL)) {
                try resolver.resolve(sourceURL: outside, in: session)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-ReferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }
}
