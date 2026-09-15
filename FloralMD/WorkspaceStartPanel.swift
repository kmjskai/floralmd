import SwiftUI

struct WorkspaceStartPanel: View {
    let panel: RecentWorkspaceResourcePanel
    let createMarkdown: () -> Void
    let createDrawing: () -> Void
    let openWorkspace: () -> Void
    let openRecent: (RecentWorkspaceResourceItem) -> Void
    let clearRecent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                Text("继续创作")
                    .font(.largeTitle.weight(.semibold))
                Text("回到最近的草稿，或开始一份新内容。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if !panel.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("最近打开")
                            .font(.headline)
                        Spacer()
                        Button("清除最近记录", action: clearRecent)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !panel.currentWorkspace.isEmpty {
                        recentSection("当前工作区", items: panel.currentWorkspace)
                    }
                    if !panel.otherWorkspaces.isEmpty {
                        recentSection("其他工作区", items: panel.otherWorkspaces)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(alignment: .leading, spacing: 10) { actionButtons }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.vertical, 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FloralMD 开始面板")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: createMarkdown) {
            Label("新建 Markdown", systemImage: "note.text.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button(action: createDrawing) {
            Label("创建绘图", systemImage: "scribble.variable")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Button(action: openWorkspace) {
            Label("打开工作区…", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func recentSection(
        _ title: String,
        items: [RecentWorkspaceResourceItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 2) {
                ForEach(items) { item in
                    Button { openRecent(item) } label: {
                        recentRow(item)
                    }
                    .buttonStyle(RecentResourceButtonStyle())
                    .accessibilityLabel(accessibilityLabel(for: item))
                    .accessibilityHint(
                        item.accessState == .needsAuthorization
                            ? "打开时需要重新授权所属工作区"
                            : "打开最近内容"
                    )
                }
            }
        }
    }

    private func recentRow(_ item: RecentWorkspaceResourceItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.resourceKind == .markdown ? "doc.text" : "scribble.variable")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.resourceName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.resourceKind == .markdown ? "Markdown" : "Excalidraw")
                    Text("·")
                    Text(item.workspaceName)
                    if item.showsRelativePath {
                        Text("·")
                        Text(item.relativePath)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.accessState == .needsAuthorization {
                Label("需要重新授权", systemImage: "lock.open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(.rect)
    }

    private func accessibilityLabel(for item: RecentWorkspaceResourceItem) -> String {
        let kind = item.resourceKind == .markdown ? "Markdown" : "Excalidraw 绘图"
        let authorization = item.accessState == .needsAuthorization ? "，需要重新授权" : ""
        return "\(kind)，\(item.resourceName)，工作区 \(item.workspaceName)\(authorization)"
    }
}

private struct RecentResourceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.accentColor.opacity(0.13)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}

enum WorkspaceSurfacePresentation: Equatable {
    case start
    case markdown
    case drawing
    case image

    static func resolve(activeKind: ResourceKind?) -> Self {
        switch activeKind {
        case nil: .start
        case .markdown: .markdown
        case .drawing: .drawing
        case .image: .image
        }
    }

    var showsMarkdownPageBoundary: Bool { self == .markdown }
}
