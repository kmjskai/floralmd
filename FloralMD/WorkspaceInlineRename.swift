import AppKit
import SwiftUI

nonisolated struct WorkspaceInlineRenameSession: Equatable, Sendable {
    let identity: WorkspaceFileIdentity
    var sourceURL: URL
    var draft: String
    var selection: NSRange
    var errorMessage: String?
    var focusRequest: Int
}

nonisolated struct WorkspaceInlineRenameModel: Equatable, Sendable {
    private(set) var session: WorkspaceInlineRenameSession?

    var isEditing: Bool { session != nil }
    var acceptsCatalogReload: Bool { session == nil }

    mutating func begin(_ entry: WorkspaceFileEntry) {
        session = WorkspaceInlineRenameSession(
            identity: entry.identity,
            sourceURL: entry.url.standardizedFileURL,
            draft: entry.name,
            selection: WorkspaceInlineRenameSelection.range(
                for: entry.name,
                isDirectory: entry.kind == .directory
            ),
            errorMessage: nil,
            focusRequest: 0
        )
    }

    mutating func updateDraft(
        _ draft: String,
        selection: NSRange,
        identity: WorkspaceFileIdentity
    ) {
        guard session?.identity == identity else { return }
        session?.draft = draft
        session?.selection = selection
        session?.errorMessage = nil
    }

    mutating func updateSelection(_ selection: NSRange, identity: WorkspaceFileIdentity) {
        guard session?.identity == identity else { return }
        session?.selection = selection
    }

    mutating func fail(_ message: String, identity: WorkspaceFileIdentity) {
        guard session?.identity == identity else { return }
        session?.errorMessage = message
        session?.focusRequest += 1
    }

    mutating func finish(identity: WorkspaceFileIdentity) {
        guard session?.identity == identity else { return }
        session = nil
    }
}

nonisolated enum WorkspaceInlineRenameSelection {
    static func range(for name: String, isDirectory: Bool) -> NSRange {
        let utf16Name = name as NSString
        let fullRange = NSRange(location: 0, length: utf16Name.length)
        guard !isDirectory else { return fullRange }

        let dot = utf16Name.range(of: ".", options: .backwards)
        guard dot.location != NSNotFound,
              dot.location > 0,
              NSMaxRange(dot) < utf16Name.length else {
            return fullRange
        }
        return NSRange(location: 0, length: dot.location)
    }
}

nonisolated enum WorkspaceInlineRenameCommitReason: Equatable, Sendable {
    case returnKey
    case focusLoss
}

struct WorkspaceInlineRenameField: NSViewRepresentable {
    let text: String
    let selection: NSRange
    let focusRequest: Int
    let accessibilityLabel: String
    let onChange: (String, NSRange) -> Void
    let onSelectionChange: (NSRange) -> Void
    let onSubmit: (WorkspaceInlineRenameCommitReason) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WorkspaceInlineRenameTextField {
        let textField = WorkspaceInlineRenameTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.cell?.usesSingleLineMode = true
        textField.cell?.lineBreakMode = .byTruncatingMiddle
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.didMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        context.coordinator.textField = textField
        return textField
    }

    func updateNSView(_ textField: WorkspaceInlineRenameTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text,
           (textField.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            textField.stringValue = text
        }
        textField.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.requestFocusIfNeeded()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WorkspaceInlineRenameField
        weak var textField: NSTextField?
        private var appliedFocusRequest: Int?
        private var selectionObserver: NSObjectProtocol?

        init(parent: WorkspaceInlineRenameField) {
            self.parent = parent
        }

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        func requestFocusIfNeeded() {
            guard appliedFocusRequest != parent.focusRequest,
                  let textField,
                  let window = textField.window else { return }
            appliedFocusRequest = parent.focusRequest
            DispatchQueue.main.async { [weak self, weak textField, weak window] in
                guard let self, let textField, let window else { return }
                window.makeFirstResponder(textField)
                guard let editor = textField.currentEditor() as? NSTextView else { return }
                let length = (textField.stringValue as NSString).length
                editor.setSelectedRange(Self.clamped(self.parent.selection, length: length))
                self.observeSelection(in: editor)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let selection = (textField.currentEditor() as? NSTextView)?.selectedRange()
                ?? NSRange(location: (textField.stringValue as NSString).length, length: 0)
            parent.onChange(textField.stringValue, selection)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onSubmit(.focusLoss)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(.returnKey)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        private func observeSelection(in editor: NSTextView) {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self, weak editor] _ in
                guard let self, let editor else { return }
                self.parent.onSelectionChange(editor.selectedRange())
            }
        }

        private static func clamped(_ range: NSRange, length: Int) -> NSRange {
            let location = min(max(range.location, 0), length)
            let availableLength = length - location
            return NSRange(location: location, length: min(max(range.length, 0), availableLength))
        }
    }
}

final class WorkspaceInlineRenameTextField: NSTextField {
    var didMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindow?()
    }
}
