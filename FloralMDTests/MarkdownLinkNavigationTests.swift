import AppKit
import Foundation
import Testing
import WebKit
@testable import FloralMD

@MainActor
struct MarkdownLinkNavigationTests {
    private let resolver = MarkdownLinkNavigationResolver()

    @Test func resolvesEncodedChineseSpacesAndParentDirectoryMarkdown() throws {
        try withTemporaryDirectory { root in
            let notes = root.appendingPathComponent("子目录", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            let current = notes.appendingPathComponent("当前.md")
            let encodedTarget = notes.appendingPathComponent("中文 空格.markdown")
            let parentTarget = root.appendingPathComponent("父级.mdown")
            try "current".write(to: current, atomically: true, encoding: .utf8)
            try "encoded".write(to: encodedTarget, atomically: true, encoding: .utf8)
            try "parent".write(to: parentTarget, atomically: true, encoding: .utf8)

            #expect(try resolver.resolve(
                "%E4%B8%AD%E6%96%87%20%E7%A9%BA%E6%A0%BC.markdown#%E6%A0%87%E9%A2%98",
                documentURL: current,
                workspaceRootURL: root
            ) == .markdown(encodedTarget.standardizedFileURL, fragment: "标题"))
            #expect(try resolver.resolve(
                "../%E7%88%B6%E7%BA%A7.mdown",
                documentURL: current,
                workspaceRootURL: root
            ) == .markdown(parentTarget.standardizedFileURL, fragment: nil))
        }
    }

    @Test func separatesCurrentFragmentsAndSystemExternalLinks() throws {
        let document = URL(fileURLWithPath: "/tmp/Current.md")
        #expect(try resolver.resolve("#section%20one", documentURL: document) == .fragment("section one"))
        #expect(try resolver.resolve("https://example.com/a?q=1", documentURL: document)
            == .external(URL(string: "https://example.com/a?q=1")!))
        #expect(try resolver.resolve("mailto:hello@example.com", documentURL: document)
            == .external(URL(string: "mailto:hello@example.com")!))
    }

    @Test func leavesImagesAndDrawingsOnTheirExistingRouteButRejectsUnsupportedFiles() throws {
        let document = URL(fileURLWithPath: "/tmp/Current.md")
        #expect(try resolver.resolve("image.png", documentURL: document) == .unchanged)
        #expect(try resolver.resolve("drawing.excalidraw", documentURL: document) == .unchanged)
        #expect(throws: MarkdownLinkNavigationError.unsupportedResource(
            URL(fileURLWithPath: "/tmp/notes.txt")
        )) {
            try resolver.resolve("notes.txt", documentURL: document)
        }
    }

    @Test func rejectsMissingDirectoriesAndSymbolicLinkEscapes() throws {
        try withTemporaryDirectory { root in
            let current = root.appendingPathComponent("Current.md")
            let directory = root.appendingPathComponent("Folder.md", isDirectory: true)
            let outside = root.deletingLastPathComponent().appendingPathComponent("Outside-(UUID()).md")
            let link = root.appendingPathComponent("Escape.md")
            try "current".write(to: current, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "outside".write(to: outside, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            #expect(throws: MarkdownLinkNavigationError.unavailable(
                root.appendingPathComponent("Missing.md")
            )) {
                try resolver.resolve("Missing.md", documentURL: current, workspaceRootURL: root)
            }
            #expect(throws: MarkdownLinkNavigationError.directory(directory.standardizedFileURL)) {
                try resolver.resolve("Folder.md", documentURL: current, workspaceRootURL: root)
            }
            #expect(throws: MarkdownLinkNavigationError.symbolicLink(link.standardizedFileURL)) {
                try resolver.resolve("Escape.md", documentURL: current, workspaceRootURL: root)
            }
        }
    }

    @Test func headingFragmentsSupportRenderedIDsAndReadableSlugs() {
        let markdown = "# 第一 标题\n\n## Second_heading!\n"
        #expect(MarkdownOutline.heading(matchingFragment: "第一-标题", in: markdown)?.id == 0)
        #expect(MarkdownOutline.heading(matchingFragment: "md-heading-1", in: markdown)?.title == "Second_heading!")
    }

    @Test func previewKeepsTheOriginalRelativeHrefForNativeRouting() {
        let html = MarkdownHTML.makeHTML(from: "[outside](../Outside%20Note.md#part)")
        #expect(html.contains(
            "href=\"../Outside%20Note.md#part\" data-md-href=\"../Outside%20Note.md#part\""
        ))

        let coordinator = MarkdownPreviewWebView.Coordinator(linkNavigationHandler: { _ in true })
        let configuration = MarkdownPreviewWebView.makeWebViewConfiguration(
            resourceHandler: coordinator.resourceHandler,
            linkMessageHandler: coordinator
        )
        #expect(configuration.userContentController.userScripts.contains {
            $0.source.contains("getAttribute('data-md-href')")
        })
    }

    @Test func dirtySaveFailureKeepsCurrentDocumentAndDoesNotJump() throws {
        try withTemporaryDirectory { root in
            let current = root.appendingPathComponent("Current.md")
            let target = root.appendingPathComponent("Target.md")
            try "before".write(to: current, atomically: true, encoding: .utf8)
            try "target".write(to: target, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: current, draftRootProvider: { root })
            controller.markdownText = "dirty"

            try FileManager.default.removeItem(at: current)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)

            #expect(throws: WorkspaceControllerError.self) {
                try controller.open(targetURL: target)
            }
            #expect(controller.activeResource?.url.path == current.standardizedFileURL.path)
            #expect(controller.markdownText == "dirty")
            #expect(controller.isMarkdownDirty)
        }
    }

    @Test func routerSwitchesTheAttachedControllerWithoutCreatingASecondWindow() throws {
        try withTemporaryDirectory { root in
            let current = root.appendingPathComponent("Current.md")
            let target = root.appendingPathComponent("Target.md")
            try "before".write(to: current, atomically: true, encoding: .utf8)
            try "target".write(to: target, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: current, draftRootProvider: { root })
            WorkspaceOpenRouter.shared.attach(controller)
            let windowCount = NSApp.windows.count

            try WorkspaceOpenRouter.shared.openMarkdownLink(target)

            #expect(controller.activeResource?.url == target.standardizedFileURL)
            #expect(controller.markdownText == "target")
            #expect(NSApp.windows.count == windowCount)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-LinkNavigation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
