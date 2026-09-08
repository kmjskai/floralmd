import AppKit
import Foundation
import QuickLookUI
import SwiftUI

enum WorkspaceFileDropPlan {
    static func request(
        sourceURL: URL,
        targetDirectoryURL: URL,
        workspaceRootURL: URL,
        optionKey: Bool
    ) -> WorkspaceFileOperationRequest {
        let source = sourceURL.standardizedFileURL
        let target = targetDirectoryURL.standardizedFileURL
        let root = workspaceRootURL.standardizedFileURL
        guard WorkspaceResolver.contains(source, in: root) else {
            return .importFile(sourceURL: source, destinationDirectoryURL: target)
        }
        if optionKey {
            if source.deletingLastPathComponent() == target {
                return .duplicate(itemURL: source)
            }
            return .copy(itemURL: source, destinationDirectoryURL: target)
        }
        return .move(itemURL: source, destinationDirectoryURL: target)
    }
}

enum WorkspaceFileClipboardOperation: String, Equatable {
    case copy
    case cut
}

struct WorkspaceFileClipboardPayload: Equatable {
    let url: URL
    let operation: WorkspaceFileClipboardOperation
}

enum WorkspaceFileClipboard {
    static let operationType = NSPasteboard.PasteboardType(
        "com.yingkaisun.floralmd.workspace-file-operation"
    )

    @discardableResult
    static func write(
        url: URL,
        operation: WorkspaceFileClipboardOperation,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url.standardizedFileURL as NSURL]) else { return false }
        return pasteboard.setString(operation.rawValue, forType: operationType)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> WorkspaceFileClipboardPayload? {
        guard let url = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first else { return nil }
        let operation = pasteboard.string(forType: operationType)
            .flatMap(WorkspaceFileClipboardOperation.init(rawValue:)) ?? .copy
        return WorkspaceFileClipboardPayload(url: url.standardizedFileURL, operation: operation)
    }
}

@MainActor
final class WorkspaceQuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = WorkspaceQuickLookController()

    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url.standardizedFileURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

enum WorkspaceFileSidebarCommand {
    case cut
    case copy
    case paste
    case rename
    case trash
    case quickLook
}

struct WorkspaceFileSidebarCommandAction {
    let perform: (WorkspaceFileSidebarCommand) -> Void
}

private struct WorkspaceFileSidebarCommandActionKey: FocusedValueKey {
    typealias Value = WorkspaceFileSidebarCommandAction
}

extension FocusedValues {
    var workspaceFileSidebarCommandAction: WorkspaceFileSidebarCommandAction? {
        get { self[WorkspaceFileSidebarCommandActionKey.self] }
        set { self[WorkspaceFileSidebarCommandActionKey.self] = newValue }
    }
}
