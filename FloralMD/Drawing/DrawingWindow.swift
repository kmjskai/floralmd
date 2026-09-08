import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DrawingWindow {
    static let id = "floralmd-drawing"
}

enum DrawingWindowTitle {
    static let untitled = "未命名绘图"

    static func title(for document: DrawingDocumentIdentity?) -> String {
        document?.sourceURL.lastPathComponent ?? untitled
    }

    static func ownsWindowTitle(embedded: Bool) -> Bool {
        !embedded
    }
}

struct DrawingLoadRequest: Equatable {
    let id: UUID
    let sceneJSON: String
}

struct DrawingPendingLoad: Equatable {
    let requestID: UUID
    let opened: OpenedDrawing
}

enum DrawingInitialResourceAction: Equatable {
    case ignore
    case beginPlaceholder
    case openExisting

    static func resolve(
        currentDocumentURL: URL?,
        targetURL: URL,
        targetExists: Bool,
        hasPendingLoad: Bool
    ) -> Self {
        guard targetURL.pathExtension.lowercased() == "excalidraw",
              currentDocumentURL?.standardizedFileURL != targetURL.standardizedFileURL,
              !hasPendingLoad else { return .ignore }
        return targetExists ? .openExisting : .beginPlaceholder
    }
}

struct DrawingFileSelectionState: Equatable {
    struct Pending: Equatable {
        let requestID: UUID
        let sourceURL: URL
    }

    private(set) var currentDocumentURL: URL?
    private(set) var pending: Pending?

    var displayedDocumentURL: URL? {
        pending?.sourceURL ?? currentDocumentURL
    }

    @discardableResult
    mutating func request(_ entry: DrawingFileEntry, id: UUID = UUID()) -> UUID {
        pending = Pending(requestID: id, sourceURL: entry.sourceURL.standardizedFileURL)
        return id
    }

    mutating func updateCurrent(_ url: URL?) {
        currentDocumentURL = url?.standardizedFileURL
        if pending?.sourceURL == currentDocumentURL {
            pending = nil
        }
    }

    @discardableResult
    mutating func promote(requestID: UUID) -> Bool {
        guard pending?.requestID == requestID else { return false }
        currentDocumentURL = pending?.sourceURL
        pending = nil
        return true
    }

    mutating func rollback(requestID: UUID? = nil) {
        guard requestID == nil || pending?.requestID == requestID else { return }
        pending = nil
    }

    mutating func clear() {
        currentDocumentURL = nil
        pending = nil
    }
}

private enum DrawingTransition {
    case newDrawing
    case newPlaceholder(URL, DrawingStorageLayout)
    case openPanel
    case openFile(DrawingFileEntry, DrawingStorageLayout, UUID)
    case closeWorkspace
}

private enum DrawingCompletionIntent {
    case save(DrawingStorageLayout, syncSVG: Bool)
    case exportSVG(URL)
    case establishBaseline
    case guardTransition(DrawingTransition)
}

enum DrawingCompletionError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "画布响应超时。当前绘图没有被替换，请重试。"
    }
}

extension Notification.Name {
    static let slateMemoNewDrawingRequested = Notification.Name("FloralMDNewDrawingRequested")
}

struct DrawingWindowTitleBridge: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleSyncView {
        TitleSyncView(title: title)
    }

    func updateNSView(_ view: TitleSyncView, context: Context) {
        view.title = title
    }

    final class TitleSyncView: NSView {
        var title: String {
            didSet { applyTitle() }
        }

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyTitle()
        }

        private func applyTitle() {
            window?.title = title
        }
    }
}

struct NativeDrawingFileList: NSViewRepresentable {
    let entries: [DrawingFileEntry]
    let selectedDocumentURL: URL?
    let requestSafeOpen: (DrawingFileEntry) -> Void

    func makeCoordinator() -> DrawingFileListCoordinator {
        DrawingFileListCoordinator(requestSafeOpen: requestSafeOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)

        let tableView = NSTableView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .small
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.refusesFirstResponder = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(DrawingFileListCoordinator.rowClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("drawing"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.update(
            entries: entries,
            selectedDocumentURL: selectedDocumentURL,
            requestSafeOpen: requestSafeOpen
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            entries: entries,
            selectedDocumentURL: selectedDocumentURL,
            requestSafeOpen: requestSafeOpen
        )
    }
}

@MainActor
final class DrawingFileListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?

    private(set) var entries: [DrawingFileEntry] = []
    private var selectedDocumentURL: URL?
    private var requestSafeOpen: (DrawingFileEntry) -> Void
    private var isUpdatingSelection = false
    private let drawingImage = NSImage(
        systemSymbolName: "scribble.variable",
        accessibilityDescription: nil
    )

    init(requestSafeOpen: @escaping (DrawingFileEntry) -> Void) {
        self.requestSafeOpen = requestSafeOpen
    }

    func update(
        entries: [DrawingFileEntry],
        selectedDocumentURL: URL?,
        requestSafeOpen: @escaping (DrawingFileEntry) -> Void
    ) {
        self.requestSafeOpen = requestSafeOpen
        let normalizedSelectedURL = selectedDocumentURL?.standardizedFileURL
        let entriesChanged = self.entries != entries
        let selectionChanged = self.selectedDocumentURL != normalizedSelectedURL
        self.entries = entries
        self.selectedDocumentURL = normalizedSelectedURL

        if entriesChanged {
            tableView?.reloadData()
        }
        if entriesChanged || selectionChanged {
            selectDisplayedDocument()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DrawingFileCell")
        let cell: NSTableCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView {
            cell = reusable
        } else {
            cell = makeCell(identifier: identifier)
        }
        cell.textField?.stringValue = entries[row].name
        cell.imageView?.image = drawingImage
        return cell
    }

    @objc func rowClicked(_ sender: NSTableView) {
        guard !isUpdatingSelection else { return }
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        activate(row: row)
    }

    func activate(row: Int) {
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        guard entry.sourceURL.standardizedFileURL != selectedDocumentURL else { return }
        selectedDocumentURL = entry.sourceURL.standardizedFileURL
        selectDisplayedDocument()
        DispatchQueue.main.async { [requestSafeOpen] in
            requestSafeOpen(entry)
        }
    }

    private func selectDisplayedDocument() {
        guard let tableView else { return }
        let matchingRow = entries.firstIndex {
            $0.sourceURL.standardizedFileURL == selectedDocumentURL
        }
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        if let matchingRow {
            tableView.selectRowIndexes(IndexSet(integer: matchingRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(matchingRow)
        } else {
            tableView.deselectAll(nil)
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

struct DrawingWindowView: View {
    let embedded: Bool
    let initialResourceURL: URL?
    let isActive: Bool
    let externalSaveRequest: Int
    let externalExportRequest: Int
    let externalCloseRequest: Int
    let workspaceCloseResolved: ((Bool) -> Void)?
    let selectionCancelled: ((URL) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var completionRequest = 0
    @State private var completionNeedsSVG = false
    @State private var resetRequest = 0
    @State private var loadRequest: DrawingLoadRequest?
    @State private var session = DrawingWorkspaceSession()
    @State private var fileSelection = DrawingFileSelectionState()
    @State private var pendingLoad: DrawingPendingLoad?
    @State private var requestedName = DrawingWindowTitle.untitled
    @State private var drawingLayout: DrawingStorageLayout?
    @State private var drawingFiles: [DrawingFileEntry] = []
    @State private var sidebarMessage = "正在读取绘图文件…"
    @State private var sidebarIsError = false
    @State private var showNamePrompt = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var status = "正在准备离线画布…"
    @State private var statusIsError = false
    @State private var windowPinningMode: WindowPinningMode = .none
    @AppStorage(AppPreferenceKey.pinnedWindowOpacityPercentage)
    private var pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.defaultPercentage
    @State private var completionIntent: DrawingCompletionIntent?
    @State private var completionTimeoutTask: Task<Void, Never>?
    @State private var loadTimeoutTask: Task<Void, Never>?
    @State private var pendingTransition: DrawingTransition?
    @State private var transitionAfterSave: DrawingTransition?
    @State private var showUnsavedChangesAlert = false
    @State private var isAwaitingResetBaseline = false
    @State private var currentResourceURL: URL?
    @State private var workspaceClosePending = false

    init(
        embedded: Bool = false,
        initialResourceURL: URL? = nil,
        isActive: Bool = true,
        externalSaveRequest: Int = 0,
        externalExportRequest: Int = 0,
        externalCloseRequest: Int = 0,
        workspaceCloseResolved: ((Bool) -> Void)? = nil,
        selectionCancelled: ((URL) -> Void)? = nil
    ) {
        self.embedded = embedded
        self.initialResourceURL = initialResourceURL?.standardizedFileURL
        self.isActive = isActive
        self.externalSaveRequest = externalSaveRequest
        self.externalExportRequest = externalExportRequest
        self.externalCloseRequest = externalCloseRequest
        self.workspaceCloseResolved = workspaceCloseResolved
        self.selectionCancelled = selectionCancelled
    }

    var body: some View {
        HStack(spacing: 0) {
            if !embedded {
                drawingSidebar
                Divider()
            }

            VStack(spacing: 0) {
                ExcalidrawWebView(
                    colorScheme: colorScheme,
                    drawingName: session.document?.name ?? requestedName,
                    completionRequest: completionRequest,
                    completionNeedsSVG: completionNeedsSVG,
                    resetRequest: resetRequest,
                    loadRequest: loadRequest,
                    onReady: {
                        status = "画布已就绪 · 所有绘图资源均为本地资源"
                        statusIsError = false
                        if session.baseline == nil, completionIntent == nil {
                            requestCompletion(for: .establishBaseline)
                        }
                    },
                    onClose: {
                        if !embedded { dismissWindow(id: DrawingWindow.id) }
                    },
                    onLoaded: handleLoaded,
                    onComplete: handleCompletion,
                    onError: handleCanvasError
                )

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(status)
                        .lineLimit(1)
                    Spacer()
                    if session.document != nil {
                        Text(session.document?.sourceURL.lastPathComponent ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.bar)
                .accessibilityIdentifier("drawingStatus")
            }
        }
        .frame(
            minWidth: DrawingWindowLayout.minimumWidth(embedded: embedded),
            minHeight: DrawingWindowLayout.minimumHeight(embedded: embedded)
        )
        .drawingWindowTitle(
            currentTitle,
            ownsWindowTitle: DrawingWindowTitle.ownsWindowTitle(embedded: embedded)
        )
        .background {
            if !embedded {
                ZStack {
                    DrawingWindowTitleBridge(title: currentTitle)
                    WindowPinningBridge(
                        mode: windowPinningMode,
                        pinnedWindowOpacity: PinnedWindowOpacityPreference.alpha(
                            for: pinnedWindowOpacityPercentage
                        )
                    )
                }
                .frame(width: 0, height: 0)
            }
        }
        .toolbar {
            if !embedded || isActive {
                ToolbarItem(placement: .primaryAction) {
                    drawingToolbarControls
                }
            }
        }
        .task {
            refreshDrawingFiles()
            openInitialResourceIfNeeded()
        }
        .onChange(of: initialResourceURL) { _, _ in
            openInitialResourceIfNeeded()
        }
        .onChange(of: externalSaveRequest) { _, _ in
            guard isActive else { return }
            saveCurrentDrawing()
        }
        .onChange(of: externalExportRequest) { _, _ in
            guard isActive else { return }
            requestManualSVGExport()
        }
        .onChange(of: externalCloseRequest) { _, _ in
            guard !workspaceClosePending else { return }
            workspaceClosePending = true
            requestTransition(.closeWorkspace)
        }
        .onAppear {
            pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.normalizeStoredValue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .slateMemoNewDrawingRequested)) { _ in
            requestNewDrawing()
        }
        .onDisappear {
            completionTimeoutTask?.cancel()
            loadTimeoutTask?.cancel()
            resolveWorkspaceClose(false)
        }
        .alert("绘图名称", isPresented: $showNamePrompt) {
            TextField("名称", text: $requestedName)
            Button("取消", role: .cancel) {
                transitionAfterSave = nil
                fileSelection.rollback()
                resolveWorkspaceClose(false)
            }
            Button("保存") { requestSave() }
        } message: {
            Text("将保存可编辑的 Excalidraw 源文件和对应 SVG；已有同名文件不会被覆盖。")
        }
        .alert("绘图操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("当前绘图有未保存的更改", isPresented: $showUnsavedChangesAlert) {
            Button("保存") {
                transitionAfterSave = pendingTransition
                pendingTransition = nil
                saveCurrentDrawing()
            }
            Button("放弃更改", role: .destructive) {
                guard let transition = pendingTransition else { return }
                pendingTransition = nil
                perform(transition)
            }
            Button("取消", role: .cancel) {
                pendingTransition = nil
                fileSelection.rollback()
                resolveWorkspaceClose(false)
                if let currentResourceURL {
                    selectionCancelled?(currentResourceURL)
                }
            }
        } message: {
            Text("新建或打开其他绘图会替换当前画布。")
        }
    }

    private var drawingToolbarControls: some View {
        HStack(spacing: 2) {
            if !embedded {
                Button(action: requestNewDrawing) {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建绘图")
                .help("新建绘图（⇧⌘D）")

                Button {
                    requestTransition(.openPanel)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开绘图")
                .help("打开绘图…")

                Divider().frame(height: 18).padding(.horizontal, 2)
            }

            Button(action: saveCurrentDrawing) {
                Image(systemName: "checkmark")
                    .frame(width: 28, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成绘图")
            .help("完成并保存绘图（⌘↩）")
            .keyboardShortcut(.return, modifiers: [.command])

            Button(action: requestManualSVGExport) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 28, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导出绘图 SVG")
            .help("导出 SVG…")

            if !embedded {
                Divider().frame(height: 18).padding(.horizontal, 2)
                Button(action: { windowPinningMode.toggle() }) {
                    Image(systemName: windowPinningMode.symbolName)
                        .frame(width: 28, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(windowPinningMode.actionTitle)
                .help(windowPinningMode.actionTitle)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var drawingSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scribble.variable")
                    .foregroundStyle(.secondary)
                Text("绘图")
                    .font(.headline)
                Spacer()
                Button(action: requestNewDrawing) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新建绘图")
                .accessibilityLabel("新建绘图")
                Button(action: refreshDrawingFiles) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新绘图列表")
                .accessibilityLabel("刷新绘图列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if drawingFiles.isEmpty {
                ContentUnavailableView {
                    Label(
                        drawingLayout == nil ? "尚未设置默认文件夹" : "没有绘图文件",
                        systemImage: drawingLayout == nil
                            ? "folder.badge.questionmark"
                            : "scribble.variable"
                    )
                } description: {
                    Text(sidebarIsError
                         ? sidebarMessage
                         : drawingLayout == nil
                            ? "首次保存时可选择默认文件夹，也可继续使用“打开…”入口。"
                            : "默认文件夹的 drawings 目录中暂无绘图。")
                }
                .foregroundStyle(sidebarIsError ? Color.red : Color.primary)
                .accessibilityIdentifier("drawingSidebarEmptyState")
            } else {
                NativeDrawingFileList(
                    entries: drawingFiles,
                    selectedDocumentURL: fileSelection.displayedDocumentURL,
                    requestSafeOpen: requestOpenDrawing
                )
                .scrollEdgeEffectHidden()
                .accessibilityIdentifier("drawingFileList")
            }

            Divider()

            Button("打开…") {
                requestTransition(.openPanel)
            }
                .frame(maxWidth: .infinity)
                .padding(10)
        }
        .frame(width: 220)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("绘图边栏")
    }

    private var currentTitle: String {
        DrawingWindowTitle.title(for: session.document)
    }

    private func openInitialResourceIfNeeded() {
        guard let initialResourceURL else { return }
        let action = DrawingInitialResourceAction.resolve(
            currentDocumentURL: session.document?.sourceURL,
            targetURL: initialResourceURL,
            targetExists: FileManager.default.fileExists(atPath: initialResourceURL.path),
            hasPendingLoad: pendingLoad != nil
        )
        guard action != .ignore else { return }

        do {
            let layout = DrawingStorageLayout.forSource(
                initialResourceURL,
                configuredDraftRoot: QuickCaptureService.shared.configuredFolderForDisplay()
            )
            drawingLayout = layout
            if action == .beginPlaceholder {
                let transition = DrawingTransition.newPlaceholder(initialResourceURL, layout)
                if session.baseline != nil {
                    requestTransition(transition)
                } else {
                    perform(transition)
                }
                return
            }
            let entry = DrawingFileEntry(sourceURL: initialResourceURL)
            let requestID = fileSelection.request(entry)
            let transition = DrawingTransition.openFile(entry, layout, requestID)
            if session.baseline != nil {
                requestTransition(transition)
            } else {
                try loadDrawing(entry, layout: layout, requestID: requestID)
            }
        } catch {
            fileSelection.rollback()
            present(error)
        }
    }

    private func saveCurrentDrawing() {
        if session.document == nil {
            requestedName = DrawingWindowTitle.untitled
            showNamePrompt = true
        } else {
            requestSave()
        }
    }

    private func requestSave() {
        do {
            guard let layout = try resolvedDrawingLayout(promptingIfNeeded: true) else {
                transitionAfterSave = nil
                fileSelection.rollback()
                status = "尚未设置新文档默认文件夹，绘图没有保存"
                statusIsError = true
                resolveWorkspaceClose(false)
                return
            }
            let policy = DrawingSVGSyncPreference.load()
            requestCompletion(for: .save(
                layout,
                syncSVG: policy.automaticallySyncsSVG(for: layout.scope)
            ))
        } catch {
            present(error)
            resolveWorkspaceClose(false)
        }
    }

    private func requestCompletion(for intent: DrawingCompletionIntent) {
        guard completionIntent == nil else { return }
        completionIntent = intent
        switch intent {
        case .save(_, let syncSVG):
            completionNeedsSVG = syncSVG
        case .exportSVG:
            completionNeedsSVG = true
        case .establishBaseline, .guardTransition:
            completionNeedsSVG = false
        }
        status = completionNeedsSVG
            ? "正在从 Web 画布接收场景、SVG 和图片数据…"
            : "正在从 Web 画布接收场景和图片数据…"
        statusIsError = false
        completionRequest += 1
        let requestID = completionRequest
        completionTimeoutTask?.cancel()
        completionTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard completionRequest == requestID, completionIntent != nil else { return }
            completionIntent = nil
            pendingTransition = nil
            transitionAfterSave = nil
            fileSelection.rollback()
            present(DrawingCompletionError.timedOut)
            resolveWorkspaceClose(false)
        }
    }

    private func handleCompletion(_ result: Result<DrawingExportPayload, Error>) {
        guard let intent = completionIntent else { return }
        completionTimeoutTask?.cancel()
        completionTimeoutTask = nil
        completionIntent = nil

        do {
            let payload = try result.get()
            switch intent {
            case .save(let layout, let syncSVG):
                try save(payload, layout: layout, syncSVG: syncSVG)
                resumePendingTransitionIfNeeded()
            case .exportSVG(let destinationURL):
                try DrawingStore.exportSVG(payload, to: destinationURL)
                status = "已导出 SVG：\(destinationURL.lastPathComponent)"
                statusIsError = false
            case .establishBaseline:
                try session.establishBaseline(from: payload)
                status = session.document.map {
                    "已载入 \($0.name) · 图片数据已恢复"
                } ?? "新绘图已就绪"
                statusIsError = false
                resumePendingTransitionIfNeeded()
            case .guardTransition(let transition):
                let requestedTransition = pendingTransition ?? transition
                pendingTransition = nil
                if try session.hasUnsavedChanges(in: payload) {
                    pendingTransition = requestedTransition
                    status = "当前绘图有未保存的更改"
                    statusIsError = false
                    showUnsavedChangesAlert = true
                } else {
                    perform(requestedTransition)
                }
            }
        } catch {
            pendingTransition = nil
            transitionAfterSave = nil
            fileSelection.rollback()
            present(error)
            resolveWorkspaceClose(false)
        }
    }

    private func resolvedDrawingLayout(
        promptingIfNeeded: Bool
    ) throws -> DrawingStorageLayout? {
        if let drawingLayout {
            return drawingLayout
        }
        return try DrawingStorageService.shared.configuredLayout(
            promptingIfNeeded: promptingIfNeeded
        )
    }

    private func save(
        _ payload: DrawingExportPayload,
        layout: DrawingStorageLayout,
        syncSVG: Bool
    ) throws {
        let isFirstSave = session.document == nil
        let saved = try DrawingStore(layout: layout).save(
            payload,
            proposedName: requestedName,
            replacing: session.document,
            syncSVG: syncSVG
        )
        try session.markSaved(saved, payload: payload)
        fileSelection.updateCurrent(saved.sourceURL)
        requestedName = saved.name
        drawingLayout = layout
        refreshDrawingFiles()
        currentResourceURL = saved.sourceURL
        let catalogChange = isFirstSave
            ? WorkspaceFileOperationResult(
                createdURL: saved.sourceURL,
                relocatedItem: nil,
                removedItemURL: nil
            )
            : nil
        NotificationCenter.default.post(
            name: .slateMemoWorkspaceDidChange,
            object: catalogChange
        )
        status = "Swift 已接收并保存：\(saved.name) · \(payload.scene.elementCount) 个元素"
        if !syncSVG { status += " · 未自动同步 SVG" }
        statusIsError = false

        if let transition = transitionAfterSave {
            transitionAfterSave = nil
            perform(transition)
        }
    }

    private func requestManualSVGExport() {
        let panel = NSSavePanel()
        panel.title = "导出绘图 SVG"
        panel.message = "选择 SVG 保存位置；若目标已存在，系统会要求确认后再覆盖。"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.svg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(DrawingNamePolicy.normalizedStem(requestedName)).svg"

        if let layout = try? resolvedDrawingLayout(promptingIfNeeded: false) {
            let preferredDirectory = layout.svgDirectory
            panel.directoryURL = FileManager.default.fileExists(atPath: preferredDirectory.path)
                ? preferredDirectory
                : preferredDirectory.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        requestCompletion(for: .exportSVG(destinationURL))
    }

    private func requestNewDrawing() {
        requestTransition(.newDrawing)
    }

    private func requestOpenDrawing(_ entry: DrawingFileEntry) {
        guard entry.sourceURL.standardizedFileURL != fileSelection.displayedDocumentURL else { return }
        guard let drawingLayout else {
            refreshDrawingFiles()
            return
        }
        let requestID = fileSelection.request(entry)
        let transition = DrawingTransition.openFile(entry, drawingLayout, requestID)
        if pendingLoad != nil {
            perform(transition)
        } else {
            requestTransition(transition)
        }
    }

    private func requestTransition(_ transition: DrawingTransition) {
        guard !showUnsavedChangesAlert else {
            pendingTransition = transition
            return
        }
        guard completionIntent == nil else {
            pendingTransition = transition
            status = "画布正在同步，已记录文件切换请求…"
            statusIsError = false
            return
        }
        requestCompletion(for: .guardTransition(transition))
    }

    private func resumePendingTransitionIfNeeded() {
        guard completionIntent == nil,
              !showUnsavedChangesAlert,
              transitionAfterSave == nil,
              let transition = pendingTransition else { return }
        pendingTransition = nil
        requestTransition(transition)
    }

    private func perform(_ transition: DrawingTransition) {
        switch transition {
        case .newDrawing:
            beginNewDrawing()
        case .newPlaceholder(let url, let layout):
            beginNewDrawing(targetURL: url, layout: layout)
        case .openPanel:
            openDrawingPanel()
        case .openFile(let entry, let layout, let requestID):
            do {
                try loadDrawing(entry, layout: layout, requestID: requestID)
            } catch {
                fileSelection.rollback(requestID: requestID)
                present(error)
            }
        case .closeWorkspace:
            resolveWorkspaceClose(true)
        }
    }

    private func beginNewDrawing(
        targetURL: URL? = nil,
        layout: DrawingStorageLayout? = nil
    ) {
        session.beginNewDrawing()
        fileSelection.clear()
        pendingLoad = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        requestedName = targetURL?.deletingPathExtension().lastPathComponent
            ?? DrawingWindowTitle.untitled
        currentResourceURL = targetURL
        if let layout { drawingLayout = layout }
        loadRequest = nil
        pendingTransition = nil
        isAwaitingResetBaseline = true
        status = "正在新建绘图…"
        statusIsError = false
        resetRequest += 1
        refreshDrawingFiles()
    }

    private func openDrawingPanel() {
        do {
            guard let selection = try DrawingStorageService.shared.chooseDrawingToOpen() else {
                if QuickCaptureService.shared.configuredFolderForDisplay() == nil {
                    status = "请先选择新文档默认文件夹"
                    statusIsError = true
                }
                return
            }
            let entry = DrawingFileEntry(sourceURL: selection.1)
            let requestID = fileSelection.request(entry)
            try loadDrawing(entry, layout: selection.0, requestID: requestID)
        } catch {
            fileSelection.rollback()
            present(error)
        }
    }

    private func loadDrawing(
        _ entry: DrawingFileEntry,
        layout: DrawingStorageLayout,
        requestID: UUID
    ) throws {
        let opened = try DrawingWorkspaceOpenPath.open(entry, in: layout)
        drawingLayout = layout
        pendingLoad = DrawingPendingLoad(requestID: requestID, opened: opened)
        status = "正在载入 \(opened.identity.name)…"
        statusIsError = false
        loadRequest = DrawingLoadRequest(id: requestID, sceneJSON: opened.scene.json)
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard pendingLoad?.requestID == requestID else { return }
            pendingLoad = nil
            fileSelection.rollback(requestID: requestID)
            present(DrawingCompletionError.timedOut)
        }
        refreshDrawingFiles()
    }

    private func handleLoaded(requestID: UUID?) {
        if let requestID {
            guard let pendingLoad, pendingLoad.requestID == requestID,
                  fileSelection.promote(requestID: requestID) else { return }
            loadTimeoutTask?.cancel()
            loadTimeoutTask = nil
            self.pendingLoad = nil
            do {
                try session.markOpened(pendingLoad.opened)
                currentResourceURL = pendingLoad.opened.identity.sourceURL
                requestedName = pendingLoad.opened.identity.name
                status = "已载入 \(pendingLoad.opened.identity.name) · 图片数据已恢复"
                statusIsError = false
                requestCompletion(for: .establishBaseline)
            } catch {
                fileSelection.updateCurrent(session.document?.sourceURL)
                present(error)
            }
            return
        }

        status = "新绘图已就绪"
        statusIsError = false
        if isAwaitingResetBaseline {
            isAwaitingResetBaseline = false
            requestCompletion(for: .establishBaseline)
        }
    }

    private func refreshDrawingFiles() {
        do {
            let configuredLayout = embedded && drawingLayout != nil
                ? nil
                : try DrawingStorageService.shared.configuredLayout(promptingIfNeeded: false)
            guard let layout = DrawingLayoutSelection.resolve(
                embedded: embedded,
                current: drawingLayout,
                configured: configuredLayout
            ) else {
                drawingLayout = nil
                drawingFiles = []
                sidebarMessage = "尚未设置新文档默认文件夹"
                sidebarIsError = false
                return
            }
            drawingLayout = layout
            drawingFiles = try DrawingFileCatalog(layout: layout).entries()
            sidebarMessage = "暂无已保存的绘图"
            sidebarIsError = false
        } catch {
            drawingFiles = []
            sidebarMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            sidebarIsError = true
        }
    }

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        showError = true
        status = "操作失败：\(message)"
        statusIsError = true
    }

    private func handleCanvasError(_ error: Error) {
        completionTimeoutTask?.cancel()
        completionTimeoutTask = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if let requestID = pendingLoad?.requestID {
            fileSelection.rollback(requestID: requestID)
            pendingLoad = nil
        }
        if completionIntent != nil {
            completionIntent = nil
            pendingTransition = nil
            transitionAfterSave = nil
        }
        present(error)
        resolveWorkspaceClose(false)
    }

    private func resolveWorkspaceClose(_ shouldClose: Bool) {
        guard workspaceClosePending else { return }
        workspaceClosePending = false
        workspaceCloseResolved?(shouldClose)
    }
}

enum DrawingWindowLayout {
    static func minimumWidth(embedded: Bool) -> Double {
        embedded ? 0 : 980
    }

    static func minimumHeight(embedded: Bool) -> Double {
        embedded ? 0 : 540
    }
}

private extension View {
    @ViewBuilder
    func drawingWindowTitle(_ title: String, ownsWindowTitle: Bool) -> some View {
        if ownsWindowTitle {
            navigationTitle(title)
        } else {
            self
        }
    }
}

private struct ExcalidrawWebView: NSViewControllerRepresentable {
    let colorScheme: ColorScheme
    let drawingName: String
    let completionRequest: Int
    let completionNeedsSVG: Bool
    let resetRequest: Int
    let loadRequest: DrawingLoadRequest?
    let onReady: () -> Void
    let onClose: () -> Void
    let onLoaded: (UUID?) -> Void
    let onComplete: (Result<DrawingExportPayload, Error>) -> Void
    let onError: (Error) -> Void

    final class Coordinator {
        var handledCompletionRequest = 0
        var handledResetRequest = 0
        var handledLoadRequest: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> ExcalidrawViewController {
        let controller = ExcalidrawViewController()
        controller.onReady = onReady
        controller.onClose = onClose
        controller.onLoaded = onLoaded
        controller.onComplete = onComplete
        controller.onError = onError
        controller.drawingName = drawingName
        controller.apply(colorScheme: colorScheme == .dark ? .darkAqua : .aqua)
        return controller
    }

    func updateNSViewController(_ controller: ExcalidrawViewController, context: Context) {
        controller.onReady = onReady
        controller.onClose = onClose
        controller.onLoaded = onLoaded
        controller.onComplete = onComplete
        controller.onError = onError
        controller.drawingName = drawingName
        controller.apply(colorScheme: colorScheme == .dark ? .darkAqua : .aqua)

        if resetRequest != context.coordinator.handledResetRequest {
            context.coordinator.handledResetRequest = resetRequest
            controller.resetScene()
        }
        if completionRequest != context.coordinator.handledCompletionRequest {
            context.coordinator.handledCompletionRequest = completionRequest
            controller.requestCompletion(includeSVG: completionNeedsSVG)
        }
        if let loadRequest, loadRequest.id != context.coordinator.handledLoadRequest {
            context.coordinator.handledLoadRequest = loadRequest.id
            controller.load(sceneJSON: loadRequest.sceneJSON, requestID: loadRequest.id)
        }
    }
}
