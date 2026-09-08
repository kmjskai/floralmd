import Foundation

enum WorkspaceKind: Equatable, Sendable {
    case draft
    case externalFolder
    case explicitFolder
}

struct WorkspaceWindowState: Codable, Hashable, Sendable {
    let explicitWorkspacePath: String

    init(explicitWorkspaceURL: URL) {
        explicitWorkspacePath = explicitWorkspaceURL.standardizedFileURL.path
    }

    var explicitWorkspaceURL: URL {
        URL(fileURLWithPath: explicitWorkspacePath, isDirectory: true).standardizedFileURL
    }
}

enum ResourceKind: String, CaseIterable, Equatable, Sendable {
    case markdown
    case drawing
    case image

    nonisolated static func resolve(url: URL) -> ResourceKind? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown":
            .markdown
        case "excalidraw":
            .drawing
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            .image
        default:
            nil
        }
    }
}

struct ActiveResource: Identifiable, Equatable, Sendable {
    let url: URL
    let kind: ResourceKind

    var id: URL { url.standardizedFileURL }

    init?(url: URL) {
        guard let kind = ResourceKind.resolve(url: url) else { return nil }
        self.url = url.standardizedFileURL
        self.kind = kind
    }
}

struct DraftWorkspaceLayout: Equatable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var notesDirectory: URL {
        root.appendingPathComponent("notes", isDirectory: true)
    }

    var notesAssetsDirectory: URL {
        notesDirectory.appendingPathComponent("assets", isDirectory: true)
    }

    var markdownImagesDirectory: URL {
        notesAssetsDirectory.appendingPathComponent("images", isDirectory: true)
    }

    var drawingsDirectory: URL {
        root.appendingPathComponent("drawings", isDirectory: true)
    }

    var requiredDirectories: [URL] {
        [
            notesDirectory,
            markdownImagesDirectory,
            drawingsDirectory
        ]
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in requiredDirectories {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}

struct WorkspaceSession: Equatable, Sendable {
    let rootURL: URL
    let kind: WorkspaceKind
    var activeResource: ActiveResource?

    init(rootURL: URL, kind: WorkspaceKind, activeResource: ActiveResource?) {
        self.rootURL = rootURL.standardizedFileURL
        self.kind = kind
        self.activeResource = activeResource
    }

    mutating func select(_ resource: ActiveResource) {
        precondition(
            WorkspaceResolver.contains(resource.url, in: rootURL),
            "The active resource must remain inside its workspace"
        )
        activeResource = resource
    }
}

enum WorkspaceResolutionError: LocalizedError, Equatable {
    case unsupportedResource(URL)
    case workspaceUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedResource(let url):
            "不支持打开“\(url.lastPathComponent)”。"
        case .workspaceUnavailable(let url):
            "无法读取工作区“\(url.lastPathComponent)”。该文件夹可能已被移动、删除或授权已失效。"
        }
    }
}

enum WorkspaceResolver {
    static func explicitWorkspace(rootURL: URL) -> WorkspaceSession {
        WorkspaceSession(
            rootURL: rootURL.standardizedFileURL,
            kind: .explicitFolder,
            activeResource: nil
        )
    }

    static func resolve(
        draftRoot: URL,
        targetURL: URL?
    ) throws -> WorkspaceSession {
        let standardizedDraftRoot = draftRoot.standardizedFileURL
        guard let targetURL else {
            return WorkspaceSession(
                rootURL: standardizedDraftRoot,
                kind: .draft,
                activeResource: nil
            )
        }

        guard let resource = ActiveResource(url: targetURL) else {
            throw WorkspaceResolutionError.unsupportedResource(targetURL)
        }

        if contains(resource.url, in: standardizedDraftRoot) {
            return WorkspaceSession(
                rootURL: standardizedDraftRoot,
                kind: .draft,
                activeResource: resource
            )
        }

        return WorkspaceSession(
            rootURL: resource.url.deletingLastPathComponent(),
            kind: .externalFolder,
            activeResource: resource
        )
    }

    static func contains(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
    }
}
