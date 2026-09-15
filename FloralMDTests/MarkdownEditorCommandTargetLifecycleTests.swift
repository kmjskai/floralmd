import Combine
import SwiftUI
import Testing
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct MarkdownEditorCommandTargetLifecycleTests {
    @Test func coordinatorConnectAllowsSynchronousCommandTargetReentry() {
        let commandTarget = MarkdownEditorCommandTarget()
        let coordinator = makeCoordinator(commandTarget: commandTarget)
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        var reentryCount = 0
        let readinessObservation = commandTarget.objectWillChange.sink {
            reentryCount += 1
            coordinator.commandTarget = commandTarget
        }

        coordinator.connect(to: controller)

        #expect(reentryCount > 0)
        withExtendedLifetime(readinessObservation) {}
    }

    @Test func coordinatorDisconnectAllowsSynchronousCommandTargetReentry() {
        let commandTarget = MarkdownEditorCommandTarget()
        let coordinator = makeCoordinator(commandTarget: commandTarget)
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        commandTarget.connect(to: controller)
        var reentryCount = 0
        let readinessObservation = commandTarget.objectWillChange.sink {
            reentryCount += 1
            coordinator.commandTarget = commandTarget
        }

        CodeMirrorEditorView.dismantleNSViewController(
            controller,
            coordinator: coordinator
        )

        #expect(reentryCount > 0)
        #expect(!commandTarget.isReady)
        withExtendedLifetime(readinessObservation) {}
    }

    private func makeCoordinator(
        commandTarget: MarkdownEditorCommandTarget
    ) -> CodeMirrorEditorView.Coordinator {
        var markdown = ""
        return CodeMirrorEditorView.Coordinator(
            markdown: Binding(
                get: { markdown },
                set: { markdown = $0 }
            ),
            documentURL: nil,
            resourceContext: nil,
            typography: .default,
            commandTarget: commandTarget,
            userDidEdit: {},
            imagePasteHandler: nil,
            imageOpenHandler: nil,
            resourceDropHandler: nil,
            linkNavigationHandler: nil
        )
    }
}
