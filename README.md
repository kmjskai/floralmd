# FloralMD

![FloralMD App Icon](docs/assets/AppIcon/AppIcon.png)

[中文](#中文) · [English](#english)

## 中文

FloralMD 是一款面向 macOS 的本地文件优先 Markdown 编辑器。它直接使用你选择的文件夹和其中的普通文件，不要求账户、云端数据库或专用项目格式。

### 主要能力

- **真实文件工作区**：浏览、创建、重命名、移动、复制和移到系统废纸篓。
- **实时 Markdown 编辑**：在保留原始 Markdown 的同时渲染标题、列表、表格、代码、数学公式、Mermaid、脚注、标签和本地图片。
- **编辑与只读预览**：在同一文件上切换实时编辑和阅读模式。
- **图片与绘图资源**：查看常见位图与 SVG，并在工作区内处理 Excalidraw 绘图。
- **大纲与查找**：按标题浏览长文档，使用应用内查找和命令面板快速操作。
- **工作辅助**：窗口置顶、跨 Space、透明度、内容宽度和打字机模式。
- **Finder Quick Look**：在 Finder 中直接预览 Markdown。
- **外部修改保护**：其他程序修改当前文件时，避免静默覆盖未保存内容。

### 2026.9.1 重大改版

FloralMD 的 macOS 版本在 `2026.9.1` 完成整体重构。新版从“单文件、标签页和附加面板”转为“本地工作区、真实文件侧栏和单一活动资源”的产品结构。

这不是对旧界面的逐项复刻。以下旧版能力已经移除：

- Git 状态、当前文件提交和提交历史面板；
- 侧边语义 Map／Minimap；
- 原生多文档标签页；
- 旧版附近文件栏及 Files／Git 双侧栏结构；
- 旧版 Markdown 扩展开关与自定义语法定义入口。

新版不会修改你的 Markdown 文件格式，也不会把文件导入数据库。升级前仍建议备份正在编辑的重要内容；旧版应用偏好和窗口布局不会迁移到新架构。

### 系统要求

- macOS 26.5 或更高版本
- Apple silicon 或 Intel Mac

### 安装

从 [GitHub Releases](https://github.com/yingkaisun-kai/floralmd/releases/latest) 下载 `FloralMD-<版本>.dmg`，打开后将 `FloralMD.app` 拖入“应用程序”。正式安装包使用 Developer ID 筛名并经过 Apple 公证。

### 数据与隐私

- 内容保存在用户选择的普通文件夹中；FloralMD 不建立账户或云端内容数据库。
- 当前 macOS 版本为了直接操作用户明确选择的工作区，不使用 App Sandbox。
- 删除操作进入系统废纸篓；同名目标不会被静默覆盖。
- 应用仅在打开网页、邮件链接或检查更新等明确操作中使用网络。

### 从源码构建

需要完整安装 Xcode：

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
```

Debug 构建使用 `com.yingkaisun.floralmd.dev` 和 `FloralMD Dev`，不会覆盖正式版身份。

## English

FloralMD is a local, file-first Markdown editor for macOS. It works directly with folders and ordinary files you choose, without requiring an account, cloud database, or proprietary project format.

### Highlights

- A real-file workspace with safe file operations
- Live Markdown editing that preserves the original source
- Edit and read-only preview modes
- Local images, SVG viewing, and Excalidraw resources
- Outline, find, and a command palette
- Window pinning, transparency, content width, and typewriter mode
- Finder Quick Look for Markdown
- Conflict protection when another app changes the active file

### 2026.9.1 major redesign

The macOS app was rebuilt around a local workspace, a real-file sidebar, and one active resource per window. This release intentionally removes the legacy Git status/commit/history panel, semantic minimap, native document tabs, the nearby-files and Files/Git dual-sidebar layout, and the old Markdown-extension settings.

Markdown files remain ordinary files and are not migrated into a database. Back up important work before upgrading; legacy app preferences and window layouts are not migrated to the new architecture.

### Requirements and installation

FloralMD requires macOS 26.5 or later and supports Apple silicon and Intel Macs. Download `FloralMD-<version>.dmg` from [GitHub Releases](https://github.com/yingkaisun-kai/floralmd/releases/latest), then drag the app into Applications. Official builds are Developer ID signed and notarized by Apple.

### Data and privacy

Your content stays in folders you choose. FloralMD has no account system or cloud content database. The current macOS app is not sandboxed so it can work directly with explicitly selected workspaces. Deletions use the system Trash, and existing files are never silently overwritten.

### Build from source

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
```

Debug builds use the isolated `com.yingkaisun.floralmd.dev` identity.

## License

FloralMD is released under the Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
