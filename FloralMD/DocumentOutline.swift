import AppKit
import Foundation
import SwiftUI

struct MarkdownHeading: Identifiable, Equatable {
    let id: Int
    let level: Int
    let title: String
    let sourceOffset: Int
    let sourceLine: Int
}

struct MarkdownOutline {
    static func headings(in markdown: String) -> [MarkdownHeading] {
        let lines = sourceLines(in: markdown)
        var result: [MarkdownHeading] = []
        var fence: (character: Character, length: Int)?
        let frontmatterEndLine = frontmatterEndLine(in: lines)

        for index in lines.indices {
            if let frontmatterEndLine, index <= frontmatterEndLine { continue }
            let line = lines[index]
            let trimmed = line.text.drop(while: { $0 == " " || $0 == "\t" })
            let leadingSpaces = line.text.prefix(while: { $0 == " " }).count

            if leadingSpaces <= 3, let marker = fenceMarker(in: trimmed) {
                if let activeFence = fence {
                    if marker.character == activeFence.character,
                       marker.length >= activeFence.length {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                continue
            }
            guard fence == nil else { continue }

            if let atx = atxHeading(in: line.text) {
                result.append(MarkdownHeading(
                    id: result.count,
                    level: atx.level,
                    title: atx.title,
                    sourceOffset: line.utf16Offset,
                    sourceLine: index + 1
                ))
                continue
            }

        }
        return result
    }

    private struct SourceLine {
        let text: String
        let utf16Offset: Int
    }

    private static func sourceLines(in markdown: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = markdown.startIndex
        var utf16Offset = 0

        while start < markdown.endIndex {
            let newline = markdown[start...].firstIndex(of: "\n")
            let end = newline ?? markdown.endIndex
            var text = String(markdown[start..<end])
            if text.last == "\r" { text.removeLast() }
            lines.append(SourceLine(text: text, utf16Offset: utf16Offset))
            guard let newline else { return lines }
            let segment = markdown[start...newline]
            utf16Offset += segment.utf16.count
            start = markdown.index(after: newline)
        }

        if markdown.isEmpty || markdown.last == "\n" {
            lines.append(SourceLine(text: "", utf16Offset: markdown.utf16.count))
        }
        return lines
    }

    private static func frontmatterEndLine(in lines: [SourceLine]) -> Int? {
        guard let first = lines.first else { return nil }
        let opening = first.text
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\u{FEFF}")
            ))
        // Only YAML `---` frontmatter is recognized; `+++` blocks are body.
        guard opening == "---" else { return nil }

        for index in lines.indices.dropFirst() {
            let candidate = lines[index].text.trimmingCharacters(in: .whitespaces)
            if candidate == "---" || candidate == "..." {
                return index
            }
        }
        return nil
    }

    private static func fenceMarker(in line: Substring) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix(while: { $0 == first }).count
        return length >= 3 ? (first, length) : nil
    }

    private static func atxHeading(in line: String) -> (level: Int, title: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, trimmed.first == "#" else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let afterMarker = trimmed.dropFirst(level)
        guard afterMarker.isEmpty || afterMarker.first?.isWhitespace == true else { return nil }

        var title = afterMarker.trimmingCharacters(in: .whitespaces)
        if let closingHashes = title.range(
            of: #"\s+#+\s*$"#,
            options: .regularExpression
        ) {
            title.removeSubrange(closingHashes)
        }
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

}

struct OutlineNavigation: Equatable {
    let requestID = UUID()
    let heading: MarkdownHeading
}

enum DocumentOutlineLayout {
    static let expandedWidth: CGFloat = 250
    static let collapsedWidth: CGFloat = 0
    static let controlInset: CGFloat = 14

    static func panelWidth(isVisible: Bool) -> CGFloat {
        isVisible ? expandedWidth : collapsedWidth
    }
}

struct DocumentOutlineControlButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.left" : "list.bullet.indent")
                .foregroundStyle(isExpanded ? Color.accentColor : .primary)
                .frame(width: 28, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(4)
        .glassEffect(.regular.interactive(), in: .circle)
        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
        .accessibilityLabel(isExpanded ? "收起文档大纲" : "展开文档大纲")
        .help(isExpanded ? "收起文档大纲" : "展开文档大纲")
    }
}

struct DocumentOutlineSidebar: View {
    let headings: [MarkdownHeading]
    let backgroundOpacity: CGFloat
    let navigate: (MarkdownHeading) -> Void
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DocumentOutlineControlButton(isExpanded: true, action: collapse)
                Text("文档大纲")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, DocumentOutlineLayout.controlInset)
            .padding(.top, DocumentOutlineLayout.controlInset)
            .padding(.bottom, 10)

            Divider()

            if headings.isEmpty {
                FloralMDEmptyState(
                    kind: .outline,
                    title: "添加一个标题",
                    message: "输入 # 标题，建立文档大纲",
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(headings) { heading in
                            Button {
                                navigate(heading)
                            } label: {
                                Text(heading.title)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat(heading.level - 1) * 14)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(heading.level) 级标题，\(heading.title)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(backgroundOpacity))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文档大纲")
    }
}
