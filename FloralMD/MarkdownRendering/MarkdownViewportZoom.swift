import AppKit

nonisolated enum MarkdownViewportZoom {
    static let minimumScale = 0.75
    static let defaultScale = 1.0
    static let maximumScale = 2.0
    static let commandStep = 0.1

    static func clamped(_ scale: Double) -> Double {
        guard scale.isFinite else { return defaultScale }
        return min(max(scale, minimumScale), maximumScale)
    }

    static func percentage(_ scale: Double) -> Int {
        Int((clamped(scale) * 100).rounded())
    }
}

nonisolated enum MarkdownViewportZoomAdjustment: Equatable, Sendable {
    case increase
    case decrease
    case reset

    func apply(to currentScale: Double) -> Double {
        let current = MarkdownViewportZoom.clamped(currentScale)
        let proposed = switch self {
        case .increase:
            current + MarkdownViewportZoom.commandStep
        case .decrease:
            current - MarkdownViewportZoom.commandStep
        case .reset:
            MarkdownViewportZoom.defaultScale
        }
        return MarkdownViewportZoom.clamped((proposed * 100).rounded() / 100)
    }

    func isAvailable(at currentScale: Double) -> Bool {
        apply(to: currentScale) != MarkdownViewportZoom.clamped(currentScale)
    }
}

nonisolated enum MarkdownViewportZoomInteractionPhase: Equatable, Sendable {
    case changed
    case ended
}

nonisolated enum MarkdownWebViewCoordinateSpace {
    static func cssViewportPoint(
        fromViewPoint point: CGPoint,
        bounds: CGRect,
        isFlipped: Bool,
        pageZoom: Double
    ) -> CGPoint {
        let zoom = max(MarkdownViewportZoom.clamped(pageZoom), .leastNonzeroMagnitude)
        let y = isFlipped ? point.y : bounds.height - point.y
        return CGPoint(x: point.x / zoom, y: y / zoom)
    }

    static func viewPoint(
        fromCSSViewportPoint point: CGPoint,
        bounds: CGRect,
        isFlipped: Bool,
        pageZoom: Double
    ) -> CGPoint {
        let zoom = max(MarkdownViewportZoom.clamped(pageZoom), .leastNonzeroMagnitude)
        let y = isFlipped ? point.y * zoom : bounds.height - point.y * zoom
        return CGPoint(x: point.x * zoom, y: y)
    }
}
