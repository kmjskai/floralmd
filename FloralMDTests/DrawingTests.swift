import AppKit
import Foundation
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct DrawingTests {
    @Test func drawingWindowTitleTracksUntitledOpenedAndSavedIdentity() {
        #expect(DrawingWindowTitle.title(for: nil) == "未命名绘图")

        let root = URL(fileURLWithPath: "/tmp/FloralMD-DrawingTitle")
        let opened = DrawingDocumentIdentity(
            name: "打开的画板",
            sourceURL: root.appendingPathComponent("打开的画板.excalidraw"),
            svgURL: root.appendingPathComponent("打开的画板.svg")
        )
        let saved = DrawingDocumentIdentity(
            name: "保存后的画板",
            sourceURL: root.appendingPathComponent("保存后的画板.excalidraw"),
            svgURL: root.appendingPathComponent("保存后的画板.svg")
        )

        #expect(DrawingWindowTitle.title(for: opened) == "打开的画板.excalidraw")
        #expect(DrawingWindowTitle.title(for: saved) == "保存后的画板.excalidraw")

        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let titleBridge = DrawingWindowTitleBridge.TitleSyncView(
            title: DrawingWindowTitle.title(for: opened)
        )
        window.contentView = titleBridge
        #expect(window.title == "打开的画板.excalidraw")
        titleBridge.title = DrawingWindowTitle.title(for: saved)
        #expect(window.title == "保存后的画板.excalidraw")
    }

    @Test func embeddedDrawingDoesNotOwnTheUnifiedWindowTitle() {
        #expect(!DrawingWindowTitle.ownsWindowTitle(embedded: true))
        #expect(DrawingWindowTitle.ownsWindowTitle(embedded: false))
    }

    @Test func aNewPlaceholderReplacesTheRetainedDrawingInsteadOfReopeningIt() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD-NewDrawing", isDirectory: true)
        let retained = root.appendingPathComponent("test1.excalidraw")
        let placeholder = root.appendingPathComponent("2026-08-11 18.30.00.excalidraw")

        #expect(DrawingInitialResourceAction.resolve(
            currentDocumentURL: retained,
            targetURL: placeholder,
            targetExists: false,
            hasPendingLoad: false
        ) == .beginPlaceholder)
        #expect(DrawingInitialResourceAction.resolve(
            currentDocumentURL: retained,
            targetURL: retained,
            targetExists: true,
            hasPendingLoad: false
        ) == .ignore)
    }

    @Test func drawingCatalogIncludesOnlyTopLevelDrawingFilesInStableOrder() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingCatalogTests-\(UUID().uuidString)", isDirectory: true)
        let layout = DrawingStorageLayout(root: temporary)
        let nestedDirectory = layout.excalidrawDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        try Data().write(to: layout.excalidrawDirectory.appendingPathComponent("board 10.excalidraw"))
        try Data().write(to: layout.excalidrawDirectory.appendingPathComponent("Board 2.EXCALIDRAW"))
        try Data().write(to: layout.excalidrawDirectory.appendingPathComponent("notes.txt"))
        try Data().write(to: layout.excalidrawDirectory.appendingPathComponent("preview.svg"))
        try Data().write(to: nestedDirectory.appendingPathComponent("nested.excalidraw"))
        try FileManager.default.createDirectory(
            at: layout.excalidrawDirectory.appendingPathComponent("folder.excalidraw"),
            withIntermediateDirectories: false
        )

        let entries = try DrawingFileCatalog(layout: layout).entries()

        #expect(entries.map(\.name) == ["Board 2", "board 10"])
    }

    @Test func nativeDrawingFileRowClickKeepsPendingSelectionUntilItBecomesCurrent() async {
        let root = URL(fileURLWithPath: "/tmp/FloralMD-DrawingClickTests", isDirectory: true)
        let entries = ["Current", "Target"].map {
            DrawingFileEntry(sourceURL: root.appendingPathComponent("\($0).excalidraw"))
        }
        var requested: DrawingFileEntry?
        let coordinator = DrawingFileListCoordinator { requested = $0 }
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("drawing")))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.update(
            entries: entries,
            selectedDocumentURL: entries[0].sourceURL,
            requestSafeOpen: { requested = $0 }
        )

        #expect(tableView.selectedRow == 0)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.rowClicked(tableView)

        #expect(tableView.selectedRow == 1)
        for _ in 0..<20 where requested == nil {
            await Task.yield()
        }
        #expect(requested == entries[1])

        // SwiftUI first publishes the pending selection and later promotes the
        // same URL to current. Neither update may make the table jump back.
        coordinator.update(
            entries: entries,
            selectedDocumentURL: entries[1].sourceURL,
            requestSafeOpen: { requested = $0 }
        )
        #expect(tableView.selectedRow == 1)
        coordinator.update(
            entries: entries,
            selectedDocumentURL: entries[1].sourceURL,
            requestSafeOpen: { requested = $0 }
        )
        #expect(tableView.selectedRow == 1)

        requested = nil
        coordinator.activate(row: 1)
        await Task.yield()
        #expect(requested == nil)
    }

    @Test func nativeDrawingFileRowClickWorksFromNewUntitledState() async {
        let entry = DrawingFileEntry(
            sourceURL: URL(fileURLWithPath: "/tmp/FloralMD-DrawingClickTests/Saved.excalidraw")
        )
        var requested: DrawingFileEntry?
        let coordinator = DrawingFileListCoordinator { requested = $0 }
        coordinator.update(
            entries: [entry],
            selectedDocumentURL: nil,
            requestSafeOpen: { requested = $0 }
        )

        coordinator.activate(row: 0)
        for _ in 0..<20 where requested == nil {
            await Task.yield()
        }
        #expect(requested == entry)
    }

    @Test func drawingFileSelectionRollsBackOnCancelFailureAndTimeout() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD-DrawingSelectionRollback", isDirectory: true)
        let current = root.appendingPathComponent("A.excalidraw")
        let target = DrawingFileEntry(sourceURL: root.appendingPathComponent("B.excalidraw"))
        var selection = DrawingFileSelectionState()
        selection.updateCurrent(current)

        let cancelRequest = selection.request(target)
        #expect(selection.displayedDocumentURL == target.sourceURL.standardizedFileURL)
        selection.rollback(requestID: cancelRequest)
        #expect(selection.displayedDocumentURL == current.standardizedFileURL)

        let failureRequest = selection.request(target)
        selection.rollback(requestID: failureRequest)
        #expect(selection.displayedDocumentURL == current.standardizedFileURL)

        let timeoutRequest = selection.request(target)
        selection.rollback(requestID: timeoutRequest)
        #expect(selection.displayedDocumentURL == current.standardizedFileURL)
    }

    @Test func drawingFileSelectionIgnoresLateResultFromSupersededRequest() {
        let root = URL(fileURLWithPath: "/tmp/FloralMD-DrawingSelectionGeneration", isDirectory: true)
        let a = root.appendingPathComponent("A.excalidraw")
        let b = DrawingFileEntry(sourceURL: root.appendingPathComponent("B.excalidraw"))
        let c = DrawingFileEntry(sourceURL: root.appendingPathComponent("C.excalidraw"))
        let bRequest = UUID()
        let cRequest = UUID()
        var selection = DrawingFileSelectionState()
        selection.updateCurrent(a)

        selection.request(b, id: bRequest)
        selection.request(c, id: cRequest)
        #expect(selection.displayedDocumentURL == c.sourceURL.standardizedFileURL)
        let didPromoteB = selection.promote(requestID: bRequest)
        #expect(!didPromoteB)
        #expect(selection.displayedDocumentURL == c.sourceURL.standardizedFileURL)
        #expect(selection.currentDocumentURL == a.standardizedFileURL)

        let didPromoteC = selection.promote(requestID: cRequest)
        #expect(didPromoteC)
        #expect(selection.currentDocumentURL == c.sourceURL.standardizedFileURL)
        #expect(selection.displayedDocumentURL == c.sourceURL.standardizedFileURL)
    }

    @Test func drawingWorkspaceSelectionUsesStoreLocationValidation() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingOpenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout(root: temporary)
        let saved = try DrawingStore(layout: layout).save(
            try samplePayload(label: "safe-open"),
            proposedName: "Safe"
        )

        let opened = try DrawingWorkspaceOpenPath.open(
            DrawingFileEntry(sourceURL: saved.sourceURL),
            in: layout
        )
        #expect(opened.identity == saved)

        let outside = temporary.deletingLastPathComponent().appendingPathComponent("outside.excalidraw")
        #expect(throws: DrawingStore.StoreError.invalidLocation) {
            try DrawingWorkspaceOpenPath.open(DrawingFileEntry(sourceURL: outside), in: layout)
        }
    }

    @Test func drawingWorkspaceNewStateClearsIdentityAndSavesWithoutOverwriting() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout(root: temporary)
        let store = DrawingStore(layout: layout)
        let originalPayload = try samplePayload(label: "original")
        let original = try store.save(originalPayload, proposedName: "Board")
        let opened = try store.open(original.sourceURL)
        var session = DrawingWorkspaceSession()

        try session.markOpened(opened)
        #expect(session.document == original)
        #expect(session.isCurrent(DrawingFileEntry(sourceURL: original.sourceURL)))
        #expect(try !session.hasUnsavedChanges(in: originalPayload))

        session.beginNewDrawing()
        #expect(session.document == nil)
        #expect(session.baseline == nil)
        #expect(DrawingWindowTitle.title(for: session.document) == "未命名绘图")
        #expect(!session.isCurrent(DrawingFileEntry(sourceURL: original.sourceURL)))

        let newPayload = try samplePayload(label: "new")
        let saved = try store.save(
            newPayload,
            proposedName: "Board",
            replacing: session.document
        )
        try session.markSaved(saved, payload: newPayload)

        #expect(saved.name == "Board 2")
        #expect(session.document == saved)
        #expect(session.isCurrent(DrawingFileEntry(sourceURL: saved.sourceURL)))
        #expect(FileManager.default.fileExists(atPath: original.sourceURL.path))
        #expect(try String(contentsOf: original.sourceURL).contains("original"))
    }

    @Test func unsavedProtectionIgnoresViewportButDetectsDrawingContent() throws {
        let baseline = try payload(
            elementsJSON: #"[{"id":"shape-1","type":"rectangle"}]"#,
            filesJSON: "{}",
            appStateJSON: ##"{"scrollX":0,"viewBackgroundColor":"#ffffff"}"##
        )
        let movedViewport = try payload(
            elementsJSON: #"[{"id":"shape-1","type":"rectangle"}]"#,
            filesJSON: "{}",
            appStateJSON: ##"{"scrollX":240,"scrollY":-30,"viewBackgroundColor":"#ffffff"}"##
        )
        let changedDrawing = try payload(
            elementsJSON: #"[{"id":"shape-1","type":"rectangle"},{"id":"shape-2","type":"ellipse"}]"#,
            filesJSON: "{}",
            appStateJSON: ##"{"scrollX":240,"viewBackgroundColor":"#ffffff"}"##
        )
        var session = DrawingWorkspaceSession()
        try session.establishBaseline(from: baseline)

        #expect(try !session.hasUnsavedChanges(in: movedViewport))
        #expect(try session.hasUnsavedChanges(in: changedDrawing))
    }

    @Test func drawingWindowPinningUsesSavedOpacityOnlyWhilePinned() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let bridge = WindowPinningHostingView()
        let root = URL(fileURLWithPath: "/tmp/FloralMD-DrawingPinnedSelection", isDirectory: true)
        let current = root.appendingPathComponent("A.excalidraw")
        let target = DrawingFileEntry(sourceURL: root.appendingPathComponent("B.excalidraw"))
        var selection = DrawingFileSelectionState()
        selection.updateCurrent(current)
        selection.request(target)
        window.contentView = bridge
        bridge.pinnedWindowOpacity = PinnedWindowOpacityPreference.alpha(for: 73)

        bridge.mode = .currentSpace
        #expect(window.level == .floating)
        #expect(abs(window.alphaValue - 0.73) < 0.001)
        #expect(selection.displayedDocumentURL == target.sourceURL.standardizedFileURL)

        bridge.pinnedWindowOpacity = PinnedWindowOpacityPreference.alpha(for: 81)
        #expect(abs(window.alphaValue - 0.81) < 0.001)
        #expect(selection.displayedDocumentURL == target.sourceURL.standardizedFileURL)

        bridge.mode = .none
        #expect(window.level == .normal)
        #expect(window.alphaValue == 1)
    }

    @Test func validExcalidrawSceneReportsLiveElementCount() throws {
        let scene = try DrawingScene(json: """
        {
          "type": "excalidraw",
          "version": 2,
          "source": "local",
          "elements": [{"id":"one"},{"id":"gone","isDeleted":true}],
          "appState": {},
          "files": {}
        }
        """)

        #expect(scene.elementCount == 1)
    }

    @Test func bridgeRejectsNonExcalidrawJSON() {
        #expect(throws: DrawingScene.ValidationError.unsupportedType) {
            try DrawingScene(json: """
            {"type":"other","elements":[],"appState":{},"files":{}}
            """)
        }
    }

    @Test func vendorMetadataPinsOfficialVersionAndOfflineEntryPage() throws {
        let versionURL = try #require(Bundle.main.url(
            forResource: "Excalidraw-VERSION",
            withExtension: "txt",
            subdirectory: "Vendor/Excalidraw"
        ) ?? Bundle.main.url(forResource: "Excalidraw-VERSION", withExtension: "txt"))
        let version = try String(contentsOf: versionURL, encoding: .utf8)
        #expect(version.contains("Version: 0.18.1"))
        #expect(version.contains("License: MIT"))

        let pageURL = try #require(Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Vendor/Excalidraw"
        ) ?? Bundle.main.url(forResource: "index", withExtension: "html"))
        let page = try String(contentsOf: pageURL, encoding: .utf8)
        #expect(page.contains("./excalidraw.js"))
        #expect(page.contains("connect-src 'none'"))
        #expect(!page.contains("src=\"http"))
        #expect(!page.contains("href=\"http"))
    }

    @Test func offlineDrawingPageConstructsExcalidrawAndWelcomeScreen() async throws {
        let controller = ExcalidrawViewController()
        controller.loadViewIfNeeded()

        var state: [String: Bool]?
        for _ in 0..<200 {
            state = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript(
                    """
                    (() => {
                      if (!window.__slateMemoComplete) return null;
                      return {
                        excalidraw: !!document.querySelector('.excalidraw'),
                        welcome: !!document.querySelector('.welcome-screen-center'),
                        customToolbarHidden: !document.querySelector('.floralmd-drawing-actions')
                      };
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Bool])
                }
            }

            if state?["excalidraw"] == true,
               state?["welcome"] == true,
               state?["customToolbarHidden"] == true {
                break
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(state?["excalidraw"] == true)
        #expect(state?["welcome"] == true)
        #expect(state?["customToolbarHidden"] == true)
    }

    @Test func helpKeepsOfflineShortcutsWithoutExposingExternalPromotionLinks() async throws {
        let controller = ExcalidrawViewController()
        controller.loadViewIfNeeded()

        var state: [String: Bool]?
        for _ in 0..<200 where state == nil {
            state = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript(
                    """
                    (() => {
                      if (!window.__slateMemoComplete) return null;
                      document.querySelector('.welcome-screen-menu-item')?.click();
                      const header = document.querySelector('.HelpDialog__header');
                      const dialog = document.querySelector('.HelpDialog');
                      if (!dialog || !header) return null;
                      return {
                        shortcuts: dialog.querySelectorAll('.HelpDialog__shortcut').length > 0,
                        externalLinksHidden: getComputedStyle(header).display === 'none'
                      };
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Bool])
                }
            }
            if state == nil { try await Task.sleep(for: .milliseconds(50)) }
        }

        #expect(state?["shortcuts"] == true)
        #expect(state?["externalLinksHidden"] == true)
    }

    @Test func drawingNavigationPolicyKeepsWebContentOffline() {
        #expect(ExcalidrawViewController.navigationPolicy(for: URL(string: "https://docs.excalidraw.com")) == .cancel)
        #expect(ExcalidrawViewController.navigationPolicy(for: URL(string: "http://example.com")) == .cancel)
        #expect(ExcalidrawViewController.navigationPolicy(
            for: ExcalidrawResourceSchemeHandler.entryURL
        ) == .allow)
        #expect(ExcalidrawViewController.navigationPolicy(for: URL(string: "data:text/plain,ok")) == .allow)
    }

    @Test func completionBridgeReturnsSceneJSONToSwift() async throws {
        let controller = ExcalidrawViewController()
        var received: Result<DrawingExportPayload, Error>?
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()

        var ready = false
        for _ in 0..<200 where !ready {
            ready = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript("!!window.__slateMemoComplete") { value in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            if !ready { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(ready)

        controller.requestCompletion()
        for _ in 0..<100 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let result = try #require(received)
        let payload = try result.get()
        #expect(payload.scene.elementCount == 0)
        #expect(!payload.scene.json.isEmpty)
        #expect(payload.svg?.contains("<svg") == true)
    }

    @Test func lightweightCompletionSkipsSVGRenderingButReturnsComparableScene() async throws {
        let controller = ExcalidrawViewController()
        var received: Result<DrawingExportPayload, Error>?
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()

        var ready = false
        for _ in 0..<200 where !ready {
            ready = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript("!!window.__slateMemoComplete") { value in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            if !ready { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(ready)

        controller.requestCompletion(includeSVG: false)
        for _ in 0..<100 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try #require(received).get()
        #expect(payload.scene.elementCount == 0)
        #expect(payload.svg == nil)
    }

    @Test func loadedImageFreeSceneCompletesWithSVGAndNoBinaryFiles() async throws {
        let controller = ExcalidrawViewController()
        let requestID = UUID()
        var loadedRequestID: UUID?
        var received: Result<DrawingExportPayload, Error>?
        controller.onLoaded = { loadedRequestID = $0 }
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()
        controller.load(sceneJSON: sceneWithPureElements(), requestID: requestID)

        for _ in 0..<200 where loadedRequestID == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loadedRequestID == requestID)

        controller.requestCompletion()
        for _ in 0..<100 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try #require(received).get()
        #expect(payload.scene.elementCount == 1)
        #expect(payload.files.isEmpty)
        #expect(payload.svg?.contains("<svg") == true)
    }

    @Test func drawingReadyMeansImmediateSnapshotRequestCanComplete() async throws {
        let controller = ExcalidrawViewController()
        var received: Result<DrawingExportPayload, Error>?
        controller.onReady = {
            controller.requestCompletion(includeSVG: false)
        }
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()

        for _ in 0..<200 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try #require(received).get()
        #expect(payload.scene.elementCount == 0)
        #expect(payload.files.isEmpty)
    }

    @Test func completionRequestedBeforeDrawingReadyIsNotDropped() async throws {
        let controller = ExcalidrawViewController()
        var received: Result<DrawingExportPayload, Error>?
        controller.onComplete = { received = $0 }
        controller.requestCompletion(includeSVG: false)
        controller.loadViewIfNeeded()

        for _ in 0..<200 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try #require(received).get()
        #expect(payload.scene.elementCount == 0)
        #expect(payload.svg == nil)
    }

    @Test func storageCreatesLayoutAvoidsNamesAndKeepsImagesSelfContained() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout(root: temporary)
        let store = DrawingStore(layout: layout)
        let first = try store.save(try samplePayload(label: "first"), proposedName: "Board")
        let second = try store.save(try samplePayload(label: "second"), proposedName: "Board.excalidraw")

        #expect(first.name == "Board")
        #expect(second.name == "Board 2")
        #expect(FileManager.default.fileExists(atPath: layout.excalidrawDirectory.path))
        #expect(FileManager.default.fileExists(atPath: layout.svgDirectory.path))
        #expect(layout.excalidrawDirectory.path.hasSuffix("/drawings"))
        #expect(layout.svgDirectory.path.hasSuffix("/drawings/exports"))
        #expect(try String(contentsOf: first.sourceURL).contains("data:image/png;base64"))
        let exportedSVG = try String(contentsOf: first.svgURL)
        #expect(exportedSVG.contains("data:image/png;base64"))
        #expect(!exportedSVG.contains("file://"))
        #expect(!FileManager.default.fileExists(
            atPath: layout.excalidrawDirectory.appendingPathComponent("images").path
        ))
    }

    @Test func savingOpenedDrawingUpdatesSameSourceAndSVG() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = DrawingStore(layout: DrawingStorageLayout(root: temporary))
        let original = try store.save(try samplePayload(label: "before"), proposedName: "Editable")
        let opened = try store.open(original.sourceURL)
        let updated = try store.save(
            try samplePayload(label: "after"),
            proposedName: "ignored",
            replacing: opened.identity
        )

        #expect(updated == original)
        #expect(try String(contentsOf: updated.sourceURL).contains("after"))
        #expect(try String(contentsOf: updated.svgURL).contains("after"))
        let reopened = try store.open(updated.sourceURL)
        #expect(reopened.scene.json.contains("data:image/png;base64"))
    }

    @Test func legacyDraftDirectoriesAreIgnoredWithoutMigrationOrDeletion() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-LegacyDrawing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout(root: temporary)
        let legacyExcalidrawDirectory = temporary.appendingPathComponent("excalidraw", isDirectory: true)
        let legacySVGDirectory = temporary.appendingPathComponent("svg", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyExcalidrawDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: legacySVGDirectory, withIntermediateDirectories: true)
        let sourceURL = legacyExcalidrawDirectory.appendingPathComponent("Legacy.excalidraw")
        let svgURL = legacySVGDirectory.appendingPathComponent("Legacy.svg")
        try sampleScene(label: "legacy").write(to: sourceURL, atomically: true, encoding: .utf8)
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".write(
            to: svgURL,
            atomically: true,
            encoding: .utf8
        )

        let entries = try DrawingFileCatalog(layout: layout).entries()
        #expect(entries.isEmpty)
        #expect(throws: DrawingStore.StoreError.invalidLocation) {
            try DrawingStore(layout: layout).open(sourceURL)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: svgURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.excalidrawDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: layout.svgDirectory.path))
    }

    @Test func svgSyncPolicyCoversDraftExternalAndNeverModes() {
        #expect(DrawingSVGSyncPolicy.draftOnly.automaticallySyncsSVG(for: .draft))
        #expect(!DrawingSVGSyncPolicy.draftOnly.automaticallySyncsSVG(for: .externalFolder))
        #expect(DrawingSVGSyncPolicy.allDrawings.automaticallySyncsSVG(for: .draft))
        #expect(DrawingSVGSyncPolicy.allDrawings.automaticallySyncsSVG(for: .externalFolder))
        #expect(!DrawingSVGSyncPolicy.never.automaticallySyncsSVG(for: .draft))
        #expect(!DrawingSVGSyncPolicy.never.automaticallySyncsSVG(for: .externalFolder))
    }

    @Test func svgSyncPreferenceDefaultsPersistsAndRepairsUnknownValues() throws {
        let suiteName = "DrawingSVGSyncPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DrawingSVGSyncPreference.load(from: defaults) == .draftOnly)
        #expect(DrawingSVGSyncPreference.persist(.allDrawings, to: defaults) == .allDrawings)
        #expect(DrawingSVGSyncPreference.load(from: defaults) == .allDrawings)
        defaults.set("unknown", forKey: AppPreferenceKey.drawingSVGSyncPolicy)
        #expect(DrawingSVGSyncPreference.normalizeStoredValue(in: defaults) == .draftOnly)
        #expect(defaults.string(forKey: AppPreferenceKey.drawingSVGSyncPolicy) == "draftOnly")
    }

    @Test func sourceOnlySaveDoesNotCreateExportsOrModifyLegacyDerivatives() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-SourceOnlyDrawing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout.external(root: temporary)
        let legacySVG = temporary.appendingPathComponent("Board.svg")
        let legacyImages = temporary.appendingPathComponent("images", isDirectory: true)
        try "existing".write(to: legacySVG, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: legacyImages, withIntermediateDirectories: true)
        try "legacy".write(
            to: legacyImages.appendingPathComponent("image.png"),
            atomically: true,
            encoding: .utf8
        )
        let sourceOnlyPayload = try payload(
            elementsJSON: "[]",
            filesJSON: "{}",
            appStateJSON: "{}",
            svg: nil
        )

        let saved = try DrawingStore(layout: layout).save(
            sourceOnlyPayload,
            proposedName: "Board",
            syncSVG: false
        )

        #expect(saved.sourceURL == temporary.appendingPathComponent("Board.excalidraw"))
        #expect(try String(contentsOf: legacySVG, encoding: .utf8) == "existing")
        #expect(try String(
            contentsOf: legacyImages.appendingPathComponent("image.png"),
            encoding: .utf8
        ) == "legacy")
        #expect(!FileManager.default.fileExists(atPath: layout.svgDirectory.path))
    }

    @Test func automaticSVGSaveUsesSiblingExportsForDraftAndExternalDrawings() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-SVGPolicyStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let draftRoot = temporary.appendingPathComponent("Draft", isDirectory: true)
        let externalRoot = temporary.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let noImagePayload = try payload(
            elementsJSON: "[]",
            filesJSON: "{}",
            appStateJSON: "{}"
        )

        let draftSaved = try DrawingStore(layout: DrawingStorageLayout(root: draftRoot)).save(
            noImagePayload,
            proposedName: "Draft Board",
            syncSVG: true
        )
        let externalSaved = try DrawingStore(layout: .external(root: externalRoot)).save(
            noImagePayload,
            proposedName: "External Board",
            syncSVG: true
        )

        #expect(draftSaved.svgURL.path.hasSuffix("/drawings/exports/Draft Board.svg"))
        #expect(externalSaved.svgURL == externalRoot.appendingPathComponent("exports/External Board.svg"))
        #expect(FileManager.default.fileExists(atPath: draftSaved.svgURL.path))
        #expect(FileManager.default.fileExists(atPath: externalSaved.svgURL.path))
    }

    @Test func manualSVGExportWritesOnlyTheSelectedTarget() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-ManualSVGExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let target = temporary.appendingPathComponent("Manual.svg")
        let payload = try samplePayload(label: "manual")

        try DrawingStore.exportSVG(payload, to: target)

        #expect(try String(contentsOf: target, encoding: .utf8).contains("manual"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == ["Manual.svg"])
    }

    @Test func externalDrawingLayoutKeepsSourceAtRootAndSVGInExports() throws {
        let root = URL(fileURLWithPath: "/tmp/External Drawing", isDirectory: true)
        let layout = DrawingStorageLayout.external(root: root)
        let source = root.appendingPathComponent("Board.excalidraw")

        #expect(layout.excalidrawDirectory == root.standardizedFileURL)
        #expect(layout.svgURL(for: source) == root.appendingPathComponent("exports/Board.svg"))
        #expect(layout.readableSourceDirectories == [root.standardizedFileURL])
    }

    @Test func sourceLayoutTreatsEveryDrawingInsideTheConfiguredDraftRootAsDraftScoped() {
        let draft = URL(fileURLWithPath: "/tmp/FloralMD Draft", isDirectory: true)
        let topLevel = draft.appendingPathComponent("drawings/Board.excalidraw")
        let noteLocal = draft.appendingPathComponent("notes/Project/drawings/Board.excalidraw")

        let draftLayout = DrawingStorageLayout.forSource(topLevel, configuredDraftRoot: draft)
        let localLayout = DrawingStorageLayout.forSource(noteLocal, configuredDraftRoot: draft)

        #expect(draftLayout.scope == .draft)
        #expect(draftLayout.excalidrawDirectory
            == draft.appendingPathComponent("drawings", isDirectory: true))
        #expect(localLayout.scope == .draft)
        #expect(localLayout.excalidrawDirectory == noteLocal.deletingLastPathComponent())
        #expect(localLayout.svgURL(for: noteLocal)
            == noteLocal.deletingLastPathComponent().appendingPathComponent("exports/Board.svg"))
    }

    @Test func noteLocalDraftDrawingFirstSaveWritesSelfContainedSourceAndStandardSVG() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-LocalDraftDrawing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("notes/Project/drawings/Board.excalidraw")
        let layout = DrawingStorageLayout.forSource(source, configuredDraftRoot: temporary)
        let syncSVG = DrawingSVGSyncPolicy.draftOnly.automaticallySyncsSVG(for: layout.scope)
        let exportPayload = try payload(
            elementsJSON: "[]",
            filesJSON: "{}",
            appStateJSON: "{}"
        )

        let saved = try DrawingStore(layout: layout).save(
            exportPayload,
            proposedName: "Board",
            syncSVG: syncSVG
        )

        #expect(syncSVG)
        #expect(saved.sourceURL == source)
        #expect(saved.svgURL == source.deletingLastPathComponent()
            .appendingPathComponent("exports/Board.svg"))
        #expect(FileManager.default.fileExists(atPath: saved.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: saved.svgURL.path))
        #expect(try String(contentsOf: saved.sourceURL, encoding: .utf8)
            == exportPayload.scene.json)
    }

    @Test func configuredDraftRootDoesNotClassifyAnOutsideDrawingAsDraftScoped() {
        let draft = URL(fileURLWithPath: "/tmp/FloralMD Draft", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/External/drawings/Board.excalidraw")

        let layout = DrawingStorageLayout.forSource(outside, configuredDraftRoot: draft)

        #expect(layout.scope == .externalFolder)
        #expect(layout.excalidrawDirectory == outside.deletingLastPathComponent())
        #expect(!DrawingSVGSyncPolicy.draftOnly.automaticallySyncsSVG(for: layout.scope))
    }

    @Test func aDraftPathThroughAnOutsideSymlinkIsNotDraftScoped() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let draft = temporary.appendingPathComponent("Draft", isDirectory: true)
        let outside = temporary.appendingPathComponent("Outside", isDirectory: true)
        let linkedDirectory = draft.appendingPathComponent("notes/Linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        let source = linkedDirectory.appendingPathComponent("drawings/Board.excalidraw")

        let layout = DrawingStorageLayout.forSource(source, configuredDraftRoot: draft)

        #expect(layout.scope == .externalFolder)
        #expect(!DrawingSVGSyncPolicy.draftOnly.automaticallySyncsSVG(for: layout.scope))
    }

    @Test func embeddedDrawingRetainsExternalLayoutInsteadOfFallingBackToDraft() {
        let external = DrawingStorageLayout.external(
            root: URL(fileURLWithPath: "/tmp/External", isDirectory: true)
        )
        let configured = DrawingStorageLayout(
            root: URL(fileURLWithPath: "/tmp/FloralMD Drafts", isDirectory: true)
        )

        #expect(DrawingLayoutSelection.resolve(
            embedded: true,
            current: external,
            configured: configured
        ) == external)
        #expect(DrawingLayoutSelection.resolve(
            embedded: false,
            current: external,
            configured: configured
        ) == configured)
    }

    @Test func invalidImageFailsWithoutClaimingACompletedSave() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let scene = try DrawingScene(json: sampleScene(label: "bad"))

        #expect(throws: DrawingExportPayload.ValidationError.invalidImage("image-1")) {
            try DrawingExportPayload(
                scene: scene,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: ["image-1": DrawingFilePayload(
                    id: "image-1",
                    mimeType: "image/png",
                    dataURL: "not-a-data-url",
                    created: nil,
                    lastRetrieved: nil
                )]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test(arguments: [
        ("image/png", "png"),
        ("image/jpeg", "jpg"),
        ("image/gif", "gif"),
        ("image/webp", "webp"),
        ("image/bmp", "bmp"),
        ("image/x-icon", "ico"),
        ("image/svg+xml", "svg"),
        ("image/avif", "avif"),
        ("image/jfif", "jfif")
    ])
    func originalImageRequestPreservesSupportedBinaryData(
        mimeType: String,
        fileExtension: String
    ) throws {
        let bytes = Data([0x00, 0x7f, 0x80, 0xff])
        let request = try originalImageRequest(mimeType: mimeType, bytes: bytes)

        #expect(request.fileID == "file-id_123456789")
        #expect(request.binary.data == bytes)
        #expect(request.binary.fileExtension == fileExtension)
        #expect(request.clientX == 42.5)
        #expect(request.clientY == 84.25)
    }

    @Test func originalImageRequestRejectsInvalidEnvelopeFileAndData() throws {
        #expect(throws: DrawingOriginalImageRequest.ValidationError.invalidEnvelope) {
            try DrawingOriginalImageRequest(messageJSON: "{}")
        }
        #expect(throws: DrawingOriginalImageRequest.ValidationError.invalidFileID) {
            try originalImageRequest(fileID: "   ")
        }
        #expect(throws: DrawingOriginalImageRequest.ValidationError.invalidImage) {
            try originalImageRequest(dataURL: "not-a-data-url")
        }
        #expect(throws: DrawingOriginalImageRequest.ValidationError.invalidImage) {
            try originalImageRequest(mimeType: "image/png", dataURL: "data:image/jpeg;base64,AA==")
        }
        #expect(throws: DrawingOriginalImageRequest.ValidationError.invalidImage) {
            try originalImageRequest(dataURL: "data:image/png;base64,")
        }
    }

    @Test func originalImageExportUsesStableNameAndWritesOnlyChosenOriginalBytes() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-OriginalImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bytes = Data([0xde, 0xad, 0xbe, 0xef])
        let request = try originalImageRequest(bytes: bytes)
        let destination = temporary.appendingPathComponent("chosen.png")
        var proposedName: String?

        let saved = try DrawingOriginalImageExporter.export(
            request,
            drawingName: "  系统 / 架构.excalidraw  "
        ) { fileName, fileExtension in
            proposedName = fileName
            #expect(fileExtension == "png")
            return destination
        }

        #expect(proposedName == "系统 - 架构--fileid12.png")
        #expect(saved == destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == ["chosen.png"])
    }

    @Test func cancellingOriginalImageExportWritesNothingAndWriteFailuresSurface() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-OriginalImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let request = try originalImageRequest()

        let cancelled = try DrawingOriginalImageExporter.export(
            request,
            drawingName: "Board"
        ) { _, _ in nil }
        #expect(cancelled == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)

        #expect(throws: (any Error).self) {
            try DrawingOriginalImageExporter.export(request, drawingName: "Board") { _, _ in
                temporary
            }
        }
    }

    @Test func imageFreeScenesAllowMissingOrEmptyFiles() throws {
        let missingFiles = try DrawingScene(json: sceneJSON(elements: "[]", files: nil))
        let pureElements = try DrawingScene(json: sceneJSON(
            elements: """
            [
              {"id":"shape","type":"rectangle","isDeleted":false},
              {"id":"label","type":"text","isDeleted":false},
              {"id":"connector","type":"arrow","isDeleted":false},
              {"id":"stroke","type":"freedraw","isDeleted":false},
              {"id":"embed","type":"iframe","isDeleted":false}
            ]
            """,
            files: "{}"
        ))

        for scene in [missingFiles, pureElements] {
            let payload = try DrawingExportPayload(
                scene: scene,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: [:]
            )
            #expect(payload.files.isEmpty)
        }
    }

    @Test func imageFreeDrawingOpensSavesReopensAndExportsSVG() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-PureDrawing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = DrawingStore(layout: DrawingStorageLayout(root: temporary))
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0L1 1\"/></svg>"
        let initial = try DrawingExportPayload(
            scene: DrawingScene(json: sceneJSON(
                elements: "[{\"id\":\"shape\",\"type\":\"rectangle\",\"isDeleted\":false}]",
                files: nil
            )),
            svg: svg,
            files: [:]
        )

        let identity = try store.save(initial, proposedName: "Pure")
        let opened = try store.open(identity.sourceURL)
        let reopenedPayload = try DrawingExportPayload(scene: opened.scene, svg: svg, files: [:])
        _ = try store.save(reopenedPayload, proposedName: "ignored", replacing: identity)
        let reopened = try store.open(identity.sourceURL)
        let destination = temporary.appendingPathComponent("manual.svg")
        try DrawingStore.exportSVG(
            DrawingExportPayload(scene: reopened.scene, svg: svg, files: [:]),
            to: destination
        )

        #expect(try String(contentsOf: identity.sourceURL, encoding: .utf8).contains("rectangle"))
        #expect(try String(contentsOf: destination, encoding: .utf8) == svg)
    }

    @Test func oneAndMultipleReferencedImagesRequireMatchingSelfContainedFiles() throws {
        let secondFile = DrawingFilePayload(
            id: "image-2",
            mimeType: "image/png",
            dataURL: "data:image/png;base64,AQ==",
            created: 2,
            lastRetrieved: nil
        )
        let filesJSON = "{\"image-1\":\(fileJSON(sampleFile)),\"image-2\":\(fileJSON(secondFile))}"
        let scene = try DrawingScene(json: sceneJSON(
            elements: "[\(minimalImageElement(id: "one", fileID: "image-1")),\(minimalImageElement(id: "two", fileID: "image-2"))]",
            files: filesJSON
        ))

        let payload = try DrawingExportPayload(
            scene: scene,
            svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
            files: ["image-1": sampleFile, "image-2": secondFile]
        )
        #expect(payload.files.count == 2)
    }

    @Test func imageWithoutFileIDOrWithoutMatchingFileFails() throws {
        let missingFileID = try DrawingScene(json: sceneJSON(
            elements: "[\(minimalImageElement(id: "missing-id", fileID: nil))]",
            files: "{}"
        ))
        #expect(throws: DrawingExportPayload.ValidationError.sceneFilesMismatch) {
            try DrawingExportPayload(
                scene: missingFileID,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: [:]
            )
        }

        let missingFile = try DrawingScene(json: sceneJSON(
            elements: "[\(minimalImageElement(id: "missing-file", fileID: "image-1"))]",
            files: "{}"
        ))
        #expect(throws: DrawingExportPayload.ValidationError.sceneFilesMismatch) {
            try DrawingExportPayload(
                scene: missingFile,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: ["image-1": sampleFile]
            )
        }
    }

    @Test(arguments: [
        ("image/png", "not-a-data-url"),
        ("image/png", "data:image/png;base64,"),
        ("image/png", "data:image/jpeg;base64,AA==")
    ])
    func referencedImageRejectsInvalidEmptyOrMismatchedDataURL(
        mimeType: String,
        dataURL: String
    ) throws {
        let invalidFile = DrawingFilePayload(
            id: "image-1",
            mimeType: mimeType,
            dataURL: dataURL,
            created: nil,
            lastRetrieved: nil
        )
        let scene = try DrawingScene(json: sceneJSON(
            elements: "[\(minimalImageElement(id: "invalid", fileID: "image-1"))]",
            files: "{\"image-1\":\(fileJSON(invalidFile))}"
        ))
        #expect(throws: DrawingExportPayload.ValidationError.invalidImage("image-1")) {
            try DrawingExportPayload(
                scene: scene,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: ["image-1": invalidFile]
            )
        }
    }

    @Test func unreferencedAndDeletedImageFilesRemainValidSceneData() throws {
        let filesJSON = "{\"image-1\":\(fileJSON(sampleFile))}"
        let unreferenced = try DrawingScene(json: sceneJSON(elements: "[]", files: filesJSON))
        let deleted = try DrawingScene(json: sceneJSON(
            elements: "[\(minimalImageElement(id: "deleted", fileID: "image-1", isDeleted: true))]",
            files: filesJSON
        ))

        for scene in [unreferenced, deleted] {
            let payload = try DrawingExportPayload(
                scene: scene,
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
                files: [:]
            )
            try DrawingExportPayload.validateScene(payload.scene)
        }
    }

    @Test func failedPairUpdateRestoresOriginalSourceAndSVG() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-DrawingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let layout = DrawingStorageLayout(root: temporary)
        let store = DrawingStore(layout: layout)
        let original = try store.save(try samplePayload(label: "original"), proposedName: "Rollback")
        let originalSource = try Data(contentsOf: original.sourceURL)
        let originalSVG = try Data(contentsOf: original.svgURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: layout.svgDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: layout.svgDirectory.path
            )
        }

        #expect(throws: (any Error).self) {
            try store.save(
                try samplePayload(label: "must-not-survive"),
                proposedName: "ignored",
                replacing: original
            )
        }
        #expect(try Data(contentsOf: original.sourceURL) == originalSource)
        #expect(try Data(contentsOf: original.svgURL) == originalSVG)
    }

    @Test func svgValidatorAllowsLinksButRejectsExternalImageReferences() throws {
        try DrawingSVGValidator.validate(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><a href=\"https://example.com\"></a></svg>"
        )
        #expect(throws: DrawingExportPayload.ValidationError.externalSVGImage("file:///tmp/image.png")) {
            try DrawingSVGValidator.validate(
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"file:///tmp/image.png\"/></svg>"
            )
        }
    }

    @Test func reopenBridgeRestoresFilePayload() async throws {
        let controller = ExcalidrawViewController()
        let requestID = UUID()
        var loadedRequestID: UUID?
        var received: Result<DrawingExportPayload, Error>?
        controller.onLoaded = { loadedRequestID = $0 }
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()

        var ready = false
        for _ in 0..<200 where !ready {
            ready = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript("!!window.__slateMemoLoadScene") { value in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            if !ready { try await Task.sleep(for: .milliseconds(50)) }
        }
        controller.load(sceneJSON: sampleScene(label: "reload"), requestID: requestID)
        for _ in 0..<100 where loadedRequestID == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loadedRequestID == requestID)

        controller.requestCompletion()
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        let payload = try #require(received).get()
        #expect(payload.files["image-1"]?.dataURL.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func firstSceneLoadWaitsForTheDrawingBridgeToBecomeReady() async throws {
        let controller = ExcalidrawViewController()
        let requestID = UUID()
        var loadedRequestID: UUID?
        var received: Result<DrawingExportPayload, Error>?
        controller.onLoaded = { loadedRequestID = $0 }
        controller.onComplete = { received = $0 }

        controller.load(sceneJSON: sceneWithVisibleElement(), requestID: requestID)
        controller.requestCompletion(includeSVG: false)
        controller.loadViewIfNeeded()

        for _ in 0..<200 where loadedRequestID == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loadedRequestID == requestID)

        for _ in 0..<100 where received == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try #require(received).get()
        #expect(payload.scene.json.contains("first-click-shape"))
        #expect(payload.files["image-1"]?.dataURL.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func newDrawingBridgeClearsLoadedSceneAndEmbeddedFiles() async throws {
        let controller = ExcalidrawViewController()
        var loadCount = 0
        var received: Result<DrawingExportPayload, Error>?
        controller.onLoaded = { _ in loadCount += 1 }
        controller.onComplete = { received = $0 }
        controller.loadViewIfNeeded()

        var ready = false
        for _ in 0..<200 where !ready {
            ready = await withCheckedContinuation { continuation in
                controller.evaluateJavaScript("!!window.__slateMemoReset") { value in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            if !ready { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(ready)

        controller.load(sceneJSON: sampleScene(label: "loaded"))
        for _ in 0..<100 where loadCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(loadCount == 1)

        controller.resetScene()
        for _ in 0..<100 where loadCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(loadCount == 2)

        controller.requestCompletion()
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        let payload = try #require(received).get()
        #expect(payload.scene.elementCount == 0)
        #expect(payload.files.isEmpty)
    }

    private func samplePayload(label: String) throws -> DrawingExportPayload {
        let scene = try DrawingScene(json: sampleScene(label: label))
        return try DrawingExportPayload(
            scene: scene,
            svg: """
            <svg xmlns="http://www.w3.org/2000/svg"><title>\(label)</title><image href="data:image/png;base64,iVBORw0KGgo="/></svg>
            """,
            files: ["image-1": sampleFile]
        )
    }

    private func payload(
        elementsJSON: String,
        filesJSON: String,
        appStateJSON: String,
        svg: String? = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"
    ) throws -> DrawingExportPayload {
        let scene = try DrawingScene(json: """
        {
          "type":"excalidraw","version":2,"source":"local",
          "elements":\(elementsJSON),"appState":\(appStateJSON),"files":\(filesJSON)
        }
        """)
        return try DrawingExportPayload(
            scene: scene,
            svg: svg,
            files: [:]
        )
    }

    private func sampleScene(label: String) -> String {
        """
        {
          "type":"excalidraw","version":2,"source":"local",
          "elements":[\(imageElementJSON(index: "a0"))],"appState":{"name":"\(label)"},
          "files":{"image-1":{"id":"image-1","mimeType":"image/png","dataURL":"data:image/png;base64,iVBORw0KGgo=","created":1}}
        }
        """
    }

    private func sceneWithVisibleElement() -> String {
        """
        {
          "type":"excalidraw","version":2,"source":"local",
          "elements":[{
            "id":"first-click-shape","type":"rectangle",
            "x":100,"y":100,"width":160,"height":100,"angle":0,
            "strokeColor":"#1e1e1e","backgroundColor":"transparent",
            "fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid",
            "roughness":1,"opacity":100,"groupIds":[],"frameId":null,
            "index":"a0","roundness":null,"seed":1,"version":1,
            "versionNonce":1,"isDeleted":false,"boundElements":null,
            "updated":1,"link":null,"locked":false
          },\(imageElementJSON(index: "a1"))],
          "appState":{},
          "files":{"image-1":{"id":"image-1","mimeType":"image/png","dataURL":"data:image/png;base64,iVBORw0KGgo=","created":1}}
        }
        """
    }

    private func sceneWithPureElements() -> String {
        sceneJSON(
            elements: """
            [{
              "id":"pure-shape","type":"rectangle",
              "x":100,"y":100,"width":160,"height":100,"angle":0,
              "strokeColor":"#1e1e1e","backgroundColor":"transparent",
              "fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid",
              "roughness":1,"opacity":100,"groupIds":[],"frameId":null,
              "index":"a0","roundness":null,"seed":1,"version":1,
              "versionNonce":1,"isDeleted":false,"boundElements":null,
              "updated":1,"link":null,"locked":false
            }]
            """,
            files: "{}"
        )
    }

    private func sceneJSON(elements: String, files: String?) -> String {
        let filesMember = files.map { ",\"files\":\($0)" } ?? ""
        return """
        {"type":"excalidraw","version":2,"source":"local","elements":\(elements),"appState":{}\(filesMember)}
        """
    }

    private func minimalImageElement(
        id: String,
        fileID: String?,
        isDeleted: Bool = false
    ) -> String {
        let fileIDMember = fileID.map { ",\"fileId\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"type\":\"image\",\"isDeleted\":\(isDeleted)\(fileIDMember)}"
    }

    private func fileJSON(_ file: DrawingFilePayload) -> String {
        """
        {"id":"\(file.id)","mimeType":"\(file.mimeType)","dataURL":"\(file.dataURL)","created":\(file.created ?? 0)}
        """
    }

    private func imageElementJSON(index: String) -> String {
        """
        {
          "id":"embedded-image","type":"image","x":20,"y":20,
          "width":1,"height":1,"angle":0,"strokeColor":"transparent",
          "backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,
          "strokeStyle":"solid","roughness":0,"opacity":100,"groupIds":[],
          "frameId":null,"index":"\(index)","roundness":null,"seed":2,
          "version":1,"versionNonce":2,"isDeleted":false,"boundElements":null,
          "updated":1,"link":null,"locked":false,"fileId":"image-1",
          "scale":[1,1],"status":"saved","crop":null
        }
        """
    }

    private var sampleFile: DrawingFilePayload {
        DrawingFilePayload(
            id: "image-1",
            mimeType: "image/png",
            dataURL: "data:image/png;base64,iVBORw0KGgo=",
            created: 1,
            lastRetrieved: nil
        )
    }

    private func originalImageRequest(
        fileID: String = "file-id_123456789",
        mimeType: String = "image/png",
        bytes: Data = Data([0x00]),
        dataURL: String? = nil
    ) throws -> DrawingOriginalImageRequest {
        let encodedURL = dataURL ?? "data:\(mimeType);base64,\(bytes.base64EncodedString())"
        let object: [String: Any] = [
            "fileId": fileID,
            "mimeType": mimeType,
            "dataURL": encodedURL,
            "clientX": 42.5,
            "clientY": 84.25
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DrawingOriginalImageRequest(
            messageJSON: String(decoding: data, as: UTF8.self)
        )
    }
}
