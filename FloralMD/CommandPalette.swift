import AppKit
import SwiftUI

struct FloralMDCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let keywords: String
    let shortcut: String?
    let isEnabled: Bool
    let action: () -> Void

    init(
        descriptor: FloralMDCommandDescriptor,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        id = descriptor.id
        title = descriptor.title
        systemImage = descriptor.systemImage
        keywords = descriptor.keywords
        shortcut = descriptor.shortcut
        self.isEnabled = isEnabled
        self.action = action
    }

    init(
        id: String,
        title: String,
        systemImage: String,
        keywords: String,
        shortcut: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.keywords = keywords
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }
}

struct FloralMDCommandDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let keywords: String
    let shortcut: String?

    init(
        id: String,
        title: String,
        systemImage: String,
        keywords: String,
        shortcut: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.keywords = keywords
        self.shortcut = shortcut
    }
}

enum MarkdownTableInsertionAvailability {
    static func resolve(
        activeKind: ResourceKind?,
        mode: MarkdownMode,
        editorReady: Bool
    ) -> Bool {
        activeKind == .markdown && mode == .edit && editorReady
    }
}

enum FloralMDCommandCatalog {
    static let openWorkspace = FloralMDCommandDescriptor(
        id: "app.open-workspace",
        title: String(localized: "Open Workspace…"),
        systemImage: "folder.badge.plus",
        keywords: "打开工作区 文件夹 open workspace folder",
        shortcut: "⌃⌘O"
    )

    static let newDrawing = FloralMDCommandDescriptor(
        id: "app.new-drawing",
        title: "新建绘图",
        systemImage: "pencil.and.outline",
        keywords: "绘图 画图 画布 drawing Excalidraw",
        shortcut: "⌘⇧D"
    )

    static let quickCapture = FloralMDCommandDescriptor(
        id: "app.quick-capture",
        title: "新建快速记录",
        systemImage: "note.text.badge.plus",
        keywords: "快速记录 新建笔记 capture note",
        shortcut: "⌃⌥N"
    )

    static let changeDefaultFolder = FloralMDCommandDescriptor(
        id: "app.change-default-folder",
        title: "更改新文档默认文件夹…",
        systemImage: "folder.badge.gearshape",
        keywords: "默认文件夹 保存位置 更改文件夹 folder location"
    )

    static let drawingSVGSyncSettings = FloralMDCommandDescriptor(
        id: "app.drawing-svg-sync-settings",
        title: "设置绘图 SVG 自动同步…",
        systemImage: "gearshape.2",
        keywords: "SVG 自动同步 导出 Draft 所有绘图 从不 设置"
    )

    static let exportDrawingSVG = FloralMDCommandDescriptor(
        id: "drawing.export-svg",
        title: "导出绘图 SVG…",
        systemImage: "square.and.arrow.up",
        keywords: "SVG 手动导出 绘图 drawing export"
    )

    static let increaseMarkdownFontSize = FloralMDCommandDescriptor(
        id: "markdown.font-size-increase",
        title: "增大 Markdown 基础字号",
        systemImage: "textformat.size.larger",
        keywords: "Markdown 基础字号 字体 排版 increase base font size"
    )

    static let decreaseMarkdownFontSize = FloralMDCommandDescriptor(
        id: "markdown.font-size-decrease",
        title: "减小 Markdown 基础字号",
        systemImage: "textformat.size.smaller",
        keywords: "Markdown 基础字号 字体 排版 decrease base font size"
    )

    static let resetMarkdownFontSize = FloralMDCommandDescriptor(
        id: "markdown.font-size-reset",
        title: "恢复默认 Markdown 基础字号",
        systemImage: "arrow.counterclockwise",
        keywords: "Markdown 基础字号 字体 排版 默认 重置 reset base font size"
    )

    static let increaseMarkdownViewportZoom = FloralMDCommandDescriptor(
        id: "markdown.viewport-zoom-increase",
        title: "放大 Markdown 内容区",
        systemImage: "plus.magnifyingglass",
        keywords: "Markdown 内容区 视图 缩放 放大 zoom in",
        shortcut: "⌘+"
    )

    static let decreaseMarkdownViewportZoom = FloralMDCommandDescriptor(
        id: "markdown.viewport-zoom-decrease",
        title: "缩小 Markdown 内容区",
        systemImage: "minus.magnifyingglass",
        keywords: "Markdown 内容区 视图 缩放 缩小 zoom out",
        shortcut: "⌘−"
    )

    static let resetMarkdownViewportZoom = FloralMDCommandDescriptor(
        id: "markdown.viewport-zoom-reset",
        title: "恢复 Markdown 内容区为 100%",
        systemImage: "1.magnifyingglass",
        keywords: "Markdown 内容区 视图 缩放 百分比 100 默认 重置 reset zoom",
        shortcut: "⌘0"
    )

    static let toggleMarkdownTypewriterMode = FloralMDCommandDescriptor(
        id: "markdown.typewriter-mode.toggle",
        title: String(localized: "切换 Markdown 打字机模式"),
        systemImage: "text.line.first.and.arrowtriangle.forward",
        keywords: "Markdown 打字机模式 光标 跟随 typewriter focus scroll"
    )

    static let insertBasicMarkdownTable = FloralMDCommandDescriptor(
        id: "markdown.table.insert-basic",
        title: "插入表格",
        systemImage: "tablecells",
        keywords: "Markdown 表格 插入 table grid"
    )

    static let menuBackedCommands = [
        openWorkspace,
        newDrawing,
        quickCapture,
        changeDefaultFolder,
        drawingSVGSyncSettings,
        increaseMarkdownViewportZoom,
        decreaseMarkdownViewportZoom,
        resetMarkdownViewportZoom,
        toggleMarkdownTypewriterMode,
        increaseMarkdownFontSize,
        decreaseMarkdownFontSize,
        resetMarkdownFontSize
    ]

    static let markdownFontSizeCommandIDs: Set<String> = [
        increaseMarkdownFontSize.id,
        decreaseMarkdownFontSize.id,
        resetMarkdownFontSize.id
    ]

    static let markdownViewportZoomCommandIDs: Set<String> = [
        increaseMarkdownViewportZoom.id,
        decreaseMarkdownViewportZoom.id,
        resetMarkdownViewportZoom.id
    ]

    static let markdownEditingCommandIDs: Set<String> = [
        toggleMarkdownTypewriterMode.id,
        insertBasicMarkdownTable.id
    ]

    static let requiredCommandIDs: Set<String> = [
        "mode.edit",
        "mode.preview",
        "sidebar.files",
        "sidebar.outline",
        "window.pin.none",
        "window.pin.current-space",
        "window.pin.all-spaces",
        "app.settings",
        exportDrawingSVG.id,
        openWorkspace.id,
        newDrawing.id,
        quickCapture.id,
        changeDefaultFolder.id,
        drawingSVGSyncSettings.id,
        increaseMarkdownViewportZoom.id,
        decreaseMarkdownViewportZoom.id,
        resetMarkdownViewportZoom.id,
        increaseMarkdownFontSize.id,
        decreaseMarkdownFontSize.id,
        resetMarkdownFontSize.id,
        toggleMarkdownTypewriterMode.id,
        insertBasicMarkdownTable.id
    ]
}

struct FloralMDOpenWorkspaceAction {
    let perform: () -> Void
}

private struct OpenFloralMDWorkspaceKey: FocusedValueKey {
    typealias Value = FloralMDOpenWorkspaceAction
}

extension FocusedValues {
    var openFloralMDWorkspace: FloralMDOpenWorkspaceAction? {
        get { self[OpenFloralMDWorkspaceKey.self] }
        set { self[OpenFloralMDWorkspaceKey.self] = newValue }
    }
}

enum CommandPaletteLayout {
    static let width: CGFloat = 600
    static let height: CGFloat = 380
}

enum CommandPaletteSearch {
    static func filter(
        _ commands: [FloralMDCommand],
        query: String
    ) -> [FloralMDCommand] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery) ||
            $0.keywords.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}

struct CommandPaletteView: View {
    let commands: [FloralMDCommand]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selectionID: String?
    @FocusState private var isSearchFocused: Bool

    private var filteredCommands: [FloralMDCommand] {
        CommandPaletteSearch.filter(commands, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索命令", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium))
                    .focused($isSearchFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            Divider()

            if filteredCommands.isEmpty {
                FloralMDEmptyState(
                    kind: .search,
                    title: "没有找到命令",
                    message: "换个关键词试试"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List(filteredCommands, selection: $selectionID) { command in
                    Button {
                        execute(command)
                    } label: {
                        HStack(spacing: 12) {
                            Label(command.title, systemImage: command.systemImage)
                                .font(.system(size: 15.5, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                            Spacer(minLength: 20)
                            if let shortcut = command.shortcut {
                                Text(shortcut)
                                    .font(.system(
                                        size: 14,
                                        weight: .medium,
                                        design: .monospaced
                                    ))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!command.isEnabled)
                    .tag(command.id)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: CommandPaletteLayout.width, height: CommandPaletteLayout.height)
        .onAppear {
            selectionID = filteredCommands.first?.id
        }
        .onChange(of: query) {
            selectionID = filteredCommands.first?.id
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let command = selectedCommand else { return .ignored }
            execute(command)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var selectedCommand: FloralMDCommand? {
        filteredCommands.first { $0.id == selectionID } ?? filteredCommands.first
    }

    private func moveSelection(by offset: Int) {
        guard !filteredCommands.isEmpty else { return }
        let currentIndex = filteredCommands.firstIndex { $0.id == selectionID } ?? 0
        let targetIndex = min(max(currentIndex + offset, 0), filteredCommands.count - 1)
        selectionID = filteredCommands[targetIndex].id
    }

    private func execute(_ command: FloralMDCommand) {
        guard command.isEnabled else { return }
        dismiss()
        command.action()
    }
}

@MainActor
final class CommandPalettePanelController: NSObject, NSWindowDelegate {
    static let shared = CommandPalettePanelController()

    private var panel: CommandPalettePanel?

    func show(commands: [FloralMDCommand]) {
        dismiss()

        let panel = CommandPalettePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CommandPaletteLayout.width,
                height: CommandPaletteLayout.height
            ),
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let content = CommandPaletteView(commands: commands) { [weak self] in
            self?.dismiss()
        }
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: .rect(cornerRadius: 18)
        )
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        panel.contentView = NSHostingView(rootView: content)

        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        position(panel, over: parentWindow)
        if let parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        focusSearchField(in: panel)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSPanel,
              panel === closingPanel else { return }
        panel = nil
        closingPanel.parent?.removeChildWindow(closingPanel)
        closingPanel.contentView = nil
    }

    private func focusSearchField(in panel: CommandPalettePanel) {
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            panel.contentView?.layoutSubtreeIfNeeded()
            guard let contentView = panel.contentView,
                  let searchField = self.firstTextField(in: contentView) else { return }
            panel.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = firstTextField(in: subview) {
                return textField
            }
        }
        return nil
    }

    private func position(_ panel: NSPanel, over parentWindow: NSWindow?) {
        guard let parentWindow else {
            panel.center()
            return
        }

        let size = panel.frame.size
        let proposedOrigin = NSPoint(
            x: parentWindow.frame.midX - size.width / 2,
            y: parentWindow.frame.midY - size.height / 2 + 48
        )
        guard let visibleFrame = parentWindow.screen?.visibleFrame else {
            panel.setFrameOrigin(proposedOrigin)
            return
        }

        panel.setFrameOrigin(NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        ))
    }
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ShowCommandPaletteKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var showFloralMDCommandPalette: (() -> Void)? {
        get { self[ShowCommandPaletteKey.self] }
        set { self[ShowCommandPaletteKey.self] = newValue }
    }
}
