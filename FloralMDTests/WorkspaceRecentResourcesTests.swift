import Foundation
import Testing
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct WorkspaceRecentResourcesTests {
    @Test func recordsOnlyMarkdownAndDrawingsInMostRecentOrder() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentWorkspaceResourceStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/Recent-Current", isDirectory: true)
        var session = WorkspaceSession(rootURL: root, kind: .explicitFolder, activeResource: nil)

        for index in 0..<6 {
            let resource = try #require(ActiveResource(
                url: root.appendingPathComponent("Note-\(index).md")
            ))
            session.activeResource = resource
            store.record(resource, in: session, at: Date(timeIntervalSince1970: Double(index)))
        }
        let image = try #require(ActiveResource(url: root.appendingPathComponent("Image.png")))
        store.record(image, in: session, at: Date(timeIntervalSince1970: 100))

        let panel = store.makePanel(currentWorkspaceRoot: root) { _ in .available }

        #expect(panel.currentWorkspace.map(\.resourceName) == [
            "Note-5", "Note-4", "Note-3", "Note-2", "Note-1"
        ])
        #expect(panel.otherWorkspaces.isEmpty)
        #expect(store.records.count == 6)
    }

    @Test func groupsCurrentWorkspaceFirstAndFillsTheFiveItemLimitFromOthers() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentWorkspaceResourceStore(defaults: defaults)
        let currentRoot = URL(fileURLWithPath: "/tmp/Recent-Current", isDirectory: true)
        let otherRoot = URL(fileURLWithPath: "/tmp/Recent-Other", isDirectory: true)

        for index in 0..<3 {
            let resource = try #require(ActiveResource(
                url: otherRoot.appendingPathComponent("Other-\(index).excalidraw")
            ))
            store.record(
                resource,
                in: WorkspaceSession(
                    rootURL: otherRoot,
                    kind: .explicitFolder,
                    activeResource: resource
                ),
                at: Date(timeIntervalSince1970: Double(100 + index))
            )
        }
        for index in 0..<3 {
            let resource = try #require(ActiveResource(
                url: currentRoot.appendingPathComponent("Current-\(index).md")
            ))
            store.record(
                resource,
                in: WorkspaceSession(
                    rootURL: currentRoot,
                    kind: .draft,
                    activeResource: resource
                ),
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        let panel = store.makePanel(currentWorkspaceRoot: currentRoot) { _ in .available }

        #expect(panel.currentWorkspace.map(\.resourceName) == [
            "Current-2", "Current-1", "Current-0"
        ])
        #expect(panel.otherWorkspaces.map(\.resourceName) == ["Other-2", "Other-1"])
    }

    @Test func duplicateNamesShowRelativePathsButUniqueNamesDoNot() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentWorkspaceResourceStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/Recent-Duplicates", isDirectory: true)

        for (index, relativePath) in ["notes/Plan.md", "archive/Plan.md", "notes/Unique.md"].enumerated() {
            let resource = try #require(ActiveResource(
                url: root.appendingPathComponent(relativePath)
            ))
            store.record(
                resource,
                in: WorkspaceSession(rootURL: root, kind: .explicitFolder, activeResource: resource),
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        let items = store.makePanel(currentWorkspaceRoot: root) { _ in .available }.currentWorkspace
        let plans = items.filter { $0.resourceName == "Plan" }
        let unique = try #require(items.first { $0.resourceName == "Unique" })

        #expect(plans.allSatisfy { $0.showsRelativePath })
        #expect(Set(plans.map(\.relativePath)) == ["notes/Plan.md", "archive/Plan.md"])
        #expect(!unique.showsRelativePath)
    }

    @Test func removesConfirmedMissingItemsButKeepsAuthorizationFailures() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentWorkspaceResourceStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/Recent-Access", isDirectory: true)
        let missing = try #require(ActiveResource(url: root.appendingPathComponent("Missing.md")))
        let locked = try #require(ActiveResource(url: root.appendingPathComponent("Locked.excalidraw")))
        let session = WorkspaceSession(rootURL: root, kind: .externalFolder, activeResource: nil)
        store.record(missing, in: session, at: Date(timeIntervalSince1970: 1))
        store.record(locked, in: session, at: Date(timeIntervalSince1970: 2))

        let panel = store.makePanel(
            currentWorkspaceRoot: URL(fileURLWithPath: "/tmp/Other", isDirectory: true)
        ) { record in
            record.resourceURL == missing.url ? .missing : .needsAuthorization
        }

        #expect(panel.otherWorkspaces.count == 1)
        #expect(panel.otherWorkspaces.first?.resourceURL == locked.url)
        #expect(panel.otherWorkspaces.first?.accessState == .needsAuthorization)
        #expect(store.records.map(\.resourceURL) == [locked.url])
    }

    @Test func clearRemovesPersistedRecentRecords() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = URL(fileURLWithPath: "/tmp/Recent-Clear", isDirectory: true)
        let resource = try #require(ActiveResource(url: root.appendingPathComponent("Note.md")))
        let session = WorkspaceSession(rootURL: root, kind: .draft, activeResource: resource)
        let store = RecentWorkspaceResourceStore(defaults: defaults)
        store.record(resource, in: session)

        store.clear()
        let restored = RecentWorkspaceResourceStore(defaults: defaults)

        #expect(store.records.isEmpty)
        #expect(restored.records.isEmpty)
    }

    @Test func markdownPageBoundaryNeverAppliesToDrawingOrImageSurfaces() {
        #expect(WorkspaceSurfacePresentation.resolve(activeKind: .markdown).showsMarkdownPageBoundary)
        #expect(!WorkspaceSurfacePresentation.resolve(activeKind: .drawing).showsMarkdownPageBoundary)
        #expect(!WorkspaceSurfacePresentation.resolve(activeKind: .image).showsMarkdownPageBoundary)
        #expect(!WorkspaceSurfacePresentation.resolve(activeKind: nil).showsMarkdownPageBoundary)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WorkspaceRecentResourcesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
