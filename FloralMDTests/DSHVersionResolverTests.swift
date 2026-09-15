import Foundation
import Testing
@testable import FloralMD

struct DSHVersionResolverTests {
    @Test func cacheRootFromNpxProcessLine() {
        let line = "node /Users/alice/.npm/_npx/1e7f6d9597241db0/node_modules/.bin/dsh web"
        #expect(
            DSHVersionResolver.cacheRoot(fromCommandLine: line)
                == "/Users/alice/.npm/_npx/1e7f6d9597241db0"
        )
    }

    @Test func cacheRootRejectsUnrelatedLines() {
        #expect(DSHVersionResolver.cacheRoot(fromCommandLine: "/usr/bin/env npx web") == nil)
        #expect(DSHVersionResolver.cacheRoot(fromCommandLine: "") == nil)
        #expect(DSHVersionResolver.cacheRoot(fromCommandLine: "node /usr/local/bin/dsh web") == nil)
    }

    @Test func listenerPIDParsesLsofLine() {
        let line = "dsh    3358  yingkai  13u  IPv4 0xabc 0t0  TCP 127.0.0.1:3080 (LISTEN)"
        #expect(DSHVersionResolver.listenerPID(fromLine: line) == "3358")
    }

    @Test func listenerPIDRejectsHeaderLine() {
        #expect(DSHVersionResolver.listenerPID(fromLine: "COMMAND PID USER FD") == nil)
    }

    @Test func versionFromPackageJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("package.json")
        try Data(#"{"name":"@deepseek-ai/dsh","version":"0.1.0-rc.6"}"#.utf8).write(to: package)

        #expect(DSHVersionResolver.version(fromPackageJSON: package) == "0.1.0-rc.6")
    }

    @Test func versionFromPackageJSONMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("package.json")
        try Data(#"{"name":"@deepseek-ai/other"}"#.utf8).write(to: package)

        #expect(DSHVersionResolver.version(fromPackageJSON: package) == nil)
    }

    @Test func cachedVersionFromCacheRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir
            .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"version":"0.1.0-rc.6"}"#.utf8).write(to: package)

        #expect(DSHVersionResolver.cachedVersion(cacheRoot: dir.path) == "0.1.0-rc.6")
    }

    @Test func newestCachedVersionPrefersNewestDirectory() throws {
        let npxRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: npxRoot) }

        let olderDir = npxRoot.appendingPathComponent("cache-old")
        let olderPackage = olderDir.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try FileManager.default.createDirectory(
            at: olderPackage.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"version":"0.1.0-rc.5"}"#.utf8).write(to: olderPackage)

        let newerDir = npxRoot.appendingPathComponent("cache-new")
        let newerPackage = newerDir.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try FileManager.default.createDirectory(
            at: newerPackage.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"version":"0.1.0-rc.6"}"#.utf8).write(to: newerPackage)

        // 显式拉开修改时间，避免文件系统时间戳粒度影响判定。
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: olderPackage.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: new], ofItemAtPath: newerPackage.path
        )

        #expect(DSHVersionResolver.newestCachedVersion(npxRoot: npxRoot) == "0.1.0-rc.6")
    }

    @Test func newestCachedVersionEmptyRoot() throws {
        let npxRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: npxRoot) }

        #expect(DSHVersionResolver.newestCachedVersion(npxRoot: npxRoot) == nil)
    }

    // MARK: - 辅助

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-version-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
