//
//  HarnessSurfaceView.swift
//  FloralMD
//
//  Created for feature/dsh-harness.
//  Harness 工具面：整体嵌入原生 dsh web 界面（WKWebView 加载 127.0.0.1:3080）。
//  原则：FloralMD 只做宿主——所有 dsh 功能（含用量/额度）都由 dsh 本体与
//  其插件生态提供（如 dsh-usage-stats 插件在 GUI 侧边栏展示用量），
//  FloralMD 不重复实现任何 dsh 功能。
//

import AppKit
import SwiftUI
import WebKit

/// Harness 专用 webview：优先拦截 ⌘+/⌘-/⌘0 转成页面缩放。
/// 原因：dsh GUI 网页自身可能绑定 ⌘- 等按键并 preventDefault，
/// 让菜单收不到快捷键；这里在按键分发阶段直接接管，保证缩放始终可用。
final class HarnessPageZoomWebView: MarkdownMagnifyingWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 只有本 webview 持有键盘焦点时才拦截缩放键；
        // 否则交还菜单，由焦点路由决定（编辑器聚焦时缩放编辑器）。
        let hasKeyboardFocus: Bool = {
            guard let firstResponder = window?.firstResponder as? NSView else { return false }
            return firstResponder === self || firstResponder.isDescendant(of: self)
        }()
        guard hasKeyboardFocus,
              event.type == .keyDown,
              event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let adjustment: MarkdownViewportZoomAdjustment? = switch key {
        case "=", "+": .increase
        case "-": .decrease
        case "0": .reset
        default: nil
        }
        guard let adjustment else {
            return super.performKeyEquivalent(with: event)
        }
        let next = adjustment.apply(to: Double(pageZoom))
        applyViewportZoom(next)
        // 与捏合路径一致：发通知让状态栏实时回显百分比。
        viewportZoomDidChange?(next, .ended)
        return true
    }
}

/// 记录当前 harness webview，供快捷键按焦点路由。
enum HarnessWebViewFocus {
    static weak var current: WKWebView?

    static var isFirstResponderInsideHarness: Bool {
        guard let webView = current,
              let firstResponder = NSApp.keyWindow?.firstResponder as? NSView else {
            return false
        }
        return firstResponder === webView || firstResponder.isDescendant(of: webView)
    }
}

struct HarnessSurfaceView: View {
    /// Harness 面是否处于可见状态（编辑器模式常驻但不可见时不加载 dsh GUI）。
    let isActive: Bool
    /// 由宿主（WorkspaceContentView）持有的 harness webview，供工具栏按钮注入脚本。
    @Binding var webView: MarkdownMagnifyingWebView?
    @StateObject private var service = DSHService.shared
    @State private var webZoomScale = 1.0
    @State private var isZoomHUDVisible = false
    @State private var zoomHUDTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .overlay(alignment: .topTrailing) { zoomHUD }
        .focusedSceneValue(
            \.adjustFloralMDHarnessZoom,
            harnessZoomAction
        )
        .task(id: isActive) {
            // 懒启动：只有 harness 真正可见时才挂接/拉起服务；
            // 编辑器模式下 WebView 常驻但不加载，不白跑 dsh 服务。
            if isActive {
                service.startIfNeeded()
            }
        }
    }

    /// ⌘+/⌘-/⌘0 作用于 harness 面（仅运行时发布，编辑模式不发布）。
    private var harnessZoomAction: MarkdownViewportZoomAction? {
        guard service.state == .running else { return nil }
        return MarkdownViewportZoomAction(
            currentScale: webZoomScale,
            perform: { adjustment in
                let next = adjustment.apply(to: webZoomScale)
                webView?.applyViewportZoom(next)
                webZoomScale = MarkdownViewportZoom.clamped(next)
                revealZoomHUD()
            }
        )
    }

    /// 缩放悬浮指示：缩放动作时显示百分比，2 秒后淡出（与编辑器侧一致）。
    @ViewBuilder
    private var zoomHUD: some View {
        if service.state == .running, isZoomHUDVisible {
            Button {
                webView?.applyViewportZoom(1)
                webZoomScale = 1
                revealZoomHUD()
            } label: {
                Text("\(Int((webZoomScale * 100).rounded()))%")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .help("恢复 Harness 页面为 100%")
            .padding(10)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            .zIndex(20)
        }
    }

    private func revealZoomHUD() {
        isZoomHUDVisible = true
        zoomHUDTask?.cancel()
        zoomHUDTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { isZoomHUDVisible = false }
        }
    }

    // MARK: - 状态与操作统一由窗口工具栏承载（无面板内状态栏）

    // MARK: - 内容区：嵌入完整 dsh GUI

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .running:
            HarnessWebView(
                webView: $webView,
                zoomScale: $webZoomScale,
                isActive: isActive,
                onZoomChanged: { revealZoomHUD() }
            )
            .id(service.state) // 挂接/重启后重新加载
        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在启动 dsh 服务…（首次需下载，可能较慢）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !service.logTail.isEmpty {
                    Text(service.logTail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            ContentUnavailableView {
                Label("服务启动失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("重试") { service.restart() }
            }
        case .stopped:
            ContentUnavailableView {
                Label("服务未运行", systemImage: "shippingbox")
            } description: {
                Text("启动后即可在 FloralMD 中直接使用 dsh。")
            } actions: {
                Button("启动服务") { service.startIfNeeded() }
            }
        case .disabled:
            ContentUnavailableView {
                Label("Harness 模块已禁用", systemImage: "cpu.slash")
            } description: {
                Text("在「设置 → Harness」中重新启用后，即可在 FloralMD 中使用 dsh。")
            }
        }
    }
}

// MARK: - WKWebView 容器

private struct HarnessWebView: NSViewRepresentable {
    @Binding var webView: MarkdownMagnifyingWebView?
    @Binding var zoomScale: Double
    /// Harness 面可见时才真正加载 dsh GUI；常驻但不可见时保持空 WebView。
    let isActive: Bool
    /// 任何缩放路径（捏合/快捷键）变化时通知宿主显示悬浮 HUD。
    var onZoomChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = HarnessPageZoomWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        // 新窗口请求（target=_blank / window.open）会走 UIDelegate；不接住会被
        // WebKit 静默丢弃（见 Coordinator.createWebViewWith）。
        webView.uiDelegate = context.coordinator
        // 睡眠唤醒 / App 回到前台时做一次健康检查（卡死的页面自动重载）。
        context.coordinator.installResumeObservers()
        // 与编辑器同一套页面缩放：捏合→pageZoom（重排），无放大镜效果。
        webView.viewportZoomDidChange = { scale, _ in
            zoomScale = scale
            onZoomChanged()
        }
        let savedZoom = UserDefaults.standard.double(
            forKey: HarnessPreferenceKey.webPageZoom
        )
        if savedZoom > 0 {
            webView.applyViewportZoom(savedZoom)
            zoomScale = MarkdownViewportZoom.clamped(savedZoom)
        }
        // make 期间直接写 @Binding 会被 SwiftUI 丢弃（父视图 @State 不更新，
        // 工具栏按钮因此永远看到 nil）—— 延迟到下一轮事件循环再写入。
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            self.webView = webView
        }
        HarnessWebViewFocus.current = webView
        // 惰性加载：加载由 updateNSView 在 isActive 时触发，避免编辑器
        // 模式下常驻的空 WebView 也去渲染整个 dsh GUI。
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 可见性变化驱动健康检查的启停；isActive 变化时立刻查一次。
        context.coordinator.setActive(isActive, webView: webView)
        if isActive {
            context.coordinator.requestLoadIfNeeded(webView)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 视图被换掉时记住缩放比例，下次进来保持。
        UserDefaults.standard.set(
            Double(nsView.pageZoom),
            forKey: HarnessPreferenceKey.webPageZoom
        )
        coordinator.teardown()
        if HarnessWebViewFocus.current === nsView {
            HarnessWebViewFocus.current = nil
        }
    }

    /// 协调加载、失败重试与健康检查（卡死自愈）。
    ///
    /// 为什么需要健康检查：dsh 页面一旦加载就长期常驻（三态切换只改宽
    /// 度/透明度，页面永不销毁），而 dsh 客户端对"静默断连"没有自愈能力
    /// （WebSocket 半死时 close 事件不来，重连循环永久挂起），WKWebView
    /// 渲染进程也可能在内存压力下被系统终止。没有干预时页面会永久卡在
    /// "看起来正常但实际已死"的状态。这里用四道防线兜底：
    /// 1. 渲染进程终止（webViewWebContentProcessDidTerminate）→ 自动重建；
    /// 2. 页面 JS 响应性探测（evaluateJavaScript 超时）→ 挂死则重载；
    /// 3. 服务可达性探测（HTTP 连续失败）→ 服务失联（挂接模式/外部重启时
    ///    DSHService 无感知）则重载页面等待恢复；
    /// 4. 睡眠唤醒 / App 回前台 → 立即做一次上述检查。
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var hasRequestedLoad = false
        /// harness 面可见（隐藏时停止健康检查与加载重试）。
        private var isActive = false
        /// 页面至少成功加载过一次（加载中不跑健康检查）。
        private var didFinishInitialLoad = false

        // MARK: 健康检查状态

        private var healthTimer: Timer?
        private var isPingInFlight = false
        private var consecutiveProbeFailures = 0
        private weak var healthWebView: WKWebView?
        private var workspaceObservers: [NSObjectProtocol] = []
        private var appObservers: [NSObjectProtocol] = []

        private let healthProbeURL = URL(string: "http://127.0.0.1:3080")!
        private let healthTickInterval: TimeInterval = 15
        private let jsPingTimeout: TimeInterval = 5
        private let probeTimeout: TimeInterval = 2

        func requestLoadIfNeeded(_ webView: WKWebView) {
            guard !hasRequestedLoad else { return }
            hasRequestedLoad = true
            load(webView)
        }

        func setActive(_ active: Bool, webView: WKWebView) {
            guard active != isActive else { return }
            isActive = active
            if active {
                healthWebView = webView
                startHealthWatchdog()
                runHealthCheck(webView, reason: "harness-visible")
            } else {
                stopHealthWatchdog()
            }
        }

        func installResumeObservers() {
            // 系统睡眠唤醒：通知发在 NSWorkspace 自己的 notificationCenter。
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onResumeTrigger("system-wake")
            })
            // App 回到前台：覆盖"长时间放着不动被挂起"的场景。
            appObservers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onResumeTrigger("app-active")
            })
        }

        func teardown() {
            stopHealthWatchdog()
            for token in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            workspaceObservers.removeAll()
            for token in appObservers {
                NotificationCenter.default.removeObserver(token)
            }
            appObservers.removeAll()
        }

        func load(_ webView: WKWebView) {
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:3080")!))
        }

        // MARK: - 健康检查

        private func onResumeTrigger(_ reason: String) {
            guard isActive, let webView = healthWebView else { return }
            runHealthCheck(webView, reason: reason)
        }

        private func startHealthWatchdog() {
            healthTimer?.invalidate()
            let timer = Timer(timeInterval: healthTickInterval, repeats: true) { [weak self] _ in
                guard let self, let webView = self.healthWebView else { return }
                self.runHealthCheck(webView, reason: "periodic")
            }
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        }

        private func stopHealthWatchdog() {
            healthTimer?.invalidate()
            healthTimer = nil
            isPingInFlight = false
            consecutiveProbeFailures = 0
        }

        /// 两层探测：页面 JS 响应性 + 服务可达性。
        /// 仅在 harness 可见、页面已加载、App 在前台且窗口未被遮挡时进行
        /// （后台/遮挡时 WKWebView 可能被挂起，探测会误报）。
        private func runHealthCheck(_ webView: WKWebView, reason: String) {
            guard isActive, didFinishInitialLoad, !isPingInFlight,
                  NSApp.isActive,
                  webView.window?.occlusionState.contains(.visible) == true else { return }

            // 1) JS 响应性：evaluateJavaScript 超时未回调 → 渲染进程挂死。
            isPingInFlight = true
            webView.evaluateJavaScript("1") { [weak self] _, _ in
                self?.pingSettled(healthy: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + jsPingTimeout) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.pingSettled(healthy: false, webView: webView, reason: reason)
            }

            // 2) 服务可达性：连续失败两次才重载，避免瞬时抖动误伤。
            var request = URLRequest(url: healthProbeURL)
            request.timeoutInterval = probeTimeout
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                let ok = (response as? HTTPURLResponse) != nil
                DispatchQueue.main.async {
                    self?.serverProbeResult(ok: ok, webView: webView, reason: reason)
                }
            }.resume()
        }

        private func pingSettled(healthy: Bool, webView: WKWebView? = nil, reason: String = "") {
            guard isPingInFlight else { return }
            isPingInFlight = false
            guard !healthy, let webView else { return }
            NSLog("HarnessHealth: 页面 JS 无响应（%@），重载 harness 页面", reason)
            reload(webView)
        }

        private func serverProbeResult(ok: Bool, webView: WKWebView, reason: String) {
            guard isActive else { return }
            if ok {
                consecutiveProbeFailures = 0
                return
            }
            consecutiveProbeFailures += 1
            guard consecutiveProbeFailures >= 2 else { return }
            consecutiveProbeFailures = 0
            NSLog("HarnessHealth: 服务探测连续失败（%@），重载 harness 页面等待恢复", reason)
            reload(webView)
        }

        private func reload(_ webView: WKWebView) {
            didFinishInitialLoad = false
            load(webView)
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // dsh GUI 把 agent 消息里的 http/https 链接渲染成 target="_blank"，
            // 这类"新窗口"导航的 targetFrame 为 nil；不拦截时 WebKit 因没有
            // 可用的新窗口宿主而静默丢弃点击（浏览器里本应新开标签页）。
            // 这里转交系统默认浏览器打开。
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url,
               HarnessExternalLinkPolicy.shouldOpenExternally(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // 其余导航（SPA 内部路由、普通同页链接）保持 WebView 内进行。
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // 服务刚起来可能还没就绪：连接类错误在 harness 可见期间持续重试
            // （connection refused 立即失败，开销可忽略；服务恢复后自动接上）。
            // 原实现 15 次后放弃，页面会永久停在错误态——这正是卡住的原因之一。
            guard isActive, isRetryableNavigationError(error) else {
                hasRequestedLoad = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let self, let webView, self.isActive else { return }
                self.load(webView)
            }
        }

        private func isRetryableNavigationError(_ error: Error) -> Bool {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return false }
            switch nsError.code {
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载成功意味着服务已就绪：此刻重新解析版本最准确
            // （启动瞬间的解析可能落在兜底缓存上）。
            Task { @MainActor in
                await DSHService.shared.refreshVersion()
            }
            didFinishInitialLoad = true
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // 渲染进程崩溃（内存压力/系统回收）后页面永久无响应；
            // 不处理的话只能重启 App。这里自动重建页面。
            NSLog("HarnessHealth: WKWebView 渲染进程终止，重载 harness 页面")
            reload(webView)
        }

        // MARK: - WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // window.open 的兜底：该路径不经 decidePolicyFor，只能在这里接住。
            // 返回 nil 不创建新 WebView，URL 已交给系统浏览器；
            // target=_blank 链接则已被 decidePolicyFor 拦截，不会走到这里（无重复打开）。
            if let url = navigationAction.request.url,
               HarnessExternalLinkPolicy.shouldOpenExternally(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
