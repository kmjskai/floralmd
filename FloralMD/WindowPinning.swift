//
//  WindowPinning.swift
//  FloralMD
//
//  Created by Yingkai Sun on 2026/8/9.
//

import AppKit
import SwiftUI

enum WindowPinningMode: String, CaseIterable, Identifiable, Equatable {
    case none
    case currentSpace
    case allSpaces

    var id: Self { self }

    static let pinnedBackgroundOpacity = PinnedWindowOpacityPreference.alpha(
        for: PinnedWindowOpacityPreference.defaultPercentage
    )

    var windowLevel: NSWindow.Level {
        switch self {
        case .none:
            .normal
        case .currentSpace, .allSpaces:
            .floating
        }
    }

    var symbolName: String {
        switch self {
        case .none:
            "pin.slash"
        case .currentSpace:
            "pin.fill"
        case .allSpaces:
            "globe"
        }
    }

    var title: String {
        switch self {
        case .none:
            String(localized: "不置顶")
        case .currentSpace:
            String(localized: "当前 Space 置顶")
        case .allSpaces:
            String(localized: "所有 Space 置顶")
        }
    }

    var backgroundOpacity: CGFloat {
        backgroundOpacity(pinnedWindowOpacity: Self.pinnedBackgroundOpacity)
    }

    func backgroundOpacity(pinnedWindowOpacity: CGFloat) -> CGFloat {
        switch self {
        case .none:
            1
        case .currentSpace, .allSpaces:
            pinnedWindowOpacity
        }
    }

    var sidebarBackgroundOpacity: CGFloat {
        1
    }

    var actionTitle: String {
        switch self {
        case .none:
            "在当前 Space 置顶"
        case .currentSpace:
            "取消窗口置顶"
        case .allSpaces:
            "取消跨 Space 置顶"
        }
    }

    var allSpacesActionTitle: String {
        self == .allSpaces ? "取消跨 Space 置顶" : "跨所有 Space 置顶"
    }

    mutating func toggle() {
        self = self == .none ? .currentSpace : .none
    }

    mutating func toggleAllSpaces() {
        self = self == .allSpaces ? .none : .allSpaces
    }
}

struct WindowPinningBridge: NSViewRepresentable {
    let mode: WindowPinningMode
    let pinnedWindowOpacity: CGFloat

    func makeNSView(context: Context) -> WindowPinningHostingView {
        let view = WindowPinningHostingView()
        view.mode = mode
        view.pinnedWindowOpacity = pinnedWindowOpacity
        return view
    }

    func updateNSView(_ nsView: WindowPinningHostingView, context: Context) {
        nsView.mode = mode
        nsView.pinnedWindowOpacity = pinnedWindowOpacity
    }

    static func dismantleNSView(_ nsView: WindowPinningHostingView, coordinator: ()) {
        nsView.restoreNormalWindowPresentation()
    }
}

final class WindowPinningHostingView: NSView {
    private let allSpacesPresentation = AllSpacesWindowPresentationController()
    private var isRestoringNormalPresentation = false

    var mode: WindowPinningMode = .none {
        didSet {
            applyWindowLevel()
        }
    }

    var pinnedWindowOpacity: CGFloat = WindowPinningMode.pinnedBackgroundOpacity {
        didSet {
            applyWindowLevel()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowLevel()
    }

    func restoreNormalWindowPresentation() {
        isRestoringNormalPresentation = true
        allSpacesPresentation.dismiss(restoringHostWindow: false)
        if let window {
            window.level = .normal
            applyBackground(opacity: 1, to: window)
        }
        isRestoringNormalPresentation = false
    }

    private func applyWindowLevel() {
        guard !isRestoringNormalPresentation else { return }
        guard let window else { return }

        if mode == .allSpaces {
            allSpacesPresentation.present(
                hostWindow: window,
                opacity: mode.backgroundOpacity(pinnedWindowOpacity: pinnedWindowOpacity)
            )
            return
        }

        if allSpacesPresentation.isPresented {
            allSpacesPresentation.dismiss(restoringHostWindow: true)
        }

        guard let presentationWindow = self.window else { return }
        presentationWindow.level = mode.windowLevel
        applyBackground(
            opacity: mode.backgroundOpacity(pinnedWindowOpacity: pinnedWindowOpacity),
            to: presentationWindow
        )
    }

    private func applyBackground(opacity: CGFloat, to window: NSWindow) {
        // AppKit's public whole-window transparency API composites every part
        // of the window uniformly, including text, controls and WebKit.
        window.alphaValue = opacity
        window.isOpaque = true
        window.backgroundColor = .textBackgroundColor
        applyContentBackground(drawsBackground: true, to: window)
        window.invalidateShadow()
    }

    /// Keep the normal opaque document canvas; `NSWindow.alphaValue` performs
    /// the public whole-window compositing after all content is rendered.
    private func applyContentBackground(drawsBackground: Bool, to window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = drawsBackground
            ? NSColor.textBackgroundColor.cgColor
            : NSColor.clear.cgColor
        contentView.needsDisplay = true
    }
}
