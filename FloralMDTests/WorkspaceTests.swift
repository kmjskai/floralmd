import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FloralMD

struct WorkspaceTests {
    @Test func workspaceExternalNoticesSeparateTransientAndPersistentStates() {
        let before = URL(fileURLWithPath: "/tmp/Before.md")
        let after = URL(fileURLWithPath: "/tmp/After.md")

        #expect(WorkspaceContentView.NoticePolicy.toastDuration == 2.5)
        #expect(WorkspaceContentView.NoticePolicy.persistentNotice(
            pathState: .movedExternally(from: before, to: after),
            externalState: .updatedFromDisk(after)
        ) == nil)
        #expect(WorkspaceContentView.NoticePolicy.persistentNotice(
            pathState: .available,
            externalState: .conflict(after)
        ) == .conflict(after))
        #expect(WorkspaceContentView.NoticePolicy.persistentNotice(
            pathState: .available,
            externalState: .divergent(after)
        ) == .divergent(after))
        #expect(WorkspaceContentView.NoticePolicy.persistentNotice(
            pathState: .missingExternally(after),
            externalState: .conflict(after)
        ) == .missing(after))
    }

    @Test func workspaceCatalogIncludesEverySupportedResourceRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in [
            "Note.md", "Board.excalidraw", "Photo.png", "Animation.gif", "Photo.webp",
            "Diagram.svg", "archive.zip", "ignored.txt"
        ] {
            try Data().write(to: nested.appendingPathComponent(name))
        }

        let entries = try WorkspaceFileCatalog().entries(in: root)
        let nestedEntry = try #require(entries.first)

        #expect(nestedEntry.kind == .directory)
        #expect(nestedEntry.children?.map(\.name) == [
            "Animation.gif", "archive.zip", "Board.excalidraw", "Diagram.svg", "ignored.txt",
            "Note.md", "Photo.png", "Photo.webp"
        ])
        #expect(nestedEntry.children?.first(where: { $0.name == "ignored.txt" })?.kind == .file)
    }

    @Test @MainActor func appCreatesReloadTheVisibleWorkspaceCatalogAfterConsecutiveNotifications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-SidebarCreate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var latestEntries: [WorkspaceFileEntry] = []
        var expandedDirectories: Set<WorkspaceFileIdentity> = []
        var selectedEntryURL: URL?
        let host = NSHostingView(rootView: WorkspaceSidebarView(
            rootURL: root,
            selectedURL: nil,
            select: { _ in },
            createMarkdown: {},
            createDrawing: {},
            didReload: { latestEntries = $0 },
            performOperation: { _ in },
            performInlineRename: { _ in .none },
            expandedDirectories: .init(get: { expandedDirectories }, set: { expandedDirectories = $0 }),
            selectedEntryURL: .init(get: { selectedEntryURL }, set: { selectedEntryURL = $0 })
        ))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        host.layoutSubtreeIfNeeded()
        try await waitUntil(timeout: .seconds(2)) { !latestEntries.isEmpty }

        let service = WorkspaceFileOperationService()
        let requests: [WorkspaceFileOperationRequest] = [
            .createMarkdown(parentURL: root, name: "Root.md"),
            .createMarkdown(parentURL: parent, name: "Child.md"),
            .createDirectory(parentURL: root, name: "Root Folder"),
            .createDirectory(parentURL: parent, name: "Child Folder")
        ]
        for request in requests {
            let result = try service.perform(request, workspaceRootURL: root)
            NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: result)
        }

        let expectedPaths: Set<String> = [
            "Parent",
            "Parent/Child.md",
            "Parent/Child Folder",
            "Root.md",
            "Root Folder"
        ]
        try await waitUntil(timeout: .seconds(2)) {
            Set(WorkspaceFileTree.flattened(latestEntries).map {
                $0.url.path.replacingOccurrences(of: root.path + "/", with: "")
            }).isSuperset(of: expectedPaths)
        }
    }

    @Test func visibleWorkspaceRowsFollowExpandedDirectoriesAndDepth() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let folder = WorkspaceFileEntry(
            url: root.appendingPathComponent("notes", isDirectory: true),
            kind: .directory,
            children: [
                WorkspaceFileEntry(
                    url: root.appendingPathComponent("notes/Note.md"),
                    kind: .resource(.markdown),
                    children: nil
                )
            ]
        )

        let collapsed = WorkspaceFileTree.visibleEntries(
            in: [folder],
            expandedDirectories: []
        )
        let expanded = WorkspaceFileTree.visibleEntries(
            in: [folder],
            expandedDirectories: [folder.identity]
        )

        #expect(collapsed.map(\.entry.name) == ["notes"])
        #expect(expanded.map(\.entry.name) == ["notes", "Note.md"])
        #expect(expanded.map(\.depth) == [0, 1])
    }

    @Test func newlyCreatedNestedItemIsRevealedWithoutDiscardingExistingExpansion() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let parentIdentity = WorkspaceFileIdentity(rawValue: "resource:parent")
        let otherIdentity = WorkspaceFileIdentity(rawValue: "resource:other")
        let child = WorkspaceFileEntry(
            url: root.appendingPathComponent("Parent/Child.md"),
            kind: .resource(.markdown),
            children: nil
        )
        let entries = [
            WorkspaceFileEntry(
                url: root.appendingPathComponent("Parent", isDirectory: true),
                kind: .directory,
                children: [child],
                identity: parentIdentity
            ),
            WorkspaceFileEntry(
                url: root.appendingPathComponent("Other", isDirectory: true),
                kind: .directory,
                children: [],
                identity: otherIdentity
            )
        ]

        let expandedDirectories = WorkspaceFileTree.expandedDirectories(
            revealing: child.url,
            in: entries,
            preserving: [otherIdentity]
        )
        let visibleNames = WorkspaceFileTree.visibleEntries(
            in: entries,
            expandedDirectories: expandedDirectories
        ).map(\.entry.name)

        #expect(expandedDirectories == [parentIdentity, otherIdentity])
        #expect(visibleNames == ["Parent", "Child.md", "Other"])
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func inlineRenameSelectsTheStemBeforeOnlyTheFinalExtension() {
        func selectedText(_ name: String, isDirectory: Bool = false) -> String {
            let range = WorkspaceInlineRenameSelection.range(
                for: name,
                isDirectory: isDirectory
            )
            return (name as NSString).substring(with: range)
        }

        #expect(selectedText("meeting.notes.md") == "meeting.notes")
        #expect(selectedText("图纸.v1.excalidraw") == "图纸.v1")
        #expect(selectedText(".meeting.notes.md") == ".meeting.notes")
        #expect(selectedText(".gitignore") == ".gitignore")
        #expect(selectedText(".md") == ".md")
        #expect(selectedText("README") == "README")
        #expect(selectedText("trailing.") == "trailing.")
        #expect(selectedText("meeting.notes.md", isDirectory: true) == "meeting.notes.md")
    }

    @Test func inlineRenameStateKeepsIdentityDraftSelectionAndInlineFailure() throws {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let entry = WorkspaceFileEntry(
            url: root.appendingPathComponent("meeting.notes.md"),
            kind: .resource(.markdown),
            children: nil,
            identity: WorkspaceFileIdentity(rawValue: "resource:test")
        )
        var model = WorkspaceInlineRenameModel()

        #expect(model.acceptsCatalogReload)
        model.begin(entry)
        #expect(model.isEditing)
        #expect(!model.acceptsCatalogReload)
        #expect(model.session?.sourceURL == entry.url.standardizedFileURL)
        #expect(model.session?.draft == "meeting.notes.md")
        #expect(model.session?.selection == NSRange(location: 0, length: 13))

        let movedCaret = NSRange(location: 4, length: 0)
        model.updateDraft("计划.notes.md", selection: movedCaret, identity: entry.identity)
        #expect(model.session?.draft == "计划.notes.md")
        #expect(model.session?.selection == movedCaret)

        model.fail("名称冲突", identity: entry.identity)
        #expect(model.session?.errorMessage == "名称冲突")
        #expect(model.session?.focusRequest == 1)

        let laterSelection = NSRange(location: 2, length: 3)
        model.updateSelection(laterSelection, identity: entry.identity)
        #expect(model.session?.selection == laterSelection)
        model.updateDraft("最终.md", selection: laterSelection, identity: entry.identity)
        #expect(model.session?.errorMessage == nil)

        model.finish(identity: WorkspaceFileIdentity(rawValue: "resource:other"))
        #expect(model.isEditing)
        model.finish(identity: entry.identity)
        #expect(!model.isEditing)
        #expect(model.acceptsCatalogReload)
    }

    @Test @MainActor func inlineRenameFieldRoutesReturnEscapeAndFocusLossSeparately() {
        var commitReasons: [WorkspaceInlineRenameCommitReason] = []
        var cancelCount = 0
        let field = WorkspaceInlineRenameField(
            text: "Note.md",
            selection: NSRange(location: 0, length: 4),
            focusRequest: 0,
            accessibilityLabel: "重命名 Note.md",
            onChange: { _, _ in },
            onSelectionChange: { _ in },
            onSubmit: { commitReasons.append($0) },
            onCancel: { cancelCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let textField = NSTextField()
        let editor = NSTextView()

        #expect(coordinator.control(
            textField,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(coordinator.control(
            textField,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: textField)
        )

        #expect(commitReasons == [.returnKey, .focusLoss])
        #expect(cancelCount == 1)
    }

    @Test func workspaceSidebarWidthClampsAndRecoversFromInvalidStorage() {
        #expect(WorkspaceSidebarLayout.clampedWidth(120) == 180)
        #expect(WorkspaceSidebarLayout.clampedWidth(300) == 300)
        #expect(WorkspaceSidebarLayout.clampedWidth(800) == 420)
        #expect(WorkspaceSidebarLayout.clampedWidth(.nan) == 250)
        #expect(WorkspaceSidebarLayout.resizeHandleLineWidth == 1)
        #expect(WorkspaceSidebarLayout.resizeHandleHitWidth == 14)
        #expect(WorkspaceSidebarLayout.resizeHandleOffset(sidebarWidth: 250) == 243)
    }

    @Test func workspaceSidebarResizeFeedbackStrengthensDuringInteraction() {
        #expect(WorkspaceSidebarResizePhase.idle.lineWidth == 1)
        #expect(WorkspaceSidebarResizePhase.idle.accentOpacity == nil)
        #expect(WorkspaceSidebarResizePhase.hovering.lineWidth == 1.5)
        #expect(WorkspaceSidebarResizePhase.hovering.accentOpacity == 0.55)
        #expect(WorkspaceSidebarResizePhase.dragging.lineWidth == 2)
        #expect(WorkspaceSidebarResizePhase.dragging.accentOpacity == 0.85)
    }

    @Test @MainActor func workspaceSidebarHandleOwnsTheHostedHitRegionAndCursorRect() throws {
        func handleView() -> AnyView {
            AnyView(WorkspaceSidebarResizeHandle(
                drag: { _ in },
                endDrag: {},
                reset: {}
            ).frame(
                width: WorkspaceSidebarLayout.resizeHandleHitWidth,
                height: 200
            ))
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 14, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: handleView())
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let handle = try #require(host.firstDescendant(of: WorkspaceSidebarResizeHandleView.self))
        let cursorBeforeRegistration = NSCursor.current

        #expect(handle.window === window)
        #expect(abs(handle.bounds.width - WorkspaceSidebarLayout.resizeHandleHitWidth) < 0.01)
        let midpoint = handle.convert(
            NSPoint(x: handle.bounds.midX, y: handle.bounds.midY),
            to: host
        )
        #expect(host.hitTest(midpoint) === handle)

        handle.resetCursorRects()
        #expect(handle.registeredCursorRect == handle.bounds)
        #expect(handle.registeredCursor === NSCursor.resizeLeftRight)
        #expect(NSCursor.current === cursorBeforeRegistration)

        let invalidationsBeforeFocusCycle = handle.cursorRectInvalidationCount
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(handle.cursorRectInvalidationCount >= invalidationsBeforeFocusCycle + 2)

        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        #expect(handle.window == nil)

        host.rootView = handleView()
        host.layoutSubtreeIfNeeded()
        let restoredHandle = try #require(
            host.firstDescendant(of: WorkspaceSidebarResizeHandleView.self)
        )
        #expect(restoredHandle.window === window)

        host.rootView = AnyView(WorkspaceSidebarResizeHandle(
            drag: { _ in },
            endDrag: {},
            reset: {}
        ).frame(width: WorkspaceSidebarLayout.resizeHandleHitWidth, height: 320))
        host.layoutSubtreeIfNeeded()
        let resizedHandle = try #require(
            host.firstDescendant(of: WorkspaceSidebarResizeHandleView.self)
        )
        resizedHandle.resetCursorRects()

        #expect(abs(resizedHandle.bounds.height - 320) < 0.01)
        #expect(resizedHandle.registeredCursorRect == resizedHandle.bounds)
        let resizedMidpoint = resizedHandle.convert(
            NSPoint(x: resizedHandle.bounds.midX, y: resizedHandle.bounds.midY),
            to: host
        )
        #expect(host.hitTest(resizedMidpoint) === resizedHandle)
    }

    @Test func imagePreviewZoomClampsAndReportsActualScale() {
        #expect(WorkspaceImageZoom.clampedScale(0.01) == 0.05)
        #expect(WorkspaceImageZoom.clampedScale(2) == 2)
        #expect(WorkspaceImageZoom.clampedScale(100) == 32)
        #expect(WorkspaceImageZoom.percentage(scale: 0.5) == 50)
        #expect(WorkspaceImageZoom.percentage(scale: 2) == 200)
        #expect(WorkspaceImageZoom.panDistance(delta: 3, hasPreciseDeltas: true) == 3)
        #expect(WorkspaceImageZoom.panDistance(delta: 3, hasPreciseDeltas: false) == 48)
        #expect(WorkspaceImageZoom.commandWheelFactor(deltaY: 10, hasPreciseDeltas: true) > 1)
        #expect(WorkspaceImageZoom.commandWheelFactor(deltaY: -10, hasPreciseDeltas: true) < 1)
        #expect(
            WorkspaceVectorRedrawBudget.current.memoryBudgetBytes
                >= WorkspaceVectorRedrawBudget.minimumMemoryBudgetBytes
        )
        #expect(
            WorkspaceVectorRedrawBudget.current.memoryBudgetBytes
                <= WorkspaceVectorRedrawBudget.maximumMemoryBudgetBytes
        )
    }

    @Test func imagePreviewHTMLTreatsTheResourceAsAnImage() {
        let resourceURL = URL(string: "floralmd-image://resource/test")!
        let html = WorkspaceImagePreviewHTML.make(
            resourceURL: resourceURL,
            displayName: "Diagram & Notes.svg"
        )

        #expect(html.contains("<img id=\"preview\""))
        #expect(html.contains("src=\"floralmd-image://resource/test\""))
        #expect(html.contains("alt=\"Diagram &amp; Notes.svg\""))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("workspaceImagePreview"))
        #expect(html.contains("panBy(deltaX, deltaY)"))
        #expect(html.contains("getSelection()?.removeAllRanges()"))
        #expect(html.contains("addEventListener('pointermove'"))
    }

    @Test @MainActor func imagePreviewSchemeResolvesOnlyRegisteredResources() throws {
        let handler = WorkspaceImageResourceSchemeHandler()
        let fileURL = URL(fileURLWithPath: "/tmp/Preview.svg")
        let resourceURL = handler.register(fileURL)

        #expect(resourceURL.scheme == WorkspaceImageResourceSchemeHandler.scheme)
        #expect(handler.resolvedFileURL(for: resourceURL) == fileURL.standardizedFileURL)
        #expect(handler.resolvedFileURL(for: URL(string: "https://example.com/image.svg")!) == nil)
        #expect(WorkspaceImageResourceSchemeHandler.mimeType(for: "PNG") == "image/png")
        #expect(WorkspaceImageResourceSchemeHandler.mimeType(for: "jpeg") == "image/jpeg")
        #expect(WorkspaceImageResourceSchemeHandler.mimeType(for: "gif") == "image/gif")
        #expect(WorkspaceImageResourceSchemeHandler.mimeType(for: "webp") == "image/webp")
        #expect(WorkspaceImageResourceSchemeHandler.mimeType(for: "svg") == "image/svg+xml")
    }

    @Test func imagePreviewSchemeLoadsRealPNGAndSVGAndReportsPermissionErrors() throws {
        try withTemporaryDirectory { root in
            let pngData = try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nZ8AAAAASUVORK5CYII="
            ))
            let svgData = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="2" height="2">
              <rect width="2" height="2" fill="#4f8cff"/>
            </svg>
            """.utf8)
            let pngURL = root.appendingPathComponent("sample.png")
            let svgURL = root.appendingPathComponent("sample.svg")
            try pngData.write(to: pngURL)
            try svgData.write(to: svgURL)

            let handler = WorkspaceImageResourceSchemeHandler()
            for (fileURL, expectedData, expectedMIME, expectedEncoding) in [
                (pngURL, pngData, "image/png", nil),
                (svgURL, svgData, "image/svg+xml", "utf-8"),
            ] {
                let requestURL = handler.register(fileURL)
                let payload = try handler.loadResource(for: requestURL).get()
                #expect(payload.requestURL == requestURL)
                #expect(payload.fileURL == fileURL.standardizedFileURL)
                #expect(payload.data == expectedData)
                #expect(payload.mimeType == expectedMIME)
                #expect(payload.textEncodingName == expectedEncoding)
            }

            var failures: [WorkspaceImageResourceLoadFailure] = []
            let deniedHandler = WorkspaceImageResourceSchemeHandler(
                dataReader: { _ in throw CocoaError(.fileReadNoPermission) },
                diagnosticHandler: { failures.append($0) }
            )
            let deniedRequestURL = deniedHandler.register(pngURL)
            let failure: WorkspaceImageResourceLoadFailure
            switch deniedHandler.loadResource(for: deniedRequestURL) {
            case .success:
                Issue.record("Expected permission-denied resource load to fail")
                return
            case .failure(let loadFailure):
                failure = loadFailure
            }
            #expect(failure.stage == .dataRead)
            #expect(failure.requestURL == deniedRequestURL)
            #expect(failure.fileURL == pngURL.standardizedFileURL)
            #expect(failure.errorDomain == NSCocoaErrorDomain)
            #expect(failure.errorCode == CocoaError.Code.fileReadNoPermission.rawValue)
            #expect(failures == [failure])

            let unresolved: WorkspaceImageResourceLoadFailure
            switch deniedHandler.loadResource(
                for: URL(string: "floralmd-image://resource/not-registered")
            ) {
            case .success:
                Issue.record("Expected an unregistered resource load to fail")
                return
            case .failure(let loadFailure):
                unresolved = loadFailure
            }
            #expect(unresolved.stage == .unresolvedResource)
            #expect(unresolved.fileURL == nil)
        }
    }

    @Test func workspaceWidthBudgetPreservesPreferenceAndAdaptsAtNarrowWidths() {
        let wide = WorkspaceWindowLayout.resolve(
            availableWidth: 1200,
            preferredSidebarWidth: 420,
            isFileSidebarVisible: true,
            isOutlineSidebarVisible: false,
            activeKind: .drawing
        )
        let narrow = WorkspaceWindowLayout.resolve(
            availableWidth: WorkspaceWindowLayout.minimumContentWidth,
            preferredSidebarWidth: 420,
            isFileSidebarVisible: true,
            isOutlineSidebarVisible: false,
            activeKind: .drawing
        )
        let restored = WorkspaceWindowLayout.resolve(
            availableWidth: 1200,
            preferredSidebarWidth: 420,
            isFileSidebarVisible: true,
            isOutlineSidebarVisible: false,
            activeKind: .drawing
        )

        #expect(wide.sidebarWidth == 420)
        #expect(narrow.sidebarWidth == 320)
        #expect(narrow.surfaceWidth == WorkspaceWindowLayout.regularMinimumSurfaceWidth)
        #expect(restored.sidebarWidth == 420)
    }

    @Test func workspaceWidthBudgetIncludesTheOutlineAndStoredValueRecovery() {
        let outlined = WorkspaceWindowLayout.resolve(
            availableWidth: WorkspaceWindowLayout.minimumContentWidth,
            preferredSidebarWidth: 400,
            isFileSidebarVisible: true,
            isOutlineSidebarVisible: true,
            activeKind: .markdown
        )
        let invalidStoredWidth = WorkspaceWindowLayout.resolve(
            availableWidth: 1100,
            preferredSidebarWidth: .nan,
            isFileSidebarVisible: true,
            isOutlineSidebarVisible: false,
            activeKind: .image
        )
        let hiddenSidebar = WorkspaceWindowLayout.resolve(
            availableWidth: WorkspaceWindowLayout.minimumContentWidth,
            preferredSidebarWidth: 400,
            isFileSidebarVisible: false,
            isOutlineSidebarVisible: true,
            activeKind: .markdown
        )

        #expect(outlined.sidebarWidth == WorkspaceSidebarLayout.minimumWidth)
        #expect(outlined.outlineWidth == Double(DocumentOutlineLayout.expandedWidth))
        #expect(outlined.surfaceWidth == WorkspaceWindowLayout.outlinedMarkdownMinimumSurfaceWidth)
        #expect(invalidStoredWidth.sidebarWidth == WorkspaceSidebarLayout.defaultWidth)
        #expect(hiddenSidebar.sidebarWidth == 0)
        #expect(hiddenSidebar.surfaceWidth == 510)
    }

    @Test func everyWorkspaceSurfaceFitsTheSupportedMinimumWindow() {
        for kind in [ResourceKind.markdown, .drawing, .image] {
            let layout = WorkspaceWindowLayout.resolve(
                availableWidth: WorkspaceWindowLayout.minimumContentWidth,
                preferredSidebarWidth: WorkspaceSidebarLayout.maximumWidth,
                isFileSidebarVisible: true,
                isOutlineSidebarVisible: false,
                activeKind: kind
            )

            #expect(layout.surfaceWidth >= WorkspaceWindowLayout.regularMinimumSurfaceWidth)
            #expect(layout.sidebarWidth >= WorkspaceSidebarLayout.minimumWidth)
        }

        #expect(WorkspaceWindowLayout.minimumContentWidth == 760)
        #expect(WorkspaceWindowLayout.minimumContentHeight == 540)
        #expect(DrawingWindowLayout.minimumWidth(embedded: true) == 0)
        #expect(DrawingWindowLayout.minimumHeight(embedded: true) == 0)
        #expect(DrawingWindowLayout.minimumWidth(embedded: false) == 980)
        #expect(DrawingWindowLayout.minimumHeight(embedded: false) == 540)
    }

    @Test @MainActor func sidebarScrollPolicyRejectsHorizontalOffsetAndElasticity() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 240))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.contentView.scroll(to: NSPoint(x: 90, y: 42))

        WorkspaceSidebarScrollPolicy.apply(to: scrollView)

        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.horizontalScrollElasticity == .none)
        #expect(scrollView.contentView.bounds.origin.x == 0)
        #expect(scrollView.contentView.bounds.origin.y == 42)
    }

    @Test @MainActor func sidebarPolicyHostDoesNotCreateAPhantomListRow() async throws {
        let legacyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let legacyHost = NSHostingView(rootView: List {
            WorkspaceSidebarScrollPolicyBridge().frame(height: 0)
            Text("Note.md")
            Text("Diagram.svg")
        }.listStyle(.sidebar))
        legacyWindow.contentView = legacyHost
        legacyHost.layoutSubtreeIfNeeded()

        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let visibleEntries = ["Note.md", "Diagram.svg"].map { name in
            WorkspaceVisibleEntry(
                entry: WorkspaceFileEntry(
                    url: root.appendingPathComponent(name),
                    kind: .resource(name.hasSuffix(".md") ? .markdown : .image),
                    children: nil
                ),
                depth: 0,
                isExpanded: false
            )
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: WorkspaceSidebarList(
            visibleEntries: visibleEntries,
            selectedURL: nil,
            rootURL: root,
            activate: { _ in },
            performOperation: { _ in }
        ))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<5 {
            await Task.yield()
            legacyHost.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        let legacyTableView = try #require(
            legacyHost.firstDescendant(of: NSTableView.self)
        )
        let tableView = try #require(host.firstDescendant(of: NSTableView.self))
        let policyHost = try #require(
            host.firstDescendant(of: WorkspaceSidebarScrollPolicyView.self)
        )
        let scrollView = try #require(tableView.enclosingScrollView)

        #expect(legacyTableView.numberOfRows == visibleEntries.count + 1)
        #expect(tableView.numberOfRows == visibleEntries.count)

        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.contentView.scroll(to: NSPoint(x: 36, y: 0))
        policyHost.scheduleConfiguration()
        await Task.yield()

        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.horizontalScrollElasticity == .none)
        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    @Test @MainActor func workspaceSidebarUsesStableSemanticIconRoles() {
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let expectations: [(WorkspaceFileEntry.Kind, WorkspaceSidebarIconRole)] = [
            (.directory, .folder),
            (.resource(.markdown), .markdown),
            (.resource(.drawing), .drawing),
            (.resource(.image), .image),
            (.file, .file)
        ]

        for (kind, role) in expectations {
            let entry = WorkspaceFileEntry(url: root, kind: kind, children: nil)
            #expect(entry.iconRole == role)
        }
    }

    @Test func commandSaveRoutesOnlyWritableWorkspaceResources() {
        #expect(WorkspaceSaveRoute.resolve(activeKind: .markdown) == .markdown)
        #expect(WorkspaceSaveRoute.resolve(activeKind: .drawing) == .drawing)
        #expect(WorkspaceSaveRoute.resolve(activeKind: .image) == .unavailable)
        #expect(WorkspaceSaveRoute.resolve(activeKind: nil) == .unavailable)
    }

    @Test func draftLayoutMatchesTheProductDirectoryContract() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let layout = DraftWorkspaceLayout(root: root)

        #expect(layout.notesDirectory.path == "/tmp/FloralMD Drafts/notes")
        #expect(layout.markdownImagesDirectory.path == "/tmp/FloralMD Drafts/notes/assets/images")
        #expect(layout.drawingsDirectory.path == "/tmp/FloralMD Drafts/drawings")
    }

    @Test func preparingDraftLayoutIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DraftWorkspaceLayout(root: root)

        try layout.prepare()
        try layout.prepare()

        for directory in layout.requiredDirectories {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        #expect(!FileManager.default.fileExists(
            atPath: layout.drawingsDirectory.appendingPathComponent("exports").path
        ))
    }

    @Test func resourceKindsCoverEverySupportedExtensionCaseInsensitively() {
        let expectations: [(String, ResourceKind)] = [
            ("Note.MD", .markdown),
            ("Note.markdown", .markdown),
            ("Note.MDOWN", .markdown),
            ("Board.excalidraw", .drawing),
            ("Photo.PNG", .image),
            ("Photo.jpg", .image),
            ("Photo.JPEG", .image),
            ("Animation.GIF", .image),
            ("Photo.WebP", .image),
            ("Diagram.svg", .image)
        ]

        for (name, expectedKind) in expectations {
            #expect(ActiveResource(url: URL(fileURLWithPath: "/tmp/\(name)"))?.kind == expectedKind)
        }
        #expect(ActiveResource(url: URL(fileURLWithPath: "/tmp/plain.txt")) == nil)
    }

    @Test func untitledFallsBackToDraftWorkspace() throws {
        let draftRoot = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let session = try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: nil)

        #expect(session.rootURL == draftRoot.standardizedFileURL)
        #expect(session.kind == .draft)
        #expect(session.activeResource == nil)
    }

    @Test func anySupportedDraftResourceKeepsTheWholeDraftAsWorkspace() throws {
        let draftRoot = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let targets = [
            "notes/A.md",
            "drawings/Board.excalidraw",
            "notes/assets/images/photo.png",
            "drawings/exports/Board.svg"
        ]

        for relativePath in targets {
            let target = draftRoot.appendingPathComponent(relativePath)
            let session = try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: target)
            #expect(session.kind == .draft)
            #expect(session.rootURL == draftRoot.standardizedFileURL)
            #expect(session.activeResource?.url == target.standardizedFileURL)
        }
    }

    @Test func externalResourceUsesOnlyItsContainingFolder() throws {
        let draftRoot = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/External/Note.md")
        let session = try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: target)

        #expect(session.kind == .externalFolder)
        #expect(session.rootURL.path == "/tmp/External")
        #expect(session.activeResource?.url == target.standardizedFileURL)
    }

    @Test func explicitlySelectedFolderRemainsTheWholeWorkspaceWithoutAnActiveResource() {
        let root = URL(fileURLWithPath: "/tmp/Chosen Workspace", isDirectory: true)
        let session = WorkspaceResolver.explicitWorkspace(rootURL: root)

        #expect(session.kind == .explicitFolder)
        #expect(session.rootURL == root.standardizedFileURL)
        #expect(session.activeResource == nil)
    }

    @Test func explicitWorkspaceWindowStateRoundTripsItsStandardizedPath() throws {
        let root = URL(fileURLWithPath: "/tmp/Chosen/../Chosen Workspace", isDirectory: true)
        let state = WorkspaceWindowState(explicitWorkspaceURL: root)
        let restored = try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: JSONEncoder().encode(state)
        )

        #expect(restored == state)
        #expect(restored.explicitWorkspaceURL == root.standardizedFileURL)
    }

    @Test func readableDirectoryValidationRejectsMissingPathsAndFiles() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("file.md")
            try Data().write(to: file)
            let unreadable = root.appendingPathComponent("Unreadable", isDirectory: true)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)

            #expect(FolderAccessService.isReadableDirectory(root))
            #expect(!FolderAccessService.isReadableDirectory(file))
            #expect(!FolderAccessService.isReadableDirectory(root.appendingPathComponent("Missing")))
            #expect(!FolderAccessService.isReadableDirectory(unreadable))
        }
    }

    @Test @MainActor func explicitWorkspaceAuthorizationPersistsAndRestoresFromExistingBookmarkStore() throws {
        try withTemporaryDirectory { root in
            let suiteName = "FloralMD-Workspace-Authorization-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let writer = FolderAccessService(defaults: defaults, accessPolicy: .securityScoped)
            try writer.rememberWorkspace(root)

            let reader = FolderAccessService(defaults: defaults, accessPolicy: .securityScoped)
            let restored = try #require(try reader.restoredFolder(for: root))
            #expect(
                restored.resolvingSymlinksInPath()
                    == root.standardizedFileURL.resolvingSymlinksInPath()
            )
        }
    }

    @Test @MainActor func folderAccessAndQuickCaptureShareTheSameRootScope() throws {
        try withTemporaryDirectory { root in
            let suiteName = "FloralMD-Shared-Authorization-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var beginCount = 0
            var stopCount = 0
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: { _ in
                    beginCount += 1
                    return true
                },
                endAccess: { _ in stopCount += 1 }
            )

            var folderAccess: FolderAccessService? = FolderAccessService(
                defaults: defaults,
                securityScopeAccessManager: manager,
                accessPolicy: .securityScoped
            )
            try folderAccess?.rememberWorkspace(root)
            #expect(beginCount == 1)
            #expect(manager.ownerCount(for: root) == 1)

            let bookmark = try root.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: "QuickCaptureFolderBookmark")
            var quickCapture: QuickCaptureService? = QuickCaptureService(
                defaults: defaults,
                securityScopeAccessManager: manager
            )
            let configured = try #require(quickCapture?.configuredFolderForDisplay())
            #expect(configured.standardizedFileURL == root.standardizedFileURL)
            #expect(beginCount == 1)
            #expect(manager.ownerCount(for: root) == 2)

            _ = quickCapture?.configuredFolderForDisplay()
            #expect(manager.ownerCount(for: root) == 2)
            quickCapture = nil
            #expect(stopCount == 0)
            #expect(manager.ownerCount(for: root) == 1)

            folderAccess = nil
            #expect(stopCount == 1)
            #expect(manager.ownerCount(for: root) == 0)
        }
    }

    @Test @MainActor func invalidWorkspaceBookmarkReportsFailureInsteadOfFallingBack() throws {
        try withTemporaryDirectory { root in
            let suiteName = "FloralMD-Workspace-Invalid-Authorization-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(
                [root.standardizedFileURL.path: Data("invalid bookmark".utf8)],
                forKey: "FileBrowserFolderBookmarks"
            )

            let service = FolderAccessService(defaults: defaults, accessPolicy: .securityScoped)
            #expect(throws: (any Error).self) {
                try service.restoredFolder(for: root)
            }
        }
    }

    @Test @MainActor func directFolderAccessNeedsNoStoredBookmarkOrSecurityScope() throws {
        try withTemporaryDirectory { root in
            let suiteName = "FloralMD-Direct-Folder-Access-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var beginCount = 0
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: { _ in
                    beginCount += 1
                    return true
                },
                endAccess: { _ in }
            )
            let service = FolderAccessService(
                defaults: defaults,
                securityScopeAccessManager: manager,
                accessPolicy: .direct
            )

            let restored = try #require(try service.restoredFolder(for: root))
            let requested = try #require(try service.requestAccess(to: root))
            try service.rememberWorkspace(root)

            #expect(restored == root.standardizedFileURL)
            #expect(requested == root.standardizedFileURL)
            #expect(beginCount == 0)
            #expect(defaults.dictionary(forKey: "FileBrowserFolderBookmarks") == nil)
        }
    }

    @Test @MainActor func directFolderAccessRejectsMissingFolder() throws {
        try withTemporaryDirectory { root in
            let missing = root.appendingPathComponent("Missing", isDirectory: true)
            let service = FolderAccessService(accessPolicy: .direct)

            #expect(throws: (any Error).self) {
                try service.restoredFolder(for: missing)
            }
            #expect(throws: (any Error).self) {
                try service.requestAccess(to: missing)
            }
        }
    }

    @Test func similarPathPrefixIsNotInsideDraftWorkspace() throws {
        let draftRoot = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/FloralMD Drafts-old/Note.md")
        let session = try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: target)

        #expect(session.kind == .externalFolder)
    }

    @Test func unsupportedTargetFailsInsteadOfGuessingAWorkspace() {
        let draftRoot = URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/External/plain.txt")

        #expect(throws: WorkspaceResolutionError.unsupportedResource(target)) {
            try WorkspaceResolver.resolve(draftRoot: draftRoot, targetURL: target)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-WorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
