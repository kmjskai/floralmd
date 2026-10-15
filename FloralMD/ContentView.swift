//
//  ContentView.swift
//  FloralMD
//
//  Created by Yingkai Sun on 2026/8/9.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @State private var windowPinningMode: WindowPinningMode = .none
    @AppStorage(AppPreferenceKey.documentMode) private var modeRawValue = MarkdownMode.edit.rawValue
    @AppStorage(AppPreferenceKey.fileSidebarVisible) private var isFileSidebarVisible = true
    @AppStorage(AppPreferenceKey.bodyFontName) private var bodyFontName = MarkdownTypography.defaultFontName
    @AppStorage(AppPreferenceKey.bodyFontSize) private var bodyFontSize = MarkdownTypography.defaultFontSize
    @AppStorage(AppPreferenceKey.bodyLineHeight) private var bodyLineHeight = MarkdownTypography.defaultLineHeight
    @AppStorage(AppPreferenceKey.markdownTypewriterModeEnabled)
    private var isMarkdownTypewriterModeEnabled = false
    @AppStorage(AppPreferenceKey.pinnedWindowOpacityPercentage)
    private var pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.defaultPercentage
    @State private var isOutlineSidebarVisible: Bool
    @State private var outlineNavigation: OutlineNavigation?
    @State private var openErrorMessage = ""
    @State private var isShowingOpenError = false
    @State private var hasUserEditedUntitledDocument = false

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _isOutlineSidebarVisible = State(
            initialValue: UserDefaults.standard.bool(
                forKey: AppPreferenceKey.outlineSidebarVisibleByDefault
            )
        )
    }

    private var headings: [MarkdownHeading] {
        MarkdownOutline.headings(in: document.text)
    }

    private var mode: MarkdownMode {
        MarkdownMode(rawValue: modeRawValue) ?? .edit
    }

    private var typography: MarkdownTypography {
        MarkdownTypography(
            fontName: bodyFontName,
            fontSize: bodyFontSize,
            lineHeight: bodyLineHeight
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isFileSidebarVisible {
                if let folderURL = fileURL?.deletingLastPathComponent() {
                    FileSidebarView(
                        rootURL: folderURL,
                        currentDocumentURL: fileURL,
                        openDocument: openMarkdownDocument
                    )
                    .frame(width: 240)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ContentUnavailableView(
                        "保存后显示附近文件",
                        systemImage: "sidebar.left",
                        description: Text("文件边栏以当前 Markdown 文档所在文件夹为范围。")
                    )
                    .frame(width: 240)
                    .frame(maxHeight: .infinity)
                }

                Divider()
            }

            DocumentOutlineSidebar(
                headings: headings,
                backgroundOpacity: windowPinningMode.sidebarBackgroundOpacity,
                navigate: { heading in
                    outlineNavigation = OutlineNavigation(heading: heading)
                },
                collapse: {
                    setOutlineSidebarVisible(false)
                }
            )
            .frame(width: DocumentOutlineLayout.expandedWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(width: DocumentOutlineLayout.panelWidth(isVisible: isOutlineSidebarVisible),
                   alignment: .leading)
            .opacity(isOutlineSidebarVisible ? 1 : 0)
            .clipped()
            .allowsHitTesting(isOutlineSidebarVisible)
            .accessibilityHidden(!isOutlineSidebarVisible)

            documentSurface
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 420)
        .background {
            ZStack {
                WindowPinningBridge(
                    mode: windowPinningMode,
                    pinnedWindowOpacity: PinnedWindowOpacityPreference.alpha(
                        for: pinnedWindowOpacityPercentage
                    )
                )
                DocumentAutosaveBridge(
                    text: document.text,
                    fileURL: fileURL,
                    hasUserEdited: hasUserEditedUntitledDocument
                )
            }
            .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy) {
                        isFileSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(isFileSidebarVisible ? "收起文件边栏" : "展开文件边栏")
                .help(isFileSidebarVisible ? "收起文件边栏" : "展开文件边栏")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 2) {
                    Button {
                        QuickCaptureService.shared.perform()
                    } label: {
                        Image(systemName: "note.text.badge.plus")
                            .frame(width: 28, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建快速记录")
                    .help("新建快速记录（⌃⌥N）")

                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 2)

                    ForEach(MarkdownMode.allCases) { candidate in
                        modeButton(candidate)
                    }

                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 2)

                    Button {
                        windowPinningMode.toggle()
                    } label: {
                        Image(systemName: windowPinningMode.symbolName)
                            .frame(width: 28, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(windowPinningMode.actionTitle)
                    .help(windowPinningMode.actionTitle)
                }
                .padding(4)
                .compatibleGlassEffect(in: Capsule())
            }
        }
        .alert("无法打开文档", isPresented: $isShowingOpenError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(openErrorMessage)
        }
        .focusedSceneValue(\.showFloralMDCommandPalette) {
            CommandPalettePanelController.shared.show(commands: commandPaletteCommands)
        }
        .focusedSceneValue(
            \.adjustFloralMDMarkdownFontSize,
            MarkdownFontSizeAction(currentSize: bodyFontSize, perform: adjustFontSize)
        )
        .onAppear {
            pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.normalizeStoredValue()
        }
    }

    private var commandPaletteCommands: [FloralMDCommand] {
        [
            FloralMDCommand(descriptor: FloralMDCommandCatalog.newDrawing) {
                openWindow(id: DrawingWindow.id)
            },
            FloralMDCommand(descriptor: FloralMDCommandCatalog.quickCapture) {
                QuickCaptureService.shared.perform()
            },
            FloralMDCommand(descriptor: FloralMDCommandCatalog.changeDefaultFolder) {
                QuickCaptureService.shared.chooseAnotherFolder()
            },
            FloralMDCommand(descriptor: FloralMDCommandCatalog.drawingSVGSyncSettings) {
                openSettings()
            },
            FloralMDCommand(
                id: "mode.edit",
                title: "切换到编辑模式",
                systemImage: "pencil",
                keywords: "编辑 Markdown edit"
            ) { selectMode(.edit) },
            FloralMDCommand(
                id: "mode.preview",
                title: "切换到预览模式",
                systemImage: "doc.richtext",
                keywords: "预览 Markdown preview"
            ) { selectMode(.preview) },
            FloralMDCommand(
                id: "sidebar.files",
                title: isFileSidebarVisible ? "隐藏文件边栏" : "显示文件边栏",
                systemImage: "sidebar.left",
                keywords: "文件 侧栏 sidebar"
            ) { isFileSidebarVisible.toggle() },
            FloralMDCommand(
                id: "sidebar.outline",
                title: isOutlineSidebarVisible ? "隐藏文档大纲" : "显示文档大纲",
                systemImage: "list.bullet.indent",
                keywords: "标题 大纲 outline"
            ) { toggleOutlineSidebar() },
            FloralMDCommand(
                id: "window.pin",
                title: windowPinningMode.actionTitle,
                systemImage: windowPinningMode.symbolName,
                keywords: "窗口 置顶 透明 pin"
            ) { windowPinningMode.toggle() },
            FloralMDCommand(
                id: "app.settings",
                title: "打开设置",
                systemImage: "gearshape",
                keywords: "偏好 设置 settings",
                shortcut: "⌘,"
            ) { openSettings() },
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
            ),
            FloralMDCommand(descriptor: FloralMDCommandCatalog.toggleMarkdownTypewriterMode) {
                isMarkdownTypewriterModeEnabled.toggle()
            }
        ]
    }

    private func adjustFontSize(_ adjustment: MarkdownFontSizeAdjustment) {
        bodyFontSize = adjustment.apply(to: bodyFontSize)
    }

    @ViewBuilder
    private var documentSurface: some View {
        Group {
            switch mode {
            case .edit:
                CodeMirrorEditorView(
                    markdown: $document.text,
                    documentURL: fileURL,
                    resourceContext: nil,
                    navigation: outlineNavigation,
                    typography: typography,
                    typewriterModeEnabled: isMarkdownTypewriterModeEnabled,
                    userDidEdit: {
                        guard fileURL == nil, !hasUserEditedUntitledDocument else { return }
                        hasUserEditedUntitledDocument = true
                    },
                    imagePasteHandler: nil,
                    imageOpenHandler: nil,
                    resourceDropHandler: nil,
                    linkNavigationHandler: nil
                )
            case .preview:
                MarkdownPreviewWebView(
                    markdown: document.text,
                    documentURL: fileURL,
                    resourceContext: nil,
                    navigation: outlineNavigation,
                    typography: typography,
                    linkNavigationHandler: nil
                )
            }
        }
        .overlay {
            if FloralMDEmptyStatePolicy.showsDocumentPrompt(
                markdown: document.text,
                mode: mode
            ) {
                FloralMDEmptyState(
                    kind: .document,
                    title: "从这里开始记录",
                    message: "直接输入 Markdown"
                )
                .padding(72)
            }
        }
        .overlay(alignment: .topLeading) {
            if !isOutlineSidebarVisible {
                DocumentOutlineControlButton(isExpanded: false) {
                    setOutlineSidebarVisible(true)
                }
                .padding(DocumentOutlineLayout.controlInset)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
            }
        }
    }

    private var minimumWindowWidth: CGFloat {
        640 + (isFileSidebarVisible ? 240 : 0)
            + DocumentOutlineLayout.panelWidth(isVisible: isOutlineSidebarVisible)
    }

    @ViewBuilder
    private func modeButton(_ candidate: MarkdownMode) -> some View {
        Button {
            selectMode(candidate)
        } label: {
            Image(systemName: candidate.systemImage)
                .foregroundStyle(mode == candidate ? Color.accentColor : .primary)
                .frame(width: 28, height: 26)
                .background {
                    if mode == candidate {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .help(candidate.helpText)
    }

    private func selectMode(_ candidate: MarkdownMode) {
        withAnimation(.snappy) {
            modeRawValue = candidate.rawValue
        }
    }

    private func toggleOutlineSidebar() {
        setOutlineSidebarVisible(!isOutlineSidebarVisible)
    }

    private func setOutlineSidebarVisible(_ isVisible: Bool) {
        withAnimation(.easeOut(duration: 0.22)) {
            isOutlineSidebarVisible = isVisible
        }
    }

    private func openMarkdownDocument(_ url: URL) {
        guard MarkdownFileBrowser.canOpen(url) else { return }
        Task {
            do {
                _ = try await openDocument(at: url)
            } catch {
                openErrorMessage = error.localizedDescription
                isShowingOpenError = true
            }
        }
    }
}

#Preview {
    ContentView(
        document: .constant(
            MarkdownDocument(text: "# FloralMD\n\n开始写作……")
        ),
        fileURL: nil
    )
}

enum MarkdownMode: String, CaseIterable, Identifiable {
    case edit
    case preview

    var id: Self { self }

    var title: String {
        switch self {
        case .edit: "编辑"
        case .preview: "预览"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .preview: "doc.richtext"
        }
    }

    var helpText: String {
        switch self {
        case .edit: "切换到实时 Markdown 编辑"
        case .preview: "切换到只读 Markdown 预览"
        }
    }
}
