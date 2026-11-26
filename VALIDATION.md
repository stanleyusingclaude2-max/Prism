# Prism 0.3.3（Build 17）验证记录

本次交付为 Xcode 源码工程。已重新生成并检查工程，包括 128 个 PBX 对象、32 个 App/UI 测试 Swift 源文件归属、字体、颜色、图标、6 个测试素材和 MPVKit 依赖锁定。工程检查使用系统 libplist 解析 OpenStep；网页 JavaScript 与 shell 脚本也通过语法检查。

本环境未运行 Xcode、Swift 单元测试、模拟器或真机测试。新回归用例覆盖相册临时文件的命名和重名、图片在网格中的多选，以及暂停后直接打开截帧面板。

在 iPhone 上请重点验收空库导入、取消相册选择、批量选择本地与 iCloud 素材、从子目录导入，以及横屏暂停时「保存此帧」的位置。

## Prism 0.3.2（Build 16）历史验证记录

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

## 上架准备与改进（0.3.2 之后）

本轮在 Linux 上安装了 Swift 6.1.2，第一次真正编译并运行了两个核心包的测试；也装齐了 `openstep-parser`、FontTools、Node.js 和 ffprobe，完整运行了工程检查。

已完成的检查：

- `swift test --package-path Packages/PlayitCore`：147 个测试，146 个通过，1 个跳过（目录权限测试在 root 用户下无法生效，属预期）。包括 0.3.2 新增的 `MediaLibraryRepository.setMetadata(_:)` 批量写入测试。
- `swift test --package-path Packages/PlayitTransferCore`：17 个测试全部通过。
- `python3 scripts/validate-project.py` 完整通过（使用真正的 openstep-parser）。
- `scripts/generate-project.py` 重新生成的工程与仓库一致；本轮唯一的工程改动是 App 的 Release 配置加入 `EXCLUDED_SOURCE_FILE_NAMES = Fixtures`。
- 隐私清单和 Info.plist 用 plistlib 解析通过。
- 导入排队、缩略图 key、缩略图缓存清理和分辨率显示这几段代码，抽出到单独的 Swift 文件里用 `-swift-version 5 -strict-concurrency=targeted` 编译（无警告）并运行：三批重叠的导入全部按顺序完成、没有丢失；同一文件在 App 容器路径变化后 key 不变，外部文件仍按完整路径区分；缓存超出预算时从最旧的文件开始删到预算的 3/4。

iOS 部分（SwiftUI、UIKit、MPVKit）仍未编译。需要在 Mac／iPhone 上确认：

1. iOS 编译通过。
2. 中文系统界面：搜索栏“取消”、分享面板、导入文件的选择器、长按文字的菜单都显示中文；把 iPhone 语言切到英文时，这些系统界面也显示中文（与 App 文字一致）。
3. 导入排队：从“+”导入一批较大的视频，拷贝过程中切到“传文件”页再“从文件导入”一批，两批都应入库，底部提示显示“另有 1 批等待”。
4. 缩略图：覆盖安装新版本后，已有的缩略图第一次启动会重新生成一次（key 格式变化），之后再更新 App 不应再全部重新生成。
5. 上传临时文件：Wi-Fi 上传一个大文件的过程中从 Xcode 停止 App，再次启动后，“文件”App 或 Xcode 的容器下载中 `Documents/.playit-incoming` 不再存在。
6. Archive 后检查 `.app` 包内没有 `Fixtures` 目录，且 `PrivacyInfo.xcprivacy` 在包内。

## 文件夹分类中的选择与全选删除

问题：在“文件夹”分类点“选择”后，轻点文件夹仍会进入文件夹而不是勾选；“全选”只选文件；删除只处理文件；只有文件夹的页面，“选择”按钮不可用。

修复：
- `MediaLibraryRepository.delete(folders:items:)`：一次删除所选文件夹和文件。先校验整个选择，再把所有条目移入暂存目录，索引写入失败时全部恢复；嵌套在所选文件夹里的文件夹和文件随上级一起删除；删除后清理变空的上级目录，与现有删除行为一致。
- `LibraryStore.deleteSelection(folders:files:)`：调用上面的操作，只重新扫描一次，并上报被删除和被清理的目录，让正在浏览的页面退回上一级。
- `LibraryView`：选择模式下文件夹行显示勾选圈，轻点切换勾选；“全选／取消全选”包含文件夹；计数包含文件夹；有文件夹时删除改为“删除 N 个文件夹和 M 个文件？”确认；选中文件夹时移动按钮不可用；文件夹的“更多”菜单和长按菜单加入“多选”；选择栏优先于导入进度显示；勾选状态报告给 VoiceOver。

已验证：
- `PlayitCore` 新增 4 个测试并全部通过（共 151 个，1 个跳过）：混合删除、嵌套与重复选择、任何一项无效时什么都不删、索引写入失败时全部恢复、变空的上级被清理、空选择不做任何事。另外故意去掉“回滚”和“跳过所选文件夹内的文件”两段实现各一次，对应测试都能失败。
- `LibraryStore.deleteSelection` 及其后台调用原样抽出，与真实的 PlayitCore 一起编译（Swift 5 模式、并发检查 targeted），在临时媒体库上运行：全选并删除一个文件夹里的两个子文件夹和一个文件后，该文件夹被清理并上报；包含不存在的文件夹时整批不删并给出错误。
- 新增 UI 测试 `testSelectionModeSelectsFoldersAndSelectAllDeletesThem`（未运行）。

`LibraryView` 的 SwiftUI 改动未编译，需要在 Mac 上确认，并按 [真机验收](docs/DEVICE-ACCEPTANCE.md) “文件库与导入”第 9 项操作一遍。

## 长视频拖动与重力感应标志

拖动：
- 原因：长视频关键帧间隔长，精确定位慢（可达一秒），而拖动中的精确预览会让后续位置排队等待，画面停住。短视频精确定位快，所以只在长视频上出现。
- `PlaybackSeekPolicy.preview`、`ExactSeekCost` 和 `PlaybackSeekCoordinator`（PlayitCore）加 18 个测试，全部通过。其中一个测试模拟长视频拖动（精确解码 0.8 秒、关键帧 30 毫秒）：修改后拖动中两帧之间最长不超过 0.1 秒；去掉“替换过时的精确解码”后同一测试失败，出现 0.75 秒的停顿。
- `MPVEngine` 改为由协调器决定何时发送定位命令。mpv 对 seek 命令的回复先于这次定位的 `MPV_EVENT_SEEK`，所以只有回复之后的定位事件才算数，被替换的旧定位晚到的事件不会结束新的定位。这部分依赖 libmpv，只能在 iOS 上编译和验证。

标志：
- 先用网页 Canvas 按同样的路径、渐变和倾斜映射画出原型，静止状态与 `Design/PrismMark.svg` 对比一致，再写成 SwiftUI `Canvas`。
- 新增 UI 测试 `testPrismMarkFollowsTilt`：调试版启动参数 `-prism-demo-tilt` 让标志自行摆动（模拟器没有运动传感器），在“关于”页截图保存到测试结果。

需要在 iPhone 上确认：[真机验收](docs/DEVICE-ACCEPTANCE.md)“长视频拖动与重力感应标志”。

