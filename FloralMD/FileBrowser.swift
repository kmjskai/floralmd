import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownFileEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case directory
        case markdown
    }

    let url: URL
    let kind: Kind

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct MarkdownFileBrowser {
    static let supportedExtensions: Set<String> = ["md", "markdown", "mdown"]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func children(of directoryURL: URL) throws -> [MarkdownFileEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isHidden != true,
                  values.isSymbolicLink != true else { return nil }

            if values.isDirectory == true {
                return MarkdownFileEntry(url: url, kind: .directory)
            }
            if values.isRegularFile == true,
               Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                return MarkdownFileEntry(url: url, kind: .markdown)
            }
            return nil
        }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

struct FileSidebarItemInformation: Equatable {
    let rootURL: URL
    let itemURL: URL

    init(rootURL: URL, itemURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.itemURL = itemURL.standardizedFileURL
    }

    var fileName: String { itemURL.lastPathComponent }
    var absolutePath: String { itemURL.path }

    var relativePath: String {
        let rootComponents = rootURL.pathComponents
        let itemComponents = itemURL.pathComponents
        guard itemComponents.starts(with: rootComponents) else { return fileName }
        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

enum FileSidebarInformationAction: CaseIterable {
    case copyFileName
    case copyRelativePath
    case copyAbsolutePath

    var title: String {
        switch self {
        case .copyFileName:
            "复制文件名"
        case .copyRelativePath:
            "复制相对路径"
        case .copyAbsolutePath:
            "复制绝对路径"
        }
    }

    func clipboardText(for information: FileSidebarItemInformation) -> String {
        switch self {
        case .copyFileName:
            information.fileName
        case .copyRelativePath:
            information.relativePath
        case .copyAbsolutePath:
            information.absolutePath
        }
    }
}

enum FileSidebarOperationRequest: Equatable {
    case createMarkdown(parentURL: URL, name: String)
    case createDirectory(parentURL: URL, name: String)
    case rename(itemURL: URL, name: String)
    case duplicateMarkdown(itemURL: URL)
    case trash(itemURL: URL)
}

struct FileSidebarOperationResult: Equatable {
    let openURL: URL?

    static let none = FileSidebarOperationResult(openURL: nil)
}

enum FileSidebarOperationError: LocalizedError {
    case emptyName
    case invalidName
    case unsupportedMarkdownExtension
    case itemAlreadyExists(String)
    case currentDocumentUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "名称不能为空。"
        case .invalidName:
            "名称不能包含“/”或“:”。"
        case .unsupportedMarkdownExtension:
            "Markdown 文件必须使用 .md、.markdown 或 .mdown 扩展名。"
        case .itemAlreadyExists(let name):
            "“\(name)”已经存在。"
        case .currentDocumentUnavailable:
            "找不到当前打开文档，已取消操作以避免后续保存到错误位置。"
        }
    }
}

struct FileSidebarPathChange {
    static func contains(_ candidateURL: URL, in itemURL: URL) -> Bool {
        let itemComponents = itemURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: itemComponents)
    }

    static func relocatedURL(
        for candidateURL: URL,
        moving itemURL: URL,
        to destinationURL: URL
    ) -> URL? {
        let itemComponents = itemURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: itemComponents) else { return nil }

        return candidateComponents.dropFirst(itemComponents.count).reduce(
            destinationURL.standardizedFileURL
        ) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
    }
}

struct FileSidebarFileOperations {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func suggestedMarkdownURL(in parentURL: URL) -> URL {
        availableURL(
            in: parentURL,
            baseName: "未命名",
            pathExtension: "md",
            separator: " "
        )
    }

    func suggestedDirectoryURL(in parentURL: URL) -> URL {
        availableURL(
            in: parentURL,
            baseName: "新建文件夹",
            pathExtension: nil,
            separator: " "
        )
    }

    func createMarkdown(in parentURL: URL, name: String) throws -> URL {
        let destinationURL = try destinationURL(
            in: parentURL,
            name: name,
            requiresMarkdownExtension: true
        )
        guard fileManager.createFile(atPath: destinationURL.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destinationURL
    }

    func createDirectory(in parentURL: URL, name: String) throws -> URL {
        let destinationURL = try destinationURL(
            in: parentURL,
            name: name,
            requiresMarkdownExtension: false
        )
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        return destinationURL
    }

    func renameDestination(for itemURL: URL, name: String) throws -> URL {
        let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
        let destinationURL = try destinationURL(
            in: itemURL.deletingLastPathComponent(),
            name: name,
            requiresMarkdownExtension: values.isDirectory != true,
            existingItemURL: itemURL
        )
        if destinationURL.standardizedFileURL == itemURL.standardizedFileURL {
            return itemURL.standardizedFileURL
        }
        return destinationURL
    }

    func renameItem(at itemURL: URL, to destinationURL: URL) throws {
        guard itemURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }
        try fileManager.moveItem(at: itemURL, to: destinationURL)
    }

    func duplicateMarkdown(at itemURL: URL) throws -> URL {
        guard MarkdownFileBrowser.canOpen(itemURL) else {
            throw FileSidebarOperationError.unsupportedMarkdownExtension
        }
        let destinationURL = availableURL(
            in: itemURL.deletingLastPathComponent(),
            baseName: itemURL.deletingPathExtension().lastPathComponent + " 副本",
            pathExtension: itemURL.pathExtension,
            separator: " "
        )
        try fileManager.copyItem(at: itemURL, to: destinationURL)
        return destinationURL
    }

    func trashItem(at itemURL: URL) throws {
        try fileManager.trashItem(at: itemURL, resultingItemURL: nil)
    }

    private func destinationURL(
        in parentURL: URL,
        name: String,
        requiresMarkdownExtension: Bool,
        existingItemURL: URL? = nil
    ) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw FileSidebarOperationError.emptyName }
        guard !trimmedName.contains("/"), !trimmedName.contains(":") else {
            throw FileSidebarOperationError.invalidName
        }

        let destinationURL = parentURL.appendingPathComponent(trimmedName)
        if requiresMarkdownExtension, !MarkdownFileBrowser.canOpen(destinationURL) {
            throw FileSidebarOperationError.unsupportedMarkdownExtension
        }
        let isExistingItem = existingItemURL?.standardizedFileURL
            == destinationURL.standardizedFileURL
        guard isExistingItem || !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileSidebarOperationError.itemAlreadyExists(trimmedName)
        }
        return destinationURL
    }

    private func availableURL(
        in parentURL: URL,
        baseName: String,
        pathExtension: String?,
        separator: String
    ) -> URL {
        for suffix in 1...Int.max {
            let numberedSuffix = suffix == 1 ? "" : "\(separator)\(suffix)"
            var candidateURL = parentURL.appendingPathComponent(baseName + numberedSuffix)
            if let pathExtension, !pathExtension.isEmpty {
                candidateURL.appendPathExtension(pathExtension)
            }
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        preconditionFailure("Unable to find an available file name")
    }
}

@MainActor
final class FileSidebarMutationCoordinator {
    private let operations: FileSidebarFileOperations
    private let documentController: NSDocumentController

    convenience init() {
        self.init(
            operations: FileSidebarFileOperations(),
            documentController: .shared
        )
    }

    init(
        operations: FileSidebarFileOperations,
        documentController: NSDocumentController
    ) {
        self.operations = operations
        self.documentController = documentController
    }

    func perform(
        _ request: FileSidebarOperationRequest,
        currentDocumentURL: URL?
    ) async throws -> FileSidebarOperationResult {
        switch request {
        case .createMarkdown(let parentURL, let name):
            return FileSidebarOperationResult(
                openURL: try operations.createMarkdown(in: parentURL, name: name)
            )
        case .createDirectory(let parentURL, let name):
            _ = try operations.createDirectory(in: parentURL, name: name)
            return .none
        case .duplicateMarkdown(let itemURL):
            _ = try operations.duplicateMarkdown(at: itemURL)
            return .none
        case .rename(let itemURL, let name):
            try await rename(
                itemURL: itemURL,
                name: name,
                currentDocumentURL: currentDocumentURL
            )
            return .none
        case .trash(let itemURL):
            try await trash(itemURL: itemURL, currentDocumentURL: currentDocumentURL)
            return .none
        }
    }

    private func rename(
        itemURL: URL,
        name: String,
        currentDocumentURL: URL?
    ) async throws {
        let destinationURL = try operations.renameDestination(for: itemURL, name: name)
        guard destinationURL.standardizedFileURL != itemURL.standardizedFileURL else { return }

        let affectedDocuments = openDocuments(inside: itemURL)
        if let currentDocumentURL,
           FileSidebarPathChange.contains(currentDocumentURL, in: itemURL),
           affectedDocuments.isEmpty {
            throw FileSidebarOperationError.currentDocumentUnavailable
        }
        guard !affectedDocuments.isEmpty else {
            try operations.renameItem(at: itemURL, to: destinationURL)
            return
        }

        for document in affectedDocuments {
            try await save(document)
        }

        if let document = affectedDocuments.first(where: {
            $0.fileURL?.standardizedFileURL == itemURL.standardizedFileURL
        }) {
            try await move(document, to: destinationURL)
        } else {
            try operations.renameItem(at: itemURL, to: destinationURL)
            for document in affectedDocuments {
                guard let documentURL = document.fileURL,
                      let relocatedDocumentURL = FileSidebarPathChange.relocatedURL(
                        for: documentURL,
                        moving: itemURL,
                        to: destinationURL
                      ) else { continue }
                document.fileURL = relocatedDocumentURL
                documentController.noteNewRecentDocumentURL(relocatedDocumentURL)
            }
        }
    }

    private func trash(itemURL: URL, currentDocumentURL: URL?) async throws {
        let affectedDocuments = openDocuments(inside: itemURL)
        if let currentDocumentURL,
           FileSidebarPathChange.contains(currentDocumentURL, in: itemURL),
           affectedDocuments.isEmpty {
            throw FileSidebarOperationError.currentDocumentUnavailable
        }
        for document in affectedDocuments {
            try await save(document)
        }
        for document in affectedDocuments {
            document.close()
        }
        try operations.trashItem(at: itemURL)
    }

    private func openDocuments(inside itemURL: URL) -> [NSDocument] {
        documentController.documents.filter {
            guard let documentURL = $0.fileURL else { return false }
            return FileSidebarPathChange.contains(documentURL, in: itemURL)
        }
    }

    private func save(_ document: NSDocument) async throws {
        guard let fileURL = document.fileURL else {
            throw FileSidebarOperationError.currentDocumentUnavailable
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            document.save(
                to: fileURL,
                ofType: document.fileType ?? MarkdownDocument.markdownType.identifier,
                for: .saveOperation
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func move(_ document: NSDocument, to destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            document.move(to: destinationURL) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum FolderAuthorizationError: LocalizedError {
    case wrongFolder(expected: URL)
    case unavailableFolder(URL)

    var errorDescription: String? {
        switch self {
        case .wrongFolder(let expected):
            "请选择当前文档所在文件夹：\(expected.lastPathComponent)"
        case .unavailableFolder(let folder):
            "无法读取工作区“\(folder.lastPathComponent)”。该文件夹可能已被移动、删除或授权已失效。"
        }
    }
}

struct FolderAuthorization {
    static func matches(requestedFolder: URL, selectedFolder: URL) -> Bool {
        requestedFolder.standardizedFileURL == selectedFolder.standardizedFileURL
    }
}

enum FolderAccessPolicy: Equatable {
    case securityScoped
    case direct

    nonisolated static var currentProcess: Self {
        SecurityScopeSupport.isSandboxed ? .securityScoped : .direct
    }
}

@MainActor
final class FolderAccessService {
    static let shared = FolderAccessService()

    private enum DefaultsKey {
        static let bookmarks = "FileBrowserFolderBookmarks"
    }

    private let defaults: UserDefaults
    private let securityScopeAccessManager: SecurityScopedResourceAccessManager
    private let accessPolicy: FolderAccessPolicy
    private var accessedFolders: [String: SecurityScopedResourceLease] = [:]

    init(
        defaults: UserDefaults = .standard,
        securityScopeAccessManager: SecurityScopedResourceAccessManager = .shared,
        accessPolicy: FolderAccessPolicy = .currentProcess
    ) {
        self.defaults = defaults
        self.securityScopeAccessManager = securityScopeAccessManager
        self.accessPolicy = accessPolicy
    }

    deinit {
        for lease in accessedFolders.values {
            lease.invalidate()
        }
    }

    func restoredFolder(for requestedFolder: URL) throws -> URL? {
        if accessPolicy == .direct {
            return try directlyAccessibleFolder(requestedFolder)
        }

        let key = requestedFolder.standardizedFileURL.path
        guard let data = bookmarkDictionary()[key] else { return nil }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: data,
            options: SecurityScopeSupport.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard FolderAuthorization.matches(
            requestedFolder: requestedFolder,
            selectedFolder: resolvedURL
        ) else {
            removeBookmark(for: key)
            return nil
        }
        if isStale {
            try persist(folderURL: resolvedURL, for: key)
        }
        beginAccessing(folderURL: resolvedURL, for: key)
        guard Self.isReadableDirectory(resolvedURL) else {
            throw FolderAuthorizationError.unavailableFolder(requestedFolder)
        }
        return resolvedURL
    }

    func chooseWorkspace() throws -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Workspace…")
        panel.message = "选择一个文件夹作为这个 FloralMD 窗口的工作区。不会移动或复制任何文件。"
        panel.prompt = String(localized: "Open Workspace")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let selectedFolder = panel.url else { return nil }
        guard Self.isReadableDirectory(selectedFolder) else {
            throw FolderAuthorizationError.unavailableFolder(selectedFolder)
        }
        try rememberWorkspace(selectedFolder)
        return selectedFolder.standardizedFileURL
    }

    func rememberWorkspace(_ folderURL: URL) throws {
        guard Self.isReadableDirectory(folderURL) else {
            throw FolderAuthorizationError.unavailableFolder(folderURL)
        }
        guard accessPolicy == .securityScoped else { return }
        let key = folderURL.standardizedFileURL.path
        try persist(folderURL: folderURL, for: key)
        beginAccessing(folderURL: folderURL, for: key)
    }

    nonisolated static func isReadableDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.standardizedFileURL.path)
    }

    func requestAccess(to requestedFolder: URL) throws -> URL? {
        if accessPolicy == .direct {
            return try directlyAccessibleFolder(requestedFolder)
        }

        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "授权文件边栏"
        panel.message = "请选择“\(requestedFolder.lastPathComponent)”文件夹，以显示当前文档附近的 Markdown 文件。取消不会修改任何文件。"
        panel.prompt = "授权此文件夹"
        panel.directoryURL = requestedFolder.deletingLastPathComponent()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let selectedFolder = panel.url else { return nil }
        guard FolderAuthorization.matches(
            requestedFolder: requestedFolder,
            selectedFolder: selectedFolder
        ) else {
            throw FolderAuthorizationError.wrongFolder(expected: requestedFolder)
        }

        let key = requestedFolder.standardizedFileURL.path
        try persist(folderURL: selectedFolder, for: key)
        beginAccessing(folderURL: selectedFolder, for: key)
        return selectedFolder
    }

    private func directlyAccessibleFolder(_ requestedFolder: URL) throws -> URL {
        let standardizedFolder = requestedFolder.standardizedFileURL
        guard Self.isReadableDirectory(standardizedFolder) else {
            throw FolderAuthorizationError.unavailableFolder(requestedFolder)
        }
        return standardizedFolder
    }

    private func bookmarkDictionary() -> [String: Data] {
        defaults.dictionary(forKey: DefaultsKey.bookmarks) as? [String: Data] ?? [:]
    }

    private func persist(folderURL: URL, for key: String) throws {
        let data = try folderURL.bookmarkData(
            options: SecurityScopeSupport.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = bookmarkDictionary()
        bookmarks[key] = data
        defaults.set(bookmarks, forKey: DefaultsKey.bookmarks)
    }

    private func removeBookmark(for key: String) {
        var bookmarks = bookmarkDictionary()
        bookmarks.removeValue(forKey: key)
        defaults.set(bookmarks, forKey: DefaultsKey.bookmarks)
    }

    private func beginAccessing(folderURL: URL, for key: String) {
        let replacement = securityScopeAccessManager.acquire(folderURL)
        let previous = accessedFolders.updateValue(replacement, forKey: key)
        previous?.invalidate()
    }
}

struct FileSidebarView: View {
    let rootURL: URL
    let currentDocumentURL: URL?
    let openDocument: (URL) -> Void

    @State private var refreshID = UUID()
    @State private var entries: [MarkdownFileEntry] = []
    @State private var loadErrorMessage: String?
    @State private var isAuthorizing = false
    private let mutationCoordinator = FileSidebarMutationCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(rootURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("新建 Markdown 文件…") {
                        requestNewMarkdown(in: rootURL)
                    }
                    Button("新建文件夹…") {
                        requestNewDirectory(in: rootURL)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("新建文件或文件夹")
                Button {
                    refreshID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新文件列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                }
                Divider()
                Button("新建 Markdown 文件…") {
                    requestNewMarkdown(in: rootURL)
                }
                Button("新建文件夹…") {
                    requestNewDirectory(in: rootURL)
                }
                Divider()
                Button("重命名此文件夹…") {
                    requestRename(itemURL: rootURL)
                }
                Button("将此文件夹移到废纸篓", role: .destructive) {
                    requestTrash(itemURL: rootURL)
                }
            }

            Divider()

            sidebarContents
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件边栏")
        .task(id: refreshID) {
            await loadRootEntries()
        }
    }

    @ViewBuilder
    private var sidebarContents: some View {
        if let loadErrorMessage {
            ContentUnavailableView {
                Label("需要文件夹权限", systemImage: "folder.badge.questionmark")
            } description: {
                Text("FloralMD 只能访问已打开的文档。授权当前文件夹后，才能显示同路径文件。")
            } actions: {
                Button("授权此文件夹…") {
                    authorizeFolder()
                }
                .disabled(isAuthorizing)
            }
            .help(loadErrorMessage)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "没有 Markdown 文件",
                systemImage: "doc.text.magnifyingglass",
                description: Text("当前文件夹中没有可显示的 Markdown 文件。")
            )
        } else {
            NativeFileOutlineView(
                rootURL: rootURL,
                entries: entries,
                currentDocumentURL: currentDocumentURL,
                refreshID: refreshID,
                openDocument: openDocument,
                performOperation: performOperation
            )
            .equatable()
            .compatibleScrollEdgeEffectHidden()
        }
    }

    private func loadRootEntries() async {
        do {
            let accessibleURL = try FolderAccessService.shared.restoredFolder(for: rootURL) ?? rootURL
            entries = try MarkdownFileBrowser().children(of: accessibleURL)
            loadErrorMessage = nil
        } catch {
            entries = []
            loadErrorMessage = error.localizedDescription
        }
    }

    private func authorizeFolder() {
        isAuthorizing = true
        defer { isAuthorizing = false }
        do {
            guard let folderURL = try FolderAccessService.shared.requestAccess(to: rootURL) else { return }
            entries = try MarkdownFileBrowser().children(of: folderURL)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.localizedDescription
            NSApplication.shared.presentError(error)
        }
    }

    private func requestNewMarkdown(in parentURL: URL) {
        let suggestedName = FileSidebarFileOperations()
            .suggestedMarkdownURL(in: parentURL)
            .lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建 Markdown 文件",
            message: "输入新文件的名称。",
            defaultValue: suggestedName
        ) else { return }
        performOperation(.createMarkdown(parentURL: parentURL, name: name))
    }

    private func requestNewDirectory(in parentURL: URL) {
        let suggestedName = FileSidebarFileOperations()
            .suggestedDirectoryURL(in: parentURL)
            .lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建文件夹",
            message: "输入新文件夹的名称。",
            defaultValue: suggestedName
        ) else { return }
        performOperation(.createDirectory(parentURL: parentURL, name: name))
    }

    private func requestRename(itemURL: URL) {
        guard let name = FileSidebarDialogs.requestName(
            title: "重命名",
            message: "输入新的名称。",
            defaultValue: itemURL.lastPathComponent
        ) else { return }
        performOperation(.rename(itemURL: itemURL, name: name))
    }

    private func requestTrash(itemURL: URL) {
        let affectsOpenDocument = NSDocumentController.shared.documents.contains {
            guard let documentURL = $0.fileURL else { return false }
            return FileSidebarPathChange.contains(documentURL, in: itemURL)
        }
        guard FileSidebarDialogs.confirmTrash(
            name: itemURL.lastPathComponent,
            affectsCurrentDocument: affectsOpenDocument
        ) else { return }
        performOperation(.trash(itemURL: itemURL))
    }

    private func performOperation(_ request: FileSidebarOperationRequest) {
        Task { @MainActor in
            do {
                let result = try await mutationCoordinator.perform(
                    request,
                    currentDocumentURL: currentDocumentURL
                )
                refreshID = UUID()
                if let openURL = result.openURL {
                    openDocument(openURL)
                }
            } catch {
                NSApplication.shared.presentError(error)
            }
        }
    }
}

@MainActor
enum FileSidebarDialogs {
    static func requestName(
        title: String,
        message: String,
        defaultValue: String
    ) -> String? {
        NSApp.activate()
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.selectText(nil)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func confirmTrash(name: String, affectsCurrentDocument: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将“\(name)”移到废纸篓？"
        alert.informativeText = affectsCurrentDocument
            ? "当前打开文档会先保存并关闭，然后将项目移到废纸篓。"
            : "项目会移到系统废纸篓，可以从 Finder 中恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

final class MarkdownFileTreeNode {
    let entry: MarkdownFileEntry
    let standardizedURL: URL
    private var cachedChildren: [MarkdownFileTreeNode]?

    init(entry: MarkdownFileEntry) {
        self.entry = entry
        standardizedURL = entry.url.standardizedFileURL
    }

    var isDirectory: Bool { entry.kind == .directory }

    func children() -> [MarkdownFileTreeNode] {
        if let cachedChildren { return cachedChildren }
        guard isDirectory else {
            cachedChildren = []
            return []
        }

        let children = ((try? MarkdownFileBrowser().children(of: entry.url)) ?? [])
            .map { MarkdownFileTreeNode(entry: $0) }
        cachedChildren = children
        return children
    }
}

@MainActor
final class FileSidebarOutlineView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let contextRow = row(at: location)
        guard contextRow >= 0 else { return nil }

        return contextMenuProvider?(contextRow)
    }
}

private struct NativeFileOutlineView: NSViewRepresentable, Equatable {
    let rootURL: URL
    let entries: [MarkdownFileEntry]
    let currentDocumentURL: URL?
    let refreshID: UUID
    let openDocument: (URL) -> Void
    let performOperation: (FileSidebarOperationRequest) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootURL == rhs.rootURL
            && lhs.entries == rhs.entries
            && lhs.currentDocumentURL == rhs.currentDocumentURL
            && lhs.refreshID == rhs.refreshID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(openDocument: openDocument, performOperation: performOperation)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.wantsLayer = true
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)

        let outlineView = FileSidebarOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .small
        outlineView.rowHeight = 24
        outlineView.usesAutomaticRowHeights = false
        outlineView.intercellSpacing = .zero
        outlineView.backgroundColor = .clear
        outlineView.wantsLayer = true
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.action = #selector(Coordinator.rowClicked(_:))
        outlineView.refusesFirstResponder = true
        outlineView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        scrollView.documentView = outlineView

        context.coordinator.outlineView = outlineView
        context.coordinator.update(
            rootURL: rootURL,
            entries: entries,
            currentDocumentURL: currentDocumentURL,
            refreshID: refreshID,
            openDocument: openDocument,
            performOperation: performOperation
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            rootURL: rootURL,
            entries: entries,
            currentDocumentURL: currentDocumentURL,
            refreshID: refreshID,
            openDocument: openDocument,
            performOperation: performOperation
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: NSOutlineView?

        private var roots: [MarkdownFileTreeNode] = []
        private var rootURL: URL?
        private var refreshID: UUID?
        private var currentDocumentURL: URL?
        private var openDocument: (URL) -> Void
        private var performOperation: (FileSidebarOperationRequest) -> Void
        private var isUpdatingSelection = false
        private let folderImage = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: nil
        )
        private let markdownImage = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: nil
        )

        init(
            openDocument: @escaping (URL) -> Void,
            performOperation: @escaping (FileSidebarOperationRequest) -> Void
        ) {
            self.openDocument = openDocument
            self.performOperation = performOperation
        }

        func update(
            rootURL: URL,
            entries: [MarkdownFileEntry],
            currentDocumentURL: URL?,
            refreshID: UUID,
            openDocument: @escaping (URL) -> Void,
            performOperation: @escaping (FileSidebarOperationRequest) -> Void
        ) {
            self.openDocument = openDocument
            self.performOperation = performOperation
            self.rootURL = rootURL.standardizedFileURL
            let normalizedCurrentURL = currentDocumentURL?.standardizedFileURL
            let selectionChanged = self.currentDocumentURL != normalizedCurrentURL
            self.currentDocumentURL = normalizedCurrentURL

            if self.refreshID != refreshID || roots.map(\.entry) != entries {
                self.refreshID = refreshID
                roots = entries.map(MarkdownFileTreeNode.init)
                outlineView?.reloadData()
                selectCurrentDocument()
            } else if selectionChanged {
                selectCurrentDocument()
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            guard let node = item as? MarkdownFileTreeNode else { return roots.count }
            return node.children().count
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            guard let node = item as? MarkdownFileTreeNode else { return roots[index] }
            return node.children()[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? MarkdownFileTreeNode)?.isDirectory == true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? MarkdownFileTreeNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("MarkdownFileCell")
            let cell: NSTableCellView

            if let reusable = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView {
                cell = reusable
            } else {
                cell = makeCell(identifier: identifier)
            }

            cell.textField?.stringValue = node.entry.name
            cell.imageView?.image = node.isDirectory ? folderImage : markdownImage
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? MarkdownFileTreeNode)?.entry.kind == .markdown
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let rootURL,
                  let node = outlineView?.item(atRow: row) as? MarkdownFileTreeNode else {
                return nil
            }

            let information = FileSidebarItemInformation(
                rootURL: rootURL,
                itemURL: node.entry.url
            )
            let menu = NSMenu()
            for action in FileSidebarInformationAction.allCases {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(copyInformation(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = action.clipboardText(for: information)
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let revealItem = NSMenuItem(
                title: "在 Finder 中显示",
                action: #selector(revealInFinder(_:)),
                keyEquivalent: ""
            )
            revealItem.target = self
            revealItem.representedObject = information.itemURL
            menu.addItem(revealItem)
            menu.addItem(.separator())

            let parentURL = node.isDirectory
                ? node.entry.url
                : node.entry.url.deletingLastPathComponent()
            addMenuItem(
                title: "新建 Markdown 文件…",
                action: #selector(createMarkdown(_:)),
                representedObject: parentURL,
                to: menu
            )
            addMenuItem(
                title: "新建文件夹…",
                action: #selector(createDirectory(_:)),
                representedObject: parentURL,
                to: menu
            )
            menu.addItem(.separator())
            addMenuItem(
                title: "重命名…",
                action: #selector(renameItem(_:)),
                representedObject: information.itemURL,
                to: menu
            )
            if node.entry.kind == .markdown {
                addMenuItem(
                    title: "复制文件",
                    action: #selector(duplicateMarkdown(_:)),
                    representedObject: information.itemURL,
                    to: menu
                )
            }
            addMenuItem(
                title: "移到废纸篓",
                action: #selector(trashItem(_:)),
                representedObject: information.itemURL,
                to: menu
            )
            return menu
        }

        private func addMenuItem(
            title: String,
            action: Selector,
            representedObject: Any,
            to menu: NSMenu
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = representedObject
            menu.addItem(item)
        }

        @objc private func copyInformation(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func revealInFinder(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc private func createMarkdown(_ sender: NSMenuItem) {
            guard let parentURL = sender.representedObject as? URL else { return }
            let suggestedName = FileSidebarFileOperations()
                .suggestedMarkdownURL(in: parentURL)
                .lastPathComponent
            guard let name = FileSidebarDialogs.requestName(
                title: "新建 Markdown 文件",
                message: "输入新文件的名称。",
                defaultValue: suggestedName
            ) else { return }
            performOperation(.createMarkdown(parentURL: parentURL, name: name))
        }

        @objc private func createDirectory(_ sender: NSMenuItem) {
            guard let parentURL = sender.representedObject as? URL else { return }
            let suggestedName = FileSidebarFileOperations()
                .suggestedDirectoryURL(in: parentURL)
                .lastPathComponent
            guard let name = FileSidebarDialogs.requestName(
                title: "新建文件夹",
                message: "输入新文件夹的名称。",
                defaultValue: suggestedName
            ) else { return }
            performOperation(.createDirectory(parentURL: parentURL, name: name))
        }

        @objc private func renameItem(_ sender: NSMenuItem) {
            guard let itemURL = sender.representedObject as? URL,
                  let name = FileSidebarDialogs.requestName(
                    title: "重命名",
                    message: "输入新的名称。",
                    defaultValue: itemURL.lastPathComponent
                  ) else { return }
            performOperation(.rename(itemURL: itemURL, name: name))
        }

        @objc private func duplicateMarkdown(_ sender: NSMenuItem) {
            guard let itemURL = sender.representedObject as? URL else { return }
            performOperation(.duplicateMarkdown(itemURL: itemURL))
        }

        @objc private func trashItem(_ sender: NSMenuItem) {
            guard let itemURL = sender.representedObject as? URL else { return }
            let affectsCurrentDocument = NSDocumentController.shared.documents.contains {
                guard let documentURL = $0.fileURL else { return false }
                return FileSidebarPathChange.contains(documentURL, in: itemURL)
            }
            guard FileSidebarDialogs.confirmTrash(
                name: itemURL.lastPathComponent,
                affectsCurrentDocument: affectsCurrentDocument
            ) else { return }
            performOperation(.trash(itemURL: itemURL))
        }

        @objc func rowClicked(_ sender: NSOutlineView) {
            guard !isUpdatingSelection,
                  sender.clickedRow >= 0,
                  let node = sender.item(atRow: sender.clickedRow) as? MarkdownFileTreeNode,
                  node.entry.kind == .markdown,
                  node.standardizedURL != currentDocumentURL else { return }

            let requestedURL = node.entry.url
            DispatchQueue.main.async { [weak self] in
                self?.openDocument(requestedURL)
            }
        }

        private func selectCurrentDocument() {
            guard let outlineView else { return }
            let matchingRow = (0..<outlineView.numberOfRows).first { row in
                guard let node = outlineView.item(atRow: row) as? MarkdownFileTreeNode else {
                    return false
                }
                return node.standardizedURL == currentDocumentURL
            }

            isUpdatingSelection = true
            defer { isUpdatingSelection = false }
            if let matchingRow {
                outlineView.selectRowIndexes(IndexSet(integer: matchingRow), byExtendingSelection: false)
            } else {
                outlineView.deselectAll(nil)
            }
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.contentTintColor = .secondaryLabelColor
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }
}
