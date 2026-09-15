import Foundation
import Testing
@testable import FloralMD

/// 回归测试：dsh GUI 把 agent 消息里的 http/https 链接渲染成 target="_blank"，
/// WKWebView 无新窗口宿主时会静默丢弃点击；宿主侧把这类导航转交系统浏览器。
/// 裁决逻辑集中在 HarnessExternalLinkPolicy，这里锁定其边界。
struct HarnessExternalLinkPolicyTests {
    @Test func opensHttpLinksExternally() {
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "https://example.com")!
        ) == true)
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "http://example.com/a?b=1#frag")!
        ) == true)
    }

    @Test func opensMailtoExternally() {
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "mailto:alice@example.com")!
        ) == true)
    }

    @Test func keepsWebViewInternalNavigations() {
        // SPA 内部相对路由、自定义 scheme、文件路径都不应被劫持到外部浏览器。
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "/sessions/1")!
        ) == false)
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "floralmd://open?path=/tmp")!
        ) == false)
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(fileURLWithPath: "/tmp/a.md")
        ) == false)
        #expect(HarnessExternalLinkPolicy.shouldOpenExternally(
            URL(string: "ftp://example.com/f")!
        ) == false)
    }
}
