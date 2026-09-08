import CryptoKit
import Foundation

nonisolated struct MarkdownDiskSnapshot: Equatable, Sendable {
    let url: URL
    let text: String
    let identity: WorkspaceFileIdentity?
    let modificationDate: Date?
    let fileSize: Int?
    let contentHash: String
    let saveGeneration: UInt64

    func withSaveGeneration(_ generation: UInt64) -> MarkdownDiskSnapshot {
        MarkdownDiskSnapshot(
            url: url,
            text: text,
            identity: identity,
            modificationDate: modificationDate,
            fileSize: fileSize,
            contentHash: contentHash,
            saveGeneration: generation
        )
    }
}

nonisolated struct CoordinatedMarkdownDiskStore: Sendable {
    func loadSnapshot(at url: URL, saveGeneration: UInt64) throws -> MarkdownDiskSnapshot {
        let standardizedURL = url.standardizedFileURL
        var coordinatorError: NSError?
        var result: Result<MarkdownDiskSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: standardizedURL,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                let values = try? coordinatedURL.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .fileResourceIdentifierKey
                ])
                let identity = values?.fileResourceIdentifier.map {
                    WorkspaceFileIdentity(rawValue: "resource:\(String(describing: $0))")
                }
                result = .success(
                    MarkdownDiskSnapshot(
                        url: coordinatedURL.standardizedFileURL,
                        text: text,
                        identity: identity,
                        modificationDate: values?.contentModificationDate,
                        fileSize: values?.fileSize,
                        contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        saveGeneration: saveGeneration
                    )
                )
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    func save(_ text: String, at url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: standardizedURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                guard let data = text.data(using: .utf8) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }
}

nonisolated final class ActiveMarkdownFileMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    enum Event: Sendable {
        case rescan(suggestedURL: URL?)
    }

    // `primaryPresentedItemURL` is the App Sandbox authority for a secondary
    // presented item. This monitor only observes the already-authorized workspace
    // directory, so it must not create or revoke a presenter-owned authority.
    let presentedItemOperationQueue: OperationQueue
    var presentedItemURL: URL? { lockedDirectoryURL() }

    private let lock = NSLock()
    private var directoryURL: URL?
    private let eventHandler: @Sendable (Event) -> Void
    private var pendingWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private var isRegistered = false

    init(
        url: URL,
        debounceInterval: TimeInterval = 0.15,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        directoryURL = url.standardizedFileURL.deletingLastPathComponent()
        self.debounceInterval = debounceInterval
        self.eventHandler = eventHandler
        let queue = OperationQueue()
        queue.name = "FloralMD.ActiveMarkdownFilePresenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        lock.lock()
        guard !isRegistered else {
            lock.unlock()
            return
        }
        isRegistered = true
        lock.unlock()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        lock.lock()
        let shouldRemove = isRegistered
        isRegistered = false
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        lock.unlock()
        if shouldRemove { NSFileCoordinator.removeFilePresenter(self) }
    }

    deinit { stop() }

    func presentedItemDidChange() {
        schedule(.rescan(suggestedURL: nil))
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        directoryURL = newURL.standardizedFileURL
        lock.unlock()
        schedule(.rescan(suggestedURL: nil))
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        schedule(.rescan(suggestedURL: nil))
        completionHandler(nil)
    }

    func presentedSubitemDidAppear(at url: URL) {
        schedule(.rescan(suggestedURL: url.standardizedFileURL))
    }

    func presentedSubitemDidChange(at url: URL) {
        schedule(.rescan(suggestedURL: url.standardizedFileURL))
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        schedule(.rescan(suggestedURL: newURL.standardizedFileURL))
    }

    func accommodatePresentedSubitemDeletion(
        at url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        schedule(.rescan(suggestedURL: url.standardizedFileURL))
        completionHandler(nil)
    }

    private func lockedDirectoryURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return directoryURL
    }

    private func schedule(_ event: Event) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let registered = self.isRegistered
            self.lock.unlock()
            if registered { self.eventHandler(event) }
        }
        lock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
    }
}
