import Combine
import Foundation

typealias DraftWorkspaceRootProvider = () throws -> URL?

enum WorkspaceControllerError: LocalizedError {
    case draftWorkspaceUnavailable
    case noMarkdownSelected
    case unableToReadMarkdown(URL, String)
    case unableToSaveMarkdown(URL, String)
    case unableToCreateResource(URL, String)
    case unableToAllocateFilename(URL)
    case activeResourceUnavailable(URL)
    case externalMarkdownConflict(URL)

    var errorDescription: String? {
        switch self {
        case .draftWorkspaceUnavailable:
            return "尚未设置 FloralMD Drafts 文件夹。"
        case .noMarkdownSelected:
            return "当前没有可保存的 Markdown 文件。"
        case .unableToReadMarkdown(let url, let reason):
            return "无法读取“\(url.lastPathComponent)”：\(reason)"
        case .unableToSaveMarkdown(let url, let reason):
            return "无法保存“\(url.lastPathComponent)”：\(reason)"
        case .unableToCreateResource(let url, let reason):
            return "无法创建“\(url.lastPathComponent)”：\(reason)"
        case .unableToAllocateFilename(let directory):
            return "无法在“\(directory.lastPathComponent)”中生成唯一文件名。"
        case .activeResourceUnavailable(let url):
            return "“\(url.lastPathComponent)”已在外部被移动或删除；请刷新并确认新位置后再保存。"
        case .externalMarkdownConflict(let url):
            return "“\(url.lastPathComponent)”的磁盘版本已变化；请先选择载入磁盘版本或保留当前版本。"
        }
    }
}

struct WorkspaceFilenameAllocator {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func stem(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    func candidate(
        in directory: URL,
        pathExtension: String,
        date: Date,
        suffix: Int
    ) -> URL {
        let base = stem(for: date)
        let filename = suffix == 0
            ? "\(base).\(pathExtension)"
            : "\(base)-\(suffix).\(pathExtension)"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }
}

struct WorkspaceFileStore {
    private let fileManager: FileManager
    private let filenameAllocator: WorkspaceFilenameAllocator
    private let maximumFilenameAttempts: Int

    init(
        fileManager: FileManager = .default,
        filenameAllocator: WorkspaceFilenameAllocator = WorkspaceFilenameAllocator(),
        maximumFilenameAttempts: Int = 10_000
    ) {
        self.fileManager = fileManager
        self.filenameAllocator = filenameAllocator
        self.maximumFilenameAttempts = maximumFilenameAttempts
    }

    func loadMarkdown(at url: URL) throws -> String {
        do {
            return try CoordinatedMarkdownDiskStore().loadSnapshot(
                at: url,
                saveGeneration: 0
            ).text
        } catch {
            throw WorkspaceControllerError.unableToReadMarkdown(
                url,
                error.localizedDescription
            )
        }
    }

    func saveMarkdown(_ text: String, at url: URL) throws {
        do {
            try CoordinatedMarkdownDiskStore().save(text, at: url)
        } catch {
            throw WorkspaceControllerError.unableToSaveMarkdown(
                url,
                error.localizedDescription
            )
        }
    }

    func createUntitledMarkdown(
        in directory: URL,
        now: Date = Date()
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceControllerError.unableToCreateResource(
                directory,
                error.localizedDescription
            )
        }

        for suffix in 0..<maximumFilenameAttempts {
            let candidate = filenameAllocator.candidate(
                in: directory,
                pathExtension: "md",
                date: now,
                suffix: suffix
            )
            do {
                try Data().write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw WorkspaceControllerError.unableToCreateResource(
                    candidate,
                    error.localizedDescription
                )
            }
        }

        throw WorkspaceControllerError.unableToAllocateFilename(directory)
    }

    func drawingPlaceholderURL(
        in directory: URL,
        now: Date = Date()
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceControllerError.unableToCreateResource(
                directory,
                error.localizedDescription
            )
        }

        for suffix in 0..<maximumFilenameAttempts {
            let candidate = filenameAllocator.candidate(
                in: directory,
                pathExtension: "excalidraw",
                date: now,
                suffix: suffix
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw WorkspaceControllerError.unableToAllocateFilename(directory)
    }
}

@MainActor
final class WorkspaceController: ObservableObject {
    enum ActivePathState: Equatable {
        case available
        case movedExternally(from: URL, to: URL)
        case missingExternally(URL)
    }

    enum ExternalMarkdownState: Equatable {
        case none
        case updatedFromDisk(URL)
        case conflict(URL)
        case divergent(URL)
    }

    @Published private(set) var session: WorkspaceSession
    @Published var markdownText: String {
        didSet {
            guard !isReplacingMarkdownText else { return }
            isMarkdownDirty = session.activeResource?.kind == .markdown
                && markdownText != savedMarkdownText
            if isMarkdownDirty, case .updatedFromDisk = externalMarkdownState {
                externalMarkdownState = .none
            }
        }
    }
    @Published private(set) var isMarkdownDirty: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var activePathState: ActivePathState = .available
    @Published private(set) var externalMarkdownState: ExternalMarkdownState = .none

    private let draftRootProvider: DraftWorkspaceRootProvider
    private let fileStore: WorkspaceFileStore
    private let securityScopeAccessManager: SecurityScopedResourceAccessManager
    private var workspaceSecurityScopeLease: SecurityScopedResourceLease
    private var savedMarkdownText: String
    private var isReplacingMarkdownText = false
    private var activeResourceIdentity: WorkspaceFileIdentity?
    private let coordinatedDiskStore = CoordinatedMarkdownDiskStore()
    private var lastDiskSnapshot: MarkdownDiskSnapshot?
    private var pendingExternalSnapshot: MarkdownDiskSnapshot?
    private var pendingSave: (generation: UInt64, text: String)?
    private var saveGeneration: UInt64 = 0
    private var fileMonitor: ActiveMarkdownFileMonitor?
    private var monitorGeneration = UUID()

    var activeMarkdownFileMonitorForTesting: ActiveMarkdownFileMonitor? { fileMonitor }

    init(
        targetURL: URL? = nil,
        explicitWorkspaceRoot: URL? = nil,
        draftRootProvider: @escaping DraftWorkspaceRootProvider,
        fileStore: WorkspaceFileStore? = nil,
        securityScopeAccessManager: SecurityScopedResourceAccessManager = .shared
    ) throws {
        let resolvedFileStore = fileStore ?? WorkspaceFileStore()
        self.draftRootProvider = draftRootProvider
        self.fileStore = resolvedFileStore
        self.securityScopeAccessManager = securityScopeAccessManager

        let resolvedSession: WorkspaceSession
        let initialAuthorizationRootURL: URL
        let initialLease: SecurityScopedResourceLease
        if let explicitWorkspaceRoot {
            initialAuthorizationRootURL = explicitWorkspaceRoot
            initialLease = securityScopeAccessManager.acquire(initialAuthorizationRootURL)
            guard FolderAccessService.isReadableDirectory(explicitWorkspaceRoot) else {
                throw WorkspaceResolutionError.workspaceUnavailable(explicitWorkspaceRoot)
            }
            resolvedSession = WorkspaceResolver.explicitWorkspace(rootURL: explicitWorkspaceRoot)
        } else {
            let draftRoot = try draftRootProvider()
            resolvedSession = try Self.resolveSession(
                draftRoot: draftRoot,
                targetURL: targetURL
            )
            initialAuthorizationRootURL = Self.authorizationRootURL(
                for: resolvedSession,
                draftRoot: draftRoot,
                explicitAuthorizationRoot: nil
            )
            initialLease = securityScopeAccessManager.acquire(initialAuthorizationRootURL)
        }
        let initialText: String
        if let resource = resolvedSession.activeResource, resource.kind == .markdown {
            initialText = try resolvedFileStore.loadMarkdown(at: resource.url)
        } else {
            initialText = ""
        }

        workspaceSecurityScopeLease = initialLease
        session = resolvedSession
        markdownText = initialText
        savedMarkdownText = initialText
        isMarkdownDirty = false
        errorMessage = nil
        activeResourceIdentity = resolvedSession.activeResource.flatMap {
            WorkspaceFileCatalog.identity(for: $0.url)
        }
        if let resource = resolvedSession.activeResource, resource.kind == .markdown {
            lastDiskSnapshot = try? coordinatedDiskStore.loadSnapshot(
                at: resource.url,
                saveGeneration: saveGeneration
            )
        }
        configureActiveMarkdownMonitor()
    }

    deinit {
        fileMonitor?.stop()
        workspaceSecurityScopeLease.invalidate()
    }

    var activeResource: ActiveResource? { session.activeResource }

    var canReplaceWithExplicitWorkspace: Bool {
        session.activeResource == nil && !isMarkdownDirty
    }

    func clearError() {
        errorMessage = nil
    }

    func clearExternalUpdateNotice() {
        if case .updatedFromDisk = externalMarkdownState {
            externalMarkdownState = .none
        }
    }

    func loadExternalMarkdownVersion() {
        guard let snapshot = pendingExternalSnapshot else { return }
        pendingExternalSnapshot = nil
        acceptDiskSnapshot(snapshot, showsUpdateNotice: true)
    }

    func keepCurrentMarkdownVersion() {
        guard let snapshot = pendingExternalSnapshot else { return }
        pendingExternalSnapshot = nil
        lastDiskSnapshot = snapshot
        externalMarkdownState = .divergent(snapshot.url)
        isMarkdownDirty = true
        errorMessage = nil
    }

    func checkForExternalMarkdownChanges(suggestedURL: URL? = nil) {
        handleActiveMarkdownFileEvent(.rescan(suggestedURL: suggestedURL))
    }

    func open(
        targetURL: URL?,
        authorizationRootURL: URL? = nil
    ) throws {
        do {
            try saveMarkdownIfNeeded()
            let nextSession: WorkspaceSession
            let nextAuthorizationRootURL: URL
            if session.kind == .explicitFolder,
               let targetURL,
               WorkspaceResolver.contains(targetURL, in: session.rootURL) {
                guard let resource = ActiveResource(url: targetURL) else {
                    throw WorkspaceResolutionError.unsupportedResource(targetURL)
                }
                nextSession = WorkspaceSession(
                    rootURL: session.rootURL,
                    kind: .explicitFolder,
                    activeResource: resource
                )
                nextAuthorizationRootURL = workspaceSecurityScopeLease.url
            } else {
                let draftRoot = try draftRootProvider()
                nextSession = try Self.resolveSession(
                    draftRoot: draftRoot,
                    targetURL: targetURL
                )
                nextAuthorizationRootURL = Self.authorizationRootURL(
                    for: nextSession,
                    draftRoot: draftRoot,
                    explicitAuthorizationRoot: authorizationRootURL
                )
            }
            try activate(
                nextSession,
                authorizationRootURL: nextAuthorizationRootURL
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func selectResource(at url: URL) throws {
        try open(targetURL: url)
    }

    func openExplicitWorkspace(rootURL: URL) throws {
        do {
            try saveMarkdownIfNeeded()
            let root = rootURL.standardizedFileURL
            let replacementLease = securityScopeAccessManager.acquire(rootURL)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: root.path) else {
                replacementLease.invalidate()
                throw WorkspaceResolutionError.workspaceUnavailable(root)
            }
            try activate(
                WorkspaceResolver.explicitWorkspace(rootURL: root),
                authorizationRootURL: rootURL,
                acquiredLease: replacementLease
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func save() throws {
        do {
            if case .missingExternally = activePathState {
                throw WorkspaceControllerError.activeResourceUnavailable(
                    session.activeResource?.url ?? session.rootURL
                )
            }
            guard let resource = session.activeResource,
                  resource.kind == .markdown else {
                throw WorkspaceControllerError.noMarkdownSelected
            }
            if case .conflict = externalMarkdownState {
                throw WorkspaceControllerError.externalMarkdownConflict(resource.url)
            }
            saveGeneration &+= 1
            let generation = saveGeneration
            pendingSave = (generation, markdownText)
            try fileStore.saveMarkdown(markdownText, at: resource.url)
            savedMarkdownText = markdownText
            isMarkdownDirty = false
            lastDiskSnapshot = try? coordinatedDiskStore.loadSnapshot(
                at: resource.url,
                saveGeneration: generation
            )
            pendingExternalSnapshot = nil
            externalMarkdownState = .none
            errorMessage = nil
        } catch {
            pendingSave = nil
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func autosave() throws {
        guard !hasUnresolvedExternalConflict else { return }
        try save()
    }

    func saveBeforeClosingIfNeeded() throws {
        try saveMarkdownIfNeeded()
    }

    func reconcileExternalChanges(with entries: [WorkspaceFileEntry]) {
        guard let resource = session.activeResource,
              let activeResourceIdentity else { return }
        let flattened = WorkspaceFileTree.flattened(entries)
        if let matchingEntry = flattened.first(where: { $0.identity == activeResourceIdentity }),
           case .resource(let kind) = matchingEntry.kind,
           kind == resource.kind {
            let nextURL = matchingEntry.url.standardizedFileURL
            if nextURL != resource.url, let nextResource = ActiveResource(url: nextURL) {
                session.activeResource = nextResource
                configureActiveMarkdownMonitor()
                activePathState = .movedExternally(from: resource.url, to: nextURL)
            } else if case .missingExternally = activePathState {
                activePathState = .available
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: resource.url.path) else { return }
        activePathState = .missingExternally(resource.url)
        externalMarkdownState = .none
        pendingExternalSnapshot = nil
        errorMessage = WorkspaceControllerError.activeResourceUnavailable(resource.url).localizedDescription
    }

    func prepareForWorkspaceMutation(affecting itemURL: URL) throws {
        guard let activeResource = session.activeResource,
              WorkspaceResolver.contains(activeResource.url, in: itemURL) else { return }
        if activeResource.kind == .drawing {
            throw WorkspaceFileOperationError.activeDrawingRequiresSave
        }
        try saveMarkdownIfNeeded()
    }

    func applyWorkspaceRelocation(from sourceURL: URL, to destinationURL: URL) {
        guard let activeResource = session.activeResource,
              let relocatedURL = FileSidebarPathChange.relocatedURL(
                for: activeResource.url,
                moving: sourceURL,
                to: destinationURL
              ),
              let relocatedResource = ActiveResource(url: relocatedURL) else { return }
        session.activeResource = relocatedResource
        activeResourceIdentity = WorkspaceFileCatalog.identity(for: relocatedURL)
        activePathState = .available
        configureActiveMarkdownMonitor()
        errorMessage = nil
    }

    func applyWorkspaceRemoval(of itemURL: URL) {
        guard let activeResource = session.activeResource,
              WorkspaceResolver.contains(activeResource.url, in: itemURL) else { return }
        session.activeResource = nil
        activeResourceIdentity = nil
        activePathState = .available
        stopActiveMarkdownMonitor()
        externalMarkdownState = .none
        pendingExternalSnapshot = nil
        replaceMarkdownText(with: "")
    }

    @discardableResult
    func createUntitledMarkdown(now: Date = Date()) throws -> URL {
        do {
            try saveMarkdownIfNeeded()
            let layout = try draftLayout()
            let url = try fileStore.createUntitledMarkdown(
                in: layout.notesDirectory,
                now: now
            )
            let nextSession = try WorkspaceResolver.resolve(
                draftRoot: layout.root,
                targetURL: url
            )
            try activate(nextSession)
            NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func createDrawingPlaceholder(now: Date = Date()) throws -> URL {
        do {
            try saveMarkdownIfNeeded()
            let directory: URL
            let nextSessionForPlaceholder: (URL) throws -> WorkspaceSession
            if let resource = session.activeResource, resource.kind == .markdown {
                directory = resource.url.deletingLastPathComponent()
                    .appendingPathComponent("drawings", isDirectory: true)
                nextSessionForPlaceholder = { [session] url in
                    guard let resource = ActiveResource(url: url) else {
                        throw WorkspaceResolutionError.unsupportedResource(url)
                    }
                    var nextSession = session
                    nextSession.select(resource)
                    return nextSession
                }
            } else {
                let layout = try draftLayout()
                directory = layout.drawingsDirectory
                nextSessionForPlaceholder = { url in
                    try WorkspaceResolver.resolve(draftRoot: layout.root, targetURL: url)
                }
            }
            let url = try fileStore.drawingPlaceholderURL(
                in: directory,
                now: now
            )
            let nextSession = try nextSessionForPlaceholder(url)
            try activate(nextSession)
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func saveMarkdownIfNeeded() throws {
        guard isMarkdownDirty else { return }
        if hasUnresolvedExternalConflict {
            throw WorkspaceControllerError.externalMarkdownConflict(
                session.activeResource?.url ?? session.rootURL
            )
        }
        if case .missingExternally = activePathState {
            throw WorkspaceControllerError.activeResourceUnavailable(
                session.activeResource?.url ?? session.rootURL
            )
        }
        guard let resource = session.activeResource,
              resource.kind == .markdown else {
            throw WorkspaceControllerError.noMarkdownSelected
        }
        try save()
    }

    private var hasUnresolvedExternalConflict: Bool {
        switch externalMarkdownState {
        case .conflict, .divergent: true
        case .none, .updatedFromDisk: false
        }
    }

    private func activate(
        _ nextSession: WorkspaceSession,
        authorizationRootURL: URL? = nil,
        acquiredLease: SecurityScopedResourceLease? = nil
    ) throws {
        let rootChanged = nextSession.rootURL.standardizedFileURL
            != session.rootURL.standardizedFileURL
        let replacementLease = rootChanged
            ? acquiredLease ?? securityScopeAccessManager.acquire(
                authorizationRootURL ?? nextSession.rootURL
            )
            : nil
        if !rootChanged {
            acquiredLease?.invalidate()
        }
        let nextText: String
        do {
            if let resource = nextSession.activeResource, resource.kind == .markdown {
                nextText = try fileStore.loadMarkdown(at: resource.url)
            } else {
                nextText = ""
            }
        } catch {
            replacementLease?.invalidate()
            throw error
        }
        if let replacementLease {
            let previousLease = workspaceSecurityScopeLease
            workspaceSecurityScopeLease = replacementLease
            previousLease.invalidate()
        }

        session = nextSession
        activeResourceIdentity = nextSession.activeResource.flatMap {
            WorkspaceFileCatalog.identity(for: $0.url)
        }
        activePathState = .available
        externalMarkdownState = .none
        pendingExternalSnapshot = nil
        replaceMarkdownText(with: nextText)
        lastDiskSnapshot = nextSession.activeResource.flatMap {
            try? coordinatedDiskStore.loadSnapshot(at: $0.url, saveGeneration: saveGeneration)
        }
        configureActiveMarkdownMonitor()
    }

    private func replaceMarkdownText(with text: String) {
        isReplacingMarkdownText = true
        markdownText = text
        savedMarkdownText = text
        isMarkdownDirty = false
        isReplacingMarkdownText = false
    }

    private func configureActiveMarkdownMonitor() {
        stopActiveMarkdownMonitor()
        guard let resource = session.activeResource, resource.kind == .markdown else { return }
        let generation = UUID()
        monitorGeneration = generation
        let monitor = ActiveMarkdownFileMonitor(url: resource.url) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation else { return }
                self.handleActiveMarkdownFileEvent(event)
            }
        }
        fileMonitor = monitor
        monitor.start()
    }

    private func stopActiveMarkdownMonitor() {
        monitorGeneration = UUID()
        fileMonitor?.stop()
        fileMonitor = nil
    }

    private func handleActiveMarkdownFileEvent(
        _ event: ActiveMarkdownFileMonitor.Event,
        readAttempt: Int = 0
    ) {
        guard var resource = session.activeResource, resource.kind == .markdown else { return }

        let suggestedURL: URL?
        switch event {
        case .rescan(let url): suggestedURL = url
        }
        let suggestedStandardizedURL = suggestedURL?.standardizedFileURL
        let isSelfEvent = suggestedStandardizedURL == resource.url.standardizedFileURL
        let existsOnDisk = FileManager.default.fileExists(atPath: resource.url.path)

        // 无关子项事件（其他文件出现/变化/移动）：主线程零 IO，
        // 只发通知让侧边栏在后台重新加载目录。
        if existsOnDisk, suggestedStandardizedURL != nil, !isSelfEvent {
            NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
            return
        }

        // 活动文件路径上的事件：优先用 presenter 提示的目标位置做轻量
        // identity 确认（单次 stat），替代原来的全工作区递归扫描。
        if !isSelfEvent, let suggestedURL {
            if let identity = activeResourceIdentity,
               let suggestedIdentity = WorkspaceFileCatalog.identity(for: suggestedURL),
               suggestedIdentity == identity,
               let relocated = ActiveResource(url: suggestedURL) {
                let oldURL = resource.url
                session.activeResource = relocated
                resource = relocated
                activePathState = .movedExternally(from: oldURL, to: relocated.url)
                configureActiveMarkdownMonitor()
                NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
            }
        }

        guard FileManager.default.fileExists(atPath: resource.url.path) else {
            // 活动文件不在磁盘：同步标记缺失，再后台按 identity 全盘扫描
            // 兜底（可能被外部改名/移动而 presenter 提示丢失）。
            activePathState = .missingExternally(resource.url)
            externalMarkdownState = .none
            pendingExternalSnapshot = nil
            errorMessage = WorkspaceControllerError.activeResourceUnavailable(resource.url).localizedDescription
            NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
            scheduleExternalRelocationSearch(for: resource.url)
            return
        }

        let snapshot: MarkdownDiskSnapshot
        do {
            snapshot = try coordinatedDiskStore.loadSnapshot(
                at: resource.url,
                saveGeneration: saveGeneration
            )
        } catch {
            guard readAttempt < 3 else {
                errorMessage = WorkspaceControllerError.unableToReadMarkdown(
                    resource.url,
                    error.localizedDescription
                ).localizedDescription
                return
            }
            let retryGeneration = monitorGeneration
            let delay = [0.05, 0.15, 0.3][readAttempt]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.monitorGeneration == retryGeneration else { return }
                self.handleActiveMarkdownFileEvent(event, readAttempt: readAttempt + 1)
            }
            return
        }
        activeResourceIdentity = snapshot.identity ?? activeResourceIdentity

        if let pendingSave, snapshot.text == pendingSave.text {
            self.pendingSave = nil
            lastDiskSnapshot = snapshot.withSaveGeneration(pendingSave.generation)
            return
        }
        pendingSave = nil
        if let baseline = lastDiskSnapshot,
           Self.softContentEquals(snapshot.text, baseline.text) {
            lastDiskSnapshot = snapshot
            return
        }
        if case .divergent = externalMarkdownState,
           Self.softContentEquals(snapshot.text, markdownText) {
            acceptDiskSnapshot(snapshot, showsUpdateNotice: false)
            return
        }
        if isMarkdownDirty || externalMarkdownState == .divergent(resource.url) {
            pendingExternalSnapshot = snapshot
            externalMarkdownState = .conflict(resource.url)
            return
        }
        acceptDiskSnapshot(snapshot, showsUpdateNotice: true)
    }

    /// 活动文件从磁盘消失后，在后台按文件 identity 扫描整个工作区，
    /// 用于 presenter 提示缺失（如整体移动/改名竞态）时找回新位置。
    /// 扫描与结果应用之间用 generation + 当前活动资源双重校验防竞态。
    private func scheduleExternalRelocationSearch(for missingURL: URL) {
        guard let identity = activeResourceIdentity else { return }
        let generation = monitorGeneration
        let rootURL = session.rootURL
        Task.detached(priority: .utility) { [weak self] in
            let entries = try? WorkspaceFileCatalog().entries(in: rootURL)
            let match = entries.flatMap { list in
                WorkspaceFileTree.flattened(list).first {
                    $0.identity == identity && $0.kind == .resource(.markdown)
                }
            }
            await MainActor.run {
                guard let self,
                      self.monitorGeneration == generation,
                      let match,
                      let relocated = ActiveResource(url: match.url),
                      self.activePathState == .missingExternally(
                        missingURL.standardizedFileURL
                      ) else { return }
                self.session.activeResource = relocated
                self.activePathState = .movedExternally(
                    from: missingURL.standardizedFileURL,
                    to: relocated.url
                )
                self.configureActiveMarkdownMonitor()
                NotificationCenter.default.post(
                    name: .slateMemoWorkspaceDidChange,
                    object: nil
                )
            }
        }
    }

    private func acceptDiskSnapshot(
        _ snapshot: MarkdownDiskSnapshot,
        showsUpdateNotice: Bool
    ) {
        replaceMarkdownText(with: snapshot.text)
        lastDiskSnapshot = snapshot
        activeResourceIdentity = snapshot.identity ?? activeResourceIdentity
        activePathState = .available
        externalMarkdownState = showsUpdateNotice ? .updatedFromDisk(snapshot.url) : .none
        errorMessage = nil
    }

    nonisolated static func softContentEquals(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            var result = value
            if result.first == "\u{feff}" { result.removeFirst() }
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            while result.hasSuffix("\n") { result.removeLast() }
            return result
        }
        return normalized(lhs) == normalized(rhs)
    }

    private func draftLayout() throws -> DraftWorkspaceLayout {
        guard let draftRoot = try draftRootProvider() else {
            throw WorkspaceControllerError.draftWorkspaceUnavailable
        }
        return DraftWorkspaceLayout(root: draftRoot)
    }

    private static func resolveSession(
        draftRoot: URL?,
        targetURL: URL?
    ) throws -> WorkspaceSession {
        if let draftRoot {
            return try WorkspaceResolver.resolve(
                draftRoot: draftRoot,
                targetURL: targetURL
            )
        }

        guard let targetURL else {
            throw WorkspaceControllerError.draftWorkspaceUnavailable
        }
        guard let resource = ActiveResource(url: targetURL) else {
            throw WorkspaceResolutionError.unsupportedResource(targetURL)
        }
        return WorkspaceSession(
            rootURL: resource.url.deletingLastPathComponent(),
            kind: .externalFolder,
            activeResource: resource
        )
    }

    private static func authorizationRootURL(
        for session: WorkspaceSession,
        draftRoot: URL?,
        explicitAuthorizationRoot: URL?
    ) -> URL {
        if let explicitAuthorizationRoot {
            return explicitAuthorizationRoot
        }
        if session.kind == .draft, let draftRoot {
            return draftRoot
        }
        return session.rootURL
    }
}
