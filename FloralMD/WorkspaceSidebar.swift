import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let slateMemoWorkspaceDidChange = Notification.Name("FloralMDWorkspaceDidChange")
}

nonisolated struct WorkspaceFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case resource(ResourceKind)
        case file
    }

    let url: URL
    let kind: Kind
    let children: [WorkspaceFileEntry]?
    let identity: WorkspaceFileIdentity
    let scanErrorDescription: String?

    init(
        url: URL,
        kind: Kind,
        children: [WorkspaceFileEntry]?,
        identity: WorkspaceFileIdentity? = nil,
        scanErrorDescription: String? = nil
    ) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.kind = kind
        self.children = children
        self.identity = identity ?? WorkspaceFileIdentity.fallback(for: standardizedURL)
        self.scanErrorDescription = scanErrorDescription
    }

    var id: URL { url.standardizedFileURL }
    var name: String { url.lastPathComponent }

    var systemImage: String {
        switch kind {
        case .directory:
            "folder"
        case .resource(.markdown):
            "doc.text"
        case .resource(.drawing):
            "scribble.variable"
        case .resource(.image):
            "photo"
        case .file:
            "doc"
        }
    }

    var iconRole: WorkspaceSidebarIconRole {
        switch kind {
        case .directory:
            .folder
        case .resource(.markdown):
            .markdown
        case .resource(.drawing):
            .drawing
        case .resource(.image):
            .image
        case .file:
            .file
        }
    }
}

nonisolated struct WorkspaceFileIdentity: Hashable, Sendable {
    let rawValue: String

    static func fallback(for url: URL) -> WorkspaceFileIdentity {
        WorkspaceFileIdentity(rawValue: "path:\(url.standardizedFileURL.path)")
    }
}

nonisolated enum WorkspaceSidebarIconRole: Equatable, Sendable {
    case folder
    case markdown
    case drawing
    case image
    case file
}

nonisolated struct WorkspaceFileCatalog {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func entries(in rootURL: URL) throws -> [WorkspaceFileEntry] {
        try entries(in: rootURL, visitedDirectories: [])
    }

    static func identity(for url: URL) -> WorkspaceFileIdentity? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let identifier = values?.fileResourceIdentifier else { return nil }
        return WorkspaceFileIdentity(rawValue: "resource:\(String(describing: identifier))")
    }

    private func entries(
        in directoryURL: URL,
        visitedDirectories: Set<URL>
    ) throws -> [WorkspaceFileEntry] {
        let standardizedDirectory = directoryURL.standardizedFileURL
        guard !visitedDirectories.contains(standardizedDirectory) else { return [] }
        var nextVisited = visitedDirectories
        nextVisited.insert(standardizedDirectory)

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isPackageKey,
            .fileResourceIdentifierKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: standardizedDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url -> WorkspaceFileEntry? in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isHidden != true,
                  values.isSymbolicLink != true,
                  values.isPackage != true else { return nil }
            let identity = values.fileResourceIdentifier.map {
                WorkspaceFileIdentity(rawValue: "resource:\(String(describing: $0))")
            } ?? WorkspaceFileIdentity.fallback(for: url)
            if values.isDirectory == true {
                do {
                    return WorkspaceFileEntry(
                        url: url,
                        kind: .directory,
                        children: try entries(in: url, visitedDirectories: nextVisited),
                        identity: identity
                    )
                } catch {
                    return WorkspaceFileEntry(
                        url: url,
                        kind: .directory,
                        children: [],
                        identity: identity,
                        scanErrorDescription: error.localizedDescription
                    )
                }
            }
            guard values.isRegularFile != false else { return nil }
            if let resourceKind = ResourceKind.resolve(url: url) {
                return WorkspaceFileEntry(
                    url: url,
                    kind: .resource(resourceKind),
                    children: nil,
                    identity: identity
                )
            }
            return WorkspaceFileEntry(
                url: url,
                kind: .file,
                children: nil,
                identity: identity
            )
        }
        .sorted(by: Self.sortsBefore)
    }

    private static func sortsBefore(_ lhs: WorkspaceFileEntry, _ rhs: WorkspaceFileEntry) -> Bool {
        switch (lhs.kind, rhs.kind) {
        case (.directory, _):
            return true
        case (_, .directory):
            return false
        default:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

nonisolated struct WorkspaceVisibleEntry: Identifiable, Equatable, Sendable {
    let entry: WorkspaceFileEntry
    let depth: Int
    let isExpanded: Bool

    var id: URL { entry.id }
}

enum WorkspaceSidebarDragItemProvider {
    static func make(fileURL: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let standardized = fileURL.standardizedFileURL
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(Data(standardized.absoluteString.utf8), nil)
            return nil
        }
        return provider
    }
}

nonisolated enum WorkspaceFileTree {
    static func flattened(_ entries: [WorkspaceFileEntry]) -> [WorkspaceFileEntry] {
        entries.flatMap { [$0] + flattened($0.children ?? []) }
    }

    static func visibleEntries(
        in entries: [WorkspaceFileEntry],
        expandedDirectories: Set<WorkspaceFileIdentity>,
        depth: Int = 0
    ) -> [WorkspaceVisibleEntry] {
        entries.flatMap { entry in
            let isExpanded = entry.kind == .directory
                && expandedDirectories.contains(entry.identity)
            var visible = [WorkspaceVisibleEntry(
                entry: entry,
                depth: depth,
                isExpanded: isExpanded
            )]
            guard isExpanded else { return visible }
            visible.append(contentsOf: visibleEntries(
                in: entry.children ?? [],
                expandedDirectories: expandedDirectories,
                depth: depth + 1
            ))
            return visible
        }
    }

    static func expandedDirectories(
        revealing targetURL: URL,
        in entries: [WorkspaceFileEntry],
        preserving expandedDirectories: Set<WorkspaceFileIdentity>
    ) -> Set<WorkspaceFileIdentity> {
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        return flattened(entries).reduce(into: expandedDirectories) { result, entry in
            guard entry.kind == .directory else { return }
            let directoryComponents = entry.url.standardizedFileURL.pathComponents
            guard targetComponents.count > directoryComponents.count,
                  targetComponents.starts(with: directoryComponents) else { return }
            result.insert(entry.identity)
        }
    }
}

struct WorkspaceSidebarView: View {
    let rootURL: URL
    let selectedURL: URL?
    let select: (URL) -> Void
    let createMarkdown: () -> Void
    let createDrawing: () -> Void
    let didReload: ([WorkspaceFileEntry]) -> Void
    let performOperation: (WorkspaceFileOperationRequest) -> Void
    let performInlineRename: (WorkspaceFileOperationRequest) throws -> WorkspaceFileOperationResult

    /// 由宿主持有：harnessOnly 模式下本视图被移除，但展开/选中状态必须保留，
    /// 切回编辑器时边栏回到离开时的位置。
    @Binding var expandedDirectories: Set<WorkspaceFileIdentity>
    @Binding var selectedEntryURL: URL?

    @State private var entries: [WorkspaceFileEntry] = []
    @State private var errorMessage: String?
    @State private var isAuthorizing = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var inlineRename = WorkspaceInlineRenameModel()
    @State private var hasDeferredReload = false
    @State private var pendingRevealURL: URL?
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(rootURL.lastPathComponent)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("新建 Markdown") { createMarkdown() }
                    Button("新建绘图") { createDrawing() }
                    Divider()
                    Button("在根目录新建 Markdown…") { requestNewMarkdown(in: rootURL) }
                    Button("在根目录新建文件夹…") { requestNewDirectory(in: rootURL) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(action: refreshWorkspace) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新工作区")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onDrop(
                of: [UTType.fileURL.identifier],
                delegate: WorkspaceDirectoryDropDelegate(
                    targetDirectoryURL: rootURL,
                    workspaceRootURL: rootURL,
                    performOperation: performOperation
                )
            )

            Divider()

            if let errorMessage {
                ContentUnavailableView {
                    Label("需要文件夹权限", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("授权当前文件夹后，FloralMD 才能显示并保存同路径资源。")
                } actions: {
                    Button("授权此文件夹…", action: authorizeFolder)
                        .disabled(isAuthorizing)
                }
                .help(errorMessage)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "工作区为空",
                    systemImage: "folder",
                    description: Text("新建 Markdown 或绘图开始记录。")
                )
            } else {
                WorkspaceSidebarList(
                    visibleEntries: WorkspaceFileTree.visibleEntries(
                        in: entries,
                        expandedDirectories: expandedDirectories
                    ),
                    selectedURL: selectedEntryURL ?? selectedURL,
                    rootURL: rootURL,
                    activate: activate,
                    performOperation: performOperation,
                    renameSession: inlineRename.session,
                    beginRename: beginRename,
                    updateRenameDraft: updateRenameDraft,
                    updateRenameSelection: updateRenameSelection,
                    submitRename: submitRename,
                    cancelRename: cancelRename
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($isSidebarFocused)
        .focusedValue(
            \.workspaceFileSidebarCommandAction,
            isSidebarFocused ? WorkspaceFileSidebarCommandAction(perform: performSidebarCommand) : nil
        )
        .task(id: rootURL.standardizedFileURL) { await reload() }
        .onChange(of: selectedURL) { _, newURL in
            guard let newURL else { return }
            let standardizedURL = newURL.standardizedFileURL
            selectedEntryURL = standardizedURL
            // 幂等 reveal：仅在目标目录尚未展开时重载树展开到该文件
            // （文件可能已在树中，但父目录未展开，旧逻辑被提前 return 挡住）。
            let expanded = WorkspaceFileTree.expandedDirectories(
                revealing: standardizedURL,
                in: entries,
                preserving: expandedDirectories
            )
            guard expanded != expandedDirectories else { return }
            pendingRevealURL = standardizedURL
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .handyNoteDefaultFolderDidChange)) { _ in
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .slateMemoWorkspaceDidChange)) { notification in
            if let result = notification.object as? WorkspaceFileOperationResult {
                applyOperationResult(result)
            }
            scheduleReload()
        }
        .onDisappear {
            reloadTask?.cancel()
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func refreshWorkspace() {
        NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
    }

    private func applyOperationResult(_ result: WorkspaceFileOperationResult) {
        if let relocation = result.relocatedItem,
           let selectedEntryURL,
           let relocatedSelection = FileSidebarPathChange.relocatedURL(
               for: selectedEntryURL,
               moving: relocation.from,
               to: relocation.to
           ) {
            self.selectedEntryURL = relocatedSelection
        } else if let removedItemURL = result.removedItemURL,
                  let selectedEntryURL,
                  WorkspaceResolver.contains(selectedEntryURL, in: removedItemURL) {
            self.selectedEntryURL = nil
        } else if let createdURL = result.createdURL {
            let standardizedURL = createdURL.standardizedFileURL
            selectedEntryURL = standardizedURL
            pendingRevealURL = standardizedURL
        }
    }

    private func requestNewMarkdown(in parentURL: URL) {
        let suggestion = WorkspaceFileOperationService()
            .suggestedMarkdownURL(in: parentURL).lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建 Markdown",
            message: "输入文件名称。已有文件不会被覆盖。",
            defaultValue: suggestion
        ) else { return }
        performOperation(.createMarkdown(parentURL: parentURL, name: name))
    }

    private func requestNewDirectory(in parentURL: URL) {
        let suggestion = WorkspaceFileOperationService()
            .suggestedDirectoryURL(in: parentURL).lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建文件夹",
            message: "输入文件夹名称。已有项目不会被覆盖。",
            defaultValue: suggestion
        ) else { return }
        performOperation(.createDirectory(parentURL: parentURL, name: name))
    }

    private func activate(_ entry: WorkspaceFileEntry) {
        selectedEntryURL = entry.url.standardizedFileURL
        isSidebarFocused = true
        switch entry.kind {
        case .directory:
            if expandedDirectories.contains(entry.identity) {
                expandedDirectories.remove(entry.identity)
            } else {
                expandedDirectories.insert(entry.identity)
            }
        case .resource:
            select(entry.url)
        case .file:
            break
        }
    }

    private func performSidebarCommand(_ command: WorkspaceFileSidebarCommand) {
        guard let selectedEntry = selectedEntry else { return }
        switch command {
        case .cut:
            _ = WorkspaceFileClipboard.write(url: selectedEntry.url, operation: .cut)
        case .copy:
            _ = WorkspaceFileClipboard.write(url: selectedEntry.url, operation: .copy)
        case .paste:
            guard let payload = WorkspaceFileClipboard.read() else { return }
            let target = selectedEntry.kind == .directory
                ? selectedEntry.url
                : selectedEntry.url.deletingLastPathComponent()
            let request = WorkspaceFileDropPlan.request(
                sourceURL: payload.url,
                targetDirectoryURL: target,
                workspaceRootURL: rootURL,
                optionKey: payload.operation == .copy
            )
            performOperation(request)
        case .rename:
            beginRename(selectedEntry)
        case .trash:
            requestTrash(selectedEntry)
        case .quickLook:
            WorkspaceQuickLookController.shared.show(selectedEntry.url)
        }
    }

    private var selectedEntry: WorkspaceFileEntry? {
        guard let selectedEntryURL else { return nil }
        return WorkspaceFileTree.flattened(entries).first {
            $0.url.standardizedFileURL == selectedEntryURL.standardizedFileURL
        }
    }

    private func beginRename(_ entry: WorkspaceFileEntry) {
        selectedEntryURL = entry.url.standardizedFileURL
        isSidebarFocused = true
        inlineRename.begin(entry)
    }

    private func updateRenameDraft(
        _ draft: String,
        selection: NSRange,
        identity: WorkspaceFileIdentity
    ) {
        inlineRename.updateDraft(draft, selection: selection, identity: identity)
    }

    private func updateRenameSelection(
        _ selection: NSRange,
        identity: WorkspaceFileIdentity
    ) {
        inlineRename.updateSelection(selection, identity: identity)
    }

    private func submitRename(
        identity: WorkspaceFileIdentity,
        reason: WorkspaceInlineRenameCommitReason
    ) {
        guard let session = inlineRename.session,
              session.identity == identity else { return }
        do {
            _ = try performInlineRename(
                .rename(itemURL: session.sourceURL, name: session.draft)
            )
            inlineRename.finish(identity: identity)
            if reason == .returnKey {
                isSidebarFocused = true
            }
            runDeferredReloadIfNeeded()
        } catch {
            inlineRename.fail(error.localizedDescription, identity: identity)
        }
    }

    private func cancelRename(identity: WorkspaceFileIdentity) {
        inlineRename.finish(identity: identity)
        isSidebarFocused = true
        runDeferredReloadIfNeeded()
    }

    private func runDeferredReloadIfNeeded() {
        guard hasDeferredReload else { return }
        hasDeferredReload = false
        scheduleReload()
    }

    private func requestTrash(_ entry: WorkspaceFileEntry) {
        guard WorkspaceFileOperationDialogs.confirmTrash(entry: entry) else { return }
        performOperation(.trash(itemURL: entry.url))
    }

    private func reload() async {
        do {
            let accessibleRoot = try FolderAccessService.shared.restoredFolder(for: rootURL)
                ?? rootURL
            let loadedEntries = try await Task.detached(priority: .userInitiated) {
                try WorkspaceFileCatalog().entries(in: accessibleRoot)
            }.value
            try Task.checkCancellation()
            guard inlineRename.acceptsCatalogReload else {
                hasDeferredReload = true
                return
            }
            if let pendingRevealURL {
                expandedDirectories = WorkspaceFileTree.expandedDirectories(
                    revealing: pendingRevealURL,
                    in: loadedEntries,
                    preserving: expandedDirectories
                )
                self.pendingRevealURL = nil
            }
            entries = loadedEntries
            errorMessage = nil
            didReload(loadedEntries)
        } catch is CancellationError {
            return
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func authorizeFolder() {
        isAuthorizing = true
        do {
            guard let root = try FolderAccessService.shared.requestAccess(to: rootURL) else {
                isAuthorizing = false
                return
            }
            reloadTask?.cancel()
            reloadTask = Task {
                do {
                    let loadedEntries = try await Task.detached(priority: .userInitiated) {
                        try WorkspaceFileCatalog().entries(in: root)
                    }.value
                    try Task.checkCancellation()
                    entries = loadedEntries
                    errorMessage = nil
                    didReload(loadedEntries)
                    isAuthorizing = false
                } catch is CancellationError {
                    isAuthorizing = false
                } catch {
                    isAuthorizing = false
                    errorMessage = error.localizedDescription
                    NSApplication.shared.presentError(error)
                }
            }
        } catch {
            isAuthorizing = false
            errorMessage = error.localizedDescription
            NSApplication.shared.presentError(error)
        }
    }
}

struct WorkspaceSidebarList: View {
    let visibleEntries: [WorkspaceVisibleEntry]
    let selectedURL: URL?
    let rootURL: URL
    let activate: (WorkspaceFileEntry) -> Void
    let performOperation: (WorkspaceFileOperationRequest) -> Void
    var renameSession: WorkspaceInlineRenameSession? = nil
    var beginRename: (WorkspaceFileEntry) -> Void = { _ in }
    var updateRenameDraft: (String, NSRange, WorkspaceFileIdentity) -> Void = { _, _, _ in }
    var updateRenameSelection: (NSRange, WorkspaceFileIdentity) -> Void = { _, _ in }
    var submitRename: (WorkspaceFileIdentity, WorkspaceInlineRenameCommitReason) -> Void = { _, _ in }
    var cancelRename: (WorkspaceFileIdentity) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(visibleEntries) { visibleEntry in
                    WorkspaceFileEntryRow(
                        visibleEntry: visibleEntry,
                        selectedURL: selectedURL,
                        rootURL: rootURL,
                        activate: activate,
                        performOperation: performOperation,
                        renameSession: renameSession?.identity == visibleEntry.entry.identity
                            ? renameSession
                            : nil,
                        beginRename: beginRename,
                        updateRenameDraft: updateRenameDraft,
                        updateRenameSelection: updateRenameSelection,
                        submitRename: submitRename,
                        cancelRename: cancelRename
                    )
                    .id(visibleEntry.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background {
                WorkspaceSidebarScrollPolicyBridge()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            .onChange(of: selectedURL) { _, newURL in
                scrollToSelection(newURL, in: visibleEntries, proxy: proxy)
            }
            .onChange(of: visibleEntries) { _, newEntries in
                scrollToSelection(selectedURL, in: newEntries, proxy: proxy)
            }
        }
    }

    /// 当前打开的文件在侧栏中保持可见：reload 展开目录后把选中行滚进视口。
    private func scrollToSelection(
        _ url: URL?,
        in entries: [WorkspaceVisibleEntry],
        proxy: ScrollViewProxy
    ) {
        guard let url else { return }
        let standardized = url.standardizedFileURL
        guard let match = entries.first(where: {
            $0.entry.url.standardizedFileURL == standardized
        }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(match.id, anchor: .center)
        }
    }
}

enum WorkspaceSidebarScrollPolicy {
    static func apply(to scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        let origin = scrollView.contentView.bounds.origin
        if origin.x != 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

struct WorkspaceSidebarScrollPolicyBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceSidebarScrollPolicyView {
        WorkspaceSidebarScrollPolicyView()
    }

    func updateNSView(_ view: WorkspaceSidebarScrollPolicyView, context: Context) {
        view.scheduleConfiguration()
    }
}

final class WorkspaceSidebarScrollPolicyView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.nearestSiblingScrollView else { return }
            WorkspaceSidebarScrollPolicy.apply(to: scrollView)
        }
    }

    private var nearestSiblingScrollView: NSScrollView? {
        if let enclosingScrollView { return enclosingScrollView }

        var branch: NSView = self
        while let parent = branch.superview {
            if let scrollView = parent as? NSScrollView { return scrollView }
            for sibling in parent.subviews where sibling !== branch {
                if let scrollView = sibling.firstScrollViewDescendant {
                    return scrollView
                }
            }
            branch = parent
        }
        return nil
    }
}

private extension NSView {
    var firstScrollViewDescendant: NSScrollView? {
        if let scrollView = self as? NSScrollView { return scrollView }
        for subview in subviews {
            if let scrollView = subview.firstScrollViewDescendant {
                return scrollView
            }
        }
        return nil
    }
}

private struct WorkspaceFileEntryRow: View {
    let visibleEntry: WorkspaceVisibleEntry
    let selectedURL: URL?
    let rootURL: URL
    let activate: (WorkspaceFileEntry) -> Void
    let performOperation: (WorkspaceFileOperationRequest) -> Void
    let renameSession: WorkspaceInlineRenameSession?
    let beginRename: (WorkspaceFileEntry) -> Void
    let updateRenameDraft: (String, NSRange, WorkspaceFileIdentity) -> Void
    let updateRenameSelection: (NSRange, WorkspaceFileIdentity) -> Void
    let submitRename: (WorkspaceFileIdentity, WorkspaceInlineRenameCommitReason) -> Void
    let cancelRename: (WorkspaceFileIdentity) -> Void

    private var entry: WorkspaceFileEntry { visibleEntry.entry }

    @ViewBuilder
    var body: some View {
        if renameSession != nil {
            row
        } else {
            switch entry.kind {
            case .directory:
                row
                    .onDrag(makeFileURLProvider)
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        delegate: WorkspaceDirectoryDropDelegate(
                            targetDirectoryURL: entry.url,
                            workspaceRootURL: rootURL,
                            performOperation: performOperation
                        )
                    )
            case .resource, .file:
                row.onDrag(makeFileURLProvider)
            }
        }
    }

    private var row: some View {
        Group {
            if let renameSession {
                VStack(alignment: .leading, spacing: 2) {
                    rowContents(renameSession: renameSession)
                    if let errorMessage = renameSession.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .padding(.leading, renameFieldLeadingInset)
                            .accessibilityLabel("重命名错误：\(errorMessage)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                Button {
                    activate(entry)
                } label: {
                    rowContents(renameSession: nil)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(rowBackground)
        .contextMenu { finderActions }
    }

    private func rowContents(renameSession: WorkspaceInlineRenameSession?) -> some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(visibleEntry.depth) * 14)
            if entry.kind == .directory {
                Image(systemName: visibleEntry.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(systemName: entry.systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
            if let renameSession {
                WorkspaceInlineRenameField(
                    text: renameSession.draft,
                    selection: renameSession.selection,
                    focusRequest: renameSession.focusRequest,
                    accessibilityLabel: "重命名 \(entry.name)",
                    onChange: { draft, selection in
                        updateRenameDraft(draft, selection, entry.identity)
                    },
                    onSelectionChange: { selection in
                        updateRenameSelection(selection, entry.identity)
                    },
                    onSubmit: { reason in submitRename(entry.identity, reason) },
                    onCancel: { cancelRename(entry.identity) }
                )
                .frame(minWidth: 70, maxWidth: .infinity, minHeight: 22)
            } else {
                Text(entry.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var renameFieldLeadingInset: CGFloat {
        CGFloat(visibleEntry.depth) * 14 + 10 + 6 + 16 + 6
    }

    private func makeFileURLProvider() -> NSItemProvider {
        WorkspaceSidebarDragItemProvider.make(fileURL: entry.url)
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.22) : .clear
    }

    private var isSelected: Bool {
        selectedURL?.standardizedFileURL == entry.url.standardizedFileURL
    }

    private var iconColor: Color {
        switch entry.iconRole {
        case .folder:
            .orange
        case .markdown:
            .blue
        case .drawing:
            .purple
        case .image:
            .green
        case .file:
            .secondary
        }
    }

    @ViewBuilder
    private var finderActions: some View {
        if entry.kind == .directory {
            Button("新建 Markdown…") { requestNewMarkdown() }
            Button("新建文件夹…") { requestNewDirectory() }
            Divider()
        }
        Button("快速查看") {
            WorkspaceQuickLookController.shared.show(entry.url)
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Button("复制绝对路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }
        Divider()
        Button("重命名") { beginRename(entry) }
        Button("制作副本") { performOperation(.duplicate(itemURL: entry.url)) }
        Button("移动到文件夹…") { requestMove() }
        Divider()
        Button("移到废纸篓…", role: .destructive) { requestTrash() }
    }

    private func requestNewMarkdown() {
        let suggestion = WorkspaceFileOperationService()
            .suggestedMarkdownURL(in: entry.url).lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建 Markdown",
            message: "输入文件名称。已有文件不会被覆盖。",
            defaultValue: suggestion
        ) else { return }
        performOperation(.createMarkdown(parentURL: entry.url, name: name))
    }

    private func requestNewDirectory() {
        let suggestion = WorkspaceFileOperationService()
            .suggestedDirectoryURL(in: entry.url).lastPathComponent
        guard let name = FileSidebarDialogs.requestName(
            title: "新建文件夹",
            message: "输入文件夹名称。已有项目不会被覆盖。",
            defaultValue: suggestion
        ) else { return }
        performOperation(.createDirectory(parentURL: entry.url, name: name))
    }

    private func requestMove() {
        let panel = NSOpenPanel()
        panel.title = "选择目标文件夹"
        panel.message = "只能移动到当前工作区内；同名项目不会被覆盖。"
        panel.prompt = "移动"
        panel.directoryURL = rootURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        performOperation(.move(itemURL: entry.url, destinationDirectoryURL: destination))
    }

    private func requestTrash() {
        guard WorkspaceFileOperationDialogs.confirmTrash(entry: entry) else { return }
        performOperation(.trash(itemURL: entry.url))
    }
}

private struct WorkspaceDirectoryDropDelegate: DropDelegate {
    let targetDirectoryURL: URL
    let workspaceRootURL: URL
    let performOperation: (WorkspaceFileOperationRequest) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.fileURL.identifier]).first else {
            return false
        }
        let optionKey = NSEvent.modifierFlags.contains(.option)
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let string = String(data: data, encoding: .utf8),
                  let sourceURL = URL(string: string),
                  sourceURL.isFileURL else { return }
            let request = WorkspaceFileDropPlan.request(
                sourceURL: sourceURL,
                targetDirectoryURL: targetDirectoryURL,
                workspaceRootURL: workspaceRootURL,
                optionKey: optionKey
            )
            Task { @MainActor in performOperation(request) }
        }
        return true
    }
}

@MainActor
enum WorkspaceFileOperationDialogs {
    static func confirmTrash(entry: WorkspaceFileEntry) -> Bool {
        let isNonEmptyDirectory = entry.kind == .directory && !(entry.children ?? []).isEmpty
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将“\(entry.name)”移到废纸篓？"
        alert.informativeText = isNonEmptyDirectory
            ? "此文件夹不是空的。整个文件夹会移到系统废纸篓，并可从 Finder 恢复。"
            : "项目会移到系统废纸篓，并可从 Finder 恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
