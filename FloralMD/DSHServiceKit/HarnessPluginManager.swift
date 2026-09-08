//
//  HarnessPluginManager.swift
//  FloralMD
//
//  Created for feature/dsh-notify; generalized for feature/harness-plugin-manager.
//  dsh 插件注入：启动 harness 前确保随包插件就位——
//  1) 把 App bundle 内的插件包拷贝到 $DSH_HOME/profiles/node_modules；
//  2) 幂等地向 $DSH_HOME/profiles/web/cordis.patch.yml 追加注册条目。
//
//  语义与 dsh-usage-stats/scripts/install.mjs 一致：只追加、绝不覆盖已有条目；
//  已存在（无论谁装的）即视为在位。关闭插件 = 移除自己注入的带标记条目
//  （只动带 `# <id>:` 注释标记的块，官方/他人条目绝不触碰），两方向均幂等。
//  所有失败静默降级——注入失败不阻塞 harness 启动。
//

import Foundation

/// 插件注入形态。
enum HarnessPluginKind {
    /// cordis.patch.yml 注册（dsh-notify 及未来 dsh-web-ui 插件）。
    case profilePatch
    /// WKWebView evaluateJavaScript 注入（dsh-editor-path），不进 patch。
    case javaScriptInjection
}

/// 随 FloralMD 分发的内置插件清单条目。
struct HarnessPluginDescriptor {
    /// 稳定标识：patch 的 id、UserDefaults 键后缀、设置页行 id。
    let id: String
    /// profilePatch 型：node_modules 目录名与 patch 条目的 name。
    let packageName: String
    /// Bundle 内资源子目录（Xcode fileSystemSynchronizedGroups 自动拷贝）。
    let bundleSubdirectory: String
    let kind: HarnessPluginKind
    /// 设置页显示名。
    let title: String
    /// 设置页描述。
    let summary: String
    /// patch 条目的注释标记（`# <id>: <note>`），移除时按此前缀定位。
    let patchNote: String
    /// 默认开关；dsh-editor-path 为 true（既有功能迁移，避免按钮凭空消失），其余默认 false。
    let defaultEnabled: Bool
    /// 迁移回退键：新键首次写入前从此键读取旧值（dsh-notify → HarnessNotifyOnJobDone）。
    let legacyKey: String?
}

/// 设置页展示的插件注入状态。
enum HarnessPluginInjectionStatus {
    /// 开关关闭，不注入。
    case disabled
    /// 已启用且就位（已注入 / 资源在 bundle）。
    case installed
    /// 已启用但未就位（缺 bundle 资源 / 尚未注入）。
    case missing
}

enum HarnessPluginManager {
    /// 内置插件清单（设置页遍历此清单渲染）。
    static let plugins: [HarnessPluginDescriptor] = [
        HarnessPluginDescriptor(
            id: "dsh-notify",
            packageName: "dsh-notify",
            bundleSubdirectory: "HarnessPlugins/dsh-notify",
            kind: .profilePatch,
            title: "任务完成通知",
            summary: "后台任务、子代理完成或失败时弹出原生通知；点击通知切到 Harness 面板。首次发送前需要授权通知权限。",
            patchNote: "task-completion notifications delivered to the host app (FloralMD).",
            defaultEnabled: true,
            legacyKey: HarnessPreferenceKey.notifyOnJobDone
        ),
        HarnessPluginDescriptor(
            id: "dsh-editor-path",
            packageName: "dsh-editor-path",
            bundleSubdirectory: "HarnessPlugins/dsh-editor-path",
            kind: .javaScriptInjection,
            title: "文档路径插入",
            summary: "把当前编辑文档的路径插入 dsh 输入栏（工具栏按钮触发）。",
            patchNote: "",
            defaultEnabled: true,
            legacyKey: nil
        ),
    ]

    static func plugin(_ id: String) -> HarnessPluginDescriptor? {
        plugins.first { $0.id == id }
    }

    private static var dshHome: String {
        // 与 dsh 的 DSH_HOME 默认一致（usage-stats 安装脚本同款解析）。
        ProcessInfo.processInfo.environment["DSH_HOME"] ?? "\(NSHomeDirectory())/.dsh"
    }

    private static var profilesNodeModules: String {
        "\(dshHome)/profiles/node_modules"
    }

    private static var webProfilePatch: String {
        "\(dshHome)/profiles/web/cordis.patch.yml"
    }

    // MARK: - 注入

    /// 遍历清单，为所有启用的 profilePatch 型插件执行幂等注入。失败不阻塞 harness 启动。
    @discardableResult
    static func ensureInstalled() -> Bool {
        var all = true
        for descriptor in plugins where descriptor.kind == .profilePatch {
            guard HarnessSettings.isPluginEnabled(descriptor.id) else { continue }
            all = ensureInstalled(for: descriptor) && all
        }
        return all
    }

    /// 幂等注入单个插件：拷贝插件 + 追加 patch 条目。返回是否全部就位。
    @discardableResult
    static func ensureInstalled(for descriptor: HarnessPluginDescriptor) -> Bool {
        let copied = copyPluginIfNeeded(for: descriptor)
        let patched = descriptor.kind == .profilePatch ? appendPatchEntryIfNeeded(for: descriptor) : true
        if !copied || !patched {
            NSLog(
                "HarnessPluginManager: 插件 %@ 注入未完成（copy=%@ patch=%@）",
                descriptor.id, "\(copied)", "\(patched)"
            )
        }
        return copied && patched
    }

    /// 移除单个插件的注入：profilePatch 型删除自己的带标记 patch 条目；JS 注入型无需处理。
    /// 幂等：条目不存在时成功。失败返回 false（不阻塞 UI）。
    @discardableResult
    static func removeEntry(for descriptor: HarnessPluginDescriptor) -> Bool {
        guard descriptor.kind == .profilePatch else { return true }
        let fileManager = FileManager.default
        let path = webProfilePatch
        do {
            guard fileManager.fileExists(atPath: path),
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let next = contentsRemovingEntry(text, for: descriptor) else {
                return true // 无文件或无条目，幂等成功
            }
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("HarnessPluginManager: 移除插件 %@ 条目失败: %@", descriptor.id, String(describing: error))
            return false
        }
    }

    /// 当前注入状态（设置页展示）。
    static func injectionStatus(for descriptor: HarnessPluginDescriptor) -> HarnessPluginInjectionStatus {
        guard HarnessSettings.isPluginEnabled(descriptor.id) else { return .disabled }
        switch descriptor.kind {
        case .javaScriptInjection:
            return bundledResourceExists(for: descriptor) ? .installed : .missing
        case .profilePatch:
            let inBundle = bundledResourceExists(for: descriptor)
            let copied = FileManager.default.fileExists(atPath: installedPluginURL(for: descriptor).path)
            let patched = profileContainsEntry(for: descriptor)
            return inBundle && copied && patched ? .installed : .missing
        }
    }

    // MARK: - 拷贝

    /// 整体替换目标插件目录（删除 + 拷贝），保证与 App bundle 内容一致。
    /// 运行中的 harness 已把模块载入内存，替换磁盘文件不影响当前进程，重启后生效。
    private static func copyPluginIfNeeded(for descriptor: HarnessPluginDescriptor) -> Bool {
        guard let source = bundledPluginURL(for: descriptor) else {
            NSLog("HarnessPluginManager: bundle 内未找到插件资源 %@", descriptor.bundleSubdirectory)
            return false
        }
        let fileManager = FileManager.default
        let target = installedPluginURL(for: descriptor)
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: target)
            return true
        } catch {
            NSLog("HarnessPluginManager: 拷贝插件 %@ 失败: %@", descriptor.id, String(describing: error))
            return false
        }
    }

    private static func bundledPluginURL(for descriptor: HarnessPluginDescriptor) -> URL? {
        Bundle.main.url(
            forResource: descriptor.packageName,
            withExtension: nil,
            subdirectory: descriptor.bundleSubdirectory
        )
    }

    private static func bundledResourceExists(for descriptor: HarnessPluginDescriptor) -> Bool {
        bundledPluginURL(for: descriptor) != nil
    }

    private static func installedPluginURL(for descriptor: HarnessPluginDescriptor) -> URL {
        URL(fileURLWithPath: profilesNodeModules, isDirectory: true)
            .appendingPathComponent(descriptor.packageName, isDirectory: true)
    }

    // MARK: - patch 条目

    /// 插件的 patch 注册块（带 `# <id>:` 注释标记，供移除时定位）。
    static func patchBlock(for descriptor: HarnessPluginDescriptor) -> String {
        """
        # \(descriptor.id): \(descriptor.patchNote)
        - insert:
            - id: \(descriptor.id)
              name: \(descriptor.packageName)
        """
    }

    /// 返回追加注册条目后的 profile 内容；已存在精确的插件名行时返回 nil。
    /// 清理独立的空根序列 `[]` 行；其余内容（含注释）原样保留。
    static func patchedProfileContents(
        _ text: String,
        for descriptor: HarnessPluginDescriptor
    ) -> String? {
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "name: \(descriptor.packageName)"
        }) {
            return nil
        }

        // 移除独立成行的空根序列 `[]`（会与追加的列表条目冲突）。
        let cleaned = lines
            .filter { $0.trimmingCharacters(in: .whitespaces) != "[]" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return cleaned.isEmpty
            ? patchBlock(for: descriptor)
            : cleaned + "\n" + patchBlock(for: descriptor) + "\n"
    }

    /// 返回移除该插件标记块后的内容；无该插件条目时返回 nil（幂等成功）。
    /// 只删除以 `# <id>:` 开头的注释行及其后的 insert 条目块（含块尾空行），
    /// 其余顶层条目（官方/他人插件）与注释原样保留。
    static func contentsRemovingEntry(
        _ text: String,
        for descriptor: HarnessPluginDescriptor
    ) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let marker = "# \(descriptor.id):"
        var result: [String] = []
        var removed = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !removed && trimmed.hasPrefix(marker) {
                removed = true
                index += 1
                // 块 = 标记注释行 + `- insert:` 顶层条目行 + 后续缩进行的多行块，
                // 再吃掉块尾连续空行（与其他条目/文件尾的分隔）。`- insert:` 本身
                // 无缩进，不能当作"下一个顶层行"——否则只删注释、留下空的 insert 块。
                if index < lines.count && lines[index].hasPrefix("- insert:") {
                    index += 1
                }
                while index < lines.count {
                    let next = lines[index]
                    if next.isEmpty || next.hasPrefix(" ") || next.hasPrefix("\t") {
                        index += 1
                    } else {
                        break
                    }
                }
                while index < lines.count && lines[index].isEmpty {
                    index += 1
                }
                continue
            }
            result.append(line)
            index += 1
        }
        guard removed else { return nil }
        return result.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// profile 内容里是否已存在该插件的 name 条目。
    private static func profileContainsEntry(for descriptor: HarnessPluginDescriptor) -> Bool {
        guard let text = try? String(contentsOfFile: webProfilePatch, encoding: .utf8) else {
            return false
        }
        return text.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "name: \(descriptor.packageName)"
        }
    }

    /// 幂等追加：内容里已存在 `name: <packageName>` 条目则跳过。
    private static func appendPatchEntryIfNeeded(for descriptor: HarnessPluginDescriptor) -> Bool {
        let path = webProfilePatch
        let fileManager = FileManager.default
        do {
            let text: String
            if fileManager.fileExists(atPath: path) {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } else {
                text = ""
            }
            guard let next = patchedProfileContents(text, for: descriptor) else {
                return true // 已注册，保持现状
            }

            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("HarnessPluginManager: 写入 patch 失败: %@", String(describing: error))
            return false
        }
    }
}
