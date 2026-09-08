//
//  DSHVersionResolver.swift
//  FloralMD
//
//  Created for feature/dsh-version-display.
//  解析"实际运行的 dsh 版本"：纯宿主侧探测，不修改 dsh 本体（ADR 0011）。
//
//  解析链：lsof 找监听 3080 的进程 PID → ps 取其命令行 → 从命令行中的
//  npx 缓存路径读 @deepseek-ai/dsh 的 package.json → version。
//  兜底：扫 ~/.npm/_npx/* 下最新的 dsh 缓存目录读版本。
//

import Foundation

enum DSHVersionResolver {
    /// 主入口：解析监听指定端口进程所用的 dsh 版本。
    /// 进程解析失败（服务未运行/命令不可用）时回退到 npx 缓存中最近安装的版本。
    /// - Parameter port: 服务监听端口，默认 3080。
    /// - Returns: 语义版本字符串（如 "0.1.0-rc.6"），解析不到时为 nil。
    static func resolve(port: Int = 3080) -> String? {
        if let line = listenerCommandLine(port: port),
           let root = cacheRoot(fromCommandLine: line),
           let version = cachedVersion(cacheRoot: root) {
            return version
        }
        return newestCachedVersion()
    }

    /// 从进程命令行提取 npx 缓存根目录。
    /// 形如 `node /Users/x/.npm/_npx/<hash>/node_modules/.bin/dsh web`，
    /// 返回 `/Users/x/.npm/_npx/<hash>`。
    static func cacheRoot(fromCommandLine line: String) -> String? {
        guard let marker = line.range(of: "/.npm/_npx/") else { return nil }
        let afterMarker = line[marker.upperBound...]
        guard let hashEnd = afterMarker.firstIndex(of: "/") else { return nil }
        guard let pathStart = line.firstIndex(of: "/") else { return nil }
        return String(line[pathStart..<hashEnd])
    }

    /// 从 @deepseek-ai/dsh 的 package.json 读取版本号。
    static func version(fromPackageJSON url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// 在 npx 缓存根下定位 dsh 包的 package.json 并读版本。
    static func cachedVersion(cacheRoot: String) -> String? {
        let packageURL = URL(fileURLWithPath: cacheRoot)
            .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        return version(fromPackageJSON: packageURL)
    }

    /// 兜底：扫 npx 缓存根下所有 dsh 安装，取修改时间最新的版本。
    /// - Parameter npxRoot: npx 缓存根（`~/.npm/_npx`）；测试可注入假根。
    static func newestCachedVersion(npxRoot: URL? = nil) -> String? {
        let root = npxRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let cacheDirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newestPackage: URL?
        var newestDate = Date.distantPast
        for dir in cacheDirs {
            let package = dir.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
            guard FileManager.default.fileExists(atPath: package.path) else { continue }
            let date = (try? package.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newestPackage = package
            }
        }
        guard let newestPackage else { return nil }
        return version(fromPackageJSON: newestPackage)
    }

    /// 监听指定端口的进程命令行（lsof 找 PID → ps 取命令行）。
    static func listenerCommandLine(port: Int) -> String? {
        guard let pid = listenerPID(port: port) else { return nil }
        return processCommandLine(pid: pid)
    }

    /// 监听指定端口的进程 PID（`lsof -nP -iTCP:<port> -sTCP:LISTEN`）。
    static func listenerPID(port: Int) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]),
              let firstLine = output.split(separator: "\n").first else { return nil }
        return listenerPID(fromLine: String(firstLine))
    }

    /// 从 lsof 输出行解析 PID（第二列）。
    static func listenerPID(fromLine line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return nil }
        let pid = String(parts[1])
        return pid.allSatisfy(\.isNumber) ? pid : nil
    }

    /// 进程完整命令行（`ps -p <pid> -o command=`）。
    static func processCommandLine(pid: String) -> String? {
        guard let output = run("/bin/ps", ["-p", pid, "-o", "command="]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 私有

    /// 同步运行一个本地命令并取回标准输出；退出码非零返回 nil。
    /// 仅用于 lsof/ps 这类输出极小的系统命令。
    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
