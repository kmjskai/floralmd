import SwiftUI

enum FloralMDEmptyStateKind {
    case document
    case outline
    case search
}

enum FloralMDEmptyStatePolicy {
    static func showsDocumentPrompt(markdown: String, mode: MarkdownMode) -> Bool {
        mode == .edit && markdown.isEmpty
    }
}

struct FloralMDEmptyState: View {
    let kind: FloralMDEmptyStateKind
    let title: String
    let message: String
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            FloralMDHandDrawnMark(kind: kind)
                .frame(width: compact ? 68 : 88, height: compact ? 54 : 70)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.86))

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: compact ? 220 : 300)
        .opacity(isPresented ? 1 : 0)
        .offset(y: reduceMotion || isPresented ? 0 : 4)
        .onAppear {
            if reduceMotion {
                isPresented = true
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    isPresented = true
                }
            }
        }
        .onChange(of: reduceMotion) {
            if reduceMotion {
                isPresented = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(message)
    }
}

private struct FloralMDHandDrawnMark: View {
    let kind: FloralMDEmptyStateKind

    var body: some View {
        ZStack {
            FloralMDHandDrawnShape(kind: kind, drawsAccent: false)
                .stroke(
                    Color.secondary.opacity(0.72),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )

            FloralMDHandDrawnShape(kind: kind, drawsAccent: true)
                .stroke(
                    Color.accentColor.opacity(0.76),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
        }
        .rotationEffect(.degrees(-0.8))
    }
}

private struct FloralMDHandDrawnShape: Shape {
    let kind: FloralMDEmptyStateKind
    let drawsAccent: Bool

    func path(in rect: CGRect) -> Path {
        switch (kind, drawsAccent) {
        case (.document, false):
            documentPath(in: rect)
        case (.document, true):
            arrowPath(in: rect, start: CGPoint(x: 0.88, y: 0.08), end: CGPoint(x: 0.67, y: 0.42))
        case (.outline, false):
            outlinePath(in: rect)
        case (.outline, true):
            arrowPath(in: rect, start: CGPoint(x: 0.9, y: 0.12), end: CGPoint(x: 0.63, y: 0.44))
        case (.search, false):
            searchPath(in: rect)
        case (.search, true):
            arrowPath(in: rect, start: CGPoint(x: 0.88, y: 0.16), end: CGPoint(x: 0.67, y: 0.48))
        }
    }

    private func documentPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.18, 0.1, in: rect))
        path.addCurve(
            to: point(0.63, 0.11, in: rect),
            control1: point(0.32, 0.07, in: rect),
            control2: point(0.52, 0.13, in: rect)
        )
        path.addCurve(
            to: point(0.64, 0.88, in: rect),
            control1: point(0.67, 0.32, in: rect),
            control2: point(0.61, 0.67, in: rect)
        )
        path.addCurve(
            to: point(0.17, 0.86, in: rect),
            control1: point(0.49, 0.91, in: rect),
            control2: point(0.31, 0.84, in: rect)
        )
        path.closeSubpath()
        addLooseLine(to: &path, from: (0.27, 0.34), to: (0.53, 0.32), in: rect)
        addLooseLine(to: &path, from: (0.26, 0.51), to: (0.55, 0.53), in: rect)
        addLooseLine(to: &path, from: (0.27, 0.69), to: (0.46, 0.67), in: rect)
        return path
    }

    private func outlinePath(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            let y = 0.25 + CGFloat(row) * 0.24
            path.addEllipse(in: CGRect(
                x: rect.minX + rect.width * 0.16,
                y: rect.minY + rect.height * (y - 0.035),
                width: rect.width * 0.07,
                height: rect.height * 0.07
            ))
            addLooseLine(
                to: &path,
                from: (0.31 + CGFloat(row) * 0.03, y),
                to: (0.65 - CGFloat(row) * 0.05, y + (row == 1 ? 0.02 : -0.01)),
                in: rect
            )
        }
        return path
    }

    private func searchPath(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.16,
            y: rect.minY + rect.height * 0.13,
            width: rect.width * 0.43,
            height: rect.height * 0.54
        ))
        path.move(to: point(0.52, 0.62, in: rect))
        path.addCurve(
            to: point(0.7, 0.87, in: rect),
            control1: point(0.59, 0.69, in: rect),
            control2: point(0.64, 0.8, in: rect)
        )
        return path
    }

    private func arrowPath(
        in rect: CGRect,
        start: CGPoint,
        end: CGPoint
    ) -> Path {
        var path = Path()
        let startPoint = point(start.x, start.y, in: rect)
        let endPoint = point(end.x, end.y, in: rect)
        path.move(to: startPoint)
        path.addCurve(
            to: endPoint,
            control1: point(start.x - 0.02, start.y + 0.18, in: rect),
            control2: point(end.x + 0.13, end.y - 0.08, in: rect)
        )
        path.move(to: point(end.x + 0.02, end.y - 0.13, in: rect))
        path.addLine(to: endPoint)
        path.addLine(to: point(end.x + 0.13, end.y + 0.01, in: rect))
        return path
    }

    private func addLooseLine(
        to path: inout Path,
        from start: (CGFloat, CGFloat),
        to end: (CGFloat, CGFloat),
        in rect: CGRect
    ) {
        path.move(to: point(start.0, start.1, in: rect))
        path.addCurve(
            to: point(end.0, end.1, in: rect),
            control1: point(start.0 + (end.0 - start.0) * 0.32, start.1 - 0.025, in: rect),
            control2: point(start.0 + (end.0 - start.0) * 0.68, end.1 + 0.025, in: rect)
        )
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

#Preview("FloralMD 空状态") {
    HStack(spacing: 44) {
        FloralMDEmptyState(
            kind: .document,
            title: "从这里开始记录",
            message: "直接输入 Markdown"
        )
        FloralMDEmptyState(
            kind: .outline,
            title: "添加一个标题",
            message: "输入 # 标题，建立文档大纲",
            compact: true
        )
        FloralMDEmptyState(
            kind: .search,
            title: "没有找到命令",
            message: "换个关键词试试"
        )
    }
    .padding(36)
}
