import AppKit
import Combine
import SwiftUI

/// Coalesces an arbitrary event stream into at most one application per frame.
/// Once a frame is requested, newer values replace the pending value without
/// postponing that frame.
final class LatestFrameValueScheduler<Value> {
    typealias FrameRequest = (@escaping () -> Void) -> Void

    private let requestFrame: FrameRequest
    private let apply: (Value) -> Void
    private var latestValue: Value?
    private var isFramePending = false
    private var generation = 0

    init(
        requestFrame: @escaping FrameRequest = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: action)
        },
        apply: @escaping (Value) -> Void
    ) {
        self.requestFrame = requestFrame
        self.apply = apply
    }

    // Swift 6.3 crashes while optimizing the synthesized generic deinit when
    // targeting older macOS runtimes. Keep this workaround local to teardown.
    // https://github.com/swiftlang/swift/issues/90385
    @_optimize(none)
    deinit {}

    func submit(_ value: Value) {
        latestValue = value
        guard !isFramePending else { return }
        isFramePending = true
        let scheduledGeneration = generation
        requestFrame { [weak self] in
            self?.consumeFrame(generation: scheduledGeneration)
        }
    }

    func flush() {
        generation += 1
        isFramePending = false
        guard let value = latestValue else { return }
        latestValue = nil
        apply(value)
    }

    func cancel() {
        generation += 1
        latestValue = nil
        isFramePending = false
    }

    private func consumeFrame(generation scheduledGeneration: Int) {
        guard generation == scheduledGeneration else { return }
        isFramePending = false
        guard let value = latestValue else { return }
        latestValue = nil
        apply(value)
    }
}

struct MarkdownContentWidthDampingModel: Equatable {
    static let responseHalfLife = 0.010
    static let snapTolerance = 1.5

    private(set) var displayedWidth: Double
    private(set) var targetWidth: Double

    var isSettled: Bool {
        displayedWidth == targetWidth
    }

    init(width: Double = 756) {
        let width = MarkdownContentWidthLayout.preferredWidth(width)
        displayedWidth = width
        targetWidth = width
    }

    mutating func setTarget(_ width: Double) {
        targetWidth = MarkdownContentWidthLayout.preferredWidth(width)
    }

    @discardableResult
    mutating func step(deltaTime: TimeInterval) -> Double {
        guard !isSettled else { return displayedWidth }
        let safeDeltaTime = deltaTime.isFinite ? max(0, deltaTime) : 0
        guard safeDeltaTime > 0 else { return displayedWidth }

        let decay = pow(0.5, safeDeltaTime / Self.responseHalfLife)
        let next = targetWidth + (displayedWidth - targetWidth) * decay
        if abs(next - targetWidth) <= Self.snapTolerance {
            displayedWidth = targetWidth
        } else {
            displayedWidth = next
        }
        return displayedWidth
    }
}

@MainActor
final class MarkdownContentWidthDampingController: ObservableObject {
    typealias FrameRequest = (@escaping (TimeInterval) -> Void) -> Void

    @Published private(set) var displayedWidth: Double
    private(set) var targetWidth: Double
    @Published private(set) var isSynchronized = false

    private var model: MarkdownContentWidthDampingModel
    private let requestFrame: FrameRequest
    private var isFramePending = false
    private var lastFrameTimestamp: TimeInterval?
    private var generation = 0

    init(
        initialWidth: Double = 756,
        requestFrame: @escaping FrameRequest = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
                action(ProcessInfo.processInfo.systemUptime)
            }
        }
    ) {
        let model = MarkdownContentWidthDampingModel(width: initialWidth)
        self.model = model
        displayedWidth = model.displayedWidth
        targetWidth = model.targetWidth
        self.requestFrame = requestFrame
    }

    func synchronize(to width: Double) {
        generation += 1
        isFramePending = false
        lastFrameTimestamp = nil
        model = MarkdownContentWidthDampingModel(width: width)
        displayedWidth = model.displayedWidth
        targetWidth = model.targetWidth
        isSynchronized = true
    }

    func setTarget(_ width: Double) {
        model.setTarget(width)
        targetWidth = model.targetWidth
        scheduleFrameIfNeeded()
    }

    func cancel() {
        generation += 1
        isFramePending = false
        lastFrameTimestamp = nil
    }

    private func scheduleFrameIfNeeded() {
        guard !model.isSettled, !isFramePending else { return }
        isFramePending = true
        let scheduledGeneration = generation
        requestFrame { [weak self] timestamp in
            guard let self, self.generation == scheduledGeneration else { return }
            self.isFramePending = false
            let deltaTime = self.lastFrameTimestamp.map { timestamp - $0 } ?? 1.0 / 60.0
            self.lastFrameTimestamp = timestamp
            self.displayedWidth = self.model.step(deltaTime: deltaTime)
            self.targetWidth = self.model.targetWidth
            if self.model.isSettled {
                self.lastFrameTimestamp = nil
            } else {
                self.scheduleFrameIfNeeded()
            }
        }
    }
}

enum MarkdownContentWidthLayout {
    static let minimumPreferredWidth = 480.0
    static let defaultPreferredWidth = 756.0
    static let maximumPreferredWidth = 1_200.0
    static let pagePadding = Double(MarkdownHTML.pagePaddingHorizontal)
    static let editorGutterWidth = 68.0
    static let boundaryHitWidth = 22.0
    static let boundaryVisualOutset = 14.0

    static func preferredWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultPreferredWidth }
        return min(max(width, minimumPreferredWidth), maximumPreferredWidth)
    }

    static func actualWidth(
        preferredWidth: Double,
        surfaceWidth: Double,
        pageZoom: Double = 1
    ) -> Double {
        let availableSurfaceWidth = surfaceWidth.isFinite ? max(0, surfaceWidth) : 0
        let safeZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        let availableContentWidth = max(0, availableSurfaceWidth / safeZoom - 2 * pagePadding)
        return min(self.preferredWidth(preferredWidth), availableContentWidth)
    }

    static func visualWidth(actualWidth: Double, pageZoom: Double) -> Double {
        let safeWidth = actualWidth.isFinite ? max(0, actualWidth) : 0
        let safeZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        return safeWidth * safeZoom
    }

    static func preferredWidth(
        startingActualWidth: Double,
        translationPoints: Double,
        pageZoom: Double = 1
    ) -> Double {
        let safeStart = startingActualWidth.isFinite
            ? startingActualWidth
            : defaultPreferredWidth
        let safeTranslation = translationPoints.isFinite ? translationPoints : 0
        let safeZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        return preferredWidth(safeStart + 2 * safeTranslation / safeZoom)
    }

    static func preferredWidth(
        startingActualWidth: Double,
        translationPoints: Double,
        edge: MarkdownContentWidthResizeEdge,
        pageZoom: Double = 1
    ) -> Double {
        preferredWidth(
            startingActualWidth: startingActualWidth,
            translationPoints: edge.widthTranslation(from: translationPoints),
            pageZoom: pageZoom
        )
    }

    static func contentBoundaryPosition(
        surfaceWidth: Double,
        actualWidth: Double,
        edge: MarkdownContentWidthResizeEdge,
        pageZoom: Double = 1,
        leadingAccessoryWidth: Double = 0
    ) -> Double {
        let safeSurfaceWidth = surfaceWidth.isFinite ? max(0, surfaceWidth) : 0
        let safeZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        let safeLeadingAccessoryWidth = leadingAccessoryWidth.isFinite
            ? max(0, leadingAccessoryWidth)
            : 0
        let visualContentWidth = visualWidth(actualWidth: actualWidth, pageZoom: pageZoom)
        let contentBoundary = safeSurfaceWidth / 2
            + edge.boundaryDirection * visualContentWidth / 2
        guard edge == .left else { return contentBoundary }
        return max(0, contentBoundary - safeLeadingAccessoryWidth * safeZoom)
    }

    static func boundaryPosition(
        surfaceWidth: Double,
        actualWidth: Double,
        edge: MarkdownContentWidthResizeEdge,
        pageZoom: Double = 1,
        leadingAccessoryWidth: Double = 0
    ) -> Double {
        let safeSurfaceWidth = surfaceWidth.isFinite ? max(0, surfaceWidth) : 0
        let outwardBoundary = contentBoundaryPosition(
            surfaceWidth: surfaceWidth,
            actualWidth: actualWidth,
            edge: edge,
            pageZoom: pageZoom,
            leadingAccessoryWidth: leadingAccessoryWidth
        ) + edge.boundaryDirection * boundaryVisualOutset
        return min(max(0, outwardBoundary), safeSurfaceWidth)
    }

    static func boundaryHitRegionOffset(
        surfaceWidth: Double,
        actualWidth: Double,
        edge: MarkdownContentWidthResizeEdge,
        pageZoom: Double = 1,
        leadingAccessoryWidth: Double = 0,
        minimumLeadingOffset: Double = 0
    ) -> Double {
        let boundary = boundaryPosition(
            surfaceWidth: surfaceWidth,
            actualWidth: actualWidth,
            edge: edge,
            pageZoom: pageZoom,
            leadingAccessoryWidth: leadingAccessoryWidth
        )
        let naturalOffset = max(0, boundary - boundaryHitWidth / 2)
        guard edge == .left else { return naturalOffset }
        let safeMinimumOffset = minimumLeadingOffset.isFinite
            ? max(0, minimumLeadingOffset)
            : 0
        return max(safeMinimumOffset, naturalOffset)
    }

    static func boundaryLineOffsetInHitRegion(
        surfaceWidth: Double,
        actualWidth: Double,
        edge: MarkdownContentWidthResizeEdge,
        pageZoom: Double = 1,
        leadingAccessoryWidth: Double = 0,
        minimumLeadingOffset: Double = 0
    ) -> Double {
        let boundary = boundaryPosition(
            surfaceWidth: surfaceWidth,
            actualWidth: actualWidth,
            edge: edge,
            pageZoom: pageZoom,
            leadingAccessoryWidth: leadingAccessoryWidth
        )
        let hitRegionOffset = boundaryHitRegionOffset(
            surfaceWidth: surfaceWidth,
            actualWidth: actualWidth,
            edge: edge,
            pageZoom: pageZoom,
            leadingAccessoryWidth: leadingAccessoryWidth,
            minimumLeadingOffset: minimumLeadingOffset
        )
        let safeMinimumOffset = minimumLeadingOffset.isFinite
            ? max(0, minimumLeadingOffset)
            : 0
        let visibleBoundary = edge == .left
            ? max(boundary, safeMinimumOffset)
            : boundary
        return visibleBoundary - hitRegionOffset - boundaryHitWidth / 2
    }
}

enum MarkdownContentWidthResizeEdge: CaseIterable, Hashable {
    case left
    case right

    fileprivate var boundaryDirection: Double {
        switch self {
        case .left: -1
        case .right: 1
        }
    }

    func widthTranslation(from pointerTranslation: Double) -> Double {
        boundaryDirection * pointerTranslation
    }

    var accessibilityDescription: String {
        switch self {
        case .left: "左侧"
        case .right: "右侧"
        }
    }
}

enum MarkdownContentWidthResizePhase: Equatable {
    case idle
    case hovering
    case dragging

    var lineWidth: Double {
        switch self {
        case .idle, .hovering: 3
        case .dragging: 4
        }
    }

    var lineOpacity: Double {
        switch self {
        case .idle: 0
        case .hovering: 0.34
        case .dragging: 0.64
        }
    }

    var glowOpacity: Double {
        switch self {
        case .idle: 0
        case .hovering: 0.06
        case .dragging: 0.14
        }
    }
}

final class MarkdownContentWidthBoundaryHitView: NSView {
    private var drag: (CGFloat) -> Void = { _ in }
    private var endDrag: () -> Void = {}
    private var reset: () -> Void = {}
    private var phaseChanged: (MarkdownContentWidthResizePhase) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var dragStartWindowX: CGFloat?
    private var isPointerInside = false
    private var interactionResetGeneration: Int?
    private(set) var phase = MarkdownContentWidthResizePhase.idle {
        didSet {
            guard phase != oldValue else { return }
            phaseChanged(phase)
        }
    }

    private(set) var registeredCursorRect: NSRect?
    private(set) var registeredCursor: NSCursor?
    private(set) var cursorRectResetCount = 0
    private(set) var cursorRectInvalidationCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动 Markdown 内容宽度边界线；双击恢复默认宽度"
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("调整 Markdown 内容宽度")
        setAccessibilityHelp("拖动内容宽度边界线调整宽度；双击恢复默认宽度")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removeWindowObservers()
    }

    func configure(
        edge: MarkdownContentWidthResizeEdge,
        drag: @escaping (CGFloat) -> Void,
        endDrag: @escaping () -> Void,
        reset: @escaping () -> Void,
        interactionResetGeneration: Int,
        phaseChanged: @escaping (MarkdownContentWidthResizePhase) -> Void
    ) {
        let shouldResetInteraction = self.interactionResetGeneration.map {
            $0 != interactionResetGeneration
        } ?? false
        self.drag = drag
        self.endDrag = endDrag
        self.reset = reset
        self.phaseChanged = phaseChanged
        self.interactionResetGeneration = interactionResetGeneration
        let side = edge.accessibilityDescription
        toolTip = "拖动 Markdown 内容宽度\(side)边界线；双击恢复默认宽度"
        setAccessibilityLabel("Markdown 内容宽度\(side)边界线")
        setAccessibilityHelp("拖动内容宽度边界线调整宽度；双击恢复默认宽度")
        if shouldResetInteraction {
            cancelInteraction()
        }
        requestCursorRectUpdate()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        registeredCursorRect = bounds
        registeredCursor = .resizeLeftRight
        cursorRectResetCount += 1
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelInteraction()
        }
        installWindowObservers()
        requestCursorRectUpdate()
    }

    override func layout() {
        super.layout()
        requestCursorRectUpdate()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        if dragStartWindowX == nil {
            phase = .hovering
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if dragStartWindowX == nil {
            phase = .idle
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            reset()
            return
        }
        dragStartWindowX = event.locationInWindow.x
        phase = .dragging
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWindowX else { return }
        drag(event.locationInWindow.x - dragStartWindowX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartWindowX != nil else { return }
        dragStartWindowX = nil
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        phase = isPointerInside ? .hovering : .idle
        endDrag()
    }

    override func cancelOperation(_ sender: Any?) {
        cancelInteraction()
    }

    func cancelInteraction() {
        let wasDragging = dragStartWindowX != nil
        dragStartWindowX = nil
        isPointerInside = false
        phase = .idle
        if wasDragging {
            endDrag()
        }
    }

    private func requestCursorRectUpdate() {
        guard let window else { return }
        cursorRectInvalidationCount += 1
        window.invalidateCursorRects(for: self)
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] notification in
                if notification.name == NSWindow.didResignKeyNotification {
                    self?.cancelInteraction()
                }
                self?.requestCursorRectUpdate()
            })
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

private struct MarkdownContentWidthBoundaryHitHost: NSViewRepresentable {
    let edge: MarkdownContentWidthResizeEdge
    let drag: (CGFloat) -> Void
    let endDrag: () -> Void
    let reset: () -> Void
    let interactionResetGeneration: Int
    let phaseChanged: (MarkdownContentWidthResizePhase) -> Void

    func makeNSView(context: Context) -> MarkdownContentWidthBoundaryHitView {
        let view = MarkdownContentWidthBoundaryHitView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: MarkdownContentWidthBoundaryHitView, context: Context) {
        configure(view)
    }

    private func configure(_ view: MarkdownContentWidthBoundaryHitView) {
        view.configure(
            edge: edge,
            drag: drag,
            endDrag: endDrag,
            reset: reset,
            interactionResetGeneration: interactionResetGeneration,
            phaseChanged: phaseChanged
        )
    }
}

struct MarkdownContentWidthBoundary: View {
    let edge: MarkdownContentWidthResizeEdge
    let lineOffset: Double
    let drag: (CGFloat) -> Void
    let endDrag: () -> Void
    let reset: () -> Void
    let interactionResetGeneration: Int

    @State private var phase = MarkdownContentWidthResizePhase.idle

    var body: some View {
        ZStack {
            MarkdownContentWidthBoundaryHitHost(
                edge: edge,
                drag: drag,
                endDrag: endDrag,
                reset: reset,
                interactionResetGeneration: interactionResetGeneration,
                phaseChanged: { phase = $0 }
            )
            RoundedRectangle(cornerRadius: phase.lineWidth / 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: phase.lineWidth)
                .frame(maxHeight: .infinity)
                .offset(x: lineOffset)
                .opacity(phase.lineOpacity)
                .shadow(
                    color: Color.accentColor.opacity(phase.glowOpacity),
                    radius: phase == .dragging ? 6 : 4
                )
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: phase == .idle ? 0.18 : 0.12), value: phase)
    }
}
