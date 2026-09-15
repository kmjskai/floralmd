import AppKit
import Foundation
import Testing
import WebKit

@testable import FloralMD

@Suite(.serialized)
struct MarkdownImageViewerTests {
    @Test func openRequestAcceptsOnlyTypedRelativeDestinations() throws {
        let request = try MarkdownImageOpenRequest(payload: [
            "destination": "../images/%E4%B8%AD%E6%96%87%20image.svg",
            "sourceFrom": 12,
            "sourceTo": 48,
            "activation": "commandClick",
        ])
        #expect(request.destination == "../images/%E4%B8%AD%E6%96%87%20image.svg")
        #expect(request.sourceRange == 12..<48)
        #expect(request.activation == .commandClick)

        for destination in [
            "/tmp/image.png",
            "file:///tmp/image.png",
            "https://example.com/image.png",
            "floralmd-resource://known/image.png",
        ] {
            #expect(throws: MarkdownImageOpenRequest.Error.invalidPayload) {
                try MarkdownImageOpenRequest(payload: [
                    "destination": destination,
                    "sourceFrom": 0,
                    "sourceTo": 10,
                    "activation": "doubleClick",
                ])
            }
        }
        #expect(throws: MarkdownImageOpenRequest.Error.invalidPayload) {
            try MarkdownImageOpenRequest(payload: [
                "destination": "image.png",
                "sourceFrom": 10,
                "sourceTo": 2,
                "activation": "singleClick",
            ])
        }
    }

    @Test func destinationResolutionReusesWorkspaceImageValidation() throws {
        try withFixture { fixture in
            let documentURL = try fixture.write(Data(), to: "notes/子目录/note.md")
            let imageURL = try fixture.write(Self.svgData, to: "notes/图片 空格.svg")
            let session = WorkspaceSession(
                rootURL: fixture.root,
                kind: .draft,
                activeResource: ActiveResource(url: documentURL)
            )
            let context = try #require(
                MarkdownLocalResourceContext(session: session, documentURL: documentURL)
            )
            let handler = MarkdownLocalResourceSchemeHandler()
            let baseURL = try #require(handler.register(context))
            let resource = try handler.resolvedResource(
                destination: "../%E5%9B%BE%E7%89%87%20%E7%A9%BA%E6%A0%BC.svg",
                relativeTo: baseURL
            )
            #expect(resource.fileURL == imageURL.standardizedFileURL)
            #expect(resource.mimeType == "image/svg+xml")

            _ = try fixture.write(Data("not an image".utf8), to: "notes/fake.png")
            #expect(throws: MarkdownLocalResourceError.invalidImageData) {
                try handler.resolvedResource(destination: "../fake.png", relativeTo: baseURL)
            }
            #expect(throws: MarkdownLocalResourceError.unavailable) {
                try handler.resolvedResource(
                    destination: "../../../outside.svg",
                    relativeTo: baseURL
                )
            }

            let outside = fixture.root.deletingLastPathComponent()
                .appendingPathComponent("outside-\(UUID().uuidString).svg")
            try Self.svgData.write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let symlink = fixture.root.appendingPathComponent("notes/link.svg")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            #expect(throws: MarkdownLocalResourceError.symbolicLinkUnsupported) {
                try handler.resolvedResource(destination: "../link.svg", relativeTo: baseURL)
            }
        }
    }

    @Test func initialWindowLayoutUsesIntrinsicSizeAndStaysInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_500, height: 1_000)
        let decoration = NSSize(width: 0, height: 28)

        let small = MarkdownImageViewerInitialLayout.frame(
            imageSize: NSSize(width: 160, height: 100),
            visibleFrame: visibleFrame,
            decorationSize: decoration
        )
        #expect(small.size == MarkdownImageViewerInitialLayout.minimumFrameSize)
        #expect(small.midX == visibleFrame.midX)
        #expect(small.midY == visibleFrame.midY)

        let medium = MarkdownImageViewerInitialLayout.frame(
            imageSize: NSSize(width: 1_000, height: 600),
            visibleFrame: visibleFrame,
            decorationSize: decoration
        )
        #expect(medium.width == 1_064)
        #expect(medium.height == 740)

        let large = MarkdownImageViewerInitialLayout.frame(
            imageSize: NSSize(width: 8_000, height: 6_000),
            visibleFrame: visibleFrame,
            decorationSize: decoration
        )
        #expect(large.width == visibleFrame.width * 0.84)
        #expect(large.height == visibleFrame.height * 0.84)
        #expect(visibleFrame.contains(large))

        let compactScreen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let compact = MarkdownImageViewerInitialLayout.frame(
            imageSize: nil,
            visibleFrame: compactScreen,
            decorationSize: decoration
        )
        #expect(compact.width == compactScreen.width * 0.84)
        #expect(compact.height == compactScreen.height * 0.84)
        #expect(compactScreen.contains(compact))
    }

    @Test @MainActor func realWebViewRoutesSingleDoubleCommandFailureAndLinks() async throws {
        try await withFixture { fixture in
            let imageURL = try fixture.write(Self.svgData, to: "notes/assets/中文 image.svg")
            let documentURL = try fixture.write(Data(), to: "notes/note.md")
            let markdown = """
            [ordinary](target.md)
            ![Loaded](assets/%E4%B8%AD%E6%96%87%20image.svg)
            [![Wrapped](assets/%E4%B8%AD%E6%96%87%20image.svg)](target.md)
            ![Missing](assets/missing.png)
            """
            let session = WorkspaceSession(
                rootURL: fixture.root,
                kind: .draft,
                activeResource: ActiveResource(url: documentURL)
            )
            let context = try #require(
                MarkdownLocalResourceContext(session: session, documentURL: documentURL)
            )
            let controller = CodeMirrorEditorViewController()
            var opened: [(MarkdownImageOpenRequest, URL)] = []
            var links: [String] = []
            controller.imageOpenRequested = { opened.append(($0, $1)) }
            controller.linkNavigationRequested = {
                links.append($0)
                return true
            }
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            controller.documentURL = documentURL
            controller.setResourceContext(context)
            controller.load(markdown: markdown)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 760, height: 620))
            window.layoutIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            try await waitForEditorImages(controller, loaded: 2, failed: 1)
            let webView = try #require(controller.view as? WKWebView)
            window.makeFirstResponder(webView)
            try await settle()

            try await sendMouseGesture(
                .singleClick,
                selector: ".cm-md-image-preview img",
                index: 0,
                modifiers: [],
                controller: controller,
                webView: webView,
                window: window
            )
            #expect(opened.isEmpty)
            let selectionAfterSingleClick = try await selectionStart(in: controller)
            let loadedImageOffset = markdown.firstRangeOffset(of: "![Loaded]")
            #expect(
                selectionAfterSingleClick == loadedImageOffset,
                "single click selected offset \(selectionAfterSingleClick), expected \(loadedImageOffset)"
            )

            let selectionBeforeCommand = markdown.firstRangeOffset(of: "ordinary")
            try await select(selectionBeforeCommand, in: controller)
            try await sendMouseGesture(
                .singleClick,
                selector: ".cm-md-image-preview img",
                index: 0,
                modifiers: .command,
                controller: controller,
                webView: webView,
                window: window
            )
            try await settle()
            try await waitUntil { opened.count >= 1 }
            try #require(opened.count == 1)
            #expect(opened[0].0.activation == .commandClick)
            #expect(opened[0].1 == imageURL.standardizedFileURL)
            #expect(try await selectionStart(in: controller) == selectionBeforeCommand)

            try await sendMouseGesture(
                .doubleClick,
                selector: ".cm-md-image-preview img",
                index: 0,
                modifiers: [],
                controller: controller,
                webView: webView,
                window: window
            )
            try await settle()
            try await waitUntil { opened.count >= 2 }
            try #require(opened.count == 2)
            #expect(opened[1].0.activation == .doubleClick)

            try await sendMouseGesture(
                .singleClick,
                selector: ".cm-md-image-preview img",
                index: 1,
                modifiers: .command,
                controller: controller,
                webView: webView,
                window: window
            )
            try await settle()
            try await waitUntil { opened.count >= 3 }
            try #require(opened.count == 3)
            #expect(opened[2].0.destination.contains("%E4%B8%AD%E6%96%87%20image.svg"))
            #expect(links.isEmpty)

            try await sendMouseGesture(
                .doubleClick,
                selector: ".cm-md-image-preview.is-error",
                index: 0,
                modifiers: [],
                controller: controller,
                webView: webView,
                window: window
            )
            try await settle()
            #expect(opened.count == 3)
            #expect(try await selectionStart(in: controller) == markdown.firstRangeOffset(of: "![Missing]"))

            try await sendMouseGesture(
                .singleClick,
                selector: ".cm-md-link[data-md-href]",
                index: 0,
                modifiers: .command,
                controller: controller,
                webView: webView,
                window: window
            )
            try await settle()
            try await waitUntil { links.count >= 1 }
            #expect(links == ["target.md"])
            #expect(opened.count == 3)
        }
    }

    @Test @MainActor func viewerDeduplicatesTitlesRevealsAndReleasesOnCommandW() async throws {
        try await withFixture { fixture in
            let firstURL = try fixture.write(Self.svgData, to: "first.svg")
            let secondURL = try fixture.write(Self.svgData, to: "second.svg")
            var revealed: [URL] = []
            var began: [URL] = []
            var ended: [URL] = []
            let accessManager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    began.append($0)
                    return true
                },
                endAccess: { ended.append($0) }
            )
            let coordinator = FloralMDImageViewerCoordinator(
                revealFile: { revealed.append($0) },
                securityScopeAccessManager: accessManager,
                imageSize: { url in
                    url == firstURL ? NSSize(width: 1_000, height: 600) : NSSize(width: 8_000, height: 6_000)
                },
                visibleFrame: { NSRect(x: 100, y: 50, width: 1_500, height: 1_000) }
            )

            let first = coordinator.openImage(at: firstURL, authorizedBy: fixture.root)
            #expect(first.window?.frame.width == 1_064)
            #expect((740...750).contains(first.window?.frame.height ?? 0))
            #expect(first.pinningMode == .currentSpace)
            #expect(first.window?.level == .floating)
            first.window?.setFrame(
                NSRect(x: 180, y: 140, width: 880, height: 640),
                display: false
            )
            first.togglePinning()
            #expect(first.pinningMode == .none)
            #expect(first.window?.level == .normal)
            let adjustedFrame = first.window?.frame
            let duplicate = coordinator.openImage(at: firstURL, authorizedBy: fixture.root)
            let second = coordinator.openImage(at: secondURL, authorizedBy: fixture.root)
            #expect(first === duplicate)
            #expect(duplicate.window?.frame == adjustedFrame)
            #expect(duplicate.pinningMode == .none)
            #expect(coordinator.openWindowCount == 2)
            #expect(began == [fixture.root.standardizedFileURL])
            #expect(first.window?.title == "first.svg")
            #expect(first.window?.representedURL == firstURL.standardizedFileURL)
            #expect(first.window?.styleMask.contains(.closable) == true)
            #expect(second.pinningMode == .currentSpace)
            #expect(second.window?.level == .floating)
            #expect((second.window?.frame.width ?? .infinity) <= 1_500 * 0.84)
            #expect((second.window?.frame.height ?? .infinity) <= 1_000 * 0.84)

            first.revealInFinder()
            #expect(revealed == [firstURL.standardizedFileURL])

            try await settle()
            #expect(first.previewController.isWebViewAttached)
            let closeEvent = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: first.window?.windowNumber ?? 0,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            ))
            #expect(first.window?.performKeyEquivalent(with: closeEvent) == true)
            try await settle()
            #expect(coordinator.openWindowCount == 1)
            #expect(first.didReleaseResources)
            #expect(!first.previewController.isWebViewAttached)
            #expect(ended.isEmpty)

            second.window?.performClose(nil)
            try await settle()
            #expect(coordinator.openWindowCount == 0)
            #expect(ended == [fixture.root.standardizedFileURL])
        }
    }

    @Test func sharedRootScopeStopsOnlyAfterTheLastOwnerReleases() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Shared-Scope-\(UUID().uuidString)", isDirectory: true)
        var beginCount = 0
        var stopCount = 0
        let begin: (URL) -> Bool = { _ in
            beginCount += 1
            return true
        }
        let end: (URL) -> Void = { _ in stopCount += 1 }

        let manager = SecurityScopedResourceAccessManager(beginAccess: begin, endAccess: end)
        let workspaceLease = manager.acquire(root)
        let imageWindowLease = manager.acquire(root.standardizedFileURL)

        #expect(beginCount == 1)
        #expect(manager.ownerCount(for: root) == 2)
        imageWindowLease.invalidate()
        imageWindowLease.invalidate()
        #expect(stopCount == 0)
        #expect(manager.ownerCount(for: root) == 1)
        workspaceLease.invalidate()
        #expect(stopCount == 1)
        #expect(manager.ownerCount(for: root) == 0)
        #expect(manager.activeRootCount == 0)
    }

    @Test @MainActor func closingImageWindowKeepsWorkspaceAndSchemeReadsAuthorized() async throws {
        try await withFixture { fixture in
            let firstNote = try fixture.write(Data("first".utf8), to: "First.md")
            let secondNote = try fixture.write(Data("second".utf8), to: "Second.md")
            let imageURL = try fixture.write(Self.svgData, to: "diagram.svg")
            var began: [URL] = []
            var ended: [URL] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    began.append($0)
                    return true
                },
                endAccess: { ended.append($0) }
            )
            var workspace: WorkspaceController? = try WorkspaceController(
                targetURL: firstNote,
                draftRootProvider: { fixture.root },
                securityScopeAccessManager: manager
            )
            let coordinator = FloralMDImageViewerCoordinator(
                revealFile: { _ in },
                securityScopeAccessManager: manager,
                imageSize: { _ in NSSize(width: 160, height: 100) }
            )

            let imageWindow = coordinator.openImage(
                at: imageURL,
                authorizedBy: fixture.root
            )
            #expect(began == [fixture.root.standardizedFileURL])
            #expect(manager.ownerCount(for: fixture.root) == 2)

            var ownerCountDuringRead = 0
            let handler = WorkspaceImageResourceSchemeHandler(dataReader: { fileURL in
                ownerCountDuringRead = manager.ownerCount(for: fixture.root)
                return try Data(contentsOf: fileURL)
            })
            let requestURL = handler.register(imageURL)
            let payload = try handler.loadResource(for: requestURL).get()
            #expect(payload.data == Self.svgData)
            #expect(ownerCountDuringRead == 2)

            imageWindow.window?.performClose(nil)
            try await settle()
            #expect(manager.ownerCount(for: fixture.root) == 1)
            #expect(ended.isEmpty)

            try workspace?.selectResource(at: secondNote)
            #expect(workspace?.markdownText == "second")
            workspace = nil
            #expect(manager.ownerCount(for: fixture.root) == 0)
            #expect(ended == [fixture.root.standardizedFileURL])
        }
    }
}

private extension MarkdownImageViewerTests {
    enum MouseGesture { case singleClick, doubleClick }

    static let svgData = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="160" height="100">
      <rect width="160" height="100" fill="#4f8cff"/>
    </svg>
    """.utf8)

    @MainActor
    func waitForEditorImages(
        _ controller: CodeMirrorEditorViewController,
        loaded: Int,
        failed: Int
    ) async throws {
        for _ in 0..<120 {
            let state = try await evaluateDictionary(controller, script: """
            (() => ({
              ready: !!window.__mdEditor,
              loaded: document.querySelectorAll('.cm-md-image-preview.is-loaded').length,
              failed: document.querySelectorAll('.cm-md-image-preview.is-error').length
            }))()
            """)
            if state["ready"] as? Bool == true,
               state["loaded"] as? Int == loaded,
               state["failed"] as? Int == failed {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Image widgets did not reach the expected states")
    }

    @MainActor
    func sendMouseGesture(
        _ gesture: MouseGesture,
        selector: String,
        index: Int,
        modifiers: NSEvent.ModifierFlags,
        controller: CodeMirrorEditorViewController,
        webView: WKWebView,
        window: NSWindow
    ) async throws {
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const element = document.querySelectorAll(\(jsString(selector)))[\(index)];
          element?.scrollIntoView({ block: 'center' });
        })()
        """)
        var rect: [String: Any] = [:]
        for _ in 0..<20 {
            try await settle()
            rect = try await evaluateDictionary(controller, script: """
            (() => {
              const element = document.querySelectorAll(\(jsString(selector)))[\(index)];
              if (!element) return {};
              const rect = element.getBoundingClientRect();
              return { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2,
                       width: rect.width, height: rect.height,
                       target: document.elementFromPoint(
                         (rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2
                       )?.tagName || '' };
            })()
            """)
            if (rect["width"] as? Double ?? 0) > 0,
               (rect["height"] as? Double ?? 0) > 0 {
                break
            }
        }
        let x = try #require(rect["x"] as? Double)
        let y = try #require(rect["y"] as? Double)
        #expect((rect["width"] as? Double ?? 0) > 0)
        #expect((rect["height"] as? Double ?? 0) > 0)
        let location = webView.convert(NSPoint(x: x, y: y), to: nil)
        let clickCounts = gesture == .doubleClick ? [1, 2] : [1]
        for clickCount in clickCounts {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickCount,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
                if type == .leftMouseDown {
                    webView.mouseDown(with: event)
                } else {
                    webView.mouseUp(with: event)
                }
            }
        }
        try await settle()
    }

    @MainActor
    func select(_ position: Int, in controller: CodeMirrorEditorViewController) async throws {
        _ = try await evaluate(controller, script: "window.__mdEditor.select(\(position))")
        try await settle()
    }

    /// WebKit synthesizes `click` from the posted mouse events asynchronously
    /// (and more slowly when suites run in parallel), so poll the side-effect
    /// counters instead of asserting right after a fixed sleep.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 4,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition not reached within \(timeout)s")
    }

    @MainActor
    func selectionStart(in controller: CodeMirrorEditorViewController) async throws -> Int {
        let state = try await evaluateDictionary(
            controller,
            script: "window.__mdEditor._selectionForTesting()"
        )
        return try #require(state["from"] as? Int)
    }

    @MainActor
    func evaluateDictionary(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> [String: Any] {
        try #require(try await evaluate(controller, script: script) as? [String: Any])
    }

    @MainActor
    func evaluate(_ controller: CodeMirrorEditorViewController, script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    @MainActor
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FloralMD-Image-Viewer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ data: Data, to relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url.standardizedFileURL
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func withFixture<T>(_ operation: (Fixture) throws -> T) throws -> T {
        let fixture = try Fixture()
        defer { fixture.remove() }
        return try operation(fixture)
    }

    func withFixture<T>(_ operation: (Fixture) async throws -> T) async throws -> T {
        let fixture = try Fixture()
        defer { fixture.remove() }
        return try await operation(fixture)
    }

    func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

private extension String {
    func firstRangeOffset(of needle: String) -> Int {
        guard let range = range(of: needle) else { return -1 }
        return utf16.distance(from: startIndex, to: range.lowerBound)
    }
}
