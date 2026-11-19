# Prism 0.3.2（Build 16）验证记录

本版本在没有 Xcode、iOS SDK 和 Swift 工具链的 Linux 环境中修改，**未经编译**。首次在 Mac 上构建时如有编译错误，请把第一条红色错误的完整内容发回。

已完成的检查：

- 工程：`scripts/generate-project.py` 先对 0.3.1 源码重新生成，结果与原工程逐字节一致；再加入新文件 `PrismBrandMark.swift` 并升到 0.3.2（Build 16）重新生成，App 与 UI 测试目标版本一致。
- `scripts/validate-project.py` 完整通过。它需要的 openstep-parser 在本环境无法安装，因此用一个只解析 pbxproj 文本格式的本地替代品运行（未放进工程）；其余检查照常执行，包括 Swift 文件归属、资源引用、`Image("PrismMark")` 能在资源目录中找到、AppIcon 为 1024×1024 无透明通道的 RGB PNG、矢量源改为 `Design/AppIcon-B.svg`、字体、测试素材（ffprobe）和上传网页 JavaScript（node）。
- 图标：`Design/AppIcon-B.svg` 用 Chrome 渲染后与 `AppIcon-1024.png` 逐像素比对，差异为 0。标志 `PrismMark` 的 1x/2x/3x 为同一矢量源按 28／56／84 像素高直接渲染，并在深色背景上检查了小尺寸效果。
- 源码结构：改动的 8 个 Swift 文件做了词法与括号配对检查。`scripts/validate-swift-syntax.py` 需要的 tree-sitter-swift 无法安装，没有运行。
- 核心逻辑：新增 `MediaLibraryRepository.setMetadata(_:)` 批量写入，并在 `MediaLibraryRepositoryTests` 中加了覆盖“成功写入、文件已被替换、文件已被删除”三种情况的测试。需在 Mac 上用 `swift test --package-path Packages/PlayitCore` 运行。
- UI 测试：新增 `testBrandMarkOpensAboutAndPhotoViewerOpensFromGrid`（点标志打开“关于”、从网格打开看图页并关闭）。

需要在 Mac／iPhone 上确认：

1. iOS 编译。可能出问题的地方：
   - `PrismBrandMark.swift` 里 iOS 26 才有的 `sharedBackgroundVisibility`，已用 `#if compiler(>=6.2)` 和 `#available(iOS 26.0, *)` 隔开，Xcode 16 编译时不会用到它。
   - `MediaThumbnail.swift` 里的 `ImageWorkLimiter` actor（取消与续体）。
   - `PhotoViewer.swift` 里的 `UIPageViewController` 封装。
2. PlayitCore、PlayitTransferCore 单元测试和全部 UI 测试。
3. [真机验收](docs/DEVICE-ACCEPTANCE.md) 中“0.3.2 图标、标志与图片性能”的 7 项，重点是上千张图片时网格滑动和看图翻页的流畅度，以及与 0.3.1 的 Instruments 对比。滑动卡顿的原因是根据代码分析定位的，本环境无法实测，修复效果以真机为准。

## 0.3.2 之后：宽屏横屏按钮

- 宽度为 regular 的屏幕（iPad、展开的 iPhone Duo 内屏）竖着拿时不再显示“横屏播放”按钮；普通 iPhone 不受影响。
- 系统拒绝强制转屏时，不再弹出“无法调整屏幕方向”，而是安静地回到常规布局。
- `assertLandscapeRotation` 在 regular 宽度下改为确认按钮不出现。
- 同样未经编译。需在 Mac 上确认：iPhone 模拟器横屏按钮照常可用；iPad 模拟器竖屏不显示按钮；有 Xcode 27.1 后在 iPhone Duo 模拟器里验证折叠／展开时的播放。
