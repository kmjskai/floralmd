//
//  HarnessSettings.swift
//  FloralMD
//
//  Created for feature/dsh-harness.
//  Harness 模块的设置存取与集中模式枚举。
//

import Foundation
import ServiceManagement

enum HarnessPreferenceKey {
    static let enabled = "HarnessEnabled"
    static let centralMode = "HarnessCentralMode"
    static let launchAtLogin = "HarnessLaunchAtLogin"
    static let lockedVersion = "HarnessLockedDSHVersion"
    static let workspacePath = "HarnessWorkspacePath"
    static let webPageZoom = "HarnessWebPageZoom"
    static let notifyOnJobDone = "HarnessNotifyOnJobDone"
    static let turnNotifyPolicy = "HarnessTurnNotifyPolicy"
}

/// 对话回合通知策略：何时弹"对话完成"通知。
enum HarnessTurnNotifyPolicy: String, CaseIterable, Identifiable {
    /// 仅 App 不在前台时通知（默认，避免自扰）。
    case backgroundOnly
    /// 前台也通知（便于测试/需要强提醒的场景）。
    case always
    /// 关闭对话回合通知。
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .backgroundOnly: "仅后台"
        case .always: "始终"
        case .off: "关闭"
        }
    }

    var helpText: String {
        switch self {
        case .backgroundOnly: "FloralMD 在前台时不打扰，切到其他应用后提醒。"
        case .always: "无论 FloralMD 是否在前台都会提醒。"
        case .off: "不发送对话回合通知。"
        }
    }
}

enum HarnessSettings {
    static let defaultWorkspaceDirectoryName = "FloralMD-Harness"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: HarnessPreferenceKey.enabled) as? Bool ?? true
    }

    // MARK: - 插件开关

    static func pluginEnabledKey(_ id: String) -> String {
        "HarnessPluginEnabled-\(id)"
    }

    /// 插件开关读取：新键优先；未设置时回退清单条目的 legacyKey（迁移），
    /// 再回退清单默认值。未知插件 id 一律视为关闭。
    static func isPluginEnabled(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        if let value = defaults.object(forKey: pluginEnabledKey(id)) as? Bool {
            return value
        }
        guard let descriptor = HarnessPluginManager.plugin(id) else { return false }
        if let legacyKey = descriptor.legacyKey,
           let value = defaults.object(forKey: legacyKey) as? Bool {
            return value
        }
        return descriptor.defaultEnabled
    }

    /// 写入插件开关并清除 legacyKey（一次性迁移，杜绝双键分叉）。
    static func setPluginEnabled(_ id: String, _ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: pluginEnabledKey(id))
        if let legacyKey = HarnessPluginManager.plugin(id)?.legacyKey {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    /// 任务通知开关（后台任务/子代理完成）；与回合通知策略完全独立。
    /// 语义 = dsh-notify 插件开关，保留此别名避免改动调用点。
    static func isNotifyEnabled(defaults: UserDefaults = .standard) -> Bool {
        isPluginEnabled("dsh-notify", defaults: defaults)
    }

    /// 对话回合通知策略；默认仅后台（App 前台不打扰）。
    static func turnNotifyPolicy(defaults: UserDefaults = .standard) -> HarnessTurnNotifyPolicy {
        HarnessTurnNotifyPolicy(rawValue: defaults.string(forKey: HarnessPreferenceKey.turnNotifyPolicy) ?? "")
            ?? .backgroundOnly
    }

    static func centralMode(defaults: UserDefaults = .standard) -> WorkspaceCentralMode {
        WorkspaceCentralMode(rawValue: defaults.string(forKey: HarnessPreferenceKey.centralMode) ?? "")
            ?? .editorOnly
    }

    /// 锁定的 dsh 版本号；空字符串表示跟随最新版。
    static func lockedDSHVersion(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: HarnessPreferenceKey.lockedVersion) ?? ""
    }

    static func isLaunchAtLoginEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: HarnessPreferenceKey.launchAtLogin) as? Bool ?? false
    }

    /// Harness 服务工作目录：默认 ~/FloralMD-Harness，可在设置中修改。
    static func workspaceURL(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: HarnessPreferenceKey.workspacePath),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultWorkspaceDirectoryName, isDirectory: true)
    }

    /// 注册/注销登录自启（需要 App 位于 /Applications 才能生效）。
    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    static func launchAtLoginStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }
}

/// ⌘⇧H：在"编辑器"与"Harness"两极之间直切（并存态按下收起编辑器进入 Harness）。
/// 通过 UserDefaults 写入，@AppStorage 会同步。
enum HarnessViewShortcut {
    static func toggle() {
        let current = WorkspaceCentralMode(
            rawValue: UserDefaults.standard.string(forKey: HarnessPreferenceKey.centralMode) ?? ""
        ) ?? .editorOnly
        let next: WorkspaceCentralMode = current == .harnessOnly ? .editorOnly : .harnessOnly
        UserDefaults.standard.set(next.rawValue, forKey: HarnessPreferenceKey.centralMode)
    }
}
