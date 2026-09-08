# FloralMD

![FloralMD App Icon](docs/assets/AppIcon/AppIcon.png)

[中文](#中文) · [English](#english)

## 中文

FloralMD 是一款原生 macOS、本地文件优先的 Markdown 工作区编辑器。它直接处理你选择的文件夹和普通文件，不要求账户、云端数据库、Vault 或专用项目格式。

[下载最新版](https://github.com/yingkaisun-kai/floralmd/releases/latest) · [使用指南](docs/USER_GUIDE.md) · [更新记录](CHANGELOG.md)

### 从文件夹到内容

FloralMD 把一个普通文件夹作为工作区：左侧 Files 显示真实磁盘结构，中央区域一次专注于一个活动资源。

1. 选择默认 Draft 文件夹、明确打开一个工作区，或从 Finder 打开单个文件。
2. 在同一窗口中浏览文件夹，并打开 Markdown、Excalidraw 绘图或图片。
3. 编辑 Markdown、查看只读预览、维护绘图，并使用相对路径组织图片与导出资源。
4. 继续用 Finder、Git、同步工具或其他编辑器管理这些普通文件；FloralMD 不会把它们导入私有数据库。

直接打开工作区外的单个文件时，其所在文件夹会成为临时工作区。不同工作区可以使用不同窗口，不会被合并进一个全局资料库。

### 主要能力

#### Markdown 编辑

- 在保留原始 Markdown 的同时实时呈现标题、列表、任务项、表格、代码、数学公式、Mermaid、脚注、标签和本地图片。
- 在实时编辑与只读预览之间切换，并通过大纲、应用内查找和命令面板浏览长文档。
- 从剪贴板粘贴图片，或从 Files 侧栏拖入已有资源，生成工作区内的相对引用。
- 提供基础字号、内容宽度和打字机模式等专注写作设置。

#### 真实文件工作区

- 浏览普通文件与文件夹；新建、重命名、移动、复制，或移到系统废纸篓。
- 不静默覆盖同名项目；切换资源前先保存尚未落盘的 Markdown。
- 外部程序修改当前文件时自动同步；若本地仍有未保存内容，则明确提示冲突而不是覆盖。
- 在 Finder 中显示、复制路径、使用系统 Quick Look，并支持从 Finder 拖入或拖出文件。

#### 绘图与图片

- 在内置离线画布中创建和编辑 `.excalidraw`，并按需同步或手动导出 SVG。
- 查看 PNG、JPEG、GIF、WebP 和 SVG，支持平移、缩放、适应窗口与 1:1 显示。
- 绘图源、SVG 导出和图片始终是工作区里的普通文件。

#### macOS 集成

- Finder Quick Look 可直接预览 Markdown。
- 窗口支持置顶、跨 Space 和透明度调节。
- 使用 Swift、AppKit 与 TextKit 构建，不依赖 Electron。

### 2026.9.2 重大改版

`2026.9.2` 是 FloralMD macOS 版的一次整体重构。产品从旧版的单文件、多标签与附加面板结构，转为本地工作区、真实 Files 侧栏和单一活动资源。

本次重构有意移除了：

- Git 状态、当前文件提交和提交历史面板；
- 侧边语义 Map／Minimap；
- 原生多文档标签页；
- 附近文件栏与 Files／Git 双侧栏；
- 旧版 Markdown 扩展开关与自定义语法定义入口。

升级不会改写 Markdown 文件格式，也不会迁移或删除工作区内容。旧版应用偏好和窗口布局不会迁移到新架构；重大升级前仍建议备份重要内容。

### 安装与更新

FloralMD 需要 macOS 26.5 或更高版本，支持 Apple silicon 与 Intel Mac。

从 [GitHub Releases](https://github.com/yingkaisun-kai/floralmd/releases/latest) 下载 `FloralMD-<版本>.dmg`，打开后将 `FloralMD.app` 拖入“应用程序”。正式安装包使用 Developer ID 签名并经过 Apple 公证。

已安装的正式版可通过应用内“检查更新…”获取稳定版本。Debug 构建使用独立应用身份和设置，不会连接正式更新通道。

### 数据与隐私

- FloralMD 不建立账户，也不提供云端内容数据库。
- 内容保存在用户选择的普通文件夹中；删除操作进入系统废纸篓。
- 当前 macOS 版本不使用 App Sandbox，以直接操作用户明确选择的工作区。
- 网络仅用于打开网页或邮件链接，以及检查软件更新等功能。

### 从源码构建与测试

需要完整安装 Xcode：

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
./scripts/test.sh
```

日常 Debug 构建使用 `com.yingkaisun.floralmd.dev` 和 `FloralMD Dev`，不会覆盖 `/Applications/FloralMD.app`。

## English

FloralMD is a native, local-file-first Markdown workspace editor for macOS. It works directly with folders and ordinary files you choose, without requiring an account, cloud database, vault, or proprietary project format.

[Download the latest release](https://github.com/yingkaisun-kai/floralmd/releases/latest) · [User guide](docs/USER_GUIDE.md) · [Changelog](CHANGELOG.md)

### From folders to content

FloralMD treats an ordinary folder as a workspace. Files presents the real on-disk structure on the left, while the center of the window focuses on one active resource at a time.

1. Choose a default Draft folder, explicitly open a workspace, or open an individual file from Finder.
2. Browse that folder in one window and open Markdown, Excalidraw drawings, or images.
3. Edit Markdown, switch to read-only preview, maintain drawings, and organize images and exports with relative paths.
4. Keep using Finder, Git, sync tools, or other editors with the same ordinary files. FloralMD never imports them into a private database.

Opening an individual file outside the Draft workspace temporarily uses its containing folder as the workspace. Separate workspaces can live in separate windows without becoming one global library.

### Highlights

#### Markdown editing

- Live rendering for headings, lists, tasks, tables, code, math, Mermaid, footnotes, tags, and local images while preserving the Markdown source.
- Live Edit and read-only Preview modes, plus an outline, in-app Find, and a command palette for long documents.
- Paste clipboard images or drag existing resources from Files to create relative references inside the workspace.
- Focused-writing controls for base font size, content width, and typewriter mode.

#### Real-file workspace

- Browse ordinary files and folders; create, rename, move, duplicate, or send items to the system Trash.
- Never silently overwrite a name collision, and save dirty Markdown before switching resources.
- Synchronize external changes when safe; show an explicit conflict instead of overwriting unsaved local edits.
- Reveal items in Finder, copy paths, use system Quick Look, and drag files between Finder and the sidebar.

#### Drawings and images

- Create and edit `.excalidraw` files in a bundled offline canvas, with optional automatic or manual SVG export.
- View PNG, JPEG, GIF, WebP, and SVG with pan, zoom, fit-to-window, and 1:1 controls.
- Drawing sources, SVG exports, and images remain ordinary files in the workspace.

#### macOS integration

- Preview Markdown directly with Finder Quick Look.
- Keep windows on top, across Spaces, or adjust their opacity.
- Built with Swift, AppKit, and TextKit rather than Electron.

### The 2026.9.2 redesign

`2026.9.2` is a ground-up redesign of FloralMD for macOS. The product moves from the legacy single-file, tabbed, panel-based structure to local workspaces, a real Files sidebar, and one active resource per window.

The redesign intentionally removes:

- the Git status, current-file commit, and commit-history panel;
- the semantic side map/minimap;
- native multi-document tabs;
- the nearby-files and Files/Git dual-sidebar layout;
- legacy Markdown-extension toggles and custom syntax definitions.

The upgrade does not rewrite Markdown formats or migrate or delete workspace content. Legacy preferences and window layouts are not migrated; back up important work before a major upgrade.

### Install and update

FloralMD requires macOS 26.5 or later and supports both Apple silicon and Intel Macs.

Download `FloralMD-<version>.dmg` from [GitHub Releases](https://github.com/yingkaisun-kai/floralmd/releases/latest), open it, and drag `FloralMD.app` into Applications. Official installers are Developer ID signed and notarized by Apple.

Installed production builds can use **Check for Updates…** to receive stable releases. Debug builds use a separate app identity and settings and do not connect to the production update channel.

### Data and privacy

- FloralMD has no account system or cloud content database.
- Content stays in ordinary folders you choose, and deletions use the system Trash.
- The current macOS app is not sandboxed so it can work directly with explicitly selected workspaces.
- Network access is limited to features such as opening web or mail links and checking for software updates.

### Build and test from source

A full Xcode installation is required:

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
./scripts/test.sh
```

Development builds use `com.yingkaisun.floralmd.dev` and `FloralMD Dev`, so they do not overwrite `/Applications/FloralMD.app`.

## Project lineage and license

FloralMD is derived from [Edmund](https://github.com/I7T5/Edmund) and continues under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for third-party notices.
