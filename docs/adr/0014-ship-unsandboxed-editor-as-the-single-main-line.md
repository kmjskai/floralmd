---
status: accepted
---

# FloralMD 以无沙箱纯编辑器作为唯一产品主线

`main` 只维护直接访问用户磁盘工作区的纯 Markdown 编辑器，正式产品目标关闭 App Sandbox，并排除 Harness/DSH 模块与资源。逐目录安全书签虽适合 App Store 沙箱分发，但会让本地文件工作流反复授权；Harness 中控台也不再属于当前产品边界。历史 Harness 与旧纯编辑器形态由提交图和标签保留，不再保留活动分支、worktree 或发布形态。
