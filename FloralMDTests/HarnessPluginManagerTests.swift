import Foundation
import Testing
@testable import FloralMD

struct HarnessPluginManagerTests {
    private var notify: HarnessPluginDescriptor {
        HarnessPluginManager.plugin("dsh-notify")!
    }

    /// 每个测试独立 UserDefaults suite，调用方 `defer` 清理。
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suite = "HarnessPluginManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: - 追加（幂等）

    @Test func existingEntryIsNotAppendedAgain() {
        let existing = """
        - insert:
            - id: dsh-notify
              name: dsh-notify
        """

        #expect(HarnessPluginManager.patchedProfileContents(existing, for: notify) == nil)
    }

    @Test func emptyRootIsReplacedWithPatchBlock() throws {
        let patched = try #require(HarnessPluginManager.patchedProfileContents("[]\n", for: notify))

        #expect(!patched.contains("[]"))
        #expect(patched.components(separatedBy: "name: dsh-notify").count == 2)
        // 条目带标记注释，供移除时定位。
        #expect(patched.contains("# dsh-notify:"))
    }

    @Test func appendingKeepsOtherEntries() throws {
        let existing = """
        # dsh-usage-stats: token usage heatmap + DeepSeek balance
        - insert:
            - id: usage-stats
              name: dsh-usage-stats
        """

        let patched = try #require(HarnessPluginManager.patchedProfileContents(existing, for: notify))
        #expect(patched.contains("name: dsh-usage-stats"))
        #expect(patched.contains("name: dsh-notify"))
        // 追加在末尾，不触碰他人条目。
        let usageIndex = try #require(patched.range(of: "name: dsh-usage-stats")?.lowerBound)
        let notifyIndex = try #require(patched.range(of: "name: dsh-notify")?.lowerBound)
        #expect(usageIndex < notifyIndex)
    }

    // MARK: - 移除（幂等 + 保留他人条目）

    @Test func removalKeepsOtherEntries() throws {
        let content = """
        # dsh-usage-stats: token usage heatmap + DeepSeek balance
        - insert:
            - id: usage-stats
              name: dsh-usage-stats

        # dsh-notify: task-completion notifications delivered to the host app (FloralMD).
        - insert:
            - id: dsh-notify
              name: dsh-notify
        """

        let removed = try #require(HarnessPluginManager.contentsRemovingEntry(content, for: notify))
        #expect(!removed.contains("dsh-notify"))
        #expect(removed.contains("dsh-usage-stats"))
        #expect(removed.contains("usage-stats"))
    }

    @Test func removalIsIdempotentWhenAbsent() {
        let content = """
        # dsh-usage-stats: token usage heatmap + DeepSeek balance
        - insert:
            - id: usage-stats
              name: dsh-usage-stats
        """

        #expect(HarnessPluginManager.contentsRemovingEntry(content, for: notify) == nil)
    }

    @Test func removalDropsTrailingBlankLines() throws {
        let content = """
        # dsh-notify: task-completion notifications delivered to the host app (FloralMD).
        - insert:
            - id: dsh-notify
              name: dsh-notify


        """

        let removed = try #require(HarnessPluginManager.contentsRemovingEntry(content, for: notify))
        #expect(removed == "")
    }

    @Test func removalWhenEntryIsFirstInFile() throws {
        let content = """
        # dsh-notify: task-completion notifications delivered to the host app (FloralMD).
        - insert:
            - id: dsh-notify
              name: dsh-notify

        # dsh-usage-stats: token usage heatmap + DeepSeek balance
        - insert:
            - id: usage-stats
              name: dsh-usage-stats
        """

        let removed = try #require(HarnessPluginManager.contentsRemovingEntry(content, for: notify))
        #expect(!removed.contains("dsh-notify"))
        #expect(removed.contains("dsh-usage-stats"))
    }

    // MARK: - 开关读取与迁移

    @Test func pluginEnabledPrefersNewKey() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set(false, forKey: HarnessPreferenceKey.notifyOnJobDone)
        defaults.set(true, forKey: HarnessSettings.pluginEnabledKey("dsh-notify"))

        #expect(HarnessSettings.isPluginEnabled("dsh-notify", defaults: defaults))
    }

    @Test func pluginEnabledFallsBackToLegacyKey() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set(false, forKey: HarnessPreferenceKey.notifyOnJobDone)

        #expect(!HarnessSettings.isPluginEnabled("dsh-notify", defaults: defaults))
    }

    @Test func pluginEnabledFallsBackToDescriptorDefault() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        // 无任何键：dsh-notify 默认开（既有行为）。
        #expect(HarnessSettings.isPluginEnabled("dsh-notify", defaults: defaults))
        // dsh-editor-path 默认开（既有功能迁移）。
        #expect(HarnessSettings.isPluginEnabled("dsh-editor-path", defaults: defaults))
        // 未知插件一律关闭。
        #expect(!HarnessSettings.isPluginEnabled("unknown-plugin", defaults: defaults))
    }

    @Test func setPluginEnabledMigratesLegacyKey() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defaults.set(false, forKey: HarnessPreferenceKey.notifyOnJobDone)

        HarnessSettings.setPluginEnabled("dsh-notify", true, defaults: defaults)

        #expect(defaults.bool(forKey: HarnessSettings.pluginEnabledKey("dsh-notify")))
        #expect(defaults.object(forKey: HarnessPreferenceKey.notifyOnJobDone) == nil)
        // 兼容别名随迁移后的新键生效。
        #expect(HarnessSettings.isNotifyEnabled(defaults: defaults))
    }
}
