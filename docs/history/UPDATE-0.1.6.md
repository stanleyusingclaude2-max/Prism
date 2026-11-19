# 在 iPhone 上更新到 prism 0.1.6

1. 解压新版源码，用 Xcode 打开 `Prism.xcodeproj`，选择 `Prism` scheme。
2. 在 `TARGETS → Prism → Signing & Capabilities` 选择之前使用的 Team，Bundle Identifier 填成旧版安装时使用的相同值。
3. 连接并解锁 iPhone，选中手机后按 `⌘R` 覆盖安装。

版本为 **0.1.6，Build 7**。名称由 playit 改为 **prism**，继续使用已选定的浅绿底 P 字标。首页、删除确认、系统局域网说明、USB／文件指引和电脑传文件网页已同步更名。

覆盖安装沿用原安装标识和原数据目录，保留已导入的媒体、元数据与排序偏好。新工程默认 Bundle Identifier 仍为 `com.playit.app`；如果之前自行改过，请继续使用你原来的实际值。内部源码和 Package 名称属于兼容实现，仍可出现 PlayitCore 等名称。

手机上重点确认：桌面显示 prism 和 P 图标；打开后原媒体仍在；媒体库首页、传文件网页及 USB 指引显示 prism。空目录自动清理、拖动实时预览、逐帧和长按 2× 功能继续使用。

工程与资源检查结果见 `VALIDATION.md`。当前环境没有 Xcode 或 iPhone，实际编译、覆盖安装和手机桌面显示仍需在 Mac／iPhone 上确认。
