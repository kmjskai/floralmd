---
status: accepted
---

# dev 与正式版的 macOS 命名矩阵：文件层连字符、界面层空格

macOS 中一个 app 有四个独立的名字层，各由不同的构建设置决定，必须分开配：**文件名**（bundle 目录名，`PRODUCT_NAME`）、**可执行/进程名**（`Contents/MacOS/<EXECUTABLE_NAME>`，默认跟随 `PRODUCT_NAME`）、**系统短名**（`CFBundleName`，通知署名/脚本引用等系统内部场合，无显示名时的回退）、**显示名**（`CFBundleDisplayName`，Dock/菜单栏/Spotlight/通知中心）。dev 版采用"**文件层连字符、界面层空格**"的混合命名：`FloralMD-Dev`（文件名/进程名，命令行免引号、`pgrep`/`cp` 直接可用）与 `FloralMD Dev`（短名/显示名，符合 Apple 生态界面惯例），两层经 `FLORALMD_DISPLAY_NAME` 与 `PRODUCT_NAME` 独立配置，互不影响；`PRODUCT_NAME` 变更后测试宿主（`TEST_HOST`）同步变量化（`$(WRAPPER_NAME)/$(EXECUTABLE_NAME)`）。配套：Debug 构建完成后由 "Install to /Applications" build phase 自动安装到 `/Applications/FloralMD-Dev.app`（Release/Archive 不触发），让 dev 版常驻系统、Spotlight 可搜、⌘R 即更新；"Verify app identity"（ADR 0012）继续保证 id/scheme/显示名与配置一致。完整命名矩阵见 `docs/dsh-harness-design.md` §3.4 与 `docs/PROGRESS.md`（2026-08-16）。

**已知双轨（实测确认，接受现状不修）**：macOS 两套 UI 的名字来源不同——LaunchServices（Dock/菜单栏/通知署名）用 `CFBundleDisplayName`（显示 "FloralMD Dev"），而 Spotlight 索引（mdimport 的 `kMDItemDisplayName`）只认 `InfoPlist.strings` 本地化显示名资源、**没有则回退文件名**（显示 "FloralMD-Dev"，对照：Terminal 有本地化资源故显示"终端"）。Spotlight 显示连字符属预期行为，两轨都能搜到、都能启动；若将来要统一为空格，给 bundle 增加 en/zh-Hans 的 `InfoPlist.strings` 即可（`"CFBundleDisplayName" = "FloralMD Dev"`）。
