//
//  HarnessModule.swift
//  FloralMD
//
//  Harness 形态的唯一认知面（seam）。
//
//  核心（编辑器、设置、生命周期、命令）只认识本文件里的 HarnessModule 协议，
//  不直接认识 DSHService / HarnessNotify / HarnessSurfaceView / 插件清单等
//  具体实现。两种形态通过 HarnessModuleSelection.current 选择：
//    - 默认主产品 = NoHarnessAdapter（纯编辑器：不编译、不打包、不运行 Harness）；
//    - FloralMD-Harness 构建 = FullHarnessAdapter（完整内嵌 dsh，见 DSHServiceKit）。
//  核心代码不因形态而改变——恢复内嵌 Harness 只需切换 target/scheme。
//

import Foundation
import SwiftUI

/// 中央区域呈现模式（核心 UI 状态，与具体 Harness 形态无关）。
enum WorkspaceCentralMode: String, CaseIterable, Identifiable {
    case editorOnly
    case harnessOnly
    case split

    var id: Self { self }

    var title: String {
        switch self {
        case .editorOnly: "仅编辑"
        case .harnessOnly: "Harness"
        case .split: "左右并存"
        }
    }

    /// 标题栏中央分段控件的短标题。
    var segmentTitle: String {
        switch self {
        case .editorOnly: "编辑"
        case .harnessOnly: "Harness"
        case .split: "并存"
        }
    }

    var systemImage: String {
        switch self {
        case .editorOnly: "doc.plaintext"
        case .harnessOnly: "cpu"
        case .split: "rectangle.split.2x1"
        }
    }

    var helpText: String {
        switch self {
        case .editorOnly: "只显示编辑面"
        case .harnessOnly: "只显示 Harness 面板"
        case .split: "编辑面与 Harness 面板左右并存"
        }
    }
}

/// 工具栏补充区域所需的上下文（核心提供、Harness 形态消费）。
struct HarnessToolbarContext {
    /// 当前编辑文档路径（无文档时为 nil）。
    var activeDocumentPath: String?
    /// Harness 面当前是否可见（独占或并存模式）。
    var harnessVisible: Bool
}

/// 核心对 Harness 形态的唯一认知面。
///
/// 保持窄而稳定：这里的每个成员都是核心在编译期直接调用的点。
/// 任何新的 Harness 能力都必须经由本协议暴露，而不是重新直连具体类型。
protocol HarnessModule {
    /// 构建形态是否包含 Harness（true = 设置页出现 Harness 入口等常驻面）。
    var isProvided: Bool { get }
    /// 运行时是否启用（Full 构建里可以在设置中关闭；NoHarness 恒为 false）。
    var isEnabled: Bool { get }
    /// 中央区域是否支持 harness 模式（三态切换 / ⌘⇧H / 工具面板）。
    var supportsHarnessModes: Bool { get }

    /// App 启动完成（通知 delegate 注册、授权请求等）。
    func applicationDidFinishLaunching()
    /// App 退出前（停掉托管的 dsh 服务等）。
    func applicationWillTerminate()
    /// 处理 App 收到的 URL；返回 true 表示已消费（如通知路由）。
    func applicationOpenURL(_ url: URL) -> Bool

    /// 设置页追加的 Harness 区内容（nil = 不显示）。
    func settingsSection() -> AnyView?

    /// 工作区中央区域追加的 Harness 面（nil = 不显示）。
    func workspaceSurface(isActive: Bool) -> AnyView?

    /// 窗口工具栏在 Harness 可见时追加的控件（状态徽标/操作按钮；nil = 不追加）。
    func toolbarSupplement(context: HarnessToolbarContext) -> AnyView?

    /// ⌘⇧H：在"编辑器"与"Harness"两极之间直切。
    func toggleCentralMode()

    /// 页面缩放的焦点路由：焦点是否在 Harness 内（NoHarness 恒为 false）。
    func routesZoomToHarness() -> Bool
}

/// 形态选择点：核心通过它拿到当前构建的 Harness 形态。
enum HarnessModuleSelection {
    static var current: any HarnessModule {
        #if HARNESS_FULL
        return FullHarnessAdapter.shared
        #else
        return NoHarnessAdapter.shared
        #endif
    }
}

/// 纯编辑器形态：所有能力为空（不托管服务、不注册通知、不显示任何 Harness UI）。
final class NoHarnessAdapter: HarnessModule {
    static let shared = NoHarnessAdapter()

    var isProvided: Bool { false }
    var isEnabled: Bool { false }
    var supportsHarnessModes: Bool { false }

    func applicationDidFinishLaunching() {}
    func applicationWillTerminate() {}
    func applicationOpenURL(_ url: URL) -> Bool { false }
    func settingsSection() -> AnyView? { nil }
    func workspaceSurface(isActive: Bool) -> AnyView? { nil }
    func toolbarSupplement(context: HarnessToolbarContext) -> AnyView? { nil }
    func toggleCentralMode() {}
    func routesZoomToHarness() -> Bool { false }
}