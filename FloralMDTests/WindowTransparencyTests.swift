import AppKit
import Foundation
import Testing
@testable import FloralMD

@Suite(.serialized)
@MainActor
struct WindowTransparencyTests {
    @Test func preferenceUsesExpectedDefaultRangeStepAndPersistenceKey() {
        #expect(PinnedWindowOpacityPreference.defaultPercentage == 88)
        #expect(PinnedWindowOpacityPreference.percentageRange == 70...100)
        #expect(PinnedWindowOpacityPreference.percentageStep == 1)
        #expect(AppPreferenceKey.pinnedWindowOpacityPercentage == "PinnedWindowOpacityPercentage")
    }

    @Test func preferenceClampsAndRoundsLegacyValues() {
        #expect(PinnedWindowOpacityPreference.clampedPercentage(12) == 70)
        #expect(PinnedWindowOpacityPreference.clampedPercentage(86.6) == 87)
        #expect(PinnedWindowOpacityPreference.clampedPercentage(140) == 100)
        #expect(PinnedWindowOpacityPreference.clampedPercentage(.nan) == 88)
        #expect(PinnedWindowOpacityPreference.clampedPercentage(-.infinity) == 70)
        #expect(PinnedWindowOpacityPreference.clampedPercentage(.infinity) == 100)
    }

    @Test func preferencePersistsAndNormalizesStoredValues() throws {
        let suiteName = "WindowTransparencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PinnedWindowOpacityPreference.load(from: defaults) == 88)
        #expect(PinnedWindowOpacityPreference.persist(75, to: defaults) == 75)
        #expect(defaults.double(forKey: AppPreferenceKey.pinnedWindowOpacityPercentage) == 75)

        defaults.set(130, forKey: AppPreferenceKey.pinnedWindowOpacityPercentage)
        #expect(PinnedWindowOpacityPreference.normalizeStoredValue(in: defaults) == 100)
        #expect(defaults.double(forKey: AppPreferenceKey.pinnedWindowOpacityPercentage) == 100)

        defaults.set("old-invalid-value", forKey: AppPreferenceKey.pinnedWindowOpacityPercentage)
        #expect(PinnedWindowOpacityPreference.normalizeStoredValue(in: defaults) == 88)
        #expect(defaults.double(forKey: AppPreferenceKey.pinnedWindowOpacityPercentage) == 88)
    }

    @Test func newWorkspacesDefaultToAllSpacesAndRespectTheStoredOverride() throws {
        let suiteName = "WorkspaceWindowPinningTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(WorkspaceWindowPinningPreference.defaultValue == .allSpaces)
        #expect(WorkspaceWindowPinningPreference.load(from: defaults) == .allSpaces)
        #expect(WorkspaceWindowPinningPreference.persist(.currentSpace, to: defaults) == .currentSpace)
        #expect(WorkspaceWindowPinningPreference.load(from: defaults) == .currentSpace)
        #expect(
            defaults.string(forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
                == WindowPinningMode.currentSpace.rawValue
        )
        #expect(
            AppPreferenceKey.defaultWorkspaceWindowPinningMode
                == "DefaultWorkspaceWindowPinningMode"
        )
    }

    @Test func workspacePinningPreferenceMigratesTheLegacyBoolean() throws {
        let suiteName = "WorkspaceWindowPinningMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: AppPreferenceKey.pinNewWorkspaceWindowsAcrossAllSpaces)
        #expect(WorkspaceWindowPinningPreference.normalizeStoredValue(in: defaults) == .none)
        #expect(
            defaults.string(forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
                == WindowPinningMode.none.rawValue
        )

        defaults.removeObject(forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
        defaults.set(true, forKey: AppPreferenceKey.pinNewWorkspaceWindowsAcrossAllSpaces)
        #expect(WorkspaceWindowPinningPreference.normalizeStoredValue(in: defaults) == .allSpaces)
    }

    @Test func invalidWorkspacePinningPreferenceNormalizesToTheDefault() throws {
        let suiteName = "WorkspaceWindowPinningInvalidTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("invalid", forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
        #expect(WorkspaceWindowPinningPreference.normalizeStoredValue(in: defaults) == .allSpaces)
        #expect(
            defaults.string(forKey: AppPreferenceKey.defaultWorkspaceWindowPinningMode)
                == WindowPinningMode.allSpaces.rawValue
        )
    }

    @Test func runtimeUpdatesEveryPinnedWindowButKeepsUnpinnedWindowsOpaque() {
        let pinnedWindows = (0..<2).map { _ in makeWindowAndBridge(mode: .currentSpace) }
        let unpinned = makeWindowAndBridge(mode: .none)

        for (_, bridge) in pinnedWindows {
            bridge.pinnedWindowOpacity = 0.74
        }
        unpinned.bridge.pinnedWindowOpacity = 0.74

        #expect(pinnedWindows.allSatisfy { abs($0.window.alphaValue - 0.74) < 0.001 })
        #expect(unpinned.window.alphaValue == 1)

        pinnedWindows[0].bridge.mode = .none
        #expect(pinnedWindows[0].window.alphaValue == 1)
    }

    @Test func newlyPinnedWindowUsesTheCurrentSavedValue() throws {
        let suiteName = "WindowTransparencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PinnedWindowOpacityPreference.persist(91, to: defaults)

        let pair = makeWindowAndBridge(mode: .none)
        pair.bridge.pinnedWindowOpacity = PinnedWindowOpacityPreference.alpha(
            for: PinnedWindowOpacityPreference.load(from: defaults)
        )
        pair.bridge.mode = .currentSpace

        #expect(abs(pair.window.alphaValue - 0.91) < 0.001)
    }

    private func makeWindowAndBridge(
        mode: WindowPinningMode
    ) -> (window: NSWindow, bridge: WindowPinningHostingView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let bridge = WindowPinningHostingView()
        window.contentView = bridge
        bridge.mode = mode
        return (window, bridge)
    }
}
