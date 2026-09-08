//
//  HarnessExternalLinkPolicy.swift
//  FloralMD
//
//  Created for feature/dsh-harness.
//  dsh GUI 站外链接的宿主侧裁决：把"新窗口"导航（target=_blank / window.open）
//  统一交给系统浏览器，避免 WKWebView 无新窗口宿主时静默丢弃点击。
//

import Foundation

enum HarnessExternalLinkPolicy {
    /// dsh GUI 把 agent 消息里的 http/https 链接渲染成 `<a target="_blank">`。
    /// WKWebView 没有 UIDelegate 时这类"新窗口"导航会被 WebKit 静默丢弃，
    /// 因此宿主侧在此拦截，交由系统默认浏览器打开。
    /// 仅放行系统能处理的 scheme；其余（SPA 内部相对路由、自定义 scheme、
    /// 文件路径等）保持 WebView 内导航。
    static func shouldOpenExternally(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return true
        default:
            return false
        }
    }
}
