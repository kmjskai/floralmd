//
//  HarnessNotify.swift
//  FloralMD
//
//  Created for feature/dsh-notify.
//  任务完成通知：接收 dsh-notify 插件经 `open -g "floralmd://notify?…"` 投递的
//  任务结算载荷，用 UNUserNotificationCenter 弹原生通知（署名 FloralMD、FloralMD
//  图标），点击后激活 App 并切到 Harness 面板。
//
//  职责边界：FloralMD 只做宿主——通知的"何时发"由 dsh 侧插件决定（jobs.onJobDone），
//  这里只负责"怎么展示"（文案/声音/权限/点击行为），与 ADR 0011 一致。
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

/// 一次通知的展示载荷（来自 `floralmd://notify` 查询参数）。
/// kind = bash/subagent → 后台任务结算；kind = turn → 根会话回合结束。
struct HarnessNotifyPayload {
    var kind: String
    var label: String
    var status: String
    var detail: String?
    var durationMs: Int?
    var jobID: String?
    var turn: Int?
    /// 会话标题（插件从首条用户消息提取），回合通知展示用。
    var sessionTitle: String?

    var isSubagent: Bool { kind == "subagent" }

    var isTurn: Bool { kind == "turn" }

    var isFailure: Bool { status == "failed" || status == "error" }

    /// 通知标题：按类型与状态区分，失败用更强措辞。
    var title: String {
        if isTurn {
            switch status {
            case "completed": return "对话完成"
            case "error": return "对话出错"
            case "blocked": return "对话需要你的输入"
            case "max-tokens": return "对话已达上限"
            case "aborted": return "对话已中断"
            default: return "对话回合结束"
            }
        }
        if isSubagent {
            return isFailure ? "子代理任务失败" : (status == "killed" ? "子代理任务已终止" : "子代理任务完成")
        }
        switch status {
        case "completed": return "后台任务完成"
        case "failed": return "后台任务失败"
        case "killed": return "后台任务已终止"
        default: return "任务已结束"
        }
    }

    /// 通知正文：回合通知显示会话标题 + 轮次；任务通知显示标签 + 失败细节 + 耗时。
    var body: String {
        if isTurn {
            let roundText: String
            if let turn {
                roundText = "第 \(turn) 轮回复已完成"
            } else {
                roundText = "回复已完成"
            }
            guard let sessionTitle, !sessionTitle.isEmpty else {
                return roundText
            }
            return "「\(Self.clamp(sessionTitle, to: 36))」\(roundText)"
        }
        var parts: [String] = []
        let label = Self.clamp(label, to: 80)
        parts.append(label.isEmpty ? "（无标签任务）" : label)
        if isFailure, let detail = detail, !detail.isEmpty {
            parts.append("（\(Self.clamp(detail, to: 120))）")
        }
        if let durationMs {
            parts.append(Self.durationText(durationMs))
        }
        return parts.joined(separator: " ")
    }

    /// 通知 identifier：按任务/会话去重，同一对象只保留最新一条。
    var notificationID: String {
        if isTurn, let jobID {
            return "dsh-notify-turn-\(jobID)"
        }
        return "dsh-notify-\(jobID ?? "\(kind)-\(startedAtFallback)")"
    }

    private var startedAtFallback: String {
        "\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    private static func durationText(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "耗时 \(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "耗时 \(minutes) 分 \(seconds) 秒" }
        return "耗时 \(seconds) 秒"
    }
}

/// 通知中心门面：懒授权、发送、点击路由。静态单例，App 生命周期内常驻。
enum HarnessNotify {
    /// 通知点击后切到的中央区域模式（harnessOnly = 聚焦 Harness 面板）。
    /// 同文件内的点击代理需要读取，故为 internal。
    static let focusModeRawValue = WorkspaceCentralMode.harnessOnly.rawValue

    /// 入口：处理 App 收到的 `floralmd://notify` URL。
    /// - Parameter url: 例如 floralmd://notify?kind=bash&label=npm+run+build&status=completed&durationMs=12000
    /// 两类通知开关完全独立：任务通知受 isNotifyEnabled 控制；回合通知受 turnNotifyPolicy 控制。
    @MainActor
    static func handleOpenURL(_ url: URL) {
        guard let payload = parse(url) else {
            NSLog("HarnessNotify: 无法解析的通知 URL: %@", url.absoluteString)
            return
        }
        if payload.isTurn {
            switch HarnessSettings.turnNotifyPolicy() {
            case .off: return
            case .backgroundOnly:
                // 前台抑制：App 活跃时用户正看着对话，回合通知不打扰。
                guard !NSApp.isActive else { return }
            case .always:
                break
            }
        } else {
            guard HarnessSettings.isNotifyEnabled() else { return }
        }
        post(payload)
    }

    /// 解析并发送一条通知。先请求授权（首次弹系统询问），拒绝则静默跳过。
    @MainActor
    private static func post(_ payload: HarnessNotifyPayload) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // 回调在后台线程；授权请求必须回到主线程，否则系统静默忽略、
            // 授权框不弹、通知永久被丢弃。
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .notDetermined:
                    requestAuthorizationThenPost(center, payload)
                case .authorized, .provisional:
                    enqueue(center, payload)
                case .denied, .ephemeral:
                    NSLog("HarnessNotify: 通知权限被拒绝，跳过（系统设置可重新开启）")
                @unknown default:
                    break
                }
            }
        }
    }

    private static func requestAuthorizationThenPost(
        _ center: UNUserNotificationCenter,
        _ payload: HarnessNotifyPayload
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("HarnessNotify: 授权请求失败: %@", String(describing: error))
                return
            }
            guard granted else {
                NSLog("HarnessNotify: 通知授权被拒绝")
                return
            }
            enqueue(center, payload)
        }
    }

    private static func enqueue(_ center: UNUserNotificationCenter, _ payload: HarnessNotifyPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = payload.isFailure
            ? UNNotificationSound(named: UNNotificationSoundName("Sosumi"))
            : .default
        content.userInfo = ["kind": payload.kind, "status": payload.status]
        let request = UNNotificationRequest(
            identifier: payload.notificationID,
            content: content,
            trigger: nil // 立即展示
        )
        center.add(request) { error in
            if let error {
                NSLog("HarnessNotify: 通知发送失败: %@", String(describing: error))
            }
        }
    }

    /// 本构建注册的 URL scheme（Debug = floralmd-dev，Release = floralmd）。
    /// 从 Info.plist 读取，避免硬编码 —— 开发版与正式版各收各的通知。
    static var registeredURLScheme: String? {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let schemes = types.first?["CFBundleURLSchemes"] as? [String] else {
            return nil
        }
        return schemes.first
    }

    /// 解析 `floralmd://notify` URL 为载荷；非 notify 路由返回 nil。
    private static func parse(_ url: URL) -> HarnessNotifyPayload? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = registeredURLScheme,
              components.scheme == scheme,
              components.host == "notify" else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let kind = value("kind"), let status = value("status") else {
            return nil
        }
        return HarnessNotifyPayload(
            kind: kind,
            label: value("label") ?? "",
            status: status,
            detail: value("detail"),
            durationMs: value("durationMs").flatMap(Int.init),
            jobID: value("id"),
            turn: value("turn").flatMap(Int.init),
            sessionTitle: value("title")
        )
    }
}

/// 通知点击响应：激活 App 并聚焦 Harness 面板。
/// 在 App 启动时注册为 UNUserNotificationCenter 的 delegate（见 FloralMDAppDelegate）。
final class HarnessNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.notification.request.identifier.hasPrefix("dsh-notify-") else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            // 切到 Harness 面板（UserDefaults 写入，@AppStorage 会同步）。
            UserDefaults.standard.set(HarnessNotify.focusModeRawValue, forKey: HarnessPreferenceKey.centralMode)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // App 在前台也展示横幅（用户可能在别的窗口工作，横幅是核心用途）。
        completionHandler([.banner, .sound])
    }
}
