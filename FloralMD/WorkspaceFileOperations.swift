import Foundation

enum WorkspaceFileOperationRequest: Equatable {
    case createMarkdown(parentURL: URL, name: String)
    case createDirectory(parentURL: URL, name: String)
    case rename(itemURL: URL, name: String)
    case duplicate(itemURL: URL)
    case copy(itemURL: URL, destinationDirectoryURL: URL)
    case move(itemURL: URL, destinationDirectoryURL: URL)
    case importFile(sourceURL: URL, destinationDirectoryURL: URL)
    case trash(itemURL: URL)
}

struct WorkspaceFileOperationResult: Equatable {
    let createdURL: URL?
    let relocatedItem: (from: URL, to: URL)?
    let removedItemURL: URL?

    static let none = WorkspaceFileOperationResult(
        createdURL: nil,
        relocatedItem: nil,
        removedItemURL: nil
    )

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.createdURL == rhs.createdURL
            && lhs.relocatedItem?.from == rhs.relocatedItem?.from
            && lhs.relocatedItem?.to == rhs.relocatedItem?.to
            && lhs.removedItemURL == rhs.removedItemURL
    }
}

enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case outsideWorkspace(URL)
    case cannotOperateOnRoot
    case emptyName
    case invalidName
    case invalidMarkdownExtension
    case itemAlreadyExists(String)
    case itemMissing(URL)
    case destinationIsDescendant
    case crossVolumeMoveUnsupported
    case activeDrawingRequiresSave

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace:
            "文件操作只能在当前工作区内进行。"
        case .cannotOperateOnRoot:
            "不能移动、重命名或删除当前工作区根目录。"
        case .emptyName:
            "名称不能为空。"
        case .invalidName:
            "名称不能包含“/”“:”或 NUL 字符。"
        case .invalidMarkdownExtension:
            "Markdown 文件必须使用 .md、.markdown 或 .mdown 扩展名。"
        case .itemAlreadyExists(let name):
            "“\(name)”已经存在；FloralMD 不会覆盖它。"
        case .itemMissing(let url):
            "找不到“\(url.lastPathComponent)”，请刷新后重试。"
        case .destinationIsDescendant:
            "不能把文件夹移动到它自身或其子目录中。"
        case .crossVolumeMoveUnsupported:
            "FloralMD 不会用复制后删除来伪装跨卷移动；请先复制并确认，再手动处理原文件。"
        case .activeDrawingRequiresSave:
            "请先保存并切换离开当前绘图，再移动、重命名或删除它。"
        }
    }
}

struct WorkspaceFileOperationService {
    typealias TrashAction = (URL) throws -> Void

    private let fileManager: FileManager
    private let trashAction: TrashAction

    init(
        fileManager: FileManager = .default,
        trashAction: TrashAction? = nil
    ) {
        self.fileManager = fileManager
        self.trashAction = trashAction ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func perform(
        _ request: WorkspaceFileOperationRequest,
        workspaceRootURL: URL
    ) throws -> WorkspaceFileOperationResult {
        switch request {
        case .createMarkdown(let parentURL, let name):
            let parent = try validatedDirectory(parentURL, root: workspaceRootURL)
            let destination = try destinationURL(parent: parent, name: name)
            guard ResourceKind.resolve(url: destination) == .markdown else {
                throw WorkspaceFileOperationError.invalidMarkdownExtension
            }
            try Data().write(to: destination, options: .withoutOverwriting)
            return WorkspaceFileOperationResult(
                createdURL: destination,
                relocatedItem: nil,
                removedItemURL: nil
            )
        case .createDirectory(let parentURL, let name):
            let parent = try validatedDirectory(parentURL, root: workspaceRootURL)
            let destination = try destinationURL(parent: parent, name: name)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return WorkspaceFileOperationResult(
                createdURL: destination,
                relocatedItem: nil,
                removedItemURL: nil
            )
        case .rename(let itemURL, let name):
            let item = try validatedItem(itemURL, root: workspaceRootURL)
            let destination = try destinationURL(
                parent: item.deletingLastPathComponent(),
                name: name,
                allowingExistingItem: item
            )
            try relocate(item, to: destination)
            return WorkspaceFileOperationResult(
                createdURL: nil,
                relocatedItem: (item, destination),
                removedItemURL: nil
            )
        case .duplicate(let itemURL):
            let item = try validatedItem(itemURL, root: workspaceRootURL)
            let destination = availableDuplicateURL(for: item)
            try fileManager.copyItem(at: item, to: destination)
            return WorkspaceFileOperationResult(
                createdURL: destination,
                relocatedItem: nil,
                removedItemURL: nil
            )
        case .copy(let itemURL, let destinationDirectoryURL):
            let item = try validatedItem(itemURL, root: workspaceRootURL)
            let destinationDirectory = try validatedDirectory(
                destinationDirectoryURL,
                root: workspaceRootURL
            )
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw WorkspaceFileOperationError.itemAlreadyExists(destination.lastPathComponent)
            }
            try fileManager.copyItem(at: item, to: destination)
            return WorkspaceFileOperationResult(
                createdURL: destination,
                relocatedItem: nil,
                removedItemURL: nil
            )
        case .move(let itemURL, let destinationDirectoryURL):
            let item = try validatedItem(itemURL, root: workspaceRootURL)
            let destinationDirectory = try validatedDirectory(
                destinationDirectoryURL,
                root: workspaceRootURL
            )
            if WorkspaceResolver.contains(destinationDirectory, in: item) {
                throw WorkspaceFileOperationError.destinationIsDescendant
            }
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw WorkspaceFileOperationError.itemAlreadyExists(destination.lastPathComponent)
            }
            guard WorkspaceFileVolumePolicy.allowsMove(
                sourceVolumeIdentifier: volumeIdentifier(for: item),
                destinationVolumeIdentifier: volumeIdentifier(for: destinationDirectory)
            ) else {
                throw WorkspaceFileOperationError.crossVolumeMoveUnsupported
            }
            try relocate(item, to: destination)
            return WorkspaceFileOperationResult(
                createdURL: nil,
                relocatedItem: (item, destination),
                removedItemURL: nil
            )
        case .importFile(let sourceURL, let destinationDirectoryURL):
            let source = sourceURL.standardizedFileURL
            guard !WorkspaceResolver.contains(source, in: workspaceRootURL.standardizedFileURL) else {
                return try perform(
                    .copy(itemURL: source, destinationDirectoryURL: destinationDirectoryURL),
                    workspaceRootURL: workspaceRootURL
                )
            }
            guard fileManager.fileExists(atPath: source.path) else {
                throw WorkspaceFileOperationError.itemMissing(source)
            }
            let destinationDirectory = try validatedDirectory(
                destinationDirectoryURL,
                root: workspaceRootURL
            )
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw WorkspaceFileOperationError.itemAlreadyExists(destination.lastPathComponent)
            }
            try fileManager.copyItem(at: source, to: destination)
            return WorkspaceFileOperationResult(
                createdURL: destination,
                relocatedItem: nil,
                removedItemURL: nil
            )
        case .trash(let itemURL):
            let item = try validatedItem(itemURL, root: workspaceRootURL)
            try trashAction(item)
            return WorkspaceFileOperationResult(
                createdURL: nil,
                relocatedItem: nil,
                removedItemURL: item
            )
        }
    }

    func suggestedMarkdownURL(in parentURL: URL) -> URL {
        availableURL(parent: parentURL, baseName: "未命名", pathExtension: "md")
    }

    func suggestedDirectoryURL(in parentURL: URL) -> URL {
        availableURL(parent: parentURL, baseName: "新建文件夹", pathExtension: nil)
    }

    private func validatedItem(_ url: URL, root: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard standardized != standardizedRoot else {
            throw WorkspaceFileOperationError.cannotOperateOnRoot
        }
        guard WorkspaceResolver.contains(standardized, in: standardizedRoot) else {
            throw WorkspaceFileOperationError.outsideWorkspace(standardized)
        }
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw WorkspaceFileOperationError.itemMissing(standardized)
        }
        return standardized
    }

    private func validatedDirectory(_ url: URL, root: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard WorkspaceResolver.contains(standardized, in: root.standardizedFileURL) else {
            throw WorkspaceFileOperationError.outsideWorkspace(standardized)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceFileOperationError.itemMissing(standardized)
        }
        return standardized
    }

    private func destinationURL(
        parent: URL,
        name: String,
        allowingExistingItem: URL? = nil
    ) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceFileOperationError.emptyName }
        guard !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            throw WorkspaceFileOperationError.invalidName
        }
        let destination = parent.appendingPathComponent(trimmed).standardizedFileURL
        if let allowingExistingItem,
           sameFilesystemItem(destination, allowingExistingItem.standardizedFileURL) {
            return destination
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.itemAlreadyExists(trimmed)
        }
        return destination
    }

    private func relocate(_ source: URL, to destination: URL) throws {
        guard source != destination else { return }
        if sameFilesystemItem(source, destination) {
            let temporary = availableURL(
                parent: source.deletingLastPathComponent(),
                baseName: ".floralmd-case-rename-\(UUID().uuidString)",
                pathExtension: nil
            )
            try fileManager.moveItem(at: source, to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.moveItem(at: temporary, to: source)
                throw error
            }
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private func sameFilesystemItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard fileManager.fileExists(atPath: lhs.path),
              fileManager.fileExists(atPath: rhs.path) else { return false }
        return (try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            .map(String.init(describing:))
            == (try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
                .map(String.init(describing:))
    }

    private func volumeIdentifier(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier)
            .map(String.init(describing:))
    }

    private func availableDuplicateURL(for item: URL) -> URL {
        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return availableURL(
            parent: item.deletingLastPathComponent(),
            baseName: isDirectory
                ? item.lastPathComponent + " 副本"
                : item.deletingPathExtension().lastPathComponent + " 副本",
            pathExtension: isDirectory ? nil : item.pathExtension
        )
    }

    private func availableURL(parent: URL, baseName: String, pathExtension: String?) -> URL {
        for suffix in 1...Int.max {
            let suffixText = suffix == 1 ? "" : " \(suffix)"
            var candidate = parent.appendingPathComponent(baseName + suffixText)
            if let pathExtension, !pathExtension.isEmpty {
                candidate.appendPathExtension(pathExtension)
            }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        preconditionFailure("Unable to allocate a file name")
    }
}

enum WorkspaceFileVolumePolicy {
    static func allowsMove(
        sourceVolumeIdentifier: String?,
        destinationVolumeIdentifier: String?
    ) -> Bool {
        guard let sourceVolumeIdentifier, let destinationVolumeIdentifier else { return true }
        return sourceVolumeIdentifier == destinationVolumeIdentifier
    }
}
