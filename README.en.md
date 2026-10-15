<p align="center">
  <img src="docs/assets/AppIcon/AppIcon.png" width="128" alt="FloralMD app icon">
</p>

<h1 align="center">FloralMD</h1>

<p align="center"><strong>Edit Markdown, Excalidraw drawings, and images directly in a native macOS workspace.</strong></p>

<p align="center">
  <a href="#requirements-and-permissions"><img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-0064e1?style=flat-square" alt="macOS 14.0+"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/releases/latest"><img src="https://img.shields.io/github/v/release/yingkaisun-kai/floralmd?style=flat-square&amp;color=2f7de1" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/yingkaisun-kai/floralmd?style=flat-square&amp;color=772678" alt="License"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/releases"><img src="https://img.shields.io/github/downloads/yingkaisun-kai/floralmd/total?style=flat-square&amp;color=ff6916" alt="Downloads"></a>
  <a href="https://github.com/yingkaisun-kai/floralmd/actions/workflows/ci.yml"><img src="https://github.com/yingkaisun-kai/floralmd/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

[Download](https://github.com/yingkaisun-kai/floralmd/releases/latest) · [User guide](docs/USER_GUIDE.md) · [Changelog](CHANGELOG.md)

## Why FloralMD

FloralMD is a native, local-file-first Markdown workspace editor for macOS. It works directly with ordinary folders and files you choose, without requiring an account, cloud database, vault, or proprietary project format.

Its workflow stays deliberately lightweight: open a folder, browse real resources in Files, focus on one active file, and keep using Finder, Git, sync tools, or other editors with the same content.

## Highlights

- **Markdown editing:** Live-render headings, lists, tasks, tables, code, math, Mermaid, footnotes, tags, and local images while preserving the Markdown source.
- **Real-file workspace:** Browse, create, rename, move, duplicate, or send files to the system Trash.
- **Drawings and images:** Create and edit `.excalidraw` files offline, export SVG, and inspect common image formats.
- **Focus tools:** Use an outline, Find, command palette, font-size and content-width controls, and typewriter mode.
- **macOS integration:** Preview Markdown with Finder Quick Look and keep windows on top, across Spaces, or translucent.

## Download and quick start

Download `FloralMD-<version>.dmg` from the [latest stable release](https://github.com/yingkaisun-kai/floralmd/releases/latest), open it, and drag `FloralMD.app` into Applications. Official installers are Developer ID signed and notarized by Apple.

1. Choose the default Draft folder, explicitly open a workspace, or open an individual file from Finder.
2. Open Markdown, Excalidraw drawings, or images from Files.
3. Edit and save ordinary files inside the workspace.

## Requirements and permissions

- macOS 14.0 or later (compatible interface styling before macOS 26)
- Apple silicon or Intel Mac
- FloralMD accesses only files or workspaces you explicitly select
- The current macOS app is not sandboxed so it can work directly with those ordinary files

macOS 14 support has passed compatibility build checks but has not been tested on a Mac running macOS 14.6.1. Please report any issues through GitHub Issues.

## Safety, recovery, and uninstall

- Name collisions are never silently overwritten, and in-app deletion uses the system Trash.
- External changes synchronize when safe; unsaved local edits produce an explicit conflict instead of being overwritten.
- Save your work and quit FloralMD before moving the app to Trash. Uninstalling the app does not delete workspace files.

## Updates

Installed production builds can use **Check for Updates…** to receive stable releases. Debug builds use a separate identity and settings and never connect to the production update channel.

## Data, network, and privacy

- No account or cloud content database is required.
- Content stays in ordinary folders you choose.
- Network access is limited to explicit features such as opening web or mail links and checking for updates.

Report problems through [Issues](https://github.com/yingkaisun-kai/floralmd/issues) with the FloralMD version, macOS version, chip type, and reproduction steps. Do not attach private files, passwords, or credentials.

## Build from source

A full Xcode installation is required:

```bash
xcodebuild -project FloralMD.xcodeproj -scheme FloralMD \
  -configuration Debug -destination 'platform=macOS' build
./scripts/test.sh
```

Development builds use `com.yingkaisun.floralmd.dev` and `FloralMD Dev`, so they do not overwrite `/Applications/FloralMD.app`.

## License

FloralMD is derived from [Edmund](https://github.com/I7T5/Edmund) and continues under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for third-party notices.
