//
//  DSHService.swift
//  FloralMD
//
//  Created for feature/dsh-harness.
//  服务托管：探测 127.0.0.1:3080 → 挂接或拉起 `npx --yes @deepseek-ai/dsh web` → 崩溃自恢复。
//
//  外部依赖面刻意保持极小（CLI + HTTP + 数据目录），这是抗 dsh 更新的关键。
//

import Combine
import Darwin
import Foundation

enum HarnessServiceState: Equatable, Hashable {
    case stopped
    case starting
    case running
    case failed(String)
    case disabled

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "启动中…"
        case .running: "运行中"
        case .failed: "启动失败"
        case .disabled: "已禁用"
        }
    }

    var canRestart: Bool {
        switch self {
        case .running, .failed: true
        case .stopped, .starting, .disabled: false
        }
    }

    var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .stopped: (0.55, 0.55, 0.55)
        case .starting: (0.95, 0.75, 0.25)
        case .running: (0.25, 0.75, 0.35)
        case .failed: (0.9, 0.3, 0.25)
        case .disabled: (0.55, 0.55, 0.55)
        }
    }
}

@MainActor
final class DSHService: ObservableObject {
    static let shared = DSHService()

    @Published private(set) var state: HarnessServiceState = .stopped
    /// 服务进程最近的输出尾部，用于排错展示。
    @Published private(set) var logTail: String = ""
    /// 实际运行的 dsh 版本（宿主侧解析：监听进程 → npx 缓存 package.json）。
    @Published private(set) var runningVersion: String?

    private var process: Process?
    private var isStopping = false
    private var restartCount = 0
    private let maxRestarts = 3
    private let servicePort = 3080
    private let probeURL = URL(string: "http://127.0.0.1:3080")!

    private var logAccumulator = ""
    private let logTailLimit = 4096

    /// 模块被禁用时绝不拉起服务。
    func startIfNeeded() {
        guard HarnessSettings.isEnabled() else {
            state = .disabled
            return
        }
        guard state != .running, state != .starting else { return }
        Task { await start() }
    }

    func start() async {
        guard HarnessSettings.isEnabled() else {
            state = .disabled
            return
        }
        state = .starting
        restartCount = 0
        if await isServiceAlive() {
            state = .running
            await refreshVersion()
            return
        }
        spawn()
        await refreshVersion()
    }

    func stop() {
        isStopping = true
        if let process, process.isRunning {
            pipeCleanup()
            // dsh 经 npx 拉起：npx 是包装进程，SIGTERM 不会传播给它的 node
            // 服务子进程。只 terminate 父进程会让旧服务继续监听 3080——
            // 任务不断、restart 变成"挂接旧服务"的假重启。必须先整树清理。
            ProcessTree.kill(process.processIdentifier)
            if process.isRunning {
                process.terminate()
            }
        }
        // 挂接模式：本实例未 spawn（process == nil）时，端口上的服务可能是
        // 孤儿/外部进程（如先前实例拉起的 dsh）。按端口定位监听者整树清理，
        // 否则 restart 同样变成假重启：任务不断、状态闪回 running。
        if let listenerPID = ProcessTree.listenerPID(on: servicePort) {
            ProcessTree.kill(listenerPID)
        }
        process = nil
        isStopping = false
        runningVersion = nil
        state = .stopped
    }

    func restart() {
        stop()
        Task { await start() }
    }

    /// 重新解析实际运行的 dsh 版本：探测监听进程（lsof/ps），失败则回退到
    /// npx 缓存中最近安装的版本。纯宿主侧，不读取 dsh 内部状态。
    func refreshVersion() async {
        let port = servicePort
        let version = await Task.detached(priority: .utility) {
            DSHVersionResolver.resolve(port: port)
        }.value
        runningVersion = version
    }

    // MARK: - 内部

    private func isServiceAlive() async -> Bool {
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    private func spawn() {
        let workspaceURL = HarnessSettings.workspaceURL()
        do {
            try FileManager.default.createDirectory(
                at: workspaceURL, withIntermediateDirectories: true
            )
        } catch {
            state = .failed("无法创建工作目录：\(error.localizedDescription)")
            return
        }

        // 任务完成通知：spawn 前确保 dsh-notify 插件就位（幂等；失败不阻塞启动）。
        HarnessPluginManager.ensureInstalled()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let package = HarnessSettings.lockedDSHVersion().isEmpty
            ? "@deepseek-ai/dsh"
            : "@deepseek-ai/dsh@\(HarnessSettings.lockedDSHVersion())"
        process.arguments = ["npx", "--yes", package, "web"]
        process.currentDirectoryURL = workspaceURL
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            // 通知 scheme 随构建身份走：Debug 版 → floralmd-dev，正式版 → floralmd。
            "DSH_NOTIFY_SCHEME": HarnessNotify.registeredURLScheme ?? "floralmd",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        self.process = process
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleTermination()
            }
        }

        do {
            try process.run()
            state = .running
        } catch {
            state = .failed("无法启动 dsh 服务：\(error.localizedDescription)")
        }
    }

    private func handleTermination() {
        pipeCleanup()
        process = nil
        guard !isStopping else {
            state = .stopped
            return
        }
        // 服务自己退了（崩溃或手动在别处停止）。
        // 它可能是"挂接"到外部服务后对方退出；此处按守护策略重启，限次。
        restartCount += 1
        if restartCount <= maxRestarts {
            appendLog("服务进程退出（第 \(restartCount) 次），2 秒后重启…")
            state = .starting
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !isStopping else { return }
                await start()
            }
        } else {
            state = .failed("服务在短时间内多次退出，已停止自动重启。请检查日志后手动重启。")
        }
    }

    private func pipeCleanup() {
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func appendLog(_ text: String) {
        logAccumulator += text
        if logAccumulator.count > logTailLimit {
            logAccumulator = String(logAccumulator.suffix(logTailLimit))
        }
        logTail = logAccumulator
    }
}

/// 进程树工具（供 DSHService.stop 使用；非 MainActor，不阻塞主线程）。
enum ProcessTree {
    static let lsofExecutableURL = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// 递归 SIGKILL 进程树（先子后父）。
    /// 通过 `pgrep -P` 逐层收集直接子进程；对已退出进程的 kill 是幂等无害的。
    /// 注意必须在父进程 terminate 之前调用：父进程死后子进程会被 init 收养，
    /// `pgrep -P <父pid>` 就再也找不到它们了。
    static func kill(_ rootPID: Int32) {
        guard rootPID > 1 else { return }
        for childPID in allPIDs(under: rootPID) {
            Darwin.kill(childPID, SIGKILL)
        }
        Darwin.kill(rootPID, SIGKILL)
    }

    /// 收集 rootPID 之下的全部后代进程（不含 root 自身），逐层展开。
    static func allPIDs(under rootPID: Int32) -> [Int32] {
        var result: [Int32] = []
        var frontier = directChildren(of: rootPID)
        while !frontier.isEmpty {
            result.append(contentsOf: frontier)
            frontier = frontier.flatMap { directChildren(of: $0) }
        }
        return result
    }

    /// 返回监听指定 TCP 端口的进程 pid（`lsof -tiTCP:<port> -sTCP:LISTEN`）。
    /// 挂接模式下定位 3080 上的 dsh 服务进程（即使它不是本实例 spawn 的）。
    /// 注意：macOS 上 lsof 位于 /usr/sbin（/usr/bin 下不存在），与 DSHVersionResolver 一致。
    static func listenerPID(on port: Int) -> Int32? {
        let lsof = Process()
        lsof.executableURL = lsofExecutableURL
        lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
            .flatMap { Int32($0) }
    }

    private static func directChildren(of parentPID: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(parentPID)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) } ?? []
    }
}
