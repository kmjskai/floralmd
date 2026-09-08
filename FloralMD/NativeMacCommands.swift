import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FloralMDWindow {
    static let workspaceID = "floralmd-workspace"
}

@MainActor
struct FloralMDApplicationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.openFloralMDWorkspace) private var openWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建 Markdown") {
                activateWorkspace()
                QuickCaptureService.shared.perform()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(FloralMDCommandCatalog.newDrawing.title) {
                activateWorkspace()
                WorkspaceOpenRouter.shared.createDrawing()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button(FloralMDCommandCatalog.quickCapture.title) {
                activateWorkspace()
                QuickCaptureService.shared.perform()
            }
            .keyboardShortcut("n", modifiers: [.control, .option])
        }

        CommandGroup(after: .newItem) {
            Button("打开…") {
                guard let url = WorkspaceOpenPanel.chooseResource() else { return }
                activateWorkspace()
                WorkspaceOpenRouter.shared.open(url)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(FloralMDCommandCatalog.openWorkspace.title) {
                openWorkspace?.perform()
            }
            .keyboardShortcut("o", modifiers: [.command, .control])
            .disabled(openWorkspace == nil)

            Divider()

            Button(FloralMDCommandCatalog.changeDefaultFolder.title) {
                activateWorkspace()
                QuickCaptureService.shared.chooseAnotherFolder()
            }
        }
    }

    private func activateWorkspace() {
        if !WorkspaceOpenRouter.shared.activateCurrentWindow() {
            openWindow(id: FloralMDWindow.workspaceID)
        }
        NSApp.activate()
    }
}

@MainActor
struct FloralMDWorkspaceCommands: Commands {
    @FocusedValue(\.showFloralMDCommandPalette) private var showCommandPalette
    @FocusedValue(\.saveFloralMDResource) private var saveResource
    @FocusedValue(\.toggleFloralMDWorkspaceSidebar) private var toggleWorkspaceSidebar
    @FocusedValue(\.toggleFloralMDOutlineSidebar) private var toggleOutlineSidebar
    @FocusedValue(\.adjustFloralMDMarkdownViewportZoom) private var adjustMarkdownViewportZoom
    @FocusedValue(\.adjustFloralMDHarnessZoom) private var adjustHarnessViewportZoom

    /// 页面缩放的焦点路由：焦点在 harness 内 → harness；否则编辑器（harness 兜底）。
    private func performViewportZoom(_ adjustment: MarkdownViewportZoomAdjustment) {
        if HarnessModuleSelection.current.routesZoomToHarness(),
           let harness = adjustHarnessViewportZoom {
            harness.perform(adjustment)
        } else if let markdown = adjustMarkdownViewportZoom {
            markdown.perform(adjustment)
        } else {
            adjustHarnessViewportZoom?.perform(adjustment)
        }
    }

    private var isAnyViewportZoomAvailable: Bool {
        adjustHarnessViewportZoom != nil || adjustMarkdownViewportZoom != nil
    }
    @FocusedValue(\.workspaceFileSidebarCommandAction) private var workspaceFileAction
    @AppStorage(AppPreferenceKey.markdownTypewriterModeEnabled)
    private var isMarkdownTypewriterModeEnabled = false

    var body: some Commands {
        // `.saveItem` also owns the system Close Window command. Insert our
        // focus-aware save before it so AppKit keeps Command-W and routes it
        // through the key window's responder chain.
        CommandGroup(before: .saveItem) {
            Button("保存") {
                saveResource?.perform()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveResource?.isEnabled != true)
        }

        CommandGroup(after: .toolbar) {
            Button("Command Palette…") {
                showCommandPalette?()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(showCommandPalette == nil)

            Divider()

            Button("显示或隐藏工作区侧栏") {
                toggleWorkspaceSidebar?()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(toggleWorkspaceSidebar == nil)

            Button("显示或隐藏文档大纲") {
                toggleOutlineSidebar?()
            }
            .disabled(toggleOutlineSidebar == nil)

            Divider()

            Button(FloralMDCommandCatalog.increaseMarkdownViewportZoom.title) {
                performViewportZoom(.increase)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!isAnyViewportZoomAvailable)

            Button(FloralMDCommandCatalog.decreaseMarkdownViewportZoom.title) {
                performViewportZoom(.decrease)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!isAnyViewportZoomAvailable)

            Button(FloralMDCommandCatalog.resetMarkdownViewportZoom.title) {
                performViewportZoom(.reset)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!isAnyViewportZoomAvailable)
        }

        CommandGroup(after: .textEditing) {
            Toggle(
                FloralMDCommandCatalog.toggleMarkdownTypewriterMode.title,
                isOn: $isMarkdownTypewriterModeEnabled
            )
        }

        CommandMenu("Files") {
            if let workspaceFileAction {
                Button("剪切") { workspaceFileAction.perform(.cut) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("复制") { workspaceFileAction.perform(.copy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { workspaceFileAction.perform(.paste) }
                    .keyboardShortcut("v", modifiers: .command)
            } else {
                Button("剪切") {}
                    .disabled(true)
                Button("复制") {}
                    .disabled(true)
                Button("粘贴") {}
                    .disabled(true)
            }
            Divider()
            Button("快速查看") { workspaceFileAction?.perform(.quickLook) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(workspaceFileAction == nil)
            Button("重命名…") { workspaceFileAction?.perform(.rename) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(workspaceFileAction == nil)
            Button("移到废纸篓…") { workspaceFileAction?.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(workspaceFileAction == nil)
        }
    }
}

private enum WorkspaceOpenPanel {
    static func chooseResource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "打开 FloralMD 文件"
        panel.message = "选择 Markdown、Excalidraw 或支持的图片文件。"
        panel.prompt = "打开"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(importedAs: "net.daringfireball.markdown"),
            UTType(importedAs: "com.floralmd.excalidraw"),
            .png,
            .jpeg,
            .svg
        ]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

enum WorkspaceCloseReason: Equatable {
    case closeWindow
    case terminateApplication
}

@MainActor
final class WorkspaceLifecycleCoordinator {
    static let shared = WorkspaceLifecycleCoordinator()

    typealias RequestHandler = (WorkspaceCloseReason, @escaping (Bool) -> Void) -> Void

    private final class Entry {
        weak var owner: AnyObject?
        let handler: RequestHandler

        init(owner: AnyObject, handler: @escaping RequestHandler) {
            self.owner = owner
            self.handler = handler
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func install(owner: AnyObject, handler: @escaping RequestHandler) {
        compactEntries()
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, handler: handler)
    }

    func uninstall(owner: AnyObject) {
        entries.removeValue(forKey: ObjectIdentifier(owner))
    }

    func request(_ reason: WorkspaceCloseReason, completion: @escaping (Bool) -> Void) {
        compactEntries()
        guard let requestHandler = entries.values.first?.handler else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        requestHandler(reason, completion)
    }

    func request(
        owner: AnyObject,
        reason: WorkspaceCloseReason,
        completion: @escaping (Bool) -> Void
    ) {
        compactEntries()
        guard let handler = entries[ObjectIdentifier(owner)]?.handler else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        handler(reason, completion)
    }

    func requestAll(
        _ reason: WorkspaceCloseReason,
        completion: @escaping (Bool) -> Void
    ) {
        compactEntries()
        let handlers = entries.values.map(\.handler)
        func requestNext(_ index: Int) {
            guard index < handlers.count else {
                completion(true)
                return
            }
            handlers[index](reason) { shouldContinue in
                guard shouldContinue else {
                    completion(false)
                    return
                }
                requestNext(index + 1)
            }
        }
        requestNext(0)
    }

    private func compactEntries() {
        entries = entries.filter { $0.value.owner != nil }
    }
}

struct WorkspaceWindowCloseBridge: NSViewRepresentable {
    let owner: AnyObject

    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservationView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        private let owner: AnyObject
        private weak var window: NSWindow?
        private var proxy: WorkspaceWindowDelegateProxy?

        init(owner: AnyObject) {
            self.owner = owner
        }

        func install(on window: NSWindow?) {
            guard self.window !== window else { return }
            uninstall()
            guard let window else { return }

            let proxy = WorkspaceWindowDelegateProxy(forwardingTo: window.delegate)
            proxy.requestClose = { [weak self] in
                guard let self else { return }
                WorkspaceLifecycleCoordinator.shared.request(owner: self.owner, reason: .closeWindow) { [weak self] shouldClose in
                    guard shouldClose, let self, let window = self.window else { return }
                    self.proxy?.allowsNextClose = true
                    window.performClose(nil)
                }
            }
            self.window = window
            self.proxy = proxy
            window.delegate = proxy
        }

        func uninstall() {
            guard let window, window.delegate === proxy else {
                self.window = nil
                proxy = nil
                return
            }
            window.delegate = proxy?.forwardedDelegate
            self.window = nil
            proxy = nil
        }
    }
}

private final class WindowObservationView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

final class WorkspaceWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var forwardedDelegate: NSWindowDelegate?
    var requestClose: (() -> Void)?
    var allowsNextClose = false

    init(forwardingTo delegate: NSWindowDelegate?) {
        forwardedDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsNextClose {
            allowsNextClose = false
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }
        requestClose?()
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || (forwardedDelegate as AnyObject?)?.responds?(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if (forwardedDelegate as AnyObject?)?.responds?(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

private struct ToggleWorkspaceSidebarKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ToggleOutlineSidebarKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct MarkdownFontSizeAction {
    let currentSize: Double
    let perform: (MarkdownFontSizeAdjustment) -> Void

    func canPerform(_ adjustment: MarkdownFontSizeAdjustment) -> Bool {
        adjustment.isAvailable(at: currentSize)
    }
}

struct MarkdownViewportZoomAction {
    let currentScale: Double
    let perform: (MarkdownViewportZoomAdjustment) -> Void

    func canPerform(_ adjustment: MarkdownViewportZoomAdjustment) -> Bool {
        adjustment.isAvailable(at: currentScale)
    }
}

private struct AdjustMarkdownFontSizeKey: FocusedValueKey {
    typealias Value = MarkdownFontSizeAction
}

private struct AdjustMarkdownViewportZoomKey: FocusedValueKey {
    typealias Value = MarkdownViewportZoomAction
}

private struct AdjustHarnessViewportZoomKey: FocusedValueKey {
    typealias Value = MarkdownViewportZoomAction
}

extension FocusedValues {
    var toggleFloralMDWorkspaceSidebar: (() -> Void)? {
        get { self[ToggleWorkspaceSidebarKey.self] }
        set { self[ToggleWorkspaceSidebarKey.self] = newValue }
    }

    var toggleFloralMDOutlineSidebar: (() -> Void)? {
        get { self[ToggleOutlineSidebarKey.self] }
        set { self[ToggleOutlineSidebarKey.self] = newValue }
    }

    var adjustFloralMDMarkdownFontSize: MarkdownFontSizeAction? {
        get { self[AdjustMarkdownFontSizeKey.self] }
        set { self[AdjustMarkdownFontSizeKey.self] = newValue }
    }

    var adjustFloralMDMarkdownViewportZoom: MarkdownViewportZoomAction? {
        get { self[AdjustMarkdownViewportZoomKey.self] }
        set { self[AdjustMarkdownViewportZoomKey.self] = newValue }
    }

    var adjustFloralMDHarnessZoom: MarkdownViewportZoomAction? {
        get { self[AdjustHarnessViewportZoomKey.self] }
        set { self[AdjustHarnessViewportZoomKey.self] = newValue }
    }
}
