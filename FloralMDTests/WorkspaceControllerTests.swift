import Foundation
import Testing
@testable import FloralMD

@MainActor
struct WorkspaceControllerTests {
    @Test func repeatedMarkdownImageAndDrawingSwitchesKeepWorkspaceLeaseIndependentFromMonitor() throws {
        try withTemporaryDirectory { root in
            let assets = root.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let png = assets.appendingPathComponent("pixel.png")
            let svg = assets.appendingPathComponent("diagram.svg")
            let first = root.appendingPathComponent("First.md")
            let second = root.appendingPathComponent("Second.md")
            let drawing = root.appendingPathComponent("Board.excalidraw")
            try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )).write(to: png)
            try """
            <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">
              <rect width="1" height="1"/>
            </svg>
            """.write(to: svg, atomically: true, encoding: .utf8)
            try "# First\n\n![PNG](assets/pixel.png)\n\n![SVG](assets/diagram.svg)"
                .write(to: first, atomically: true, encoding: .utf8)
            try "# Second".write(to: second, atomically: true, encoding: .utf8)
            try """
            {"type":"excalidraw","version":2,"source":"https://excalidraw.com","elements":[],"appState":{},"files":{}}
            """.write(to: drawing, atomically: true, encoding: .utf8)

            let authorizationRoot = authorizationURL(for: root)
            var scopeEvents: [String] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    scopeEvents.append("begin:\($0.absoluteString)")
                    return true
                },
                endAccess: { scopeEvents.append("end:\($0.absoluteString)") }
            )
            var controller: WorkspaceController? = try WorkspaceController(
                explicitWorkspaceRoot: authorizationRoot,
                draftRootProvider: { nil },
                securityScopeAccessManager: manager
            )

            for _ in 0..<3 {
                try controller?.selectResource(at: first)
                #expect(controller?.markdownText.contains("assets/pixel.png") == true)
                let firstMonitor = try #require(controller?.activeMarkdownFileMonitorForTesting)
                #expect(!firstMonitor.responds(to: NSSelectorFromString("primaryPresentedItemURL")))
                try expectImageResourcesReadable(
                    controller: try #require(controller),
                    png: png,
                    svg: svg
                )

                try controller?.selectResource(at: second)
                #expect(controller?.markdownText == "# Second")
                let secondMonitor = try #require(controller?.activeMarkdownFileMonitorForTesting)
                #expect(firstMonitor !== secondMonitor)
                #expect(!secondMonitor.responds(to: NSSelectorFromString("primaryPresentedItemURL")))

                try controller?.selectResource(at: drawing)
                #expect(controller?.activeResource?.kind == .drawing)
                #expect(controller?.activeMarkdownFileMonitorForTesting == nil)
                #expect(try Data(contentsOf: drawing).isEmpty == false)
                #expect(scopeEvents == ["begin:\(authorizationRoot.absoluteString)"])
            }

            controller = nil
            #expect(scopeEvents == [
                "begin:\(authorizationRoot.absoluteString)",
                "end:\(authorizationRoot.absoluteString)",
            ])
        }
    }

    @Test func securityScopeUsesOriginalAuthorizationURLAndCanonicalIdentityKey() {
        let canonicalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Capability-\(UUID().uuidString)", isDirectory: true)
        let authorizationRoot = URL(
            fileURLWithPath: canonicalRoot.appendingPathComponent("child/..").path,
            isDirectory: true
        )
        var began: [URL] = []
        var ended: [URL] = []
        let manager = SecurityScopedResourceAccessManager(
            beginAccess: {
                began.append($0)
                return true
            },
            endAccess: { ended.append($0) }
        )

        let bookmarkLease = manager.acquire(authorizationRoot)
        let canonicalLease = manager.acquire(canonicalRoot)

        #expect(began == [authorizationRoot])
        #expect(manager.ownerCount(for: canonicalRoot) == 2)
        canonicalLease.invalidate()
        #expect(ended.isEmpty)
        bookmarkLease.invalidate()
        #expect(ended == [authorizationRoot])
    }

    @Test func controllerRetainsTheOriginalDraftAuthorizationURLForItsLifetime() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Main.md")
            try "authorized".write(to: note, atomically: true, encoding: .utf8)
            let authorizationRoot = URL(
                fileURLWithPath: root.appendingPathComponent("bookmark-marker/..").path,
                isDirectory: true
            )
            var began: [URL] = []
            var ended: [URL] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    began.append($0)
                    return true
                },
                endAccess: { ended.append($0) }
            )

            var controller: WorkspaceController? = try WorkspaceController(
                targetURL: note,
                draftRootProvider: { authorizationRoot },
                securityScopeAccessManager: manager
            )
            #expect(began == [authorizationRoot])
            #expect(controller?.session.rootURL == root.standardizedFileURL)
            #expect(controller?.markdownText == "authorized")
            #expect(manager.ownerCount(for: root) == 1)

            controller = nil
            #expect(ended == [authorizationRoot])
        }
    }

    @Test func explicitWorkspaceAcquiresOriginalAuthorizationBeforeCanonicalizingSession() throws {
        try withTemporaryDirectory { root in
            let authorizationRoot = authorizationURL(for: root)
            var began: [URL] = []
            var ended: [URL] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    began.append($0)
                    return true
                },
                endAccess: { ended.append($0) }
            )

            var controller: WorkspaceController? = try WorkspaceController(
                explicitWorkspaceRoot: authorizationRoot,
                draftRootProvider: { nil },
                securityScopeAccessManager: manager
            )
            #expect(began == [authorizationRoot])
            #expect(controller?.session.kind == .explicitFolder)
            #expect(controller?.session.rootURL == root.standardizedFileURL)

            controller = nil
            #expect(ended == [authorizationRoot])
        }
    }

    @Test func switchingRootsAcquiresNewAuthorizationBeforeReleasingOld() throws {
        try withTemporaryDirectory { container in
            let firstRoot = container.appendingPathComponent("First", isDirectory: true)
            let secondRoot = container.appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            let firstNote = firstRoot.appendingPathComponent("First.md")
            let secondNote = secondRoot.appendingPathComponent("Second.md")
            try "first".write(to: firstNote, atomically: true, encoding: .utf8)
            try "second".write(to: secondNote, atomically: true, encoding: .utf8)
            let firstAuthorization = authorizationURL(for: firstRoot)
            let secondAuthorization = authorizationURL(for: secondRoot)
            var events: [String] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    events.append("begin:\($0.absoluteString)")
                    return true
                },
                endAccess: { events.append("end:\($0.absoluteString)") }
            )
            var controller: WorkspaceController? = try WorkspaceController(
                targetURL: firstNote,
                draftRootProvider: { firstAuthorization },
                securityScopeAccessManager: manager
            )

            try controller?.open(
                targetURL: secondNote,
                authorizationRootURL: secondAuthorization
            )

            #expect(events == [
                "begin:\(firstAuthorization.absoluteString)",
                "begin:\(secondAuthorization.absoluteString)",
                "end:\(firstAuthorization.absoluteString)",
            ])
            #expect(controller?.session.rootURL == secondRoot.standardizedFileURL)
            #expect(controller?.markdownText == "second")
            controller = nil
            #expect(events.last == "end:\(secondAuthorization.absoluteString)")
        }
    }

    @Test func failedRootSwitchReleasesNewAuthorizationAndKeepsOldSession() throws {
        try withTemporaryDirectory { container in
            let firstRoot = container.appendingPathComponent("First", isDirectory: true)
            let secondRoot = container.appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            let firstNote = firstRoot.appendingPathComponent("First.md")
            let missingNote = secondRoot.appendingPathComponent("Missing.md")
            try "first".write(to: firstNote, atomically: true, encoding: .utf8)
            let firstAuthorization = authorizationURL(for: firstRoot)
            let secondAuthorization = authorizationURL(for: secondRoot)
            var events: [String] = []
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: {
                    events.append("begin:\($0.absoluteString)")
                    return true
                },
                endAccess: { events.append("end:\($0.absoluteString)") }
            )
            var controller: WorkspaceController? = try WorkspaceController(
                targetURL: firstNote,
                draftRootProvider: { firstAuthorization },
                securityScopeAccessManager: manager
            )

            #expect(throws: WorkspaceControllerError.self) {
                try controller?.open(
                    targetURL: missingNote,
                    authorizationRootURL: secondAuthorization
                )
            }
            #expect(events == [
                "begin:\(firstAuthorization.absoluteString)",
                "begin:\(secondAuthorization.absoluteString)",
                "end:\(secondAuthorization.absoluteString)",
            ])
            #expect(controller?.session.rootURL == firstRoot.standardizedFileURL)
            #expect(controller?.activeResource?.url == firstNote.standardizedFileURL)
            #expect(controller?.markdownText == "first")
            #expect(manager.ownerCount(for: firstRoot) == 1)
            #expect(manager.ownerCount(for: secondRoot) == 0)

            controller = nil
            #expect(events.last == "end:\(firstAuthorization.absoluteString)")
        }
    }

    @Test func multipleWorkspaceControllersShareOneRootScopeUntilLastClose() throws {
        try withTemporaryDirectory { root in
            let firstNote = root.appendingPathComponent("First.md")
            let secondNote = root.appendingPathComponent("Second.md")
            try "first".write(to: firstNote, atomically: true, encoding: .utf8)
            try "second".write(to: secondNote, atomically: true, encoding: .utf8)
            var beginCount = 0
            var stopCount = 0
            let manager = SecurityScopedResourceAccessManager(
                beginAccess: { _ in
                    beginCount += 1
                    return true
                },
                endAccess: { _ in stopCount += 1 }
            )

            var first: WorkspaceController? = try WorkspaceController(
                targetURL: firstNote,
                draftRootProvider: { root },
                securityScopeAccessManager: manager
            )
            var second: WorkspaceController? = try WorkspaceController(
                targetURL: secondNote,
                draftRootProvider: { root.standardizedFileURL },
                securityScopeAccessManager: manager
            )
            #expect(beginCount == 1)
            #expect(manager.ownerCount(for: root) == 2)

            first = nil
            #expect(stopCount == 0)
            #expect(manager.ownerCount(for: root) == 1)
            #expect(second?.markdownText == "second")

            second = nil
            #expect(stopCount == 1)
            #expect(manager.ownerCount(for: root) == 0)
            _ = first
        }
    }

    @Test func loadsDraftMarkdownAndTracksDirtyStateUntilAtomicSave() throws {
        try withTemporaryDirectory { root in
            let layout = DraftWorkspaceLayout(root: root)
            try layout.prepare()
            let noteURL = layout.notesDirectory.appendingPathComponent("Existing.md")
            try "before".write(to: noteURL, atomically: true, encoding: .utf8)

            let controller = try WorkspaceController(
                targetURL: noteURL,
                draftRootProvider: { root }
            )
            #expect(controller.session.kind == .draft)
            #expect(controller.markdownText == "before")
            #expect(!controller.isMarkdownDirty)

            controller.markdownText = "after"
            #expect(controller.isMarkdownDirty)
            try controller.save()

            #expect(!controller.isMarkdownDirty)
            #expect(try String(contentsOf: noteURL, encoding: .utf8) == "after")
        }
    }

    @Test func switchingResourcesSavesDirtyMarkdownBeforeSelectingReadOnlyImage() throws {
        try withTemporaryDirectory { root in
            let noteURL = root.appendingPathComponent("Note.md")
            let imageURL = root.appendingPathComponent("Image.png")
            try "old".write(to: noteURL, atomically: true, encoding: .utf8)
            try Data([0x89, 0x50]).write(to: imageURL)
            let controller = try WorkspaceController(
                targetURL: noteURL,
                draftRootProvider: { nil }
            )

            controller.markdownText = "saved on switch"
            try controller.selectResource(at: imageURL)

            #expect(try String(contentsOf: noteURL, encoding: .utf8) == "saved on switch")
            #expect(controller.activeResource?.kind == .image)
            #expect(controller.markdownText.isEmpty)
            #expect(!controller.isMarkdownDirty)
        }
    }

    @Test func externalMarkdownWorksWithoutAConfiguredDraftRoot() throws {
        try withTemporaryDirectory { root in
            let noteURL = root.appendingPathComponent("Outside.markdown")
            try "external".write(to: noteURL, atomically: true, encoding: .utf8)

            let controller = try WorkspaceController(
                targetURL: noteURL,
                draftRootProvider: { nil }
            )

            #expect(controller.session.kind == .externalFolder)
            #expect(controller.session.rootURL == root.standardizedFileURL)
            #expect(controller.markdownText == "external")
        }
    }

    @Test func explicitWorkspaceKeepsItsRootWhileSelectingNestedResources() throws {
        try withTemporaryDirectory { root in
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let note = nested.appendingPathComponent("Note.md")
            try "explicit".write(to: note, atomically: true, encoding: .utf8)

            let controller = try WorkspaceController(
                explicitWorkspaceRoot: root,
                draftRootProvider: { nil }
            )
            #expect(controller.canReplaceWithExplicitWorkspace)

            try controller.selectResource(at: note)

            #expect(controller.session.kind == .explicitFolder)
            #expect(controller.session.rootURL == root.standardizedFileURL)
            #expect(controller.activeResource?.url == note.standardizedFileURL)
            #expect(!controller.canReplaceWithExplicitWorkspace)
        }
    }

    @Test func emptyWindowCanSwitchToExplicitWorkspaceButActiveOrDirtyWindowCannot() throws {
        try withTemporaryDirectory { draftRoot in
            try withTemporaryDirectory { explicitRoot in
                let controller = try WorkspaceController(draftRootProvider: { draftRoot })
                #expect(controller.canReplaceWithExplicitWorkspace)

                try controller.openExplicitWorkspace(rootURL: explicitRoot)
                #expect(controller.session.kind == .explicitFolder)
                #expect(controller.session.rootURL == explicitRoot.standardizedFileURL)
                #expect(controller.canReplaceWithExplicitWorkspace)

                let note = explicitRoot.appendingPathComponent("Note.md")
                try "before".write(to: note, atomically: true, encoding: .utf8)
                try controller.selectResource(at: note)
                #expect(!controller.canReplaceWithExplicitWorkspace)

                controller.markdownText = "dirty"
                #expect(controller.isMarkdownDirty)
                #expect(!controller.canReplaceWithExplicitWorkspace)
            }
        }
    }

    @Test func missingExplicitWorkspaceFailsWithoutFallingBackToDraft() throws {
        try withTemporaryDirectory { draftRoot in
            let controller = try WorkspaceController(draftRootProvider: { draftRoot })
            let missing = draftRoot.appendingPathComponent("Missing", isDirectory: true)

            #expect(throws: WorkspaceResolutionError.self) {
                try controller.openExplicitWorkspace(rootURL: missing)
            }
            #expect(controller.session.kind == .draft)
            #expect(controller.session.rootURL == draftRoot.standardizedFileURL)
        }
    }

    @Test func untitledMarkdownUsesDraftNotesAndNeverOverwritesCollision() throws {
        try withTemporaryDirectory { root in
            let layout = DraftWorkspaceLayout(root: root)
            try layout.prepare()
            let now = Date(timeIntervalSince1970: 1_786_406_400)
            let allocator = WorkspaceFilenameAllocator(
                calendar: fixedCalendar
            )
            let collidingURL = allocator.candidate(
                in: layout.notesDirectory,
                pathExtension: "md",
                date: now,
                suffix: 0
            )
            try "keep me".write(to: collidingURL, atomically: true, encoding: .utf8)

            let controller = try WorkspaceController(
                draftRootProvider: { root },
                fileStore: WorkspaceFileStore(filenameAllocator: allocator)
            )
            let createdURL = try controller.createUntitledMarkdown(now: now)

            #expect(createdURL.deletingLastPathComponent() == layout.notesDirectory)
            #expect(createdURL.lastPathComponent.hasSuffix("-1.md"))
            #expect(try String(contentsOf: collidingURL, encoding: .utf8) == "keep me")
            #expect(FileManager.default.fileExists(atPath: createdURL.path))
            #expect(controller.activeResource?.url == createdURL.standardizedFileURL)
        }
    }

    @Test func drawingPlaceholderUsesDraftDrawingsWithoutCreatingAFile() throws {
        try withTemporaryDirectory { root in
            let controller = try WorkspaceController(draftRootProvider: { root })
            let url = try controller.createDrawingPlaceholder(
                now: Date(timeIntervalSince1970: 1_786_406_400)
            )

            #expect(url.deletingLastPathComponent() == DraftWorkspaceLayout(root: root).drawingsDirectory)
            #expect(url.pathExtension == "excalidraw")
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(controller.activeResource?.kind == .drawing)
        }
    }

    @Test func drawingPlaceholderUsesTheActiveSavedMarkdownsLocalDrawingsDirectory() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("notes/Project/Plan.md")
            try FileManager.default.createDirectory(
                at: note.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "# Plan".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(
                targetURL: note,
                draftRootProvider: { root }
            )

            let url = try controller.createDrawingPlaceholder(
                now: Date(timeIntervalSince1970: 1_786_406_400)
            )

            #expect(url.deletingLastPathComponent()
                == note.deletingLastPathComponent().appendingPathComponent("drawings"))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(controller.session.rootURL == root.standardizedFileURL)
            #expect(controller.activeResource?.url == url.standardizedFileURL)
        }
    }

    @Test func drawingPlaceholderFallsBackToDraftDrawingsForANonMarkdownResource() throws {
        try withTemporaryDirectory { root in
            let image = root.appendingPathComponent("notes/Project/Photo.png")
            try FileManager.default.createDirectory(
                at: image.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            let controller = try WorkspaceController(
                targetURL: image,
                draftRootProvider: { root }
            )

            let url = try controller.createDrawingPlaceholder(
                now: Date(timeIntervalSince1970: 1_786_406_400)
            )

            #expect(url.deletingLastPathComponent()
                == DraftWorkspaceLayout(root: root).drawingsDirectory)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func externalSavedMarkdownUsesItsLocalDrawingsWithoutAConfiguredDraft() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("External/Plan.md")
            try FileManager.default.createDirectory(
                at: note.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "# Plan".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(
                targetURL: note,
                draftRootProvider: { nil }
            )

            let url = try controller.createDrawingPlaceholder(
                now: Date(timeIntervalSince1970: 1_786_406_400)
            )

            #expect(url.deletingLastPathComponent()
                == note.deletingLastPathComponent().appendingPathComponent("drawings"))
            #expect(controller.session.kind == .externalFolder)
            #expect(controller.session.rootURL == note.deletingLastPathComponent())
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func externalNonMarkdownResourceFallsBackToTheConfiguredDraftWorkspace() throws {
        try withTemporaryDirectory { root in
            let draft = root.appendingPathComponent("Draft", isDirectory: true)
            let image = root.appendingPathComponent("External/Photo.png")
            try FileManager.default.createDirectory(
                at: image.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            let controller = try WorkspaceController(
                targetURL: image,
                draftRootProvider: { draft }
            )

            let url = try controller.createDrawingPlaceholder(
                now: Date(timeIntervalSince1970: 1_786_406_400)
            )

            #expect(url.deletingLastPathComponent()
                == DraftWorkspaceLayout(root: draft).drawingsDirectory)
            #expect(controller.session.kind == .draft)
            #expect(controller.session.rootURL == draft.standardizedFileURL)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func aDrawingPlaceholderSkipsAnExistingNameWithoutChangingIt() throws {
        try withTemporaryDirectory { root in
            let layout = DraftWorkspaceLayout(root: root)
            try FileManager.default.createDirectory(
                at: layout.drawingsDirectory,
                withIntermediateDirectories: true
            )
            let now = Date(timeIntervalSince1970: 1_786_406_400)
            let allocator = WorkspaceFilenameAllocator(calendar: fixedCalendar)
            let existingURL = allocator.candidate(
                in: layout.drawingsDirectory,
                pathExtension: "excalidraw",
                date: now,
                suffix: 0
            )
            try "existing drawing".write(to: existingURL, atomically: true, encoding: .utf8)
            let store = WorkspaceFileStore(filenameAllocator: allocator)

            let placeholder = try store.drawingPlaceholderURL(
                in: layout.drawingsDirectory,
                now: now
            )

            #expect(placeholder.lastPathComponent.hasSuffix("-1.excalidraw"))
            #expect(!FileManager.default.fileExists(atPath: placeholder.path))
            #expect(try String(contentsOf: existingURL, encoding: .utf8) == "existing drawing")
        }
    }

    @Test func failedOpenPublishesALocalizedErrorAndKeepsCurrentSelection() throws {
        try withTemporaryDirectory { root in
            let noteURL = root.appendingPathComponent("Note.md")
            try "safe".write(to: noteURL, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(
                targetURL: noteURL,
                draftRootProvider: { root }
            )
            let missingURL = root.appendingPathComponent("Missing.md")

            #expect(throws: (any Error).self) {
                try controller.open(targetURL: missingURL)
            }
            #expect(controller.errorMessage?.contains("Missing.md") == true)
            #expect(controller.activeResource?.url == noteURL.standardizedFileURL)
            #expect(controller.markdownText == "safe")
        }
    }

    @Test func untitledWithoutDraftRootFailsWithLocalizedError() throws {
        try withTemporaryDirectory { root in
            let noteURL = root.appendingPathComponent("Note.md")
            try "safe".write(to: noteURL, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(
                targetURL: noteURL,
                draftRootProvider: { nil }
            )

            #expect(throws: WorkspaceControllerError.self) {
                try controller.createUntitledMarkdown()
            }
            #expect(controller.errorMessage == "尚未设置 FloralMD Drafts 文件夹。")
        }
    }

    @Test func externalRenameRebindsDirtyMarkdownBeforeSaving() throws {
        try withTemporaryDirectory { root in
            let original = root.appendingPathComponent("Before.md")
            let renamed = root.appendingPathComponent("After.md")
            try "before".write(to: original, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: original, draftRootProvider: { root })
            controller.markdownText = "dirty text"

            try FileManager.default.moveItem(at: original, to: renamed)
            controller.reconcileExternalChanges(with: try WorkspaceFileCatalog().entries(in: root))

            #expect(controller.activeResource?.url == renamed.standardizedFileURL)
            #expect(controller.activePathState == .movedExternally(
                from: original.standardizedFileURL,
                to: renamed.standardizedFileURL
            ))
            try controller.save()
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "dirty text")
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func externalDeletionBlocksDirtyMarkdownSave() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Deleted.md")
            try "before".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })
            controller.markdownText = "must not be recreated"

            try FileManager.default.removeItem(at: note)
            controller.reconcileExternalChanges(with: try WorkspaceFileCatalog().entries(in: root))

            #expect(controller.activePathState == .missingExternally(note.standardizedFileURL))
            #expect(throws: WorkspaceControllerError.self) { try controller.save() }
            #expect(!FileManager.default.fileExists(atPath: note.path))
            #expect(controller.markdownText == "must not be recreated")
        }
    }

    @Test func cleanExternalChangeReloadsWhileDirtyChangeRequiresChoice() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Live.md")
            try "one".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })

            try "two".write(to: note, atomically: true, encoding: .utf8)
            controller.checkForExternalMarkdownChanges(suggestedURL: note)
            #expect(controller.markdownText == "two")
            #expect(controller.externalMarkdownState == .updatedFromDisk(note.standardizedFileURL))
            #expect(!controller.isMarkdownDirty)

            controller.markdownText = "two local"
            #expect(controller.externalMarkdownState == .none)
            try controller.autosave()
            #expect(try String(contentsOf: note, encoding: .utf8) == "two local")

            controller.markdownText = "local edits"
            try "three".write(to: note, atomically: true, encoding: .utf8)
            controller.checkForExternalMarkdownChanges(suggestedURL: note)
            #expect(controller.markdownText == "local edits")
            #expect(controller.externalMarkdownState == .conflict(note.standardizedFileURL))
            #expect(controller.isMarkdownDirty)

            controller.loadExternalMarkdownVersion()
            #expect(controller.markdownText == "three")
            #expect(!controller.isMarkdownDirty)
        }
    }

    @Test func keepingDirtyVersionPausesAutosaveUntilExplicitSave() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Divergent.md")
            try "disk one".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })
            controller.markdownText = "local version"
            try "disk two".write(to: note, atomically: true, encoding: .utf8)
            controller.checkForExternalMarkdownChanges(suggestedURL: note)

            controller.keepCurrentMarkdownVersion()
            #expect(controller.externalMarkdownState == .divergent(note.standardizedFileURL))
            try controller.autosave()
            #expect(try String(contentsOf: note, encoding: .utf8) == "disk two")
            #expect(controller.isMarkdownDirty)
            #expect(throws: WorkspaceControllerError.self) {
                try controller.saveBeforeClosingIfNeeded()
            }

            try controller.save()
            #expect(try String(contentsOf: note, encoding: .utf8) == "local version")
            #expect(controller.externalMarkdownState == .none)
        }
    }

    @Test func ownAtomicSaveAndSoftEquivalentRewriteDoNotEcho() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Echo.md")
            try "alpha\n".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })
            controller.markdownText = "beta\n"
            try controller.save()
            controller.checkForExternalMarkdownChanges(suggestedURL: note)
            #expect(controller.externalMarkdownState == .none)

            try "\u{feff}beta\r\n".write(to: note, atomically: true, encoding: .utf8)
            controller.checkForExternalMarkdownChanges(suggestedURL: note)
            #expect(controller.markdownText == "beta\n")
            #expect(controller.externalMarkdownState == .none)
        }
    }

    @Test func atomicReplacementAndBurstConvergeToFinalDiskState() throws {
        try withTemporaryDirectory { root in
            let note = root.appendingPathComponent("Atomic.md")
            try "zero".write(to: note, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: note, draftRootProvider: { root })

            for content in ["one", "two", "final"] {
                let replacement = root.appendingPathComponent(".Atomic.tmp")
                try? FileManager.default.removeItem(at: replacement)
                try content.write(to: replacement, atomically: true, encoding: .utf8)
                _ = try FileManager.default.replaceItemAt(note, withItemAt: replacement)
            }
            controller.checkForExternalMarkdownChanges(suggestedURL: note)
            #expect(controller.markdownText == "final")
            #expect(!controller.isMarkdownDirty)
        }
    }

    @Test func externalRenameDeleteAndOldDocumentEventsStayScopedToActiveMarkdown() throws {
        try withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First.md")
            let renamed = root.appendingPathComponent("Renamed.md")
            let second = root.appendingPathComponent("Second.md")
            try "first".write(to: first, atomically: true, encoding: .utf8)
            try "second".write(to: second, atomically: true, encoding: .utf8)
            let controller = try WorkspaceController(targetURL: first, draftRootProvider: { root })

            try FileManager.default.moveItem(at: first, to: renamed)
            controller.checkForExternalMarkdownChanges(suggestedURL: renamed)
            #expect(controller.activeResource?.url == renamed.standardizedFileURL)

            try controller.selectResource(at: second)
            try "stale event".write(to: renamed, atomically: true, encoding: .utf8)
            controller.checkForExternalMarkdownChanges(suggestedURL: renamed)
            #expect(controller.activeResource?.url == second.standardizedFileURL)
            #expect(controller.markdownText == "second")

            try FileManager.default.removeItem(at: second)
            controller.checkForExternalMarkdownChanges(suggestedURL: second)
            #expect(controller.activePathState == .missingExternally(second.standardizedFileURL))
            #expect(controller.markdownText == "second")
        }
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func authorizationURL(for root: URL) -> URL {
        URL(
            fileURLWithPath: root.appendingPathComponent("bookmark-marker/..").path,
            isDirectory: true
        )
    }

    private func expectImageResourcesReadable(
        controller: WorkspaceController,
        png: URL,
        svg: URL
    ) throws {
        let context = try #require(MarkdownLocalResourceContext(
            session: controller.session,
            documentURL: controller.activeResource?.url
        ))
        let handler = MarkdownLocalResourceSchemeHandler()
        let baseURL = try #require(handler.register(context))
        let pngURL = try #require(URL(string: "assets/pixel.png", relativeTo: baseURL)?.absoluteURL)
        let svgURL = try #require(URL(string: "assets/diagram.svg", relativeTo: baseURL)?.absoluteURL)

        #expect(try handler.resolvedResource(for: pngURL).fileURL == png.standardizedFileURL)
        #expect(try handler.resolvedResource(for: svgURL).fileURL == svg.standardizedFileURL)
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-WorkspaceController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
