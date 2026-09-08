import AppKit

/// Hosts one existing SwiftUI workspace hierarchy in the AppKit role that can
/// accompany another app's native full-screen window. The content is moved,
/// not copied, so editor selection, IME state, undo, and controllers keep one
/// owner.
@MainActor
final class AllSpacesWindowPresentationController: NSObject, NSWindowDelegate {
    private weak var hostWindow: NSWindow?
    private weak var originalFirstResponder: NSResponder?
    private var hostedContentView: NSView?
    private var placeholder = NSView(frame: .zero)
    private var originalToolbar: NSToolbar?
    private var originalAccessories: [NSTitlebarAccessoryViewController] = []
    private var originalAlpha: CGFloat = 1
    private var originalIgnoresMouseEvents = false
    private var isSynchronizingFrame = false
    private var activationTask: Task<Void, Never>?
    private var isTransitioning = false

    private(set) var panel: AllSpacesWorkspacePanel?
    private(set) var isPresented = false

    func present(hostWindow candidate: NSWindow, opacity: CGFloat) {
        guard !isTransitioning else { return }
        if let panel, candidate === panel {
            applyOpacity(opacity, to: panel)
            return
        }

        if isPresented {
            if let panel { applyOpacity(opacity, to: panel) }
            return
        }

        guard !candidate.styleMask.contains(.fullScreen),
              let contentView = candidate.contentView else { return }

        hostWindow = candidate
        hostedContentView = contentView
        originalFirstResponder = candidate.firstResponder
        originalToolbar = candidate.toolbar
        originalAccessories = candidate.titlebarAccessoryViewControllers
        originalAlpha = candidate.alphaValue
        originalIgnoresMouseEvents = candidate.ignoresMouseEvents

        placeholder = NSView(frame: contentView.frame)
        placeholder.autoresizingMask = [.width, .height]

        let panel = makePanel(from: candidate)
        self.panel = panel
        isPresented = true
        isTransitioning = true

        transferAccessories(from: candidate, to: panel)
        candidate.toolbar = nil
        panel.toolbar = originalToolbar
        candidate.contentView = placeholder
        panel.contentView = contentView
        applyOpacity(opacity, to: panel)

        candidate.alphaValue = 0
        candidate.ignoresMouseEvents = true
        isTransitioning = false
        scheduleActivation()
    }

    func dismiss(restoringHostWindow: Bool) {
        guard isPresented,
              let hostWindow,
              let panel,
              let hostedContentView else { return }
        isPresented = false
        isTransitioning = true
        activationTask?.cancel()
        activationTask = nil

        let finalFrame = panel.frame
        panel.orderOut(nil)
        panel.contentView = NSView(frame: .zero)
        panel.toolbar = nil
        transferAccessories(from: panel, to: hostWindow)
        hostWindow.toolbar = originalToolbar
        hostWindow.contentView = hostedContentView
        hostWindow.setFrame(finalFrame, display: false)
        hostWindow.alphaValue = originalAlpha
        hostWindow.ignoresMouseEvents = originalIgnoresMouseEvents

        if restoringHostWindow {
            hostWindow.makeKeyAndOrderFront(nil)
            if let originalFirstResponder {
                hostWindow.makeFirstResponder(originalFirstResponder)
            }
        }

        panel.delegate = nil
        panel.onRequestFullScreen = nil
        self.panel = nil
        self.hostedContentView = nil
        originalToolbar = nil
        originalAccessories = []
        isTransitioning = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let hostWindow else { return true }
        dismiss(restoringHostWindow: true)
        Task { @MainActor in
            hostWindow.performClose(nil)
        }
        return false
    }

    func windowDidMove(_ notification: Notification) {
        synchronizeHostFrame()
    }

    func windowDidResize(_ notification: Notification) {
        synchronizeHostFrame()
    }

    private func makePanel(from hostWindow: NSWindow) -> AllSpacesWorkspacePanel {
        let panel = AllSpacesWorkspacePanel(
            contentRect: hostWindow.contentRect(forFrameRect: hostWindow.frame),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(hostWindow.frame, display: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.title = hostWindow.title
        panel.representedURL = hostWindow.representedURL
        panel.titleVisibility = hostWindow.titleVisibility
        panel.titlebarAppearsTransparent = hostWindow.titlebarAppearsTransparent
        panel.titlebarSeparatorStyle = hostWindow.titlebarSeparatorStyle
        panel.toolbarStyle = hostWindow.toolbarStyle
        panel.isMovableByWindowBackground = hostWindow.isMovableByWindowBackground
        panel.minSize = hostWindow.minSize
        panel.maxSize = hostWindow.maxSize
        panel.backgroundColor = hostWindow.backgroundColor
        panel.delegate = self
        panel.onRequestFullScreen = { [weak self] sender in
            guard let self, let hostWindow = self.hostWindow else { return }
            self.dismiss(restoringHostWindow: true)
            hostWindow.toggleFullScreen(sender)
        }
        return panel
    }

    private func scheduleActivation() {
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.isPresented,
                  let panel = self.panel else { return }
            panel.makeKeyAndOrderFront(nil)
            if let originalFirstResponder = self.originalFirstResponder {
                panel.makeFirstResponder(originalFirstResponder)
            }
        }
    }

    private func synchronizeHostFrame() {
        guard isPresented, !isSynchronizingFrame,
              let hostWindow, let panel else { return }
        isSynchronizingFrame = true
        hostWindow.setFrame(panel.frame, display: false)
        isSynchronizingFrame = false
    }

    private func transferAccessories(from source: NSWindow, to destination: NSWindow) {
        for accessory in originalAccessories {
            if let index = source.titlebarAccessoryViewControllers.firstIndex(
                where: { $0 === accessory }
            ) {
                source.removeTitlebarAccessoryViewController(at: index)
            }
            destination.addTitlebarAccessoryViewController(accessory)
        }
    }

    private func applyOpacity(_ opacity: CGFloat, to window: NSWindow) {
        window.alphaValue = opacity
        window.isOpaque = true
        window.backgroundColor = .textBackgroundColor
        window.invalidateShadow()
    }
}

final class AllSpacesWorkspacePanel: NSPanel {
    var onRequestFullScreen: ((Any?) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func toggleFullScreen(_ sender: Any?) {
        onRequestFullScreen?(sender)
    }
}
