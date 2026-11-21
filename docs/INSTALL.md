# 安装到 iPhone

iPhone 上的 App 必须经过 Apple ID 签名才能安装。本项目生成的是**未签名 IPA**：它是完整的安装包，但安装时要用你自己的 Apple ID 签一次名。

## 方法一：有 Mac 和 Xcode（最简单）

不需要 IPA。按 [开始使用.md](../开始使用.md) 打开工程，在 Signing & Capabilities 里选择你的 Team（普通 Apple ID 也可以），连接 iPhone 后按 ⌘R，Xcode 会签名并直接安装。

## 方法二：用 IPA 安装（Windows 或 Mac）

### 1. 获取 IPA

- **从 GitHub 下载**：打开仓库的 Actions → “Build installable IPA” → 最新一次成功的运行，在页面底部 Artifacts 里下载 `Prism-unsigned-ipa`，解压后得到 `Prism-版本-Build-unsigned.ipa`。每次推送到 `main` 都会自动构建；也可以在该页面点 “Run workflow” 手动构建。下载 Artifacts 需要登录 GitHub，文件保留 30 天。
- **在 Mac 上自己生成**：在源码目录运行 `bash scripts/build-ipa.sh`，生成的文件在 `build/` 目录下。

### 2. 签名并安装

用 [Sideloadly](https://sideloadly.io)（Windows / Mac）或 [AltStore](https://altstore.io)：

1. 用数据线连接 iPhone，在电脑上信任这台设备。
2. 把 IPA 拖进 Sideloadly，填入你的 Apple ID，点 Start。
3. 如果提示 Bundle ID 不可用（`com.playit.app` 已被别人注册），在高级选项里改成自己的，例如 `com.你的名字.prism`。以后每次都用同一个 Bundle ID，否则会装成另一个 App，媒体库不互通。
4. 在 iPhone 的“设置 → 通用 → VPN 与设备管理”里信任你的 Apple ID。
5. iOS 16 起还要打开“设置 → 隐私与安全性 → 开发者模式”，按提示重启。

### 有效期

- **免费 Apple ID**：签名 7 天后过期，App 会打不开，需要用同一个 Apple ID 和 Bundle ID 重新签名安装（Sideloadly 和 AltStore 都可以自动续签）。重新签名覆盖安装不会丢失媒体库。免费账号同时最多装 3 个这样的 App。
- **付费开发者账号**（每年 99 美元）：签名有效 1 年；也可以通过 TestFlight 分发，见 [APP-STORE.md](APP-STORE.md)。

## 注意

- 删除 App 会连同导入到 Prism 里的视频和图片一起删除。需要保留的文件请先在“文件”App 中拷出。
- 以前用 Xcode 装过 Prism 的话，用同一个 Team 和 Bundle ID 安装才会覆盖原来的 App 并保留媒体库。
