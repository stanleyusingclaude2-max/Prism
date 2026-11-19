# 在 iPhone 上更新到 0.1.5

1. 解压新版源码，用 Xcode 打开 `Playit.xcodeproj`。
2. 在 `TARGETS → Playit → Signing & Capabilities` 保持之前的 Team 和 Bundle Identifier。
3. 连接并解锁 iPhone，在 Xcode 顶部选中手机，按 `⌘R` 覆盖安装。相同 Team 和 Bundle Identifier 可保留已导入的媒体文件。
4. 回到主屏幕，确认 playit 已使用你选择的 C 方案图标。

版本为 **0.1.5，Build 6**。本轮将选定的 C 方案作为正式 AppIcon 资源接入；完整方形源图为 1024×1024、不透明 RGB PNG，由 iOS 应用系统图标遮罩。

本轮不改播放、检索、文件管理或 Wi-Fi 传输代码。0.1.4 的删除最后文件后自动清理空目录与导航返回功能保留。

图标文件、资源清单、构建配置及源码包检查结果见 `VALIDATION.md`。当前环境无法执行 Xcode 安装，桌面上的最终图标显示仍需在 iPhone 上确认。
