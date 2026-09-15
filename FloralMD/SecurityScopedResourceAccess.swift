import Foundation

/// 沙盒感知的安全作用域支持。
/// 沙盒开启时（App Store 分发形态）使用 `.withSecurityScope` bookmark；
/// 非沙盒（GitHub/官网分发形态）解析普通 bookmark，避免 errSecMissingEntitlement。
enum SecurityScopeSupport {
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    nonisolated static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope, .withoutUI] : [.withoutUI]
    }

    nonisolated static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        isSandboxed ? .withSecurityScope : []
    }
}

nonisolated final class SecurityScopedResourceAccessManager {
    static let shared = SecurityScopedResourceAccessManager()

    typealias BeginAccess = (URL) -> Bool
    typealias EndAccess = (URL) -> Void

    private struct Entry {
        var accessURL: URL
        var ownerCount: Int
        var didBeginAccess: Bool
    }

    private let beginAccess: BeginAccess
    private let endAccess: EndAccess
    private let lock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]

    init(
        beginAccess: @escaping BeginAccess = { $0.startAccessingSecurityScopedResource() },
        endAccess: @escaping EndAccess = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.beginAccess = beginAccess
        self.endAccess = endAccess
    }

    func acquire(_ url: URL) -> SecurityScopedResourceLease {
        let key = url.standardizedFileURL.path
        lock.lock()
        if var entry = entries[key] {
            if !entry.didBeginAccess, beginAccess(url) {
                entry.accessURL = url
                entry.didBeginAccess = true
            }
            entry.ownerCount += 1
            entries[key] = entry
        } else {
            entries[key] = Entry(
                accessURL: url,
                ownerCount: 1,
                didBeginAccess: beginAccess(url)
            )
        }
        lock.unlock()
        return SecurityScopedResourceLease(
            url: url,
            manager: self,
            key: key
        )
    }

    func ownerCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[url.standardizedFileURL.path]?.ownerCount ?? 0
    }

    var activeRootCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    fileprivate func release(key: String) {
        lock.lock()
        guard var entry = entries[key], entry.ownerCount > 0 else {
            lock.unlock()
            return
        }
        entry.ownerCount -= 1
        if entry.ownerCount > 0 {
            entries[key] = entry
            lock.unlock()
            return
        }
        entries.removeValue(forKey: key)
        if entry.didBeginAccess {
            endAccess(entry.accessURL)
        }
        lock.unlock()
    }
}

nonisolated final class SecurityScopedResourceLease {
    let url: URL

    private let lock = NSLock()
    private var manager: SecurityScopedResourceAccessManager?
    private let key: String

    fileprivate init(
        url: URL,
        manager: SecurityScopedResourceAccessManager,
        key: String
    ) {
        self.url = url
        self.manager = manager
        self.key = key
    }

    func invalidate() {
        lock.lock()
        let manager = self.manager
        self.manager = nil
        lock.unlock()
        manager?.release(key: key)
    }

    deinit {
        invalidate()
    }
}
