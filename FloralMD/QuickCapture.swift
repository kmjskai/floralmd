import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension Notification.Name {
    static let handyNoteDefaultFolderDidChange = Notification.Name(
        "FloralMDDefaultFolderDidChange"
    )
}

enum QuickCaptureError: LocalizedError {
    case invalidFolder

    var errorDescription: String? {
        switch self {
        case .invalidFolder:
            "快速记录文件夹不可用，请重新选择。"
        }
    }
}

struct QuickCaptureFileWriter {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func createEmptyDocument(in folderURL: URL, now: Date = Date()) throws -> URL {
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw QuickCaptureError.invalidFolder }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = formatter.string(from: now)

        for suffix in 0..<10_000 {
            let filename = suffix == 0 ? "\(stem).md" : "\(stem)-\(suffix).md"
            let candidate = folderURL.appendingPathComponent(filename, isDirectory: false)
            do {
                try Data().write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }

        throw CocoaError(.fileWriteUnknown)
    }
}

@MainActor
final class QuickCaptureService {
    static let shared = QuickCaptureService()

    private enum DefaultsKey {
        static let folderBookmark = "QuickCaptureFolderBookmark"
    }

    private let defaults: UserDefaults
    private let fileWriter: QuickCaptureFileWriter
    private let securityScopeAccessManager: SecurityScopedResourceAccessManager
    private var accessedFolderLease: SecurityScopedResourceLease?

    init(
        defaults: UserDefaults = .standard,
        fileWriter: QuickCaptureFileWriter? = nil,
        securityScopeAccessManager: SecurityScopedResourceAccessManager = .shared
    ) {
        self.defaults = defaults
        self.fileWriter = fileWriter ?? QuickCaptureFileWriter()
        self.securityScopeAccessManager = securityScopeAccessManager
    }

    deinit {
        accessedFolderLease?.invalidate()
    }

    func perform() {
        NSApp.activate()

        do {
            if let controller = WorkspaceOpenRouter.shared.controller {
                _ = try controller.createUntitledMarkdown()
            } else {
                guard let rootURL = try defaultDocumentFolder(promptingIfNeeded: true) else { return }
                let layout = DraftWorkspaceLayout(root: rootURL)
                try layout.prepare()
                let documentURL = try fileWriter.createEmptyDocument(in: layout.notesDirectory)
                WorkspaceOpenRouter.shared.open(documentURL)
            }
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    @discardableResult
    func chooseAnotherFolder() -> URL? {
        NSApp.activate()
        do {
            let folder = try chooseFolder()
            if folder != nil {
                try WorkspaceOpenRouter.shared.controller?.open(targetURL: nil)
            }
            return folder
        } catch {
            NSApplication.shared.presentError(error)
            return nil
        }
    }

    func configuredFolderForDisplay() -> URL? {
        try? configuredFolderURL()
    }

    /// Returns the single security-scoped default folder shared by new documents,
    /// quick capture, and drawing persistence.
    func defaultDocumentFolder(promptingIfNeeded: Bool) throws -> URL? {
        if let configured = try configuredFolderURL() { return configured }
        return promptingIfNeeded ? try chooseFolder() : nil
    }

    private func configuredFolderURL() throws -> URL? {
        guard let data = defaults.data(forKey: DefaultsKey.folderBookmark) else { return nil }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: SecurityScopeSupport.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try persist(folderURL: url)
        }
        beginAccessing(folderURL: url)
        return url
    }

    private func chooseFolder() throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择新文档默认文件夹"
        panel.message = "快速记录和绘图都会保存在这里。取消不会创建或修改任何文件。"
        panel.prompt = "设为默认文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let folderURL = panel.url else { return nil }
        try persist(folderURL: folderURL)
        beginAccessing(folderURL: folderURL)
        return folderURL
    }

    private func persist(folderURL: URL) throws {
        let data = try folderURL.bookmarkData(
            options: SecurityScopeSupport.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: DefaultsKey.folderBookmark)
        NotificationCenter.default.post(name: .handyNoteDefaultFolderDidChange, object: nil)
    }

    private func beginAccessing(folderURL: URL) {
        let replacement = securityScopeAccessManager.acquire(folderURL)
        let previous = accessedFolderLease
        accessedFolderLease = replacement
        previous?.invalidate()
    }
}

enum UntitledDocumentContentPolicy {
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldClearEditedState(fileURL: URL?, text: String) -> Bool {
        fileURL == nil && isBlank(text)
    }

    static func shouldScheduleEditedStateReconciliation(
        fileURL: URL?,
        text: String,
        hasUserEdited: Bool
    ) -> Bool {
        hasUserEdited && shouldClearEditedState(fileURL: fileURL, text: text)
    }

    static func needsEditedStateReconciliation(
        fileURL: URL?,
        text: String,
        documentIsEdited: Bool,
        windowIsEdited: Bool
    ) -> Bool {
        shouldClearEditedState(fileURL: fileURL, text: text)
            && (documentIsEdited || windowIsEdited)
    }

    @MainActor
    static func clearEditedState(
        of document: NSDocument,
        in window: NSWindow,
        fileURL: URL?,
        text: String
    ) {
        guard document.fileURL == nil,
              needsEditedStateReconciliation(
                fileURL: fileURL,
                text: text,
                documentIsEdited: document.isDocumentEdited,
                windowIsEdited: window.isDocumentEdited
              )
        else { return }

        document.updateChangeCount(.changeCleared)
        window.isDocumentEdited = false
    }
}

enum UntitledDocumentAutosavePolicy {
    static func shouldSchedule(
        fileURL: URL?,
        text: String,
        hasUserEdited: Bool
    ) -> Bool {
        fileURL == nil
            && hasUserEdited
            && !UntitledDocumentContentPolicy.isBlank(text)
    }
}

enum DocumentSaveStateReconciliation {
    static func persistedContentMatches(_ text: String, at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let persistedText = String(data: data, encoding: .utf8)
        else { return false }
        return persistedText == text
    }

    @MainActor
    @discardableResult
    static func clearEditedStateIfSaved(
        document: NSDocument,
        window: NSWindow,
        destinationURL: URL,
        currentText: String
    ) -> Bool {
        guard document.fileURL?.standardizedFileURL == destinationURL.standardizedFileURL,
              persistedContentMatches(currentText, at: destinationURL)
        else { return false }

        document.updateChangeCount(.changeCleared)
        document.windowControllers.forEach { $0.setDocumentEdited(false) }
        window.isDocumentEdited = false
        return true
    }
}

enum ExistingDocumentAutosavePolicy {
    static func shouldSchedule(
        hasPendingTextChange: Bool,
        currentText: String,
        fileURL: URL
    ) -> Bool {
        hasPendingTextChange
            && !DocumentSaveStateReconciliation.persistedContentMatches(
                currentText,
                at: fileURL
            )
    }
}

private final class DocumentWindowObservationView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

struct DocumentAutosaveBridge: NSViewRepresentable {
    let text: String
    let fileURL: URL?
    let hasUserEdited: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = DocumentWindowObservationView(frame: .zero)
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.setWindow(window)
        }
        context.coordinator.update(
            text: text,
            fileURL: fileURL,
            hasUserEdited: hasUserEdited
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            text: text,
            fileURL: fileURL,
            hasUserEdited: hasUserEdited
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var text = ""
        private var fileURL: URL?
        private var hasUserEdited = false
        private var hasReceivedContent = false
        private var hasPendingTextChange = false
        private var editedStateWorkItems: [DispatchWorkItem] = []
        private var savedStateWorkItems: [DispatchWorkItem] = []
        private var saveWorkItem: DispatchWorkItem?
        private var isSaving = false
        private var hasPresentedFailure = false
        private var folderObserver: NSObjectProtocol?

        init() {
            folderObserver = NotificationCenter.default.addObserver(
                forName: .handyNoteDefaultFolderDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleIfNeeded()
                }
            }
        }

        deinit {
            if let folderObserver {
                NotificationCenter.default.removeObserver(folderObserver)
            }
            editedStateWorkItems.forEach { $0.cancel() }
            savedStateWorkItems.forEach { $0.cancel() }
            saveWorkItem?.cancel()
        }

        func setWindow(_ window: NSWindow?) {
            self.window = window
            scheduleEditedStateReconciliation()
            scheduleIfNeeded()
        }

        func update(text: String, fileURL: URL?, hasUserEdited: Bool) {
            if hasReceivedContent, self.text != text {
                hasPendingTextChange = true
            }
            self.text = text
            hasReceivedContent = true
            self.fileURL = fileURL
            self.hasUserEdited = hasUserEdited
            if fileURL != nil {
                hasPresentedFailure = false
            }
            scheduleEditedStateReconciliation()
            scheduleIfNeeded()
        }

        func stop() {
            editedStateWorkItems.forEach { $0.cancel() }
            editedStateWorkItems.removeAll()
            savedStateWorkItems.forEach { $0.cancel() }
            savedStateWorkItems.removeAll()
            saveWorkItem?.cancel()
            saveWorkItem = nil
        }

        private func scheduleEditedStateReconciliation() {
            editedStateWorkItems.forEach { $0.cancel() }
            editedStateWorkItems.removeAll()
            guard UntitledDocumentContentPolicy.shouldScheduleEditedStateReconciliation(
                    fileURL: fileURL,
                    text: text,
                    hasUserEdited: hasUserEdited
                  )
            else { return }

            // `updateNSView` can run inside AppKit's constraint pass, while
            // DocumentGroup can update its backing NSDocument change count in
            // a later transaction. Reconcile after both propagation windows
            // so deleting an Untitled draft back to blank wins the race.
            editedStateWorkItems = [0.05, 0.25].map { delay in
                let workItem = DispatchWorkItem { [weak self] in
                    self?.reconcileUntitledEditedState()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                return workItem
            }
        }

        private func reconcileUntitledEditedState() {
            guard let window,
                  UntitledDocumentContentPolicy.shouldClearEditedState(
                    fileURL: fileURL,
                    text: text
                  ),
                  let document = NSDocumentController.shared.document(for: window),
                  document.fileURL == nil
            else { return }

            UntitledDocumentContentPolicy.clearEditedState(
                of: document,
                in: window,
                fileURL: fileURL,
                text: text
            )
        }

        private func scheduleIfNeeded() {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            guard !isSaving,
                  let window,
                  let document = NSDocumentController.shared.document(for: window)
            else { return }

            if let existingURL = document.fileURL {
                guard ExistingDocumentAutosavePolicy.shouldSchedule(
                    hasPendingTextChange: hasPendingTextChange,
                    currentText: text,
                    fileURL: existingURL
                ) else {
                    if DocumentSaveStateReconciliation.persistedContentMatches(
                        text,
                        at: existingURL
                    ) {
                        hasPendingTextChange = false
                        _ = reconcileSavedState(
                            document: document,
                            window: window,
                            destinationURL: existingURL
                        )
                        scheduleSavedStateReconciliation(
                            document: document,
                            window: window,
                            destinationURL: existingURL
                        )
                    }
                    return
                }

                let workItem = DispatchWorkItem { [weak self] in
                    self?.saveExistingDocumentIfPossible()
                }
                saveWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + DocumentAutosavePolicy.delay,
                    execute: workItem
                )
                return
            }

            guard UntitledDocumentAutosavePolicy.shouldSchedule(
                fileURL: fileURL,
                text: text,
                hasUserEdited: hasUserEdited
            ) else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.saveUntitledDocumentIfPossible()
            }
            saveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
        }

        private func saveUntitledDocumentIfPossible() {
            saveWorkItem = nil
            guard !isSaving,
                  let window,
                  UntitledDocumentAutosavePolicy.shouldSchedule(
                    fileURL: fileURL,
                    text: text,
                    hasUserEdited: hasUserEdited
                  ),
                  let document = NSDocumentController.shared.document(for: window),
                  document.fileURL == nil,
                  let folderURL = QuickCaptureService.shared.configuredFolderForDisplay()
            else { return }

            let destinationURL: URL
            do {
                destinationURL = try QuickCaptureFileWriter().createEmptyDocument(in: folderURL)
            } catch {
                presentFailure(error)
                return
            }

            isSaving = true
            document.save(
                to: destinationURL,
                ofType: MarkdownDocument.markdownType.identifier,
                for: .saveAsOperation
            ) { [weak self] error in
                guard let self else { return }
                self.isSaving = false
                if let error {
                    Self.removeEmptyReservation(at: destinationURL)
                    self.presentFailure(error)
                    return
                }
                self.fileURL = destinationURL
                self.hasPresentedFailure = false
                if self.reconcileSavedState(
                    document: document,
                    window: window,
                    destinationURL: destinationURL
                ) {
                    self.hasPendingTextChange = false
                }
                self.scheduleSavedStateReconciliation(
                    document: document,
                    window: window,
                    destinationURL: destinationURL
                )
                self.scheduleIfNeeded()
                NSDocumentController.shared.noteNewRecentDocumentURL(destinationURL)
            }
        }

        private func saveExistingDocumentIfPossible() {
            saveWorkItem = nil
            guard !isSaving,
                  hasPendingTextChange,
                  let window,
                  let document = NSDocumentController.shared.document(for: window),
                  let destinationURL = document.fileURL,
                  ExistingDocumentAutosavePolicy.shouldSchedule(
                    hasPendingTextChange: hasPendingTextChange,
                    currentText: text,
                    fileURL: destinationURL
                  )
            else { return }

            isSaving = true
            document.save(
                to: destinationURL,
                ofType: document.fileType ?? MarkdownDocument.markdownType.identifier,
                for: .autosaveInPlaceOperation
            ) { [weak self, weak document, weak window] error in
                guard let self, let document, let window else { return }
                self.isSaving = false
                if let error {
                    self.presentFailure(error)
                    return
                }
                self.hasPresentedFailure = false
                if self.reconcileSavedState(
                    document: document,
                    window: window,
                    destinationURL: destinationURL
                ) {
                    self.hasPendingTextChange = false
                }
                self.scheduleSavedStateReconciliation(
                    document: document,
                    window: window,
                    destinationURL: destinationURL
                )
                self.scheduleIfNeeded()
            }
        }

        private func scheduleSavedStateReconciliation(
            document: NSDocument,
            window: NSWindow,
            destinationURL: URL
        ) {
            savedStateWorkItems.forEach { $0.cancel() }
            savedStateWorkItems = [0.05, 0.25].map { delay in
                let workItem = DispatchWorkItem { [weak self, weak document, weak window] in
                    guard let self, let document, let window else { return }
                    if self.reconcileSavedState(
                        document: document,
                        window: window,
                        destinationURL: destinationURL
                    ) {
                        self.hasPendingTextChange = false
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                return workItem
            }
        }

        @discardableResult
        private func reconcileSavedState(
            document: NSDocument,
            window: NSWindow,
            destinationURL: URL
        ) -> Bool {
            DocumentSaveStateReconciliation.clearEditedStateIfSaved(
                document: document,
                window: window,
                destinationURL: destinationURL,
                currentText: text
            )
        }

        private func presentFailure(_ error: Error) {
            guard !hasPresentedFailure else { return }
            hasPresentedFailure = true
            NSApplication.shared.presentError(error)
        }

        private static func removeEmptyReservation(at url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  values.fileSize == 0 else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum FloralMDLaunchPolicy {
    static func shouldOpenUntitledDocument(
        arguments: [String],
        hasOpenDocuments: Bool
    ) -> Bool {
        guard !hasOpenDocuments else { return false }
        return !arguments.dropFirst().contains { argument in
            guard !argument.hasPrefix("-") else { return false }
            return ResourceKind.resolve(url: URL(fileURLWithPath: argument)) != nil
        }
    }
}

@MainActor
final class GlobalQuickCaptureHotKey {
    private static let signature: OSType = 0x484E5143 // "HNQC"

    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    var onPressed: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalQuickCaptureHotKey>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.onPressed?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register() -> OSStatus {
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(controlKey | optionKey),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registered
        )
        if status == noErr {
            hotKey = registered
        }
        return status
    }
}

@MainActor
final class FloralMDAppDelegate: NSObject, NSApplicationDelegate {
    private let quickCaptureHotKey = GlobalQuickCaptureHotKey()
    private var terminationReplyPending = false
    private var appActivityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 退出 App Nap：窗口被遮挡/失焦时系统会节流定时器与 WebKit 渲染，
        // 用户切回窗口的第一下交互会出现迟滞。FloralMD 是用户随时会
        // 回来的工具台，声明保持即时响应。
        appActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "FloralMD 需要保持即时响应"
        )

        // Keep AppKit's normal timer enabled as a fallback. The bridge above
        // also drives both the first save-as and later in-place saves because
        // SwiftUI's FileDocument wrapper does not expose FloralMD's custom
        // NSDocument save/close overrides.
        DocumentAutosavePolicy.apply()

        // Harness 形态生命周期（NoHarness 为空实现：不注册通知、不请求授权）。
        HarnessModuleSelection.current.applicationDidFinishLaunching()

        quickCaptureHotKey.onPressed = { QuickCaptureService.shared.perform() }
        let status = quickCaptureHotKey.register()
        if status != noErr {
            NSLog("Unable to register FloralMD quick-capture shortcut: %d", status)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Harness 形态退出清理（NoHarness 为空实现）。
        HarnessModuleSelection.current.applicationWillTerminate()
        if let appActivityToken {
            ProcessInfo.processInfo.endActivity(appActivityToken)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // 通知 scheme 由 Harness 形态路由（返回 true = 已消费）；其余按文档资源打开。
        if let firstURL = urls.first,
           HarnessModuleSelection.current.applicationOpenURL(firstURL) {
            return
        }
        guard let target = urls.first(where: { ResourceKind.resolve(url: $0) != nil }) else {
            return
        }
        WorkspaceOpenRouter.shared.open(target)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        WorkspaceLifecycleCoordinator.shared.requestAll(.terminateApplication) { [weak self, weak sender] shouldTerminate in
            self?.terminationReplyPending = false
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
