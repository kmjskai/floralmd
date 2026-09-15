<p align="center">
  <img src="docs/assets/AppIcon/AppIcon.png" width="128" alt="FloralMD 应用图标">
</p>

<h1 align="center">FloralMD</h1>

<p align="center"><strong>在原生 macOS 工作区中，直接编辑 Markdown、Excalidraw 和图片。</strong></p>

<p align="center">
  <a href="#系统要求与权限"><img src="https://img.shields.io/badge/platform-macOS%2026.5%2B-0064e1?style=flat-square" alt="macOS 26.5+"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/releases/latest"><img src="https://img.shields.io/github/v/release/yingkaisun-kai/floralmd?style=flat-square&amp;color=2f7de1" alt="最新版本"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/yingkaisun-kai/floralmd?style=flat-square&amp;color=772678" alt="开源许可证"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/releases"><img src="https://img.shields.io/github/downloads/yingkaisun-kai/floralmd/total?style=flat-square&amp;color=ff6916" alt="累计下载量"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/actions/workflows/ci.yml"><img src="https://github.com/yingkaisun-kai/floralmd/actions/workflows/ci.yml/badge.svg" alt="CI 状态"></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

[下载最新版](https://github.com/yingkaisun-kai/floralmd/releases/latest) · [使用指南](docs/USER_GUIDE.md) · [更新记录](CHANGELOG.md)

## 为什么做 FloralMD

FloralMD 是一款原生 macOS、本地文件优先的 Markdown 工作区编辑器。它直接处理你选择的普通文件夹和文件，不要求账户、云端数据库、Vault 或专用项目格式。

它聚焦于一个轻量的内容工作循环：打开普通文件夹，在 Files 侧栏中浏览真实资源，在中央处理当前文件，再交给 Finder、Git、同步工具或其他编辑器继续使用。

## 主要能力

- **Markdown 编辑**：实时呈现标题、列表、任务项、表格、代码、数学公式、Mermaid、脚注、标签和本地图片，同时保留原始 Markdown。
- **真实文件工作区**：浏览、新建、重命名、移动、复制文件，或将它们移到系统废纸篓。
- **绘图与图片**：离线创建和编辑 `.excalidraw`，导出 SVG，并查看常见图片格式。
- **专注工具**：提供大纲、查找、命令面板、字号、内容宽度和打字机模式。
- **macOS 集成**：支持 Finder Quick Look、窗口置顶、跨 Space 和透明度调节。

## 下载与快速开始

从 [最新正式版](https://github.com/yingkaisun-kai/floralmd/releases/latest) 下载 `FloralMD-<版本>.dmg`，打开后将 `FloralMD.app` 拖入“应用程序”，再从“应用程序”启动。正式安装包使用 Developer ID 签名并经过 Apple 公证。如果公司网络禁止下载 DMG，也可以下载同版本的 `FloralMD-<版本>.zip`，解压后将其中的 `FloralMD.app` 移入“应用程序”。

1. 选择默认 Draft 文件夹、明确打开一个工作区，或从 Finder 打开单个文件。
2. 在 Files 侧栏中打开 Markdown、Excalidraw 绘图或图片。
3. 编辑并保存为工作区中的普通文件。

## 系统要求与权限

- macOS 26.5 或更高版本
- Apple silicon 或 Intel Mac
- FloralMD 只访问你明确选择的文件或工作区
- 当前 macOS 版不使用 App Sandbox，以直接操作用户选择的普通文件

## 安全、恢复与卸载

- 同名文件不会被静默覆盖；应用内删除进入系统废纸篓。
- 外部程序修改当前文件时，FloralMD 会在安全时同步；如存在未保存内容，则明确提示冲突。
- 卸载前先保存内容并退出 FloralMD，再将 App 移入废纸篓。卸载不会删除你的工作区文件。

## 更新

已安装的正式版可通过应用内“检查更新…”获取稳定版本。Debug 构建使用独立应用身份和设置，不会连接正式更新通道。

## 数据、网络与隐私

- 不需要账户，不建立云端内容数据库。
- 内容保存在你选择的普通文件夹中。
- 网络仅用于打开网页或邮件链接、检查软件更新等明确功能。

如遇到问题，请前往 [Issues](https://github.com/yingkaisun-kai/floralmd/issues)，附上 FloralMD 版本、macOS 版本、芯片类型和复现步骤，请勿提交私人文件、密码或凭据。

## 从源码构建

需要完整安装 Xcode：

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
./scripts/test.sh
```

日常 Debug 构建使用 `com.yingkaisun.floralmd.dev` 和 `FloralMD Dev`，不会覆盖 `/Applications/FloralMD.app`。

## 开源许可

FloralMD 由 [Edmund](https://github.com/I7T5/Edmund) 派生，并继续采用 [Apache License 2.0](LICENSE)。第三方归属见 [NOTICE](NOTICE)。
