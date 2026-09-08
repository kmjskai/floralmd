import AppKit
import SwiftUI
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct MarkdownContentWidthTests {
    @Test func preferredAndActualWidthsClampIndependently() {
        #expect(MarkdownContentWidthLayout.preferredWidth(100) == 480)
        #expect(MarkdownContentWidthLayout.preferredWidth(756) == 756)
        #expect(MarkdownContentWidthLayout.preferredWidth(2_000) == 1_200)
        #expect(MarkdownContentWidthLayout.preferredWidth(.nan) == 756)

        let narrow = MarkdownContentWidthLayout.actualWidth(
            preferredWidth: 1_000,
            surfaceWidth: 620
        )
        let restored = MarkdownContentWidthLayout.actualWidth(
            preferredWidth: 1_000,
            surfaceWidth: 1_400
        )
        #expect(narrow == 476)
        #expect(restored == 1_000)

        let zoomed = MarkdownContentWidthLayout.actualWidth(
            preferredWidth: 756,
            surfaceWidth: 1_000,
            pageZoom: 2
        )
        #expect(zoomed == 356)
        #expect(MarkdownContentWidthLayout.visualWidth(
            actualWidth: zoomed,
            pageZoom: 2
        ) == 712)

        let zoomedOut = MarkdownContentWidthLayout.actualWidth(
            preferredWidth: 1_200,
            surfaceWidth: 1_000,
            pageZoom: 0.75
        )
        #expect(abs(zoomedOut - 1_189.333_333_333_333_3) < 0.001)
        #expect(abs(MarkdownContentWidthLayout.visualWidth(
            actualWidth: zoomedOut,
            pageZoom: 0.75
        ) - 892) < 0.001)
    }

    @Test func bothEdgesUseIntuitiveCenteredTwoSidedGeometry() {
        #expect(MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: 756,
            translationPoints: 22,
            edge: .right
        ) == 800)
        #expect(MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: 756,
            translationPoints: -22,
            edge: .left
        ) == 800)
        #expect(MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: 756,
            translationPoints: 22,
            edge: .left
        ) == 712)
        #expect(MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: 756,
            translationPoints: -200,
            edge: .right
        ) == 480)
        #expect(MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: 756,
            translationPoints: 22,
            edge: .right,
            pageZoom: 2
        ) == 778)
        #expect(MarkdownContentWidthLayout.boundaryHitWidth == 22)
        #expect(MarkdownContentWidthLayout.boundaryVisualOutset == 14)
        #expect(MarkdownContentWidthLayout.boundaryHitRegionOffset(
            surfaceWidth: 1_000,
            actualWidth: 756,
            edge: .left
        ) == 97)
        #expect(MarkdownContentWidthLayout.boundaryHitRegionOffset(
            surfaceWidth: 1_000,
            actualWidth: 756,
            edge: .right
        ) == 881)
    }

    @Test func bothVisibleBoundariesMoveOutwardSymmetricallyWithoutChangingContentWidth() {
        let surfaceWidth = 2_000.0
        let actualWidth = 756.0
        for zoom in [0.75, 1, 1.37, 2] {
            for edge in MarkdownContentWidthResizeEdge.allCases {
                let contentBoundary = MarkdownContentWidthLayout.contentBoundaryPosition(
                    surfaceWidth: surfaceWidth,
                    actualWidth: actualWidth,
                    edge: edge,
                    pageZoom: zoom
                )
                let visibleBoundary = MarkdownContentWidthLayout.boundaryPosition(
                    surfaceWidth: surfaceWidth,
                    actualWidth: actualWidth,
                    edge: edge,
                    pageZoom: zoom
                )
                let offset = MarkdownContentWidthLayout.boundaryHitRegionOffset(
                    surfaceWidth: surfaceWidth,
                    actualWidth: actualWidth,
                    edge: edge,
                    pageZoom: zoom
                )
                let expectedBoundary = contentBoundary
                    + (edge == .left ? -1 : 1) * MarkdownContentWidthLayout.boundaryVisualOutset
                #expect(abs(visibleBoundary - expectedBoundary) < 0.001)
                #expect(abs(offset + MarkdownContentWidthLayout.boundaryHitWidth / 2
                    - expectedBoundary) < 0.001)
            }
            #expect(MarkdownContentWidthLayout.preferredWidth(actualWidth) == actualWidth)
        }
    }

    @Test func editorLeftBoundaryIncludesTheWholeSemanticGutterAtEveryZoom() {
        let surfaceWidth = 2_000.0
        let actualWidth = 756.0
        for zoom in [0.75, 1, 1.37, 2] {
            let contentLeft = surfaceWidth / 2
                - MarkdownContentWidthLayout.visualWidth(
                    actualWidth: actualWidth,
                    pageZoom: zoom
                ) / 2
            let leftBoundary = MarkdownContentWidthLayout.boundaryPosition(
                surfaceWidth: surfaceWidth,
                actualWidth: actualWidth,
                edge: .left,
                pageZoom: zoom,
                leadingAccessoryWidth: MarkdownContentWidthLayout.editorGutterWidth
            )
            let rightBoundary = MarkdownContentWidthLayout.boundaryPosition(
                surfaceWidth: surfaceWidth,
                actualWidth: actualWidth,
                edge: .right,
                pageZoom: zoom,
                leadingAccessoryWidth: MarkdownContentWidthLayout.editorGutterWidth
            )
            #expect(abs(leftBoundary - (
                contentLeft - MarkdownContentWidthLayout.editorGutterWidth * zoom
                    - MarkdownContentWidthLayout.boundaryVisualOutset
            )) < 0.001)
            #expect(abs(rightBoundary - (
                surfaceWidth / 2
                    + MarkdownContentWidthLayout.visualWidth(
                        actualWidth: actualWidth,
                        pageZoom: zoom
                    ) / 2
                    + MarkdownContentWidthLayout.boundaryVisualOutset
            )) < 0.001)
        }
    }

    @Test func narrowEditorMovesOnlyTheLeftHitBandClearOfTheSidebarBoundary() {
        let minimumHitOffset = 9.0
        let boundary = MarkdownContentWidthLayout.boundaryPosition(
            surfaceWidth: 620,
            actualWidth: 476,
            edge: .left,
            leadingAccessoryWidth: MarkdownContentWidthLayout.editorGutterWidth
        )
        let hitOffset = MarkdownContentWidthLayout.boundaryHitRegionOffset(
            surfaceWidth: 620,
            actualWidth: 476,
            edge: .left,
            leadingAccessoryWidth: MarkdownContentWidthLayout.editorGutterWidth,
            minimumLeadingOffset: minimumHitOffset
        )
        let lineOffset = MarkdownContentWidthLayout.boundaryLineOffsetInHitRegion(
            surfaceWidth: 620,
            actualWidth: 476,
            edge: .left,
            leadingAccessoryWidth: MarkdownContentWidthLayout.editorGutterWidth,
            minimumLeadingOffset: minimumHitOffset
        )

        #expect(boundary == 0)
        #expect(hitOffset == minimumHitOffset)
        #expect(lineOffset == -MarkdownContentWidthLayout.boundaryHitWidth / 2)
        #expect(abs(hitOffset + MarkdownContentWidthLayout.boundaryHitWidth / 2
            + lineOffset - minimumHitOffset) < 0.001)
    }

    @Test func visibleBoundaryTracksPointerWithoutChangingWidthAtDragStart() {
        let surfaceWidth = 2_000.0
        let startingWidth = 756.0
        for zoom in [0.75, 1, 1.37, 2] {
            for edge in MarkdownContentWidthResizeEdge.allCases {
                let startBoundary = MarkdownContentWidthLayout.boundaryPosition(
                    surfaceWidth: surfaceWidth,
                    actualWidth: startingWidth,
                    edge: edge,
                    pageZoom: zoom
                )
                let zeroTranslationWidth = MarkdownContentWidthLayout.preferredWidth(
                    startingActualWidth: startingWidth,
                    translationPoints: 0,
                    edge: edge,
                    pageZoom: zoom
                )
                #expect(zeroTranslationWidth == startingWidth)

                let pointerTranslation = edge == .left ? -30.0 : 30.0
                let draggedWidth = MarkdownContentWidthLayout.preferredWidth(
                    startingActualWidth: startingWidth,
                    translationPoints: pointerTranslation,
                    edge: edge,
                    pageZoom: zoom
                )
                let draggedBoundary = MarkdownContentWidthLayout.boundaryPosition(
                    surfaceWidth: surfaceWidth,
                    actualWidth: draggedWidth,
                    edge: edge,
                    pageZoom: zoom
                )
                #expect(abs(draggedBoundary - startBoundary - pointerTranslation) < 0.001)
            }
        }
    }

    @Test func bothBoundaryDirectionsRemainIntuitiveAtEveryZoom() {
        for zoom in [0.75, 1, 1.37, 2] {
            let rightOutward = MarkdownContentWidthLayout.preferredWidth(
                startingActualWidth: 756,
                translationPoints: 30,
                edge: .right,
                pageZoom: zoom
            )
            let leftOutward = MarkdownContentWidthLayout.preferredWidth(
                startingActualWidth: 756,
                translationPoints: -30,
                edge: .left,
                pageZoom: zoom
            )
            let rightInward = MarkdownContentWidthLayout.preferredWidth(
                startingActualWidth: 756,
                translationPoints: -30,
                edge: .right,
                pageZoom: zoom
            )
            let leftInward = MarkdownContentWidthLayout.preferredWidth(
                startingActualWidth: 756,
                translationPoints: 30,
                edge: .left,
                pageZoom: zoom
            )
            #expect(rightOutward == leftOutward)
            #expect(rightInward == leftInward)
            #expect(rightOutward > 756)
            #expect(rightInward < 756)
        }
    }

    @Test func widthPreferenceAndViewportZoomStayIndependentAcrossExtremes() {
        let surfaceWidth = 1_400.0
        for preferredWidth in [480.0, 1_200.0] {
            for zoom in [0.75, 1, 1.37, 2] {
                let actualWidth = MarkdownContentWidthLayout.actualWidth(
                    preferredWidth: preferredWidth,
                    surfaceWidth: surfaceWidth,
                    pageZoom: zoom
                )
                let visualWidth = MarkdownContentWidthLayout.visualWidth(
                    actualWidth: actualWidth,
                    pageZoom: zoom
                )
                #expect(actualWidth <= preferredWidth)
                #expect(visualWidth <= surfaceWidth - 2 * MarkdownContentWidthLayout.pagePadding * zoom + 0.001)
                #expect(MarkdownContentWidthLayout.preferredWidth(preferredWidth) == preferredWidth)
            }
        }
    }

    @Test func alternatingZoomAndWidthDragNeverWritesOneStateIntoTheOther() {
        var preferredWidth = 756.0
        var zoom = MarkdownViewportZoom.defaultScale

        zoom = MarkdownViewportZoom.clamped(1.37)
        preferredWidth = MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: preferredWidth,
            translationPoints: 68.5,
            edge: .right,
            pageZoom: zoom
        )
        #expect(preferredWidth == 856)
        #expect(zoom == 1.37)

        zoom = MarkdownViewportZoom.clamped(0.75)
        #expect(preferredWidth == 856)
        preferredWidth = MarkdownContentWidthLayout.preferredWidth(
            startingActualWidth: preferredWidth,
            translationPoints: 37.5,
            edge: .left,
            pageZoom: zoom
        )
        #expect(preferredWidth == 756)
        #expect(zoom == 0.75)

        zoom = MarkdownViewportZoomAdjustment.reset.apply(to: zoom)
        #expect(zoom == 1)
        #expect(preferredWidth == 756)
    }

    @Test func fullHeightBoundaryIsInvisibleAtIdleAndStrengthensDuringInteraction() {
        #expect(MarkdownContentWidthResizePhase.idle.lineOpacity == 0)
        #expect(MarkdownContentWidthResizePhase.idle.glowOpacity == 0)
        #expect(MarkdownContentWidthResizePhase.hovering.lineWidth == 3)
        #expect(MarkdownContentWidthResizePhase.hovering.lineOpacity == 0.34)
        #expect(MarkdownContentWidthResizePhase.hovering.glowOpacity == 0.06)
        #expect(MarkdownContentWidthResizePhase.dragging.lineWidth == 4)
        #expect(MarkdownContentWidthResizePhase.dragging.lineOpacity == 0.64)
        #expect(MarkdownContentWidthResizePhase.dragging.glowOpacity == 0.14)
    }

    @Test func dampingStartsImmediatelyAndConvergesMonotonicallyWithoutOvershoot() {
        var model = MarkdownContentWidthDampingModel(width: 756)
        model.setTarget(1_200)
        var previous = model.displayedWidth
        var elapsed = 0.0

        while !model.isSettled, elapsed < 0.2 {
            let displayed = model.step(deltaTime: 1.0 / 60.0)
            #expect(displayed > previous)
            #expect(displayed <= model.targetWidth)
            previous = displayed
            elapsed += 1.0 / 60.0
        }

        #expect(model.displayedWidth == 1_200)
        #expect(elapsed >= 0.08)
        #expect(elapsed <= 0.12)
    }

    @Test func dampingIsStableAcrossCommonFrameRatesAndFinishesExactly() {
        for frameRate in [30.0, 60.0, 120.0] {
            var model = MarkdownContentWidthDampingModel(width: 480)
            model.setTarget(1_200)
            var elapsed = 0.0
            while !model.isSettled, elapsed < 0.2 {
                model.step(deltaTime: 1 / frameRate)
                elapsed += 1 / frameRate
            }
            #expect(model.displayedWidth == 1_200)
            #expect(elapsed >= 0.08)
            #expect(elapsed <= 0.12)
        }
    }

    @Test func continuousTargetsAdvanceEveryFrameAndNewTargetTakesOver() {
        var model = MarkdownContentWidthDampingModel(width: 756)
        var previous = model.displayedWidth
        for step in 1...24 {
            model.setTarget(756 + Double(step) * 10)
            let displayed = model.step(deltaTime: 1.0 / 120.0)
            #expect(displayed > previous)
            #expect(displayed <= model.targetWidth)
            previous = displayed
        }

        let takeoverStart = model.displayedWidth
        model.setTarget(480)
        let takeoverFrame = model.step(deltaTime: 1.0 / 60.0)
        #expect(takeoverFrame < takeoverStart)
        #expect(takeoverFrame >= 480)

        while !model.isSettled {
            model.step(deltaTime: 1.0 / 60.0)
        }
        #expect(model.displayedWidth == 480)
    }

    @Test func controllerCoalescesTargetsWithoutStarvingThePendingFrame() {
        var requestedFrames: [(TimeInterval) -> Void] = []
        let controller = MarkdownContentWidthDampingController(
            requestFrame: { requestedFrames.append($0) }
        )
        controller.synchronize(to: 756)
        controller.setTarget(800)
        controller.setTarget(900)
        controller.setTarget(1_000)

        #expect(controller.targetWidth == 1_000)
        #expect(controller.displayedWidth == 756)
        #expect(requestedFrames.count == 1)

        requestedFrames.removeFirst()(1)
        #expect(controller.displayedWidth > 756)
        #expect(controller.displayedWidth < 1_000)
        #expect(requestedFrames.count == 1)

        controller.setTarget(480)
        #expect(requestedFrames.count == 1)
        let beforeTakeover = controller.displayedWidth
        requestedFrames.removeFirst()(1 + 1.0 / 60.0)
        #expect(controller.displayedWidth < beforeTakeover)
        #expect(controller.displayedWidth >= 480)
    }

    @Test func dampingClampsEveryTargetAndResetConvergesExactly() {
        var model = MarkdownContentWidthDampingModel(width: 900)
        model.setTarget(2_000)
        #expect(model.targetWidth == 1_200)
        model.setTarget(100)
        #expect(model.targetWidth == 480)
        model.setTarget(MarkdownContentWidthLayout.defaultPreferredWidth)
        while !model.isSettled {
            model.step(deltaTime: 1.0 / 60.0)
        }
        #expect(model.displayedWidth == 756)
    }

    @Test func frameSchedulerConsumesLatestValueWithoutPostponingTheFrame() {
        var requestedFrames: [() -> Void] = []
        var appliedValues: [Double] = []
        let scheduler = LatestFrameValueScheduler<Double>(
            requestFrame: { requestedFrames.append($0) },
            apply: { appliedValues.append($0) }
        )

        scheduler.submit(1)
        scheduler.submit(2)
        scheduler.submit(3)
        #expect(requestedFrames.count == 1)
        #expect(appliedValues.isEmpty)

        requestedFrames.removeFirst()()
        #expect(appliedValues == [3])

        scheduler.submit(4)
        scheduler.submit(5)
        #expect(requestedFrames.count == 1)
        scheduler.flush()
        #expect(appliedValues == [3, 5])
        requestedFrames.removeFirst()()
        #expect(appliedValues == [3, 5])
    }

    @Test func boundaryOwnsItsTwentyTwoPointTransparentHitRegion() throws {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MarkdownContentWidthLayout.boundaryHitWidth,
                height: 240
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: AnyView(
            MarkdownContentWidthBoundary(
                edge: .left,
                lineOffset: 0,
                drag: { _ in },
                endDrag: {},
                reset: {},
                interactionResetGeneration: 0
            )
            .frame(width: MarkdownContentWidthLayout.boundaryHitWidth, height: 240)
        ))
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let boundary = try #require(
            descendants(of: host).compactMap { $0 as? MarkdownContentWidthBoundaryHitView }.first
        )
        #expect(abs(boundary.bounds.width - MarkdownContentWidthLayout.boundaryHitWidth) < 0.01)
        let midpoint = boundary.convert(
            NSPoint(x: boundary.bounds.midX, y: boundary.bounds.midY),
            to: host
        )
        #expect(host.hitTest(midpoint) === boundary)
        boundary.resetCursorRects()
        #expect(boundary.registeredCursorRect == boundary.bounds)
        #expect(boundary.registeredCursor === NSCursor.resizeLeftRight)
    }

    @Test func bothBoundariesKeepHoverAndDoubleClickResetIndependentFromZoom() throws {
        for zoom in [0.75, 1, 1.37, 2] {
            for edge in MarkdownContentWidthResizeEdge.allCases {
                var translations: [CGFloat] = []
                var endDragCount = 0
                var resetCount = 0
                var preferredWidth = 900.0
                let originalZoom = zoom
                let boundary = MarkdownContentWidthBoundaryHitView(
                    frame: NSRect(
                        x: 0,
                        y: 0,
                        width: MarkdownContentWidthLayout.boundaryHitWidth,
                        height: 240
                    )
                )
                boundary.configure(
                    edge: edge,
                    drag: { translations.append($0) },
                    endDrag: { endDragCount += 1 },
                    reset: {
                        resetCount += 1
                        preferredWidth = MarkdownContentWidthLayout.defaultPreferredWidth
                    },
                    interactionResetGeneration: 0,
                    phaseChanged: { _ in }
                )
                let window = NSWindow(
                    contentRect: NSRect(
                        x: 0,
                        y: 0,
                        width: MarkdownContentWidthLayout.boundaryHitWidth,
                        height: 240
                    ),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = boundary

                let insideEvent = try #require(mouseEvent(.mouseMoved, x: 11, window: window))
                boundary.mouseEntered(with: insideEvent)
                #expect(boundary.phase == .hovering)

                let adjustedZoom = MarkdownViewportZoomAdjustment.increase.apply(to: zoom)
                #expect(boundary.phase == .hovering)
                #expect(preferredWidth == 900)
                #expect(abs(adjustedZoom - MarkdownViewportZoom.clamped(zoom + 0.1)) < 0.001)

                let downEvent = try #require(mouseEvent(.leftMouseDown, x: 11, window: window))
                boundary.mouseDown(with: downEvent)
                #expect(boundary.phase == .dragging)

                let dragEvent = try #require(mouseEvent(.leftMouseDragged, x: 23, window: window))
                boundary.mouseDragged(with: dragEvent)
                #expect(translations == [12])

                let upOutsideEvent = try #require(mouseEvent(.leftMouseUp, x: 40, window: window))
                boundary.mouseUp(with: upOutsideEvent)
                #expect(boundary.phase == .idle)
                #expect(endDragCount == 1)

                boundary.mouseEntered(with: insideEvent)
                boundary.mouseExited(with: insideEvent)
                #expect(boundary.phase == .idle)

                let doubleClick = try #require(
                    mouseEvent(.leftMouseDown, x: 11, clickCount: 2, window: window)
                )
                boundary.mouseDown(with: doubleClick)
                #expect(resetCount == 1)
                #expect(preferredWidth == MarkdownContentWidthLayout.defaultPreferredWidth)
                #expect(zoom == originalZoom)
                #expect(boundary.phase == .idle)
            }
        }
    }

    @Test func boundaryResetsAcrossSidebarSelectionAndCanHoverAgain() throws {
        var endDragCount = 0
        let boundary = MarkdownContentWidthBoundaryHitView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: MarkdownContentWidthLayout.boundaryHitWidth,
                height: 240
            )
        )
        let window = NSWindow(
            contentRect: boundary.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = boundary
        let insideEvent = try #require(mouseEvent(.mouseMoved, x: 11, window: window))

        func configure(generation: Int) {
            boundary.configure(
                edge: .right,
                drag: { _ in },
                endDrag: { endDragCount += 1 },
                reset: {},
                interactionResetGeneration: generation,
                phaseChanged: { _ in }
            )
        }

        configure(generation: 0)
        boundary.mouseEntered(with: insideEvent)
        #expect(boundary.phase == .hovering)

        configure(generation: 1)
        #expect(boundary.phase == .idle)
        #expect(endDragCount == 0)

        boundary.mouseEntered(with: insideEvent)
        #expect(boundary.phase == .hovering)
    }

    @Test func boundaryEndsInterruptedDragAndClearsFeedbackOnFocusLoss() throws {
        var endDragCount = 0
        let boundary = MarkdownContentWidthBoundaryHitView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: MarkdownContentWidthLayout.boundaryHitWidth,
                height: 240
            )
        )
        let window = NSWindow(
            contentRect: boundary.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = boundary
        boundary.configure(
            edge: .left,
            drag: { _ in },
            endDrag: { endDragCount += 1 },
            reset: {},
            interactionResetGeneration: 0,
            phaseChanged: { _ in }
        )
        let insideEvent = try #require(mouseEvent(.mouseMoved, x: 11, window: window))
        let downEvent = try #require(mouseEvent(.leftMouseDown, x: 11, window: window))

        boundary.mouseEntered(with: insideEvent)
        boundary.mouseDown(with: downEvent)
        #expect(boundary.phase == .dragging)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(boundary.phase == .idle)
        #expect(endDragCount == 1)

        boundary.cancelInteraction()
        #expect(endDragCount == 1)
        boundary.mouseEntered(with: insideEvent)
        #expect(boundary.phase == .hovering)

        boundary.mouseDown(with: downEvent)
        boundary.cancelInteraction()
        #expect(boundary.phase == .idle)
        #expect(endDragCount == 2)
        boundary.mouseEntered(with: insideEvent)
        #expect(boundary.phase == .hovering)
    }

    @Test func editorWidthUpdatePreservesSourceAndWaitsForComposition() async throws {
        let markdown = "# 标题\n\n一段会软换行的中文正文。"
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        controller.load(markdown: markdown, contentWidth: 756)
        try await waitForEditor(in: controller)

        _ = await evaluate(
            """
            window.__widthLayoutEvents = 0;
            window.addEventListener('floralmd-layout-change', function () {
                window.__widthLayoutEvents += 1;
            });
            window.__mdEditor.select(3, 3);
            true;
            """,
            in: controller
        )
        controller.applyContentWidth(640)
        try await waitForRootWidth("640px", in: controller)
        try await waitForLayoutEvent(in: controller)

        let firstState = try #require(await evaluate(
            """
            ({
                markdown: window.__mdEditor.getMarkdown(),
                selection: window.__mdEditor._selectionForTesting().from,
                events: window.__widthLayoutEvents
            })
            """,
            in: controller
        ) as? [String: Any])
        #expect(firstState["markdown"] as? String == markdown)
        #expect((firstState["selection"] as? NSNumber)?.intValue == 3)
        #expect((firstState["events"] as? NSNumber)?.intValue ?? 0 >= 1)

        _ = await evaluate(
            "window.__mdEditor._setCompositionActiveForTesting(true)",
            in: controller
        )
        controller.applyContentWidth(700)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await rootWidth(in: controller) == "640px")

        _ = await evaluate(
            "window.__mdEditor._setCompositionActiveForTesting(false)",
            in: controller
        )
        try await waitForRootWidth("700px", in: controller)
        #expect(await currentMarkdown(in: controller) == markdown)
    }

    @Test func editorConsumesLatestWidthWhileHighFrequencyInputContinues() async throws {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        controller.load(markdown: "# 高频拖动", contentWidth: 639)
        try await waitForEditor(in: controller)
        controller.applyContentWidth(640)
        try await waitForRootWidth("640px", in: controller)

        let producer = Task { @MainActor in
            for step in 1...50 {
                controller.applyContentWidth(640 + Double(step))
                try await Task.sleep(for: .milliseconds(4))
            }
        }

        try await Task.sleep(for: .milliseconds(80))
        let widthWhileProducerIsActive = await rootWidth(in: controller)
        #expect(widthWhileProducerIsActive != "640px")

        try await producer.value
        try await waitForRootWidth("690px", in: controller)
    }

    @Test func previewAppliesWidthWithoutReloadingMarkdown() async throws {
        let coordinator = MarkdownPreviewWebView.Coordinator(linkNavigationHandler: nil)
        let configuration = MarkdownPreviewWebView.makeWebViewConfiguration(
            resourceHandler: coordinator.resourceHandler,
            linkMessageHandler: coordinator
        )
        let webView = TransparentMarkdownWebView(frame: .zero, configuration: configuration)
        webView.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
        webView.navigationDelegate = coordinator
        coordinator.display(
            markdown: "# Preview",
            documentURL: nil,
            resourceContext: nil,
            typography: .default,
            in: webView
        )
        coordinator.applyContentWidth(680, in: webView)

        var result: [String: String]?
        for _ in 0..<120 where result == nil {
            result = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(
                    """
                    document.readyState === 'complete'
                        && document.documentElement.style.getPropertyValue('--floralmd-content-width') === '680.0px'
                        ? {
                            width: getComputedStyle(document.querySelector('article')).maxWidth,
                            heading: document.querySelector('h1')?.textContent || ''
                        }
                        : null
                    """
                ) { value, _ in
                    continuation.resume(returning: value as? [String: String])
                }
            }
            if result == nil {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        #expect(result?["width"] == "680px")
        #expect(result?["heading"] == "Preview")

        let producer = Task { @MainActor in
            for step in 1...50 {
                coordinator.applyContentWidth(680 + Double(step), in: webView)
                try await Task.sleep(for: .milliseconds(4))
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await previewRootWidth(in: webView) != "680.0px")
        try await producer.value
        try await waitForPreviewRootWidth("730.0px", in: webView)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        x: CGFloat,
        clickCount: Int = 0,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 120),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        )
    }

    private func waitForEditor(in controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<120 {
            if await evaluate("Boolean(window.__mdEditor)", in: controller) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    private func waitForRootWidth(
        _ expected: String,
        in controller: CodeMirrorEditorViewController
    ) async throws {
        for _ in 0..<120 {
            if await rootWidth(in: controller) == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Editor did not apply content width \(expected)")
    }

    private func waitForLayoutEvent(in controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<120 {
            let count = await evaluate("window.__widthLayoutEvents || 0", in: controller) as? NSNumber
            if count?.intValue ?? 0 > 0 { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Editor did not dispatch a content-width layout event")
    }

    private func rootWidth(in controller: CodeMirrorEditorViewController) async -> String? {
        await evaluate(
            "document.documentElement.style.getPropertyValue('--floralmd-content-width')",
            in: controller
        ) as? String
    }

    private func currentMarkdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await evaluate("window.__mdEditor.getMarkdown()", in: controller) as? String
    }

    private func waitForPreviewRootWidth(_ expected: String, in webView: WKWebView) async throws {
        for _ in 0..<120 {
            if await previewRootWidth(in: webView) == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Preview did not apply content width \(expected)")
    }

    private func previewRootWidth(in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "document.documentElement.style.getPropertyValue('--floralmd-content-width')"
            ) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private func evaluate(
        _ script: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { value in
                continuation.resume(returning: value)
            }
        }
    }
}
