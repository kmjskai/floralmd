//
//  FullHarnessAdapter.swift
//  FloralMD
//
//  Created for harness-seam-removal.
//  Full 形态适配器：把 DSHServiceKit 的既有能力（服务托管、内嵌面板、通知、
//  插件注入、设置区）包装成核心认识的 HarnessModule。仅 HARNESS_FULL 构建编译。
//

import AppKit
import Combine
import SwiftUI
import WebKit
@preconcurrency import UserNotifications

/// Full 形态：内嵌 dsh 中控台（WKWebView + DSHService + HarnessNotify + 插件清单）。
@MainActor
final class FullHarnessAdapter: HarnessModule {
    static let shared = FullHarnessAdapter()

    private let service = DSHService.shared
    private let notificationDelegate = HarnessNotificationDelegate()
    private var harnessWebView: MarkdownMagnifyingWebView?
    private var latestToolbarContext = HarnessToolbarContext(
        activeDocumentPath: nil,
        harnessVisible: false
    )

    var isProvided: Bool { true }
    var isEnabled: Bool { HarnessSettings.isEnabled() }
    var supportsHarnessModes: Bool { isEnabled }

    // MARK: - 生命周期

    func applicationDidFinishLaunching() {
        // 任务完成通知：delegate 处理点击（激活 App + 切 Harness 面板）。
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // 启动即请求通知授权（趁 App 前台活跃，弹框时机可靠）。
        if HarnessSettings.isNotifyEnabled() || HarnessSettings.turnNotifyPolicy() != .off {
            requestNotificationAuthorizationIfNeeded()
        }
    }

    func applicationWillTerminate() {
        // 随应用退出停掉 Harness 托管服务，避免遗留孤儿进程。
        service.stop()
    }

    func applicationOpenURL(_ url: URL) -> Bool {
        guard url.scheme == HarnessNotify.registeredURLScheme else { return false }
        HarnessNotify.handleOpenURL(url)
        return true
    }

    // MARK: - 设置

    func settingsSection() -> AnyView? {
        AnyView(HarnessSettingsSectionView())
    }

    // MARK: - 工作区

    func workspaceSurface(isActive: Bool) -> AnyView? {
        guard supportsHarnessModes else { return nil }
        return AnyView(HarnessSurfaceView(isActive: isActive, webView: webViewBinding))
    }

    func toolbarSupplement(context: HarnessToolbarContext) -> AnyView? {
        latestToolbarContext = context
        guard supportsHarnessModes, context.harnessVisible else { return nil }
        return AnyView(HarnessToolbarSupplementView(adapter: self))
    }

    func toggleCentralMode() {
        guard supportsHarnessModes else { return }
        HarnessViewShortcut.toggle()
    }

    func routesZoomToHarness() -> Bool {
        guard supportsHarnessModes else { return false }
        return HarnessWebViewFocus.isFirstResponderInsideHarness
    }

    // MARK: - 内部

    private var webViewBinding: Binding<MarkdownMagnifyingWebView?> {
        Binding(
            get: { [weak self] in self?.harnessWebView },
            set: { [weak self] in self?.harnessWebView = $0 }
        )
    }

    /// 把当前编辑文档路径插入 dsh 输入栏（React 受控 textarea 注入）。
    /// 脚本是打进 bundle 的前端资源，宿主只负责拼参数，不逆向前端内部 API。
    /// 受"文档路径插入"插件开关控制（dsh-editor-path）。
    fileprivate func insertEditorPath() {
        guard HarnessSettings.isPluginEnabled("dsh-editor-path") else { return }
        guard let path = latestToolbarContext.activeDocumentPath,
              let harnessWebView else { return }
        guard let scriptURL = Bundle.main.url(
            forResource: "inject",
            withExtension: "js",
            subdirectory: "HarnessPlugins/dsh-editor-path"
        ), let source = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            NSLog("FullHarnessAdapter: 缺少 dsh-editor-path/inject.js 资源")
            return
        }
        let pathJSON = (try? JSONEncoder().encode(path)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
        harnessWebView.evaluateJavaScript("(\(source))(\(pathJSON))") { _, error in
            if let error {
                NSLog("FullHarnessAdapter: 注入文档路径失败: %@", String(describing: error))
            }
        }
    }

    /// 未决定过授权时才请求（已允许/已拒绝都不打扰）。
    /// 授权请求必须在主线程执行，否则系统静默忽略（回调线程是后台线程）。
    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                guard settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        NSLog("HarnessNotify: 启动授权请求失败: %@", String(describing: error))
                    } else if !granted {
                        NSLog("HarnessNotify: 启动授权被拒绝")
                    }
                }
            }
        }
    }
}

/// 工具栏补充：运行状态点 + 版本 + 面板操作按钮（路径插入 / 浏览器打开 / 重启）。
private struct HarnessToolbarSupplementView: View {
    let adapter: FullHarnessAdapter
    @ObservedObject private var service = DSHService.shared

    var body: some View {
        HStack(spacing: 10) {
            HarnessStatusBadge()

            Button {
                adapter.insertEditorPath()
            } label: {
                Image(systemName: "text.insert")
            }
            .help(pathButtonDisabledReason)
            .disabled(!pathInsertionReady)

            Button {
                NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3080")!)
            } label: {
                Image(systemName: "safari")
            }
            .help("在浏览器中打开")

            if service.state.canRestart {
                Button {
                    service.restart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重启 dsh 服务")
            }
        }
    }

    private var pathInsertionReady: Bool {
        adapter.toolbarPathAvailable
            && HarnessSettings.isPluginEnabled("dsh-editor-path")
    }

    private var pathButtonDisabledReason: String {
        if !adapter.toolbarPathDocumentReady {
            return "未打开文档（无路径可插入）"
        }
        if !adapter.toolbarPathWebViewReady {
            return "harness 页面未就绪"
        }
        if !HarnessSettings.isPluginEnabled("dsh-editor-path") {
            return "“文档路径插入”插件已关闭（设置 › Harness › 插件）"
        }
        return "把当前文档路径插入 dsh 输入栏"
    }
}

/// 工具栏 dsh 服务状态徽标：状态点 + 状态文字 +（已解析到时）版本号。
/// 观察 DSHService 使状态与版本随服务变化响应式刷新。
private struct HarnessStatusBadge: View {
    @ObservedObject private var service = DSHService.shared

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(
                    red: service.state.tint.red,
                    green: service.state.tint.green,
                    blue: service.state.tint.blue
                ))
                .frame(width: 8, height: 8)
            Text(service.state.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let version = service.runningVersion {
                Text("· dsh \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(service.state.title)
        .padding(.leading, 4)
    }
}

// MARK: - 设置区（原 AppSettings.harnessSettings 整体迁入）

/// Harness 设置区内容（由核心的设置页在 module.isProvided 时嵌入）。
private struct HarnessSettingsSectionView: View {
    @AppStorage(HarnessPreferenceKey.enabled) private var harnessEnabled = true
    @AppStorage(HarnessPreferenceKey.centralMode)
    private var centralModeRawValue = WorkspaceCentralMode.editorOnly.rawValue
    @AppStorage(HarnessPreferenceKey.launchAtLogin) private var harnessLaunchAtLogin = false
    @AppStorage(HarnessPreferenceKey.lockedVersion) private var harnessLockedVersion = ""
    @AppStorage(HarnessPreferenceKey.workspacePath) private var harnessWorkspacePath = ""
    @AppStorage(HarnessPreferenceKey.turnNotifyPolicy)
    private var turnNotifyPolicyRawValue = HarnessTurnNotifyPolicy.backgroundOnly.rawValue
    @State private var harnessSelfStartMessage = ""
    @StateObject private var pluginPreferences = HarnessPluginPreferences()
    @ObservedObject private var service = DSHService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("模块", symbolName: "cpu") {
                Toggle("启用 Harness 模块", isOn: $harnessEnabled)
                Text("关闭后完全回归纯编辑器：不托管服务、不读取用量数据。")
                    .settingsSupportingText()

                Divider()

                Picker("对话回合通知", selection: $turnNotifyPolicyRawValue) {
                    ForEach(HarnessTurnNotifyPolicy.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(selectedTurnNotifyPolicy.helpText)
                    .settingsSupportingText()

                Divider()

                Picker("中央区域模式", selection: $centralModeRawValue) {
                    ForEach(WorkspaceCentralMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("仅编辑：只显示编辑面；Harness：只显示用量面板；左右并存：两者同屏。")
                    .settingsSupportingText()
            }

            SettingsCard("服务", symbolName: "shippingbox") {
                Toggle("登录时启动 FloralMD", isOn: Binding(
                    get: { harnessLaunchAtLogin },
                    set: { newValue in
                        if HarnessSettings.setLaunchAtLogin(newValue) {
                            harnessLaunchAtLogin = newValue
                            harnessSelfStartMessage = ""
                        } else {
                            harnessLaunchAtLogin = false
                            harnessSelfStartMessage = "注册失败：请将 FloralMD 放入 /Applications 后重试。"
                        }
                    }
                ))
                if !harnessSelfStartMessage.isEmpty {
                    Text(harnessSelfStartMessage)
                        .settingsSupportingText()
                }
                Text("登录自启后，打开 FloralMD 时 Harness 服务会随面板首次出现而启动。")
                    .settingsSupportingText()

                Divider()

                LabeledContent("锁定 dsh 版本") {
                    TextField("留空 = 最新版", text: $harnessLockedVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
                Text("例如 0.1.0-rc.6；dsh 更新出现异常时可固定旧版本回退。")
                    .settingsSupportingText()

                Divider()

                LabeledContent("当前运行版本") {
                    Text(service.runningVersion ?? "未知")
                        .textSelection(.enabled)
                        .foregroundStyle(service.runningVersion == nil ? .secondary : .primary)
                }
                Text(runningVersionExplanation)
                    .settingsSupportingText()
                if let locked = lockedDSHVersion,
                   let running = service.runningVersion,
                   locked != running {
                    Label(
                        "锁定版本 \(locked) 与运行版本 \(running) 不一致，重启服务后生效。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("重新解析") {
                    Task { await service.refreshVersion() }
                }
                .help("重新从监听进程与 npx 缓存解析 dsh 版本")
            }

            SettingsCard("插件", symbolName: "puzzlepiece") {
                ForEach(Array(HarnessPluginManager.plugins.enumerated()), id: \.element.id) { index, descriptor in
                    Toggle(descriptor.title, isOn: Binding(
                        get: { pluginPreferences.isEnabled(descriptor.id) },
                        set: { pluginPreferences.setEnabled(descriptor.id, $0) }
                    ))
                    HStack(spacing: 8) {
                        Text(descriptor.summary)
                            .settingsSupportingText()
                        Spacer()
                        pluginStatusBadge(descriptor)
                    }
                    if index < HarnessPluginManager.plugins.count - 1 {
                        Divider()
                    }
                }
                Text("关闭后插件将从 Harness 移除，重启 Harness 后生效。")
                    .settingsSupportingText()
            }

            SettingsCard("工作目录", symbolName: "folder") {
                LabeledContent("Harness 服务工作区") {
                    Text(harnessWorkspaceDisplayPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Button("更改目录…") {
                    chooseHarnessWorkspace()
                }
                .padding(.top, 2)
            }
        }
    }

    private var harnessWorkspaceDisplayPath: String {
        if !harnessWorkspacePath.isEmpty {
            return harnessWorkspacePath
        }
        return HarnessSettings.workspaceURL().path(percentEncoded: false)
    }

    /// 用户填写的锁定版本；去空白后为空表示未锁定（跟随最新版）。
    private var lockedDSHVersion: String? {
        let trimmed = harnessLockedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var runningVersionExplanation: String {
        if let locked = lockedDSHVersion {
            return "已锁定 \(locked)。解析结果来自正在运行的 dsh 服务进程；如与锁定版本不一致，重启服务后生效。"
        }
        return "未锁定（跟随最新版）。解析结果来自正在运行的 dsh 服务进程或 npx 缓存中最近安装的版本。"
    }

    private var selectedTurnNotifyPolicy: HarnessTurnNotifyPolicy {
        HarnessTurnNotifyPolicy(rawValue: turnNotifyPolicyRawValue) ?? .backgroundOnly
    }

    private func chooseHarnessWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 dsh 服务工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            harnessWorkspacePath = url.path(percentEncoded: false)
        }
    }

    /// 插件注入状态徽章：已关闭 / 已注入 / 未就位。
    @ViewBuilder
    private func pluginStatusBadge(_ descriptor: HarnessPluginDescriptor) -> some View {
        let (label, color): (String, Color) = switch HarnessPluginManager.injectionStatus(for: descriptor) {
        case .disabled: ("已关闭", .secondary)
        case .installed: ("已注入", .green)
        case .missing: ("未就位", .orange)
        }
        Text(label)
            .font(.caption)
            .foregroundStyle(color)
    }
}

/// 插件开关的 UserDefaults 桥接：清单驱动 UI 无法用编译期 @AppStorage 键，
/// 由本对象统一读写并广播变化（任一插件开关变化会刷新整个插件区）。
@MainActor
final class HarnessPluginPreferences: ObservableObject {
    @Published private var enabledByID: [String: Bool] = [:]

    init() {
        enabledByID = Dictionary(
            uniqueKeysWithValues: HarnessPluginManager.plugins.map {
                ($0.id, HarnessSettings.isPluginEnabled($0.id))
            }
        )
    }

    func isEnabled(_ id: String) -> Bool {
        enabledByID[id] ?? false
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        HarnessSettings.setPluginEnabled(id, enabled)
        enabledByID[id] = enabled
    }
}

// MARK: - 工具栏状态判定（供 HarnessToolbarSupplementView 使用）

extension FullHarnessAdapter {
    /// 当前是否有可插入的文档路径。
    var toolbarPathDocumentReady: Bool {
        latestToolbarContext.activeDocumentPath != nil
    }

    /// harness webview 是否已就绪。
    var toolbarPathWebViewReady: Bool {
        harnessWebView != nil
    }

    var toolbarPathAvailable: Bool {
        toolbarPathDocumentReady && toolbarPathWebViewReady
    }
}