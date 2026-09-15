import Darwin
import Foundation
import Testing
@testable import FloralMD

struct ProcessTreeTests {
    /// 造一棵真实进程树：sh 前台 exec sleep（保持 root 存活），后台再挂两个 sleep。
    /// 树形：root(sh→sleep) ─┬─ sleep
    ///                       └─ sleep
    private func spawnTree() async throws -> (root: Int32, tree: [Int32]) {
        let script = "sleep 30 & sleep 30 & exec sleep 30"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        let rootPID = process.processIdentifier
        // 等子进程 spawn 完成。
        try await Task.sleep(nanoseconds: 500_000_000)
        let tree = ProcessTree.allPIDs(under: rootPID)
        return (rootPID, tree)
    }

    private func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 核心回归：kill 必须让整棵进程树消失（npx → node 的场景）。
    /// 修复前只 terminate 父进程，node 子进程存活、任务不断。
    @Test func killTerminatesEntireTree() async throws {
        let (rootPID, tree) = try await spawnTree()
        defer {
            // 断言失败时兜底清理，避免残留 sleep 进程。
            if tree.contains(where: { isAlive($0) }) || isAlive(rootPID) {
                ProcessTree.kill(rootPID)
            }
        }

        #expect(!tree.isEmpty, "测试进程树未建立")
        let aliveBefore = (tree + [rootPID]).filter { isAlive($0) }
        #expect(aliveBefore.count == tree.count + 1, "进程树不完整: \(aliveBefore)")

        ProcessTree.kill(rootPID)

        // SIGKILL 生效需要调度时间。
        try await Task.sleep(nanoseconds: 300_000_000)

        let aliveAfter = (tree + [rootPID]).filter { isAlive($0) }
        #expect(aliveAfter.isEmpty, "进程树未杀净，仍存活: \(aliveAfter)")
    }

    /// 幂等：对不存在的 pid 调用必须无害。
    @Test func killIsIdempotentForUnknownPID() {
        ProcessTree.kill(999_999)
        ProcessTree.kill(0)
    }

    /// 挂接模式必须调用 macOS 实际安装的 lsof；路径错误会让重启静默挂接旧服务。
    @Test func listenerLookupUsesAvailableSystemLsof() {
        #expect(ProcessTree.lsofExecutableURL.path == "/usr/sbin/lsof")
        #expect(
            FileManager.default.isExecutableFile(
                atPath: ProcessTree.lsofExecutableURL.path
            )
        )
        #expect(ProcessTree.listenerPID(on: 18988) == nil)
    }
}
