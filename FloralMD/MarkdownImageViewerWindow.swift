import AppKit
import Combine
import SwiftUI

nonisolated enum MarkdownImageViewerInitialLayout {
    static let minimumFrameSize = NSSize(width: 720, height: 520)
    static let maximumVisibleFrameFraction = 0.84
    static let contentPadding = NSSize(width: 64, height: 112)

    static func frame(
        imageSize: NSSize?,
        visibleFrame: NSRect,
        decorationSize: NSSize
    ) -> NSRect {
        let maximumSize = NSSize(
            width: visibleFrame.width * maximumVisibleFrameFraction,
            height: visibleFrame.height * maximumVisibleFrameFraction
        )
        let safeImageSize: NSSize
        if let imageSize,
           imageSize.width.isFinite,
           imageSize.height.isFinite,
           imageSize.width > 0,
           imageSize.height > 0 {
            safeImageSize = imageSize
        } else {
            safeImageSize = .zero
        }
        let desiredSize = NSSize(
            width: safeImageSize.width + contentPadding.width + decorationSize.width,
            height: safeImageSize.height + contentPadding.height + decorationSize.height
        )
        let frameSize = NSSize(
            width: min(maximumSize.width, max(minimumFrameSize.width, desiredSize.width)),
            height: min(maximumSize.height, max(minimumFrameSize.height, desiredSize.height))
        )
        return NSRect(
            x: visibleFrame.midX - frameSize.width / 2,
            y: visibleFrame.midY - frameSize.height / 2,
            width: frameSize.width,
            height: frameSize.height
        )
    }
}

@MainActor
final class FloralMDImageViewerCoordinator {
    static let shared = FloralMDImageViewerCoordinator()

    typealias RevealFile = (URL) -> Void
    typealias ImageSize = @MainActor (URL) -> NSSize?
    typealias VisibleFrame = @MainActor () -> NSRect

    private var windowControllers: [URL: FloralMDImageViewerWindowController] = [:]
    private let revealFile: RevealFile
    private let securityScopeAccessManager: SecurityScopedResourceAccessManager
    private let imageSize: ImageSize
    private let visibleFrame: VisibleFrame

    init(
        revealFile: @escaping RevealFile = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        },
        securityScopeAccessManager: SecurityScopedResourceAccessManager = .shared,
        imageSize: @escaping ImageSize = {
            NSImage(contentsOf: $0)?.size
        },
        visibleFrame: @escaping VisibleFrame = {
            NSApp.keyWindow?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
    ) {
        self.revealFile = revealFile
        self.securityScopeAccessManager = securityScopeAccessManager
        self.imageSize = imageSize
        self.visibleFrame = visibleFrame
    }

    @discardableResult
    func openImage(
        at fileURL: URL,
        authorizedBy workspaceRootURL: URL
    ) -> FloralMDImageViewerWindowController {
        let key = fileURL.standardizedFileURL
        if let existing = windowControllers[key] {
            existing.activate()
            return existing
        }

        let lease = securityScopeAccessManager.acquire(workspaceRootURL)
        let controller = FloralMDImageViewerWindowController(
            fileURL: key,
            securityScopeLease: lease,
            revealFile: revealFile,
            imageSize: imageSize(key),
            visibleFrame: visibleFrame()
        )
        controller.viewerCoordinator = self
        windowControllers[key] = controller
        controller.activate()
        return controller
    }

    var openWindowCount: Int {
        windowControllers.count
    }

    func windowController(for fileURL: URL) -> FloralMDImageViewerWindowController? {
        windowControllers[fileURL.standardizedFileURL]
    }

    fileprivate func viewerDidClose(_ controller: FloralMDImageViewerWindowController) {
        let key = controller.fileURL.standardizedFileURL
        if windowControllers[key] === controller {
            windowControllers.removeValue(forKey: key)
        }
    }
}

@MainActor
final class FloralMDImageViewerWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    let fileURL: URL
    let previewController = WorkspaceImagePreviewController()
    weak var viewerCoordinator: FloralMDImageViewerCoordinator?
    @Published private(set) var pinningMode: WindowPinningMode = .currentSpace

    private let securityScopeLease: SecurityScopedResourceLease
    private let revealFile: FloralMDImageViewerCoordinator.RevealFile
    private(set) var didReleaseResources = false

    init(
        fileURL: URL,
        securityScopeLease: SecurityScopedResourceLease,
        revealFile: @escaping FloralMDImageViewerCoordinator.RevealFile,
        imageSize: NSSize?,
        visibleFrame: NSRect
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.securityScopeLease = securityScopeLease
        self.revealFile = revealFile

        let window = FloralMDImageViewerWindow(
            contentRect: NSRect(origin: .zero, size: MarkdownImageViewerInitialLayout.minimumFrameSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = self.fileURL.lastPathComponent
        window.representedURL = self.fileURL
        window.minSize = NSSize(
            width: min(
                MarkdownImageViewerInitialLayout.minimumFrameSize.width,
                visibleFrame.width * MarkdownImageViewerInitialLayout.maximumVisibleFrameFraction
            ),
            height: min(
                MarkdownImageViewerInitialLayout.minimumFrameSize.height,
                visibleFrame.height * MarkdownImageViewerInitialLayout.maximumVisibleFrameFraction
            )
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let decorationSize = NSSize(
            width: window.frame.width - window.contentLayoutRect.width,
            height: window.frame.height - window.contentLayoutRect.height
        )
        window.contentViewController = NSHostingController(
            rootView: MarkdownImageViewerContent(windowController: self)
        )
        window.setFrame(
            MarkdownImageViewerInitialLayout.frame(
                imageSize: imageSize,
                visibleFrame: visibleFrame,
                decorationSize: decorationSize
            ),
            display: false
        )
        applyPinningMode()
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func revealInFinder() {
        revealFile(fileURL)
    }

    func togglePinning() {
        pinningMode.toggle()
        applyPinningMode()
    }

    private func applyPinningMode() {
        window?.level = pinningMode.windowLevel
    }

    func windowWillClose(_ notification: Notification) {
        releaseResources()
        viewerCoordinator?.viewerDidClose(self)
    }

    func releaseResources() {
        guard !didReleaseResources else { return }
        didReleaseResources = true
        window?.contentViewController = nil
        window?.delegate = nil
        securityScopeLease.invalidate()
    }
}

private struct MarkdownImageViewerContent: View {
    @ObservedObject var windowController: FloralMDImageViewerWindowController

    var body: some View {
        WorkspaceImagePreview(
            url: windowController.fileURL,
            controller: windowController.previewController,
            revealInFinder: { [weak windowController] in
                windowController?.revealInFinder()
            },
            pinningMode: windowController.pinningMode,
            togglePinning: { [weak windowController] in
                windowController?.togglePinning()
            }
        )
    }
}

final class FloralMDImageViewerWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
