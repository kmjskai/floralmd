import Combine
import Foundation

enum RecentWorkspaceResourceAccessState: Equatable {
    case available
    case needsAuthorization
    case missing
}

struct RecentWorkspaceResourceRecord: Codable, Equatable, Identifiable {
    let resourcePath: String
    let resourceKindRawValue: String
    let workspaceRootPath: String
    let workspaceKindRawValue: String
    let lastOpenedAt: Date

    var id: String { resourcePath }

    var resourceURL: URL {
        URL(fileURLWithPath: resourcePath, isDirectory: false).standardizedFileURL
    }

    var workspaceRootURL: URL {
        URL(fileURLWithPath: workspaceRootPath, isDirectory: true).standardizedFileURL
    }

    var resourceKind: ResourceKind? {
        ResourceKind(rawValue: resourceKindRawValue)
    }

    var workspaceKind: WorkspaceKind? {
        switch workspaceKindRawValue {
        case "draft": .draft
        case "externalFolder": .externalFolder
        case "explicitFolder": .explicitFolder
        default: nil
        }
    }

    init(resource: ActiveResource, session: WorkspaceSession, lastOpenedAt: Date) {
        resourcePath = resource.url.standardizedFileURL.path
        resourceKindRawValue = resource.kind.rawValue
        workspaceRootPath = session.rootURL.standardizedFileURL.path
        workspaceKindRawValue = switch session.kind {
        case .draft: "draft"
        case .externalFolder: "externalFolder"
        case .explicitFolder: "explicitFolder"
        }
        self.lastOpenedAt = lastOpenedAt
    }
}

struct RecentWorkspaceResourceItem: Equatable, Identifiable {
    let record: RecentWorkspaceResourceRecord
    let accessState: RecentWorkspaceResourceAccessState
    let showsRelativePath: Bool

    var id: String { record.id }
    var resourceURL: URL { record.resourceURL }
    var workspaceRootURL: URL { record.workspaceRootURL }
    var resourceKind: ResourceKind { record.resourceKind ?? .markdown }
    var resourceName: String { resourceURL.deletingPathExtension().lastPathComponent }
    var workspaceName: String { workspaceRootURL.lastPathComponent }

    var relativePath: String {
        let rootComponents = workspaceRootURL.pathComponents
        let resourceComponents = resourceURL.pathComponents
        guard resourceComponents.starts(with: rootComponents) else {
            return resourceURL.lastPathComponent
        }
        return resourceComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

struct RecentWorkspaceResourcePanel: Equatable {
    static let empty = RecentWorkspaceResourcePanel(currentWorkspace: [], otherWorkspaces: [])

    let currentWorkspace: [RecentWorkspaceResourceItem]
    let otherWorkspaces: [RecentWorkspaceResourceItem]

    var isEmpty: Bool { currentWorkspace.isEmpty && otherWorkspaces.isEmpty }
}

@MainActor
final class RecentWorkspaceResourceStore: ObservableObject {
    static let shared = RecentWorkspaceResourceStore()

    private enum DefaultsKey {
        static let records = "RecentWorkspaceResourceRecords"
    }

    static let panelLimit = 5
    private static let storageLimit = 50

    @Published private(set) var records: [RecentWorkspaceResourceRecord]

    private let defaults: UserDefaults
    private let defaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String? = nil
    ) {
        let resolvedDefaultsKey = defaultsKey ?? DefaultsKey.records
        self.defaults = defaults
        self.defaultsKey = resolvedDefaultsKey
        if let data = defaults.data(forKey: resolvedDefaultsKey),
           let decoded = try? JSONDecoder().decode([RecentWorkspaceResourceRecord].self, from: data) {
            records = decoded
                .filter { $0.resourceKind == .markdown || $0.resourceKind == .drawing }
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        } else {
            records = []
        }
    }

    func record(_ resource: ActiveResource, in session: WorkspaceSession, at date: Date = Date()) {
        guard resource.kind == .markdown || resource.kind == .drawing else { return }
        let next = RecentWorkspaceResourceRecord(
            resource: resource,
            session: session,
            lastOpenedAt: date
        )
        records.removeAll { $0.resourcePath == next.resourcePath }
        records.insert(next, at: 0)
        if records.count > Self.storageLimit {
            records.removeLast(records.count - Self.storageLimit)
        }
        persist()
    }

    func remove(_ record: RecentWorkspaceResourceRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    func clear() {
        records = []
        defaults.removeObject(forKey: defaultsKey)
    }

    func makePanel(
        currentWorkspaceRoot: URL,
        accessState: (RecentWorkspaceResourceRecord) -> RecentWorkspaceResourceAccessState
    ) -> RecentWorkspaceResourcePanel {
        let currentRoot = currentWorkspaceRoot.standardizedFileURL
        var current: [(RecentWorkspaceResourceRecord, RecentWorkspaceResourceAccessState)] = []
        var other: [(RecentWorkspaceResourceRecord, RecentWorkspaceResourceAccessState)] = []
        var missingIDs = Set<String>()

        for record in records.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) {
            let state = accessState(record)
            if state == .missing {
                missingIDs.insert(record.id)
                continue
            }
            if record.workspaceRootURL == currentRoot {
                current.append((record, state))
            } else {
                other.append((record, state))
            }
        }

        if !missingIDs.isEmpty {
            records.removeAll { missingIDs.contains($0.id) }
            persist()
        }

        let limited = Array((current + other).prefix(Self.panelLimit))
        let duplicateNames = Dictionary(grouping: limited, by: {
            $0.0.resourceURL.lastPathComponent.localizedLowercase
        }).filter { $0.value.count > 1 }.keys

        func item(
            _ value: (RecentWorkspaceResourceRecord, RecentWorkspaceResourceAccessState)
        ) -> RecentWorkspaceResourceItem {
            RecentWorkspaceResourceItem(
                record: value.0,
                accessState: value.1,
                showsRelativePath: duplicateNames.contains(
                    value.0.resourceURL.lastPathComponent.localizedLowercase
                )
            )
        }

        return RecentWorkspaceResourcePanel(
            currentWorkspace: limited
                .filter { $0.0.workspaceRootURL == currentRoot }
                .map(item),
            otherWorkspaces: limited
                .filter { $0.0.workspaceRootURL != currentRoot }
                .map(item)
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
