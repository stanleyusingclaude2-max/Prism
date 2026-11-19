# 上架 App Store 清单

## 代码里已经完成

- 出口合规：Info.plist 声明 `ITSAppUsesNonExemptEncryption = NO`，上传时不再询问加密问题。
- 隐私清单 `PrivacyInfo.xcprivacy`：不追踪、不收集数据；声明了 UserDefaults、文件时间戳、磁盘空间和系统开机时间四类 API 的使用理由。
- 语言：开发语言和唯一的本地化为简体中文（`CFBundleDevelopmentRegion`、`CFBundleLocalizations`），系统界面显示中文。
- “关于”页：版本、反馈邮箱 s7anleyzn@gmail.com、技术支持和隐私政策链接、三份开源许可。
- 网页：`docs/privacy.html`（隐私政策）、`docs/support.html`（技术支持），由 GitHub Pages 发布。
- 测试素材只打包进 Debug 构建，Archive 出的 Release 版本不包含。

## 上传前（在 Mac 上）

1. 用 Xcode 打开 `Prism.xcodeproj`，在 Signing & Capabilities 里选择你的开发者团队。
2. Bundle Identifier 现在是 `com.playit.app`，很可能已被占用，改成自己的（例如 `com.你的名字.prism`）。上架后不能再改。改的时候同时修改 `scripts/generate-project.py` 里的 `PRODUCT_BUNDLE_IDENTIFIER`，否则下次重新生成工程会被改回去。
3. 编译并运行测试：
   ```sh
   swift test --package-path Packages/PlayitCore
   swift test --package-path Packages/PlayitTransferCore
   xcodebuild test -project Prism.xcodeproj -scheme Prism \
     -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
   ```
4. 按 [DEVICE-ACCEPTANCE.md](DEVICE-ACCEPTANCE.md) 做真机验收。
5. 完成 [LGPL-RELEASE-CHECKLIST.md](LGPL-RELEASE-CHECKLIST.md) 的第 1、3、4 步：确认打包的组件、保存对应源码、保存重新链接材料。
6. 版本号：`MARKETING_VERSION`（现为 0.3.2）和 `CURRENT_PROJECT_VERSION`（Build，现为 16）写在 `scripts/generate-project.py` 里。每次上传的 Build 号必须比上一次大；改完运行 `python3 scripts/generate-project.py` 重新生成工程。
7. Product → Archive，然后在 Organizer 里 Distribute App → App Store Connect。

## App Store Connect 里要填的

- App 名称：“Prism”大概率已被占用，可以用“Prism 视频播放器”之类；桌面上的名字仍是 Prism。
- 主要语言：简体中文。
- 截图：iPhone 6.9 英寸必需。App 同时支持 iPad，所以还要 13 英寸 iPad 截图；如果不想适配 iPad，可以把 `TARGETED_DEVICE_FAMILY` 改为 `1`（只支持 iPhone）。
- 技术支持网址：https://stanleyusingclaude2-max.github.io/Prism/support.html
- 隐私政策网址：https://stanleyusingclaude2-max.github.io/Prism/privacy.html
- App 隐私：选择“不收集数据”，与隐私清单一致。
- 年龄分级：按问卷如实填写。
- 审核备注：审核员手机里没有视频，写明测试方法，例如“在‘传文件’页开启 Wi-Fi 传输，用同一网络的电脑浏览器上传视频；或从‘文件’App 导入。本地网络权限只用于局域网内接收文件。”

## 上传之后

- 留意 Apple 发来的邮件。如果出现 **ITMS-91053（Missing API declaration）** 且点名 `Frameworks/` 下的文件（MPVKit 的 libmpv、FFmpeg 等），说明这些框架本身缺少隐私清单。App 自己的清单已经声明了相关类别；遇到这种邮件时，把邮件全文保存下来再处理。
- 在 App Store Connect 的版本页面确认语言显示为“简体中文”。

## 中国大陆地区

在中国大陆 App Store 分发的 App 通常需要在 App Store Connect 填写 ICP 备案号。Prism 不连接互联网，只在局域网内接收文件，是否必须备案请以 Apple 和工信部当前的要求为准。暂时不处理的话，可以在“价格与销售范围”里先不勾选中国大陆。
