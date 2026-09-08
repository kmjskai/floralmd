import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class WorkspaceOpenRouter {
    static let shared = WorkspaceOpenRouter()

    private final class Registration {
        weak var controller: WorkspaceController?
        weak var window: NSWindow?

        init(controller: WorkspaceController) {
            self.controller = controller
        }
    }

    private var registrations: [Registration] = []
    private(set) var pendingTargetURL: URL?
    private(set) var hasPendingDrawingCreation = false

    var controller: WorkspaceController? {
        compactRegistrations()
        if let keyWindow = NSApp.keyWindow,
           let registration = registrations.first(where: { $0.window === keyWindow }) {
            return registration.controller
        }
        return registrations.last?.controller
    }

    func attach(_ controller: WorkspaceController) {
        compactRegistrations()
        if !registrations.contains(where: { $0.controller === controller }) {
            registrations.append(Registration(controller: controller))
        }
        if let pendingTargetURL {
            self.pendingTargetURL = nil
            open(pendingTargetURL)
        }
        if hasPendingDrawingCreation {
            hasPendingDrawingCreation = false
            createDrawing()
        }
    }

    func register(window: NSWindow?, for controller: WorkspaceController) {
        compactRegistrations()
        registrations.first(where: { $0.controller === controller })?.window = window
    }

    func detach(_ controller: WorkspaceController) {
        registrations.removeAll { $0.controller == nil || $0.controller === controller }
    }

    @discardableResult
    func activateCurrentWindow() -> Bool {
        guard let controller else { return false }
        activateWindow(for: controller)
        return true
    }

    @discardableResult
    func activateWindow(forExplicitWorkspace rootURL: URL) -> Bool {
        compactRegistrations()
        let root = rootURL.standardizedFileURL
        guard let registration = registrations.first(where: {
            $0.controller?.session.kind == .explicitFolder
                && $0.controller?.session.rootURL == root
        }) else { return false }
        NSApp.activate()
        registration.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func open(_ url: URL) {
        if let controller {
            do {
                let authorizationRootURL = try authorizeExternalWorkspaceIfNeeded(for: url)
                try controller.open(
                    targetURL: url,
                    authorizationRootURL: authorizationRootURL
                )
            } catch {
                NSApplication.shared.presentError(error)
            }
            activateWindow(for: controller)
        } else {
            pendingTargetURL = url
        }
    }

    /// Reuses an already-owned explicit-workspace window when a recent item
    /// points into that root. The controller remains the only state-transition
    /// owner, so a failed load cannot replace its current valid resource.
    @discardableResult
    func open(_ url: URL, inExplicitWorkspace rootURL: URL) -> Bool {
        compactRegistrations()
        let root = rootURL.standardizedFileURL
        guard WorkspaceResolver.contains(url, in: root),
              let registration = registrations.first(where: {
                  $0.controller?.session.kind == .explicitFolder
                      && $0.controller?.session.rootURL == root
              }),
              let controller = registration.controller else { return false }
        do {
            try controller.open(targetURL: url)
            activateWindow(for: controller)
        } catch {
            NSApplication.shared.presentError(error)
        }
        return true
    }

    /// Opens a Markdown link in the controller already attached to this window.
    /// Authorization happens before validation so sandboxed external folders can
    /// be inspected without routing the URL back through NSWorkspace.
    func openMarkdownLink(_ url: URL) throws {
        guard let controller else {
            throw MarkdownLinkNavigationError.documentRequired
        }
        let authorizationRootURL = try authorizeExternalWorkspaceIfNeeded(for: url)
        let validationRoot = WorkspaceResolver.contains(url, in: controller.session.rootURL)
            ? controller.session.rootURL
            : url.deletingLastPathComponent()
        try MarkdownLinkNavigationResolver().validateMarkdownURL(
            url,
            allowedRootURL: validationRoot
        )
        try controller.open(
            targetURL: url,
            authorizationRootURL: authorizationRootURL
        )
        activateWindow(for: controller)
    }

    func createDrawing() {
        guard let controller else {
            hasPendingDrawingCreation = true
            return
        }
        do {
            _ = try controller.createDrawingPlaceholder()
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    private func authorizeExternalWorkspaceIfNeeded(for targetURL: URL) throws -> URL? {
        if let controller,
           WorkspaceResolver.contains(targetURL, in: controller.session.rootURL) {
            return nil
        }
        if let draftRoot = QuickCaptureService.shared.configuredFolderForDisplay(),
           WorkspaceResolver.contains(targetURL, in: draftRoot) {
            return draftRoot
        }
        let root = targetURL.deletingLastPathComponent()
        if let restoredRoot = try FolderAccessService.shared.restoredFolder(for: root) {
            return restoredRoot
        }
        guard let authorizedRoot = try FolderAccessService.shared.requestAccess(to: root) else {
            throw MarkdownLinkNavigationError.authorizationCancelled(root)
        }
        return authorizedRoot
    }

    private func compactRegistrations() {
        registrations.removeAll { $0.controller == nil }
    }

    private func activateWindow(for controller: WorkspaceController) {
        compactRegistrations()
        NSApp.activate()
        registrations.first(where: { $0.controller === controller })?
            .window?.makeKeyAndOrderFront(nil)
    }
}

struct WorkspaceHostView: View {
    @Binding private var windowState: WorkspaceWindowState?
    @State private var controller: WorkspaceController?
    @State private var setupError: String?

    init(windowState: Binding<WorkspaceWindowState?>) {
        _windowState = windowState
    }

    var body: some View {
        Group {
            if let controller {
                WorkspaceContentView(controller: controller, windowState: $windowState)
            } else if let setupError {
                ContentUnavailableView {
                    Label("无法打开工作区", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(setupError)
                } actions: {
                    Button(windowState == nil ? "选择 FloralMD Drafts 文件夹…" : "重新选择工作区…") {
                        if windowState == nil {
                            configureWorkspace()
                        } else {
                            chooseReplacementWorkspace()
                        }
                    }
                }
                .frame(
                    minWidth: WorkspaceWindowLayout.minimumContentWidth,
                    minHeight: WorkspaceWindowLayout.minimumContentHeight
                )
            } else {
                ProgressView("正在打开 FloralMD Drafts…")
                    .frame(
                        minWidth: WorkspaceWindowLayout.minimumContentWidth,
                        minHeight: WorkspaceWindowLayout.minimumContentHeight
                    )
            }
        }
        .task { configureWorkspace() }
    }

    private func configureWorkspace() {
        do {
            if let explicitRoot = windowState?.explicitWorkspaceURL {
                guard let restoredRoot = try FolderAccessService.shared.restoredFolder(for: explicitRoot) else {
                    throw FolderAuthorizationError.unavailableFolder(explicitRoot)
                }
                let nextController = try WorkspaceController(
                    explicitWorkspaceRoot: restoredRoot,
                    draftRootProvider: {
                        try QuickCaptureService.shared.defaultDocumentFolder(promptingIfNeeded: false)
                    }
                )
                controller = nextController
                setupError = nil
                WorkspaceOpenRouter.shared.attach(nextController)
                return
            }
            guard let root = try QuickCaptureService.shared.defaultDocumentFolder(
                promptingIfNeeded: true
            ) else {
                setupError = "需要选择一个文件夹作为 FloralMD Drafts 工作区。"
                return
            }
            try DraftWorkspaceLayout(root: root).prepare()
            let nextController = try WorkspaceController(
                draftRootProvider: {
                    try QuickCaptureService.shared.defaultDocumentFolder(
                        promptingIfNeeded: false
                    )
                }
            )
            controller = nextController
            setupError = nil
            WorkspaceOpenRouter.shared.attach(nextController)
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func chooseReplacementWorkspace() {
        do {
            guard let root = try FolderAccessService.shared.chooseWorkspace() else { return }
            windowState = WorkspaceWindowState(explicitWorkspaceURL: root)
            controller = nil
            setupError = nil
            configureWorkspace()
        } catch {
            setupError = error.localizedDescription
        }
    }
}

struct WorkspaceContentView: View {
    enum InformationalToast: Equatable, Identifiable {
        case updatedFromDisk(URL)
        case movedExternally(URL)

        var id: String {
            switch self {
            case .updatedFromDisk(let url): "updated:\(url.standardizedFileURL.path)"
            case .movedExternally(let url): "moved:\(url.standardizedFileURL.path)"
            }
        }
    }

    enum PersistentNotice: Equatable {
        case conflict(URL)
        case divergent(URL)
        case missing(URL)
    }

    enum NoticePolicy {
        static let toastDuration: TimeInterval = 2.5

        static func persistentNotice(
            pathState: WorkspaceController.ActivePathState,
            externalState: WorkspaceController.ExternalMarkdownState
        ) -> PersistentNotice? {
            if case .missingExternally(let url) = pathState { return .missing(url) }
            switch externalState {
            case .conflict(let url): return .conflict(url)
            case .divergent(let url): return .divergent(url)
            case .none, .updatedFromDisk: return nil
            }
        }
    }

    @ObservedObject var controller: WorkspaceController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Binding private var windowState: WorkspaceWindowState?

    @State private var isFileSidebarVisible = true
    @State private var isOutlineSidebarVisible = false
    @State private var outlineNavigation: OutlineNavigation?
    @State private var windowPinningMode: WindowPinningMode
    @State private var presentedError = ""
    @State private var isShowingError = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var informationalToast: InformationalToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var retainedDrawingURL: URL?
    @State private var drawingSaveRequest = 0
    @State private var drawingExportRequest = 0
    @State private var drawingCloseRequest = 0
    @State private var pendingCloseCompletion: ((Bool) -> Void)?
    @State private var lifecycleOwner = WorkspaceLifecycleOwner()
    @State private var sidebarDragStartWidth: Double?
    @State private var liveSidebarWidth: Double?
    @State private var markdownContentDragStartWidth: Double?
    @State private var liveMarkdownContentWidth: Double?
    @State private var markdownContentWidthInteractionResetGeneration = 0
    @State private var markdownViewportZoom = MarkdownViewportZoom.defaultScale
    @State private var isMarkdownZoomHUDVisible = false
    @State private var markdownZoomHUDTask: Task<Void, Never>?
    /// 文件边栏的展开/选中状态：harnessOnly 时边栏视图被移除，但状态必须保留。
    @State private var sidebarExpandedDirectories: Set<WorkspaceFileIdentity> = []
    @State private var sidebarSelectedEntryURL: URL?
    /// 文档跳转返回栈（链接跳转/打开文档时记录离开的文档，工具栏返回按钮弹出）。
    @State private var documentBackStack: [URL] = []
    /// 返回按钮触发的切换不应再入栈（否则 back 后会立即被 push 回去）。
    @State private var isNavigatingBack = false
    @State private var recentPanel = RecentWorkspaceResourcePanel.empty
    @StateObject private var markdownContentWidthDamping = MarkdownContentWidthDampingController()
    @StateObject private var markdownEditorCommandTarget = MarkdownEditorCommandTarget()
    @StateObject private var recentResources = RecentWorkspaceResourceStore.shared

    @SceneStorage("floralmd.markdownContentWidth")
    private var storedMarkdownContentWidth = MarkdownContentWidthLayout.defaultPreferredWidth

    @AppStorage(AppPreferenceKey.workspaceSidebarWidth)
    private var storedSidebarWidth = WorkspaceSidebarLayout.defaultWidth
    @AppStorage(AppPreferenceKey.documentMode) private var modeRawValue = MarkdownMode.edit.rawValue
    @AppStorage(AppPreferenceKey.bodyFontName) private var bodyFontName = MarkdownTypography.defaultFontName
    @AppStorage(AppPreferenceKey.bodyFontSize) private var bodyFontSize = MarkdownTypography.defaultFontSize
    @AppStorage(AppPreferenceKey.bodyLineHeight) private var bodyLineHeight = MarkdownTypography.defaultLineHeight
    @AppStorage(AppPreferenceKey.markdownTypewriterModeEnabled)
    private var isMarkdownTypewriterModeEnabled = false
    @AppStorage(AppPreferenceKey.pinnedWindowOpacityPercentage)
    private var pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.defaultPercentage
    @AppStorage(AppPreferenceKey.centralMode)
    private var workspaceCentralModeRawValue = WorkspaceCentralMode.editorOnly.rawValue

    private var activeResource: ActiveResource? { controller.activeResource }
    private var activeKind: ResourceKind? { activeResource?.kind }
    private var activeURL: URL? { activeResource?.url }

    /// 窗口标题：Harness 独占模式显示面板名，其余模式显示当前编辑文档名。
    private var windowTitle: String {
        if HarnessModuleSelection.current.supportsHarnessModes,
           workspaceCentralMode == .harnessOnly {
            return "DeepSeek Harness"
        }
        return activeURL?.lastPathComponent ?? controller.session.rootURL.lastPathComponent
    }

    /// 文档切换时记录"离开的文档"进返回栈（返回按钮触发的切换除外）。
    private func recordDocumentBackStep(_ newURL: URL?) {
        guard !isNavigatingBack else { return }
        guard let newURL else { return }
        let standardized = newURL.standardizedFileURL
        guard standardized != documentBackStack.last else { return }
        documentBackStack.append(standardized)
        if documentBackStack.count > 50 {
            documentBackStack.removeFirst(documentBackStack.count - 50)
        }
    }

    /// 返回上一个文档（弹出返回栈并切换）。
    private func navigateBackInDocuments() {
        guard let target = documentBackStack.popLast() else { return }
        isNavigatingBack = true
        defer { isNavigatingBack = false }
        selectResource(target)
    }

    private var mode: MarkdownMode { MarkdownMode(rawValue: modeRawValue) ?? .edit }
    private var preferredSidebarWidth: Double {
        WorkspaceSidebarLayout.clampedWidth(liveSidebarWidth ?? storedSidebarWidth)
    }
    private var preferredMarkdownContentWidth: Double {
        MarkdownContentWidthLayout.preferredWidth(
            liveMarkdownContentWidth ?? storedMarkdownContentWidth
        )
    }
    private var displayedMarkdownContentWidth: Double {
        markdownContentWidthDamping.isSynchronized
            ? markdownContentWidthDamping.displayedWidth
            : preferredMarkdownContentWidth
    }

    private var typography: MarkdownTypography {
        MarkdownTypography(
            fontName: bodyFontName,
            fontSize: bodyFontSize,
            lineHeight: bodyLineHeight
        )
    }

    private var markdownViewportZoomAction: MarkdownViewportZoomAction? {
        guard activeKind == .markdown else { return nil }
        return MarkdownViewportZoomAction(
            currentScale: markdownViewportZoom,
            perform: adjustMarkdownViewportZoom
        )
    }

    init(
        controller: WorkspaceController,
        windowState: Binding<WorkspaceWindowState?> = .constant(nil)
    ) {
        self.controller = controller
        _windowState = windowState
        _windowPinningMode = State(initialValue: WorkspaceWindowPinningPreference.load())
    }

    var body: some View {
        let harnessModesEnabled = HarnessModuleSelection.current.supportsHarnessModes
        let editorVisible = !harnessModesEnabled || workspaceCentralMode != .harnessOnly
        return GeometryReader { geometry in
            workspace(
                layout: WorkspaceWindowLayout.resolve(
                    availableWidth: geometry.size.width,
                    preferredSidebarWidth: preferredSidebarWidth,
                    isFileSidebarVisible: isFileSidebarVisible && editorVisible,
                    isOutlineSidebarVisible: isOutlineSidebarVisible && editorVisible,
                    activeKind: activeKind
                )
            )
        }
        .frame(
            minWidth: WorkspaceWindowLayout.minimumContentWidth,
            minHeight: WorkspaceWindowLayout.minimumContentHeight
        )
        .navigationTitle(windowTitle)
        .background {
            ZStack {
                WindowPinningBridge(
                    mode: windowPinningMode,
                    pinnedWindowOpacity: PinnedWindowOpacityPreference.alpha(
                        for: pinnedWindowOpacityPercentage
                    )
                )
                WorkspaceWindowCloseBridge(owner: lifecycleOwner)
                WorkspaceWindowRegistrationBridge(controller: controller)
                recentResourceTracking
            }
            .frame(width: 0, height: 0)
        }
        .toolbar { workspaceToolbar }
        .alert("FloralMD 操作失败", isPresented: $isShowingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(presentedError)
        }
        .onChange(of: controller.markdownText) { _, _ in scheduleAutosave() }
        .onChange(of: activeURL) { _, newURL in
            markdownContentWidthInteractionResetGeneration &+= 1
            if activeKind == .drawing { retainedDrawingURL = newURL }
            recordDocumentBackStep(newURL)
        }
        .onChange(of: controller.activePathState) { _, state in
            handleActivePathNotice(state)
        }
        .onChange(of: controller.externalMarkdownState) { _, state in
            handleExternalMarkdownNotice(state)
        }
        .onDisappear {
            autosaveTask?.cancel()
            toastTask?.cancel()
            markdownZoomHUDTask?.cancel()
            markdownContentWidthDamping.cancel()
            WorkspaceLifecycleCoordinator.shared.uninstall(owner: lifecycleOwner)
            WorkspaceOpenRouter.shared.detach(controller)
            pendingCloseCompletion?(false)
            pendingCloseCompletion = nil
        }
        .onAppear {
            markdownContentWidthDamping.synchronize(to: preferredMarkdownContentWidth)
            WorkspaceLifecycleCoordinator.shared.install(owner: lifecycleOwner) { reason, completion in
                requestWorkspaceClose(reason: reason, completion: completion)
            }
            handleActivePathNotice(controller.activePathState)
            handleExternalMarkdownNotice(controller.externalMarkdownState)
        }
        .focusedSceneValue(\.showFloralMDCommandPalette) {
            CommandPalettePanelController.shared.show(commands: commandPaletteCommands)
        }
        .focusedSceneValue(
            \.openFloralMDWorkspace,
            FloralMDOpenWorkspaceAction(perform: openWorkspace)
        )
        .focusedSceneValue(
            \.saveFloralMDResource,
            FloralMDSaveAction(
                isEnabled: WorkspaceSaveRoute.resolve(activeKind: activeKind) != .unavailable,
                perform: saveActiveResource
            )
        )
        .focusedSceneValue(\.toggleFloralMDWorkspaceSidebar) {
            isFileSidebarVisible.toggle()
        }
        .focusedSceneValue(\.toggleFloralMDOutlineSidebar) {
            guard activeKind == .markdown else { return }
            isOutlineSidebarVisible.toggle()
        }
        .focusedSceneValue(
            \.adjustFloralMDMarkdownFontSize,
            activeKind == .markdown
                ? MarkdownFontSizeAction(currentSize: bodyFontSize, perform: adjustFontSize)
                : nil
        )
    }

    private var workspaceCentralMode: WorkspaceCentralMode {
        WorkspaceCentralMode(rawValue: workspaceCentralModeRawValue) ?? .editorOnly
    }

    private func workspace(layout: WorkspaceWindowLayout.Resolved) -> some View {
        let harnessModesEnabled = HarnessModuleSelection.current.supportsHarnessModes
        let editorVisible = !harnessModesEnabled || workspaceCentralMode != .harnessOnly
        let harnessVisible = harnessModesEnabled && workspaceCentralMode != .editorOnly
        // 并存模式下，编辑面与 Harness 面各占一半（减去分隔线）。
        let editorSurfaceWidth = (harnessModesEnabled && workspaceCentralMode == .split)
            ? max(WorkspaceWindowLayout.minimumContentWidth / 2, (layout.surfaceWidth - 1) / 2)
            : layout.surfaceWidth
        let harnessSurfaceWidth = (harnessModesEnabled && workspaceCentralMode == .split)
            ? editorSurfaceWidth
            : layout.surfaceWidth
        let markdownContentWidth = MarkdownContentWidthLayout.actualWidth(
            preferredWidth: displayedMarkdownContentWidth,
            surfaceWidth: editorSurfaceWidth,
            pageZoom: markdownViewportZoom
        )
        let markdownLeadingAccessoryWidth = mode == .edit
            ? MarkdownContentWidthLayout.editorGutterWidth
            : 0
        let markdownBoundaryMinimumLeadingHitOffset = isFileSidebarVisible && editorVisible
            ? WorkspaceSidebarLayout.resizeHandleHitWidth / 2 + 2
            : 0
        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if isFileSidebarVisible, editorVisible {
                    WorkspaceSidebarView(
                        rootURL: controller.session.rootURL,
                        selectedURL: activeURL,
                        select: selectResource,
                        createMarkdown: createMarkdown,
                        createDrawing: createDrawing,
                        didReload: controller.reconcileExternalChanges,
                        performOperation: performWorkspaceFileOperation,
                        performInlineRename: performWorkspaceFileOperationReporting,
                        expandedDirectories: $sidebarExpandedDirectories,
                        selectedEntryURL: $sidebarSelectedEntryURL
                    )
                    .frame(width: layout.sidebarWidth)
                    .clipped()
                }

                // 大纲只在编辑器上下文、且明确展开时构建（含 headings 解析）。
                if activeKind == .markdown, editorVisible {
                    Group {
                        if isOutlineSidebarVisible {
                            DocumentOutlineSidebar(
                                headings: MarkdownOutline.headings(in: controller.markdownText),
                                backgroundOpacity: windowPinningMode.sidebarBackgroundOpacity,
                                navigate: { outlineNavigation = OutlineNavigation(heading: $0) },
                                collapse: { isOutlineSidebarVisible = false }
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: DocumentOutlineLayout.expandedWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(
                        width: layout.outlineWidth,
                        alignment: .leading
                    )
                    .clipped()
                }

                // 编辑面与 Harness 面常驻视图树（WebView 不销毁），
                // 三态切换只改变宽度与透明度：宽度瞬时、透明度 0.15s 淡入淡出。
                editorSurface(
                    surfaceWidth: editorSurfaceWidth,
                    contentWidth: markdownContentWidth,
                    leadingAccessoryWidth: markdownLeadingAccessoryWidth,
                    boundaryMinimumLeadingHitOffset: markdownBoundaryMinimumLeadingHitOffset
                )
                .opacity(editorVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: editorVisible)
                .frame(width: editorVisible ? editorSurfaceWidth : 0)
                .clipped()
                .allowsHitTesting(editorVisible)

                if harnessModesEnabled, workspaceCentralMode == .split {
                    Divider()
                }

                if let harnessSurface = HarnessModuleSelection.current.workspaceSurface(isActive: harnessVisible) {
                    harnessSurface
                        .opacity(harnessVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: harnessVisible)
                        .frame(width: harnessVisible ? harnessSurfaceWidth : 0)
                        .clipped()
                        .allowsHitTesting(harnessVisible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if isFileSidebarVisible, editorVisible {
                WorkspaceSidebarResizeHandle(
                    drag: { resizeSidebar($0, startingWidth: layout.sidebarWidth) },
                    endDrag: finishSidebarResize,
                    reset: resetSidebarWidth
                )
                .offset(x: WorkspaceSidebarLayout.resizeHandleOffset(
                    sidebarWidth: layout.sidebarWidth
                ))
                .zIndex(10)
                .frame(maxHeight: .infinity)
            }
        }
        .clipped()
        .focusedSceneValue(
            \.adjustFloralMDMarkdownViewportZoom,
            markdownViewportZoomAction
        )
    }

    /// 编辑面（含居中宽度边界、通知与缩放 HUD）。供"仅编辑"与"左右并存"两种模式复用。
    private func editorSurface(
        surfaceWidth: CGFloat,
        contentWidth: CGFloat,
        leadingAccessoryWidth: CGFloat,
        boundaryMinimumLeadingHitOffset: CGFloat
    ) -> some View {
        centralSurface(contentWidth: contentWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) { activeResourceNameBadge }
            .overlay(alignment: .top) { centralSurfaceNotice }
            .overlay(alignment: .topTrailing) { markdownZoomHUD }
            .overlay(alignment: .leading) {
                if activeKind == .markdown {
                    ZStack(alignment: .leading) {
                        ForEach(MarkdownContentWidthResizeEdge.allCases, id: \.self) { edge in
                            // 原始语义（0a444c0）：surfaceWidth = 编辑面宽度，
                            // actualWidth = 渲染应用的内容列宽度（markdownContentWidth，
                            // 含视口/缩放限制，与渲染注入值一致）—— 边界线与内容列
                            // 完全对齐，拖拽中随 live 变化实时跟随。
                            let hitRegionOffset = MarkdownContentWidthLayout.boundaryHitRegionOffset(
                                surfaceWidth: surfaceWidth,
                                actualWidth: contentWidth,
                                edge: edge,
                                pageZoom: markdownViewportZoom,
                                leadingAccessoryWidth: leadingAccessoryWidth,
                                minimumLeadingOffset: boundaryMinimumLeadingHitOffset
                            )
                            let lineOffset = MarkdownContentWidthLayout.boundaryLineOffsetInHitRegion(
                                surfaceWidth: surfaceWidth,
                                actualWidth: contentWidth,
                                edge: edge,
                                pageZoom: markdownViewportZoom,
                                leadingAccessoryWidth: leadingAccessoryWidth,
                                minimumLeadingOffset: boundaryMinimumLeadingHitOffset
                            )
                            MarkdownContentWidthBoundary(
                                edge: edge,
                                lineOffset: lineOffset,
                                drag: {
                                    resizeMarkdownContent(
                                        $0,
                                        edge: edge,
                                        startingWidth: contentWidth,
                                        pageZoom: markdownViewportZoom
                                    )
                                },
                                endDrag: finishMarkdownContentResize,
                                reset: resetMarkdownContentWidth,
                                interactionResetGeneration: markdownContentWidthInteractionResetGeneration
                            )
                            .frame(
                                width: MarkdownContentWidthLayout.boundaryHitWidth,
                                height: nil
                            )
                            .frame(maxHeight: .infinity)
                            .offset(x: hitRegionOffset)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .zIndex(9)
                }
            }
            .clipped()
            .layoutPriority(1)
    }

    /// 编辑器区域顶部的活动资源名标识（markdown / 图片 / 绘图通用；空态不显示）。
    @ViewBuilder
    private var activeResourceNameBadge: some View {
        if let name = activeURL?.lastPathComponent {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var centralSurfaceNotice: some View {
        if let persistent = NoticePolicy.persistentNotice(
            pathState: controller.activePathState,
            externalState: controller.externalMarkdownState
        ) {
            persistentNotice(persistent)
                .padding(12)
        } else if let informationalToast {
            informationalToastView(informationalToast)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var markdownZoomHUD: some View {
        if activeKind == .markdown, isMarkdownZoomHUDVisible {
            Button {
                adjustMarkdownViewportZoom(.reset)
            } label: {
                Text("\(MarkdownViewportZoom.percentage(markdownViewportZoom))%")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .help("恢复 Markdown 内容区为 100%")
            .accessibilityLabel("Markdown 内容区缩放")
            .accessibilityValue("\(MarkdownViewportZoom.percentage(markdownViewportZoom))%")
            .padding(12)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            .zIndex(20)
        }
    }

    private func informationalToastView(_ toast: InformationalToast) -> some View {
        let content: (String, String) = switch toast {
        case .updatedFromDisk(let url):
            ("已从磁盘更新“\(url.lastPathComponent)”", "arrow.clockwise")
        case .movedExternally(let url):
            ("已跟随外部改名为“\(url.lastPathComponent)”", "arrow.trianglehead.2.clockwise.rotate.90")
        }
        return Label(content.0, systemImage: content.1)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private func persistentNotice(_ notice: PersistentNotice) -> some View {
        switch notice {
        case .missing(let url):
            compactBanner(
                text: "“\(url.lastPathComponent)”已在外部删除或移出工作区；保存已停用。",
                systemImage: "exclamationmark.triangle",
                color: .red
            )
        case .divergent(let url):
            compactBanner(
                text: "已保留“\(url.lastPathComponent)”的当前版本；自动保存已暂停，Command-S 会明确覆盖磁盘版本。",
                systemImage: "hand.raised",
                color: .orange
            )
        case .conflict(let url):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    conflictLabel(url)
                    conflictButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    conflictLabel(url)
                    conflictButtons
                }
            }
            .font(.callout)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.45)) }
            .frame(maxWidth: 720)
        }
    }

    private func conflictLabel(_ url: URL) -> some View {
        Label(
            "“\(url.lastPathComponent)”的磁盘版本已更改；当前内容未被覆盖。",
            systemImage: "exclamationmark.triangle"
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var conflictButtons: some View {
        HStack(spacing: 8) {
            Button("载入磁盘版本") { controller.loadExternalMarkdownVersion() }
            Button("保留当前版本") { controller.keepCurrentMarkdownVersion() }
        }
        .fixedSize()
    }

    private func compactBanner(
        text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.45)) }
            .frame(maxWidth: 680)
    }

    private func handleActivePathNotice(_ state: WorkspaceController.ActivePathState) {
        switch state {
        case .movedExternally(_, let destination):
            presentInformationalToast(.movedExternally(destination))
        case .missingExternally:
            dismissInformationalToast()
        case .available:
            break
        }
    }

    private func handleExternalMarkdownNotice(_ state: WorkspaceController.ExternalMarkdownState) {
        switch state {
        case .updatedFromDisk(let url):
            presentInformationalToast(.updatedFromDisk(url))
        case .conflict, .divergent:
            dismissInformationalToast()
        case .none:
            break
        }
    }

    private func presentInformationalToast(_ toast: InformationalToast) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { informationalToast = toast }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NoticePolicy.toastDuration))
            guard !Task.isCancelled, informationalToast == toast else { return }
            if case .updatedFromDisk = toast { controller.clearExternalUpdateNotice() }
            withAnimation(.easeIn(duration: 0.16)) { informationalToast = nil }
        }
    }

    private func dismissInformationalToast() {
        toastTask?.cancel()
        toastTask = nil
        withAnimation(.easeIn(duration: 0.12)) { informationalToast = nil }
    }

    @ViewBuilder
    private func centralSurface(contentWidth: Double) -> some View {
        ZStack {
            if activeKind != .drawing {
                switch activeKind {
                case .markdown:
                    markdownSurface(contentWidth: contentWidth)
                case .none:
                    WorkspaceStartPanel(
                        panel: recentPanel,
                        createMarkdown: createMarkdown,
                        createDrawing: createDrawing,
                        openWorkspace: openWorkspace,
                        openRecent: openRecentResource,
                        clearRecent: recentResources.clear
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                case .image:
                    if let activeURL {
                        WorkspaceImagePreview(url: activeURL)
                            .rejectsWorkspaceResourceDrops()
                    }
                case .drawing:
                    EmptyView()
                }
            }

            if let drawingURL = activeKind == .drawing ? activeURL : retainedDrawingURL {
                DrawingWindowView(
                    embedded: true,
                    initialResourceURL: drawingURL,
                    isActive: activeKind == .drawing,
                    externalSaveRequest: drawingSaveRequest,
                    externalExportRequest: drawingExportRequest,
                    externalCloseRequest: drawingCloseRequest,
                    workspaceCloseResolved: resolveWorkspaceClose,
                    selectionCancelled: restoreDrawingSelection
                )
                .opacity(activeKind == .drawing ? 1 : 0)
                .allowsHitTesting(activeKind == .drawing)
                .accessibilityHidden(activeKind != .drawing)
                .rejectsWorkspaceResourceDrops()
            }
        }
    }

    @ViewBuilder
    private func markdownSurface(contentWidth: Double) -> some View {
        Group {
            switch mode {
            case .edit:
                CodeMirrorEditorView(
                        markdown: markdownBinding,
                        contentWidth: contentWidth,
                        zoomScale: markdownViewportZoom,
                        documentURL: activeURL,
                        resourceContext: MarkdownLocalResourceContext(
                            session: controller.session,
                            documentURL: activeURL
                        ),
                        navigation: outlineNavigation,
                        typography: typography,
                        typewriterModeEnabled: isMarkdownTypewriterModeEnabled,
                        commandTarget: markdownEditorCommandTarget,
                        userDidEdit: {},
                        imagePasteHandler: persistPastedImage,
                        imageOpenHandler: openMarkdownImage,
                        resourceDropHandler: resolveDroppedResources,
                        linkNavigationHandler: navigateMarkdownLink,
                        zoomDidChange: handleMarkdownViewportZoomChange
                )
            case .preview:
                MarkdownPreviewWebView(
                        markdown: controller.markdownText,
                        contentWidth: contentWidth,
                        zoomScale: markdownViewportZoom,
                        documentURL: activeURL,
                        resourceContext: MarkdownLocalResourceContext(
                            session: controller.session,
                            documentURL: activeURL
                        ),
                        navigation: outlineNavigation,
                        typography: typography,
                        linkNavigationHandler: navigateMarkdownLink,
                        zoomDidChange: handleMarkdownViewportZoomChange
                )
                .rejectsWorkspaceResourceDrops()
            }
        }
        .overlay(alignment: .topLeading) {
            if activeKind == .markdown, !isOutlineSidebarVisible {
                DocumentOutlineControlButton(isExpanded: false) {
                    isOutlineSidebarVisible = true
                }
                .padding(DocumentOutlineLayout.controlInset)
            }
        }
        .overlay(alignment: .top) {
            if activeKind == .markdown,
               FloralMDEmptyStatePolicy.showsDocumentPrompt(
                   markdown: controller.markdownText,
                   mode: mode
               ) {
                Text("开始输入，或拖入文件建立引用")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: MarkdownContentWidthLayout.visualWidth(
                        actualWidth: contentWidth,
                        pageZoom: markdownViewportZoom
                    ), alignment: .leading)
                    .padding(.top, 56 * markdownViewportZoom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var markdownBinding: Binding<String> {
        Binding(
            get: { controller.markdownText },
            set: { newValue in
                if controller.activeResource == nil {
                    do {
                        _ = try controller.createUntitledMarkdown()
                    } catch {
                        present(error)
                        return
                    }
                }
                controller.markdownText = newValue
            }
        )
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        let harnessModesEnabled = HarnessModuleSelection.current.supportsHarnessModes
        let editorVisible = !harnessModesEnabled || workspaceCentralMode != .harnessOnly

        // 标题栏中央：三态分段切换（仅 Harness 形态提供）。
        if harnessModesEnabled {
            ToolbarItem(placement: .principal) {
                WorkspaceCentralModePicker(selection: $workspaceCentralModeRawValue)
            }
        }

        if editorVisible {
            ToolbarItem(placement: .navigation) {
                Button {
                    isFileSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(isFileSidebarVisible ? "收起工作区侧栏" : "展开工作区侧栏")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if editorVisible {
                Button {
                    navigateBackInDocuments()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("返回上一个文档（⌘[）")
                .disabled(documentBackStack.isEmpty)

                Button(action: createMarkdown) { Image(systemName: "note.text.badge.plus") }
                    .help("新建 Markdown")
                Button(action: createDrawing) { Image(systemName: "scribble.variable") }
                    .help("新建绘图")

                if activeKind == .markdown || activeKind == nil {
                    Picker("文档模式", selection: $modeRawValue) {
                        ForEach(MarkdownMode.allCases) { candidate in
                            Label(candidate.title, systemImage: candidate.systemImage)
                                .tag(candidate.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("编辑 / 预览")
                    .padding(.leading, 10)

                    Button {
                        do { try controller.save() } catch { present(error) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!controller.isMarkdownDirty)
                    .help("保存")
                }
            }

            let harnessVisible = harnessModesEnabled && workspaceCentralMode != .editorOnly
            if let supplement = HarnessModuleSelection.current.toolbarSupplement(
                context: HarnessToolbarContext(
                    activeDocumentPath: activeURL?.path,
                    harnessVisible: harnessVisible
                )
            ) {
                supplement
            }

            Menu {
                ForEach(WindowPinningMode.allCases) { mode in
                    Button {
                        windowPinningMode = mode
                    } label: {
                        if windowPinningMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.symbolName)
                        }
                    }
                }
            } label: {
                Image(systemName: windowPinningMode.symbolName)
            }
            .help(
                String(
                    format: String(localized: "窗口置顶：%@"),
                    windowPinningMode.title
                )
            )
            .padding(.leading, 10)
        }
    }

    var commandPaletteCommands: [FloralMDCommand] {
        [
            FloralMDCommand(descriptor: FloralMDCommandCatalog.openWorkspace, action: openWorkspace),
            FloralMDCommand(descriptor: FloralMDCommandCatalog.newDrawing, action: createDrawing),
            FloralMDCommand(descriptor: FloralMDCommandCatalog.quickCapture, action: createMarkdown),
            FloralMDCommand(descriptor: FloralMDCommandCatalog.changeDefaultFolder) {
                QuickCaptureService.shared.chooseAnotherFolder()
            },
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.drawingSVGSyncSettings,
                action: { openSettings() }
            ),
            FloralMDCommand(
                id: "mode.edit",
                title: "切换到编辑模式",
                systemImage: "pencil",
                keywords: "编辑 Markdown edit"
            ) { modeRawValue = MarkdownMode.edit.rawValue },
            FloralMDCommand(
                id: "mode.preview",
                title: "切换到预览模式",
                systemImage: "doc.richtext",
                keywords: "预览 Markdown preview"
            ) { modeRawValue = MarkdownMode.preview.rawValue },
            FloralMDCommand(
                id: "sidebar.files",
                title: isFileSidebarVisible ? "隐藏工作区侧栏" : "显示工作区侧栏",
                systemImage: "sidebar.left",
                keywords: "文件 工作区 侧栏"
            ) { isFileSidebarVisible.toggle() },
            FloralMDCommand(
                id: "sidebar.outline",
                title: isOutlineSidebarVisible ? "隐藏文档大纲" : "显示文档大纲",
                systemImage: "list.bullet.indent",
                keywords: "标题 大纲 outline"
            ) { isOutlineSidebarVisible.toggle() },
            FloralMDCommand(
                id: "window.pin.none",
                title: String(localized: "窗口不置顶"),
                systemImage: WindowPinningMode.none.symbolName,
                keywords: "窗口 取消 置顶 透明 Space"
            ) { windowPinningMode = .none },
            FloralMDCommand(
                id: "window.pin.current-space",
                title: String(localized: "窗口在当前 Space 置顶"),
                systemImage: WindowPinningMode.currentSpace.symbolName,
                keywords: "窗口 当前 置顶 透明 Space"
            ) { windowPinningMode = .currentSpace },
            FloralMDCommand(
                id: "window.pin.all-spaces",
                title: String(localized: "窗口在所有 Space 置顶"),
                systemImage: WindowPinningMode.allSpaces.symbolName,
                keywords: "窗口 全局 跨 置顶 透明 所有 Space"
            ) { windowPinningMode = .allSpaces },
            FloralMDCommand(
                id: "app.settings",
                title: "打开设置",
                systemImage: "gearshape",
                keywords: "偏好 设置"
            ) { openSettings() }
        ] + (activeKind == .markdown ? markdownViewportZoomCommands + markdownFontSizeCommands : [])
        + (activeKind == .markdown ? [
            FloralMDCommand(descriptor: FloralMDCommandCatalog.toggleMarkdownTypewriterMode) {
                isMarkdownTypewriterModeEnabled.toggle()
            },
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.insertBasicMarkdownTable,
                isEnabled: MarkdownTableInsertionAvailability.resolve(
                    activeKind: activeKind,
                    mode: mode,
                    editorReady: markdownEditorCommandTarget.isReady
                )
            ) {
                markdownEditorCommandTarget.insertBasicMarkdownTable()
            }
        ] : [])
        + (activeKind == .drawing ? [
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.exportDrawingSVG,
                action: { drawingExportRequest += 1 }
            )
        ] : [])
    }

    private func openWorkspace() {
        do {
            guard let root = try FolderAccessService.shared.chooseWorkspace() else { return }
            if WorkspaceOpenRouter.shared.activateWindow(forExplicitWorkspace: root) { return }

            let nextState = WorkspaceWindowState(explicitWorkspaceURL: root)
            if controller.canReplaceWithExplicitWorkspace {
                try controller.openExplicitWorkspace(rootURL: root)
                windowState = nextState
            } else {
                openWindow(value: nextState)
            }
        } catch {
            present(error)
        }
    }

    private func refreshRecentPanel() {
        recentPanel = recentResources.makePanel(
            currentWorkspaceRoot: controller.session.rootURL,
            accessState: recentAccessState
        )
    }

    private var recentResourceTracking: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                recordActiveResourceIfAvailable()
                refreshRecentPanel()
            }
            .onChange(of: activeURL) { _, _ in
                recordActiveResourceIfAvailable()
                refreshRecentPanel()
            }
            .onChange(of: controller.session.rootURL) { _, _ in
                refreshRecentPanel()
            }
            .onReceive(recentResources.$records) { _ in
                refreshRecentPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .slateMemoWorkspaceDidChange)) { _ in
                recordActiveResourceIfAvailable()
                refreshRecentPanel()
            }
            .accessibilityHidden(true)
    }

    private func recordActiveResourceIfAvailable() {
        guard let resource = controller.activeResource else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resource.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        recentResources.record(resource, in: controller.session)
    }

    private func recentAccessState(
        _ record: RecentWorkspaceResourceRecord
    ) -> RecentWorkspaceResourceAccessState {
        let root = record.workspaceRootURL
        if root == controller.session.rootURL.standardizedFileURL
            || root == QuickCaptureService.shared.configuredFolderForDisplay()?.standardizedFileURL {
            guard FolderAccessService.isReadableDirectory(root) else {
                return .needsAuthorization
            }
            return recentResourceExists(record) ? .available : .missing
        }
        do {
            guard try FolderAccessService.shared.restoredFolder(for: root) != nil else {
                return .needsAuthorization
            }
            return recentResourceExists(record) ? .available : .missing
        } catch {
            return .needsAuthorization
        }
    }

    private func recentResourceExists(_ record: RecentWorkspaceResourceRecord) -> Bool {
        guard let kind = record.resourceKind,
              kind == ResourceKind.resolve(url: record.resourceURL),
              WorkspaceResolver.contains(record.resourceURL, in: record.workspaceRootURL)
        else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: record.resourceURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }

    private func openRecentResource(_ item: RecentWorkspaceResourceItem) {
        do {
            if item.accessState == .needsAuthorization {
                guard try FolderAccessService.shared.requestAccess(to: item.workspaceRootURL) != nil else {
                    return
                }
            }
            guard recentResourceExists(item.record) else {
                recentResources.remove(item.record)
                refreshRecentPanel()
                return
            }

            if item.workspaceRootURL == controller.session.rootURL.standardizedFileURL {
                try controller.selectResource(at: item.resourceURL)
            } else if item.record.workspaceKind == .explicitFolder {
                if WorkspaceOpenRouter.shared.open(
                    item.resourceURL,
                    inExplicitWorkspace: item.workspaceRootURL
                ) {
                    return
                }
                try controller.openExplicitWorkspace(rootURL: item.workspaceRootURL)
                try controller.selectResource(at: item.resourceURL)
                windowState = WorkspaceWindowState(explicitWorkspaceURL: item.workspaceRootURL)
            } else {
                WorkspaceOpenRouter.shared.open(item.resourceURL)
            }
            isOutlineSidebarVisible = false
        } catch {
            present(error)
        }
    }

    private var markdownFontSizeCommands: [FloralMDCommand] {
        [
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.increaseMarkdownFontSize,
                action: { adjustFontSize(.increase) }
            ),
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.decreaseMarkdownFontSize,
                action: { adjustFontSize(.decrease) }
            ),
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.resetMarkdownFontSize,
                action: { adjustFontSize(.reset) }
            )
        ]
    }

    private var markdownViewportZoomCommands: [FloralMDCommand] {
        [
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.increaseMarkdownViewportZoom,
                action: { adjustMarkdownViewportZoom(.increase) }
            ),
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.decreaseMarkdownViewportZoom,
                action: { adjustMarkdownViewportZoom(.decrease) }
            ),
            FloralMDCommand(
                descriptor: FloralMDCommandCatalog.resetMarkdownViewportZoom,
                action: { adjustMarkdownViewportZoom(.reset) }
            )
        ]
    }

    private func adjustMarkdownViewportZoom(_ adjustment: MarkdownViewportZoomAdjustment) {
        markdownViewportZoom = adjustment.apply(to: markdownViewportZoom)
        showMarkdownZoomHUD(dismissAfterDelay: true)
    }

    private func handleMarkdownViewportZoomChange(
        _ scale: Double,
        phase: MarkdownViewportZoomInteractionPhase
    ) {
        markdownViewportZoom = MarkdownViewportZoom.clamped(scale)
        showMarkdownZoomHUD(dismissAfterDelay: phase == .ended)
    }

    private func showMarkdownZoomHUD(dismissAfterDelay: Bool) {
        markdownZoomHUDTask?.cancel()
        markdownZoomHUDTask = nil
        withAnimation(.easeOut(duration: 0.12)) {
            isMarkdownZoomHUDVisible = true
        }
        guard dismissAfterDelay else { return }
        markdownZoomHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                isMarkdownZoomHUDVisible = false
            }
        }
    }

    private func adjustFontSize(_ adjustment: MarkdownFontSizeAdjustment) {
        bodyFontSize = adjustment.apply(to: bodyFontSize)
    }

    private func selectResource(_ url: URL) {
        markdownContentWidthInteractionResetGeneration &+= 1
        do {
            try controller.selectResource(at: url)
            isOutlineSidebarVisible = false
        } catch {
            present(error)
        }
    }

    private func performWorkspaceFileOperation(_ request: WorkspaceFileOperationRequest) {
        do {
            _ = try performWorkspaceFileOperationReporting(request)
        } catch {
            present(error)
        }
    }

    @discardableResult
    private func performWorkspaceFileOperationReporting(
        _ request: WorkspaceFileOperationRequest
    ) throws -> WorkspaceFileOperationResult {
        switch request {
        case .rename(let itemURL, _),
             .duplicate(let itemURL),
             .copy(let itemURL, _),
             .move(let itemURL, _),
             .trash(let itemURL):
            try controller.prepareForWorkspaceMutation(affecting: itemURL)
        case .createMarkdown, .createDirectory, .importFile:
            break
        }
        let result = try WorkspaceFileOperationService().perform(
            request,
            workspaceRootURL: controller.session.rootURL
        )
        if let relocation = result.relocatedItem {
            controller.applyWorkspaceRelocation(from: relocation.from, to: relocation.to)
        }
        if let removedItemURL = result.removedItemURL {
            controller.applyWorkspaceRemoval(of: removedItemURL)
        }
        if let createdURL = result.createdURL,
           ResourceKind.resolve(url: createdURL) == .markdown {
            try controller.selectResource(at: createdURL)
        }
        NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: result)
        return result
    }

    private func resizeSidebar(_ translation: CGFloat, startingWidth: Double) {
        if sidebarDragStartWidth == nil {
            sidebarDragStartWidth = startingWidth
        }
        liveSidebarWidth = WorkspaceSidebarLayout.clampedWidth(
            (sidebarDragStartWidth ?? WorkspaceSidebarLayout.defaultWidth) + Double(translation)
        )
    }

    private func finishSidebarResize() {
        if let liveSidebarWidth {
            storedSidebarWidth = WorkspaceSidebarLayout.clampedWidth(liveSidebarWidth)
        }
        liveSidebarWidth = nil
        sidebarDragStartWidth = nil
    }

    private func resetSidebarWidth() {
        liveSidebarWidth = nil
        sidebarDragStartWidth = nil
        storedSidebarWidth = WorkspaceSidebarLayout.defaultWidth
    }

    private func resizeMarkdownContent(
        _ translation: CGFloat,
        edge: MarkdownContentWidthResizeEdge,
        startingWidth: Double,
        pageZoom: Double
    ) {
        if markdownContentDragStartWidth == nil {
            markdownContentDragStartWidth = startingWidth
        }
        liveMarkdownContentWidth = MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: markdownContentDragStartWidth
                ?? MarkdownContentWidthLayout.defaultPreferredWidth,
            translationPoints: Double(translation),
            edge: edge,
            pageZoom: pageZoom
        )
        markdownContentWidthDamping.setTarget(
            liveMarkdownContentWidth ?? MarkdownContentWidthLayout.defaultPreferredWidth
        )
    }

    private func finishMarkdownContentResize() {
        let finalTarget = liveMarkdownContentWidth.map {
            MarkdownContentWidthLayout.preferredWidth($0)
        } ?? storedMarkdownContentWidth
        storedMarkdownContentWidth = finalTarget
        markdownContentWidthDamping.setTarget(finalTarget)
        liveMarkdownContentWidth = nil
        markdownContentDragStartWidth = nil
    }

    private func resetMarkdownContentWidth() {
        liveMarkdownContentWidth = nil
        markdownContentDragStartWidth = nil
        storedMarkdownContentWidth = MarkdownContentWidthLayout.defaultPreferredWidth
        markdownContentWidthDamping.setTarget(
            MarkdownContentWidthLayout.defaultPreferredWidth
        )
    }

    private func saveActiveResource() {
        switch WorkspaceSaveRoute.resolve(activeKind: activeKind) {
        case .markdown:
            do { try controller.save() } catch { present(error) }
        case .drawing:
            drawingSaveRequest += 1
        case .unavailable:
            break
        }
    }

    private func requestWorkspaceClose(
        reason: WorkspaceCloseReason,
        completion: @escaping (Bool) -> Void
    ) {
        guard pendingCloseCompletion == nil else {
            completion(false)
            return
        }
        autosaveTask?.cancel()
        do {
            if controller.isMarkdownDirty {
                try controller.saveBeforeClosingIfNeeded()
            }
        } catch {
            present(error)
            completion(false)
            return
        }

        guard retainedDrawingURL != nil else {
            completion(true)
            return
        }
        pendingCloseCompletion = completion
        drawingCloseRequest += 1
    }

    private func resolveWorkspaceClose(_ shouldClose: Bool) {
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        completion?(shouldClose)
    }

    private func createMarkdown() {
        do {
            _ = try controller.createUntitledMarkdown()
            isOutlineSidebarVisible = false
        } catch {
            present(error)
        }
    }

    private func createDrawing() {
        do {
            _ = try controller.createDrawingPlaceholder()
            isOutlineSidebarVisible = false
        } catch {
            present(error)
        }
    }

    private func restoreDrawingSelection(_ url: URL) {
        do {
            try controller.selectResource(at: url)
            retainedDrawingURL = url
        } catch {
            present(error)
        }
    }

    private func persistPastedImage(_ request: MarkdownImagePasteRequest) throws -> String {
        let assets = try MarkdownImageAssetStore().persistClipboardItems(
            request.items,
            in: controller.session,
            markdownDocumentURL: controller.activeResource?.url
        )
        return assets.map(\.markdownInsertion).joined(separator: "\n")
    }

    private func openMarkdownImage(_ request: MarkdownImageOpenRequest, fileURL: URL) {
        _ = request
        FloralMDImageViewerCoordinator.shared.openImage(
            at: fileURL,
            authorizedBy: controller.session.rootURL
        )
    }

    private func resolveDroppedResources(_ urls: [URL]) throws -> String {
        try MarkdownResourceReferenceResolver().markdownInsertion(
            for: urls,
            in: controller.session,
            markdownDocumentURL: controller.activeResource?.url
        )
    }

    @discardableResult
    private func navigateMarkdownLink(_ destination: String) throws -> Bool {
        switch try MarkdownLinkNavigationResolver().resolve(
            destination,
            documentURL: activeURL,
            validatesTarget: false
        ) {
        case .fragment(let fragment):
            return navigateToFragment(fragment)
        case .markdown(let url, let fragment):
            try WorkspaceOpenRouter.shared.openMarkdownLink(url)
            isOutlineSidebarVisible = false
            if let fragment {
                _ = navigateToFragment(fragment)
            }
            return true
        case .external(let url):
            guard NSWorkspace.shared.open(url) else {
                throw MarkdownLinkNavigationError.unavailable(url)
            }
            return true
        case .unchanged:
            return false
        }
    }

    private func navigateToFragment(_ fragment: String) -> Bool {
        guard let heading = MarkdownOutline.heading(
            matchingFragment: fragment,
            in: controller.markdownText
        ) else { return false }
        outlineNavigation = OutlineNavigation(heading: heading)
        return true
    }

    private func scheduleAutosave() {
        guard controller.isMarkdownDirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(DocumentAutosavePolicy.delay))
                guard !Task.isCancelled, controller.isMarkdownDirty else { return }
                try controller.autosave()
            } catch is CancellationError {
                return
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        presentedError = error.localizedDescription
        isShowingError = true
    }
}

/// 标题栏中央的三态分段切换：编辑 / 并存 / Harness（仅 Harness 形态构建显示）。
/// 使用系统原生分段控件（macOS 液态玻璃分块外观，选中段自带高亮）。
private struct WorkspaceCentralModePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("中央区域模式", selection: $selection) {
            ForEach(WorkspaceCentralMode.allCases) { mode in
                Label(mode.segmentTitle, systemImage: mode.systemImage)
                    .tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("中央区域模式")
        .accessibilityLabel("中央区域模式")
    }
}

enum WorkspaceWindowLayout {
    static let minimumContentWidth = 760.0
    static let minimumContentHeight = 540.0
    static let regularMinimumSurfaceWidth = 440.0
    static let outlinedMarkdownMinimumSurfaceWidth = 330.0

    struct Resolved: Equatable {
        let sidebarWidth: Double
        let outlineWidth: Double
        let surfaceWidth: Double
    }

    static func resolve(
        availableWidth: Double,
        preferredSidebarWidth: Double,
        isFileSidebarVisible: Bool,
        isOutlineSidebarVisible: Bool,
        activeKind: ResourceKind?
    ) -> Resolved {
        let width = availableWidth.isFinite ? max(0, availableWidth) : minimumContentWidth
        let showsOutline = activeKind == .markdown && isOutlineSidebarVisible
        let outlineWidth = showsOutline ? Double(DocumentOutlineLayout.expandedWidth) : 0
        let minimumSurfaceWidth = showsOutline
            ? outlinedMarkdownMinimumSurfaceWidth
            : regularMinimumSurfaceWidth

        let sidebarWidth: Double
        if isFileSidebarVisible {
            let maximumAvailableSidebarWidth = max(
                WorkspaceSidebarLayout.minimumWidth,
                width - outlineWidth - minimumSurfaceWidth
            )
            sidebarWidth = min(
                WorkspaceSidebarLayout.clampedWidth(preferredSidebarWidth),
                maximumAvailableSidebarWidth
            )
        } else {
            sidebarWidth = 0
        }

        return Resolved(
            sidebarWidth: sidebarWidth,
            outlineWidth: outlineWidth,
            surfaceWidth: max(0, width - sidebarWidth - outlineWidth)
        )
    }
}

private struct RejectWorkspaceResourceDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool { false }
    func performDrop(info: DropInfo) -> Bool { false }
}

private extension View {
    func rejectsWorkspaceResourceDrops() -> some View {
        onDrop(
            of: [UTType.fileURL.identifier],
            delegate: RejectWorkspaceResourceDropDelegate()
        )
    }
}

private struct WorkspaceWindowRegistrationBridge: NSViewRepresentable {
    let controller: WorkspaceController

    func makeNSView(context: Context) -> NSView {
        let view = WorkspaceWindowRegistrationView()
        view.windowDidChange = { window in
            WorkspaceOpenRouter.shared.register(window: window, for: controller)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WorkspaceOpenRouter.shared.register(window: nsView.window, for: controller)
    }
}

private final class WorkspaceWindowRegistrationView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

private final class WorkspaceLifecycleOwner {}

enum WorkspaceSaveRoute: Equatable {
    case markdown
    case drawing
    case unavailable

    static func resolve(activeKind: ResourceKind?) -> WorkspaceSaveRoute {
        switch activeKind {
        case .markdown:
            .markdown
        case .drawing:
            .drawing
        case .image, .none:
            .unavailable
        }
    }
}

struct FloralMDSaveAction {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct FloralMDSaveActionKey: FocusedValueKey {
    typealias Value = FloralMDSaveAction
}

extension FocusedValues {
    var saveFloralMDResource: FloralMDSaveAction? {
        get { self[FloralMDSaveActionKey.self] }
        set { self[FloralMDSaveActionKey.self] = newValue }
    }
}

enum WorkspaceSidebarLayout {
    static let minimumWidth = 180.0
    static let defaultWidth = 250.0
    static let maximumWidth = 420.0
    static let resizeHandleLineWidth = 1.0
    static let resizeHandleHitWidth = 14.0

    static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    static func resizeHandleOffset(sidebarWidth: Double) -> Double {
        clampedWidth(sidebarWidth) - resizeHandleHitWidth / 2
    }
}

enum WorkspaceSidebarResizePhase: Equatable {
    case idle
    case hovering
    case dragging

    var lineWidth: Double {
        switch self {
        case .idle: 1
        case .hovering: 1.5
        case .dragging: 2
        }
    }

    var accentOpacity: Double? {
        switch self {
        case .idle: nil
        case .hovering: 0.55
        case .dragging: 0.85
        }
    }
}

final class WorkspaceSidebarResizeHandleView: NSView {
    private var drag: (CGFloat) -> Void = { _ in }
    private var endDrag: () -> Void = {}
    private var reset: () -> Void = {}
    private var phaseChanged: (WorkspaceSidebarResizePhase) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var dragStartWindowX: CGFloat?
    private var isPointerInside = false
    private var phase = WorkspaceSidebarResizePhase.idle {
        didSet {
            guard phase != oldValue else { return }
            phaseChanged(phase)
        }
    }

    private(set) var registeredCursorRect: NSRect?
    private(set) var registeredCursor: NSCursor?
    private(set) var cursorRectResetCount = 0
    private(set) var cursorRectInvalidationCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动调整侧边栏宽度；双击恢复默认宽度"
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("调整工作区侧边栏宽度")
        setAccessibilityHelp("拖动调整侧边栏宽度；双击恢复默认宽度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removeWindowObservers()
    }

    func configure(
        drag: @escaping (CGFloat) -> Void,
        endDrag: @escaping () -> Void,
        reset: @escaping () -> Void,
        phaseChanged: @escaping (WorkspaceSidebarResizePhase) -> Void
    ) {
        self.drag = drag
        self.endDrag = endDrag
        self.reset = reset
        self.phaseChanged = phaseChanged
        requestCursorRectUpdate()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        registeredCursorRect = bounds
        registeredCursor = .resizeLeftRight
        cursorRectResetCount += 1
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        requestCursorRectUpdate()
    }

    override func layout() {
        super.layout()
        requestCursorRectUpdate()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        if dragStartWindowX == nil {
            phase = .hovering
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if dragStartWindowX == nil {
            phase = .idle
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            reset()
            return
        }
        dragStartWindowX = event.locationInWindow.x
        phase = .dragging
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWindowX else { return }
        drag(event.locationInWindow.x - dragStartWindowX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartWindowX != nil else { return }
        dragStartWindowX = nil
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        phase = isPointerInside ? .hovering : .idle
        endDrag()
    }

    private func requestCursorRectUpdate() {
        guard let window else { return }
        cursorRectInvalidationCount += 1
        window.invalidateCursorRects(for: self)
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.requestCursorRectUpdate()
            })
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

private struct WorkspaceSidebarResizeHandleHost: NSViewRepresentable {
    let drag: (CGFloat) -> Void
    let endDrag: () -> Void
    let reset: () -> Void
    let phaseChanged: (WorkspaceSidebarResizePhase) -> Void

    func makeNSView(context: Context) -> WorkspaceSidebarResizeHandleView {
        let view = WorkspaceSidebarResizeHandleView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: WorkspaceSidebarResizeHandleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: WorkspaceSidebarResizeHandleView) {
        view.configure(
            drag: drag,
            endDrag: endDrag,
            reset: reset,
            phaseChanged: phaseChanged
        )
    }
}

struct WorkspaceSidebarResizeHandle: View {
    let drag: (CGFloat) -> Void
    let endDrag: () -> Void
    let reset: () -> Void

    @State private var phase = WorkspaceSidebarResizePhase.idle

    private var lineColor: Color {
        guard let accentOpacity = phase.accentOpacity else {
            return Color(nsColor: .separatorColor).opacity(0.9)
        }
        return Color.accentColor.opacity(accentOpacity)
    }

    var body: some View {
        ZStack {
            WorkspaceSidebarResizeHandleHost(
                drag: drag,
                endDrag: endDrag,
                reset: reset,
                phaseChanged: { phase = $0 }
            )
            Rectangle()
                .fill(lineColor)
                .frame(width: phase.lineWidth)
                .allowsHitTesting(false)
        }
        .frame(width: WorkspaceSidebarLayout.resizeHandleHitWidth)
        .animation(.easeOut(duration: 0.1), value: phase)
    }
}
