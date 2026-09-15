import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum AppPreferenceKey {
    static let fileSidebarVisible = "FileSidebarVisible"
    static let workspaceSidebarWidth = "WorkspaceSidebarWidth"
    static let outlineSidebarVisibleByDefault = "OutlineSidebarVisibleByDefault"
    static let documentMode = "DocumentMode"
    static let bodyFontName = "BodyFontName"
    static let bodyFontSize = "BodyFontSize"
    static let bodyLineHeight = "BodyLineHeight"
    static let markdownTypewriterModeEnabled = "MarkdownTypewriterModeEnabled"
    static let pinnedWindowOpacityPercentage = "PinnedWindowOpacityPercentage"
    static let defaultWorkspaceWindowPinningMode = "DefaultWorkspaceWindowPinningMode"
    /// 仅用于从旧版布尔设置迁移。
    static let pinNewWorkspaceWindowsAcrossAllSpaces = "PinNewWorkspaceWindowsAcrossAllSpaces"
    static let drawingSVGSyncPolicy = "DrawingSVGSyncPolicy"
    /// 中央区域模式（editorOnly / harnessOnly / split）。
    /// 键名沿用历史 "HarnessCentralMode" 以兼容既有用户偏好，不随形态重构迁移。
    static let centralMode = "HarnessCentralMode"
}

enum MarkdownTypewriterModePreference {
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.markdownTypewriterModeEnabled)
    }

    @discardableResult
    static func persist(_ isEnabled: Bool, to defaults: UserDefaults = .standard) -> Bool {
        defaults.set(isEnabled, forKey: AppPreferenceKey.markdownTypewriterModeEnabled)
        return isEnabled
    }
}

enum DrawingSVGSyncPolicy: String, CaseIterable, Identifiable, Sendable {
    case draftOnly
    case allDrawings
    case never

    static let defaultValue = Self.draftOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .draftOnly: "仅 Draft 工作区"
        case .allDrawings: "所有绘图"
        case .never: "从不"
        }
    }

    var explanation: String {
        switch self {
        case .draftOnly:
            "保存 Draft 绘图时同步到源文件所在目录的 exports；外部绘图只保存源文件。"
        case .allDrawings:
            "所有绘图都同步到源文件所在目录的 exports 子目录。"
        case .never:
            "自动保存只写可编辑源文件；仍可随时手动导出 SVG。"
        }
    }

    func automaticallySyncsSVG(for scope: DrawingStorageLayout.Scope) -> Bool {
        switch self {
        case .draftOnly: scope == .draft
        case .allDrawings: true
        case .never: false
        }
    }
}

enum DrawingSVGSyncPreference {
    static func load(from defaults: UserDefaults = .standard) -> DrawingSVGSyncPolicy {
        guard let rawValue = defaults.string(forKey: AppPreferenceKey.drawingSVGSyncPolicy),
              let policy = DrawingSVGSyncPolicy(rawValue: rawValue) else {
            return .defaultValue
        }
        return policy
    }

    @discardableResult
    static func persist(
        _ policy: DrawingSVGSyncPolicy,
        to defaults: UserDefaults = .standard
    ) -> DrawingSVGSyncPolicy {
        defaults.set(policy.rawValue, forKey: AppPreferenceKey.drawingSVGSyncPolicy)
        return policy
    }

    @discardableResult
    static func normalizeStoredValue(
        in defaults: UserDefaults = .standard
    ) -> DrawingSVGSyncPolicy {
        persist(load(from: defaults), to: defaults)
    }
}

enum PinnedWindowOpacityPreference {
    static let percentageRange = 70.0...100.0
    static let percentageStep = 1.0
    static let defaultPercentage = 88.0

    static func clampedPercentage(_ percentage: Double) -> Double {
        guard !percentage.isNaN else { return defaultPercentage }
        return min(
            max(percentage.rounded(), percentageRange.lowerBound),
            percentageRange.upperBound
        )
    }

    static func alpha(for percentage: Double) -> CGFloat {
        CGFloat(clampedPercentage(percentage) / 100)
    }

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard let storedValue = defaults.object(
            forKey: AppPreferenceKey.pinnedWindowOpacityPercentage
        ) as? NSNumber else {
            return defaultPercentage
        }
        return clampedPercentage(storedValue.doubleValue)
    }

    @discardableResult
    static func persist(_ percentage: Double, to defaults: UserDefaults = .standard) -> Double {
        let clamped = clampedPercentage(percentage)
        defaults.set(clamped, forKey: AppPreferenceKey.pinnedWindowOpacityPercentage)
        return clamped
    }

    @discardableResult
    static func normalizeStoredValue(in defaults: UserDefaults = .standard) -> Double {
        persist(load(from: defaults), to: defaults)
    }
}

enum WorkspaceWindowPinningPreference {
    static let defaultValue = WindowPinningMode.allSpaces

    static func load(from defaults: UserDefaults = .standard) -> WindowPinningMode {
        if let rawValue = defaults.string(
            forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode
        ), let mode = WindowPinningMode(rawValue: rawValue) {
            return mode
        }

        if defaults.object(forKey: AppPreferenceKey.pinNewWorkspaceWindowsAcrossAllSpaces) != nil {
            return defaults.bool(forKey: AppPreferenceKey.pinNewWorkspaceWindowsAcrossAllSpaces)
                ? .allSpaces
                : .none
        }

        return defaultValue
    }

    @discardableResult
    static func persist(
        _ mode: WindowPinningMode,
        to defaults: UserDefaults = .standard
    ) -> WindowPinningMode {
        defaults.set(mode.rawValue, forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
        return mode
    }

    @discardableResult
    static func normalizeStoredValue(
        in defaults: UserDefaults = .standard
    ) -> WindowPinningMode {
        persist(load(from: defaults), to: defaults)
    }
}

enum DocumentAutosavePolicy {
    static let delay: TimeInterval = 2

    @MainActor
    static func apply() {
        apply(to: .shared)
    }

    @MainActor
    static func apply(to controller: NSDocumentController) {
        controller.autosavingDelay = delay
    }
}

struct FloralMDSettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general
        case display
        case editing
        case harness

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "通用"
            case .display: "显示"
            case .editing: "编辑"
            case .harness: "Harness"
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .display: "rectangle.on.rectangle"
            case .editing: "pencil"
            case .harness: "cpu"
            }
        }
    }

    @AppStorage(AppPreferenceKey.fileSidebarVisible) private var isFileSidebarVisible = true
    @AppStorage(AppPreferenceKey.outlineSidebarVisibleByDefault) private var isOutlineSidebarVisibleByDefault = false
    @AppStorage(AppPreferenceKey.documentMode) private var documentMode = MarkdownMode.edit.rawValue
    @AppStorage(AppPreferenceKey.markdownTypewriterModeEnabled)
    private var isMarkdownTypewriterModeEnabled = false
    @AppStorage(AppPreferenceKey.drawingSVGSyncPolicy)
    private var drawingSVGSyncPolicy = DrawingSVGSyncPolicy.defaultValue.rawValue
    @AppStorage(AppPreferenceKey.pinnedWindowOpacityPercentage)
    private var pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.defaultPercentage
    @AppStorage(AppPreferenceKey.defaultWorkspaceWindowPinningMode)
    private var defaultWorkspaceWindowPinningMode = WorkspaceWindowPinningPreference.defaultValue.rawValue
    @StateObject private var typography = TypographySettings()
    @State private var selectedSection: Section = .general
    @State private var quickCaptureFolderURL: URL?

    private var visibleSections: [Section] {
        HarnessModuleSelection.current.isProvided
            ? Section.allCases
            : Section.allCases.filter { $0 != .harness }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(visibleSections, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
                    .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 520)
        .task {
            quickCaptureFolderURL = QuickCaptureService.shared.configuredFolderForDisplay()
            pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.normalizeStoredValue()
            drawingSVGSyncPolicy = DrawingSVGSyncPreference.normalizeStoredValue().rawValue
            defaultWorkspaceWindowPinningMode = WorkspaceWindowPinningPreference
                .normalizeStoredValue()
                .rawValue
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general:
            SettingsPage(
                title: "通用",
                subtitle: "管理快速记录与默认保存位置。"
            ) {
                generalSettings
            }
        case .display:
            SettingsPage(
                title: "显示",
                subtitle: "管理窗口外观与导航组件。"
            ) {
                displaySettings
            }
        case .editing:
            SettingsPage(
                title: "编辑",
                subtitle: "选择打开文档时使用的默认模式。"
            ) {
                editingSettings
            }
        case .harness:
            SettingsPage(
                title: "Harness",
                subtitle: "托管 DeepSeek Harness 服务并查看 AI 用量。"
            ) {
                if let harnessSection = HarnessModuleSelection.current.settingsSection() {
                    harnessSection
                } else {
                    EmptyView()
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("默认保存", symbolName: "folder") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("默认文件夹")
                        .font(.subheadline.weight(.medium))

                    Text(quickCaptureFolderURL?.path(percentEncoded: false) ?? "尚未设置")
                        .foregroundStyle(quickCaptureFolderURL == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(quickCaptureFolderURL == nil ? "选择文件夹…" : "更改文件夹…") {
                        if let selectedURL = QuickCaptureService.shared.chooseAnotherFolder() {
                            quickCaptureFolderURL = selectedURL
                        }
                    }
                    .padding(.top, 2)
                }

                Divider()

                LabeledContent("全局快捷键") {
                    Text("⌃⌥N")
                        .foregroundStyle(.secondary)
                }

                Text("启动、新建和快速记录会直接进入编辑；绘图源文件和图片会保存到此文件夹下的专用目录。首次生成 Markdown 文件后，后续修改会在停止输入约 2 秒后继续自动保存。")
                    .settingsSupportingText()
            }

            SettingsCard("绘图 SVG", symbolName: "square.and.arrow.up") {
                Picker("自动同步", selection: drawingSVGSyncPolicyBinding) {
                    ForEach(DrawingSVGSyncPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedDrawingSVGSyncPolicy.explanation)
                    .settingsSupportingText()
            }
        }
    }

    private var selectedDrawingSVGSyncPolicy: DrawingSVGSyncPolicy {
        DrawingSVGSyncPolicy(rawValue: drawingSVGSyncPolicy) ?? .defaultValue
    }

    private var drawingSVGSyncPolicyBinding: Binding<DrawingSVGSyncPolicy> {
        Binding(
            get: { selectedDrawingSVGSyncPolicy },
            set: { drawingSVGSyncPolicy = DrawingSVGSyncPreference.persist($0).rawValue }
        )
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("窗口", symbolName: "rectangle.on.rectangle") {
                Picker("新工作空间默认置顶", selection: defaultWorkspaceWindowPinningModeBinding) {
                    ForEach(WindowPinningMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("修改从下一个工作空间窗口开始生效；工具栏中的置顶菜单可以临时调整当前窗口。")
                    .settingsSupportingText()

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("置顶窗口透明度")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(pinnedWindowOpacityText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("当前置顶窗口透明度")
                            .accessibilityValue(pinnedWindowOpacityText)
                    }

                    Slider(
                        value: pinnedWindowOpacityBinding,
                        in: PinnedWindowOpacityPreference.percentageRange,
                        step: PinnedWindowOpacityPreference.percentageStep
                    )
                    .accessibilityLabel("置顶窗口透明度")
                    .accessibilityValue(pinnedWindowOpacityText)

                    HStack {
                        Text("修改会立即应用到所有已置顶窗口；未置顶窗口始终完全不透明。")
                            .settingsSupportingText()
                        Spacer()
                        Button("恢复默认值") {
                            pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.persist(
                                PinnedWindowOpacityPreference.defaultPercentage
                            )
                        }
                        .disabled(
                            PinnedWindowOpacityPreference.clampedPercentage(
                                pinnedWindowOpacityPercentage
                            ) == PinnedWindowOpacityPreference.defaultPercentage
                        )
                        .accessibilityLabel("恢复默认置顶窗口透明度")
                        .accessibilityHint("恢复为 88%")
                    }
                }
            }

            SettingsCard("侧栏", symbolName: "sidebar.left") {
                Toggle("显示文件边栏", isOn: $isFileSidebarVisible)
                Toggle("新窗口默认展开文档大纲", isOn: $isOutlineSidebarVisibleByDefault)
                Text("文件边栏修改会立即应用；大纲偏好从下一个文档窗口开始生效。")
                    .settingsSupportingText()
            }
        }
    }

    private var selectedDefaultWorkspaceWindowPinningMode: WindowPinningMode {
        WindowPinningMode(rawValue: defaultWorkspaceWindowPinningMode)
            ?? WorkspaceWindowPinningPreference.defaultValue
    }

    private var defaultWorkspaceWindowPinningModeBinding: Binding<WindowPinningMode> {
        Binding(
            get: { selectedDefaultWorkspaceWindowPinningMode },
            set: {
                defaultWorkspaceWindowPinningMode = WorkspaceWindowPinningPreference
                    .persist($0)
                    .rawValue
            }
        )
    }

    private var pinnedWindowOpacityBinding: Binding<Double> {
        Binding(
            get: {
                PinnedWindowOpacityPreference.clampedPercentage(
                    pinnedWindowOpacityPercentage
                )
            },
            set: { newValue in
                pinnedWindowOpacityPercentage = PinnedWindowOpacityPreference.persist(newValue)
            }
        )
    }

    private var pinnedWindowOpacityText: String {
        "\(Int(PinnedWindowOpacityPreference.clampedPercentage(pinnedWindowOpacityPercentage)))%"
    }

    private var editingSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("文档模式", symbolName: "doc.text") {
                Picker("默认模式", selection: $documentMode) {
                    ForEach(MarkdownMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("修改会立即应用到所有打开的文档窗口。")
                    .settingsSupportingText()
            }

            SettingsCard("打字机模式", symbolName: "text.line.first.and.arrowtriangle.forward") {
                Toggle("键盘输入时让当前视觉行保持在舒适位置", isOn: $isMarkdownTypewriterModeEnabled)
                Text("仅在 Markdown 编辑模式中生效。鼠标或触控板滚动、点击与拖选不会被拉回；再次键盘输入或移动光标时恢复跟随。")
                    .settingsSupportingText()
            }

            SettingsCard("字体排版", symbolName: "textformat") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正文字体")
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        Text(typography.fontSummary)
                            .font(typography.previewFont)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("选择…") {
                            typography.selectFont()
                        }

                        Button("系统字体") {
                            typography.useSystemFont()
                        }
                        .disabled(typography.usesSystemFont)
                    }
                }

                Divider()

                LabeledContent("基础字号") {
                    HStack(spacing: 8) {
                        Text("\(Int(typography.fontSize.rounded())) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)

                        Stepper(
                            "基础字号",
                            value: Binding(
                                get: { typography.fontSize },
                                set: { typography.setFontSize($0) }
                            ),
                            in: MarkdownTypography.fontSizeRange,
                            step: 1
                        )
                        .labelsHidden()
                    }
                }

                Picker("行高", selection: $typography.lineHeight) {
                    Text("紧凑").tag(1.35)
                    Text("标准").tag(MarkdownTypography.defaultLineHeight)
                    Text("宽松").tag(1.7)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("标题随基础字号按比例变化；代码、代码块和行号保持等宽字体。")
                        .settingsSupportingText()
                    Spacer()
                    Button("恢复默认") {
                        typography.restoreDefaults()
                    }
                    .disabled(typography.isUsingDefaults)
                }
            }
        }
    }

    }

/// 插件开关的 UserDefaults 桥接已随 Harness 设置区迁入 DSHServiceKit/FullHarnessAdapter.swift。

@MainActor
private final class TypographySettings: NSObject, ObservableObject {
    @Published private(set) var font: NSFont
    @Published private(set) var fontName: String
    @Published private(set) var fontSize: Double
    @Published var lineHeight: Double {
        didSet {
            let clamped = min(
                max(lineHeight, MarkdownTypography.lineHeightRange.lowerBound),
                MarkdownTypography.lineHeightRange.upperBound
            )
            if clamped != lineHeight {
                lineHeight = clamped
                return
            }
            UserDefaults.standard.set(lineHeight, forKey: AppPreferenceKey.bodyLineHeight)
        }
    }

    override init() {
        let defaults = UserDefaults.standard
        let storedName = defaults.string(forKey: AppPreferenceKey.bodyFontName)
            ?? MarkdownTypography.defaultFontName
        let storedSize = defaults.object(forKey: AppPreferenceKey.bodyFontSize) as? Double
            ?? MarkdownTypography.defaultFontSize
        let storedLineHeight = defaults.object(forKey: AppPreferenceKey.bodyLineHeight) as? Double
            ?? MarkdownTypography.defaultLineHeight
        let typography = MarkdownTypography(
            fontName: storedName,
            fontSize: storedSize,
            lineHeight: storedLineHeight
        )

        fontName = typography.fontName
        fontSize = typography.fontSize
        lineHeight = typography.lineHeight
        font = Self.makeFont(name: typography.fontName, size: typography.fontSize)
        super.init()
    }

    var usesSystemFont: Bool {
        fontName.isEmpty
    }

    var fontSummary: String {
        let displayName = usesSystemFont
            ? "系统字体"
            : (font.displayName ?? font.familyName ?? font.fontName)
        return "\(displayName)  \(Int(fontSize.rounded()))"
    }

    var previewFont: Font {
        Font(font)
    }

    var isUsingDefaults: Bool {
        usesSystemFont
            && fontSize == MarkdownTypography.defaultFontSize
            && lineHeight == MarkdownTypography.defaultLineHeight
    }

    func selectFont() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(font, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    func useSystemFont() {
        fontName = MarkdownTypography.defaultFontName
        font = .systemFont(ofSize: fontSize)
        persistFont()
    }

    func setFontSize(_ value: Double) {
        let clamped = min(
            max(value, MarkdownTypography.fontSizeRange.lowerBound),
            MarkdownTypography.fontSizeRange.upperBound
        )
        guard clamped != fontSize else { return }
        fontSize = clamped
        font = Self.makeFont(name: fontName, size: clamped)
        persistFont()
    }

    func restoreDefaults() {
        fontName = MarkdownTypography.defaultFontName
        fontSize = MarkdownTypography.defaultFontSize
        lineHeight = MarkdownTypography.defaultLineHeight
        font = .systemFont(ofSize: fontSize)
        persistFont()
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        let selectedFont = sender.convert(font)
        fontName = selectedFont.fontName
        fontSize = min(
            max(Double(selectedFont.pointSize), MarkdownTypography.fontSizeRange.lowerBound),
            MarkdownTypography.fontSizeRange.upperBound
        )
        font = Self.makeFont(name: fontName, size: fontSize)
        persistFont()
    }

    private func persistFont() {
        UserDefaults.standard.set(fontName, forKey: AppPreferenceKey.bodyFontName)
        UserDefaults.standard.set(fontSize, forKey: AppPreferenceKey.bodyFontSize)
    }

    private static func makeFont(name: String, size: Double) -> NSFont {
        guard !name.isEmpty, let font = NSFont(name: name, size: size) else {
            return .systemFont(ofSize: size)
        }
        return font
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(.init(top: 28, leading: 30, bottom: 32, trailing: 30))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbolName: String
    @ViewBuilder let content: Content

    init(_ title: String, symbolName: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbolName = symbolName
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbolName)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}

extension View {
    func settingsSupportingText() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
