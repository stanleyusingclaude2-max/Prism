# 依赖与构建

| 产品 | 来源 | 配置 |
| --- | --- | --- |
| PlayitCore | Packages/PlayitCore | 本地包，包含媒体模型、仓库和播放状态逻辑 |
| PlayitTransferCore | Packages/PlayitTransferCore | 本地包，包含 HTTP 和文件策略 |
| MPVKit | https://github.com/mpvkit/MPVKit.git | 固定提交 98c3453e252922e3136422da3fbb2e341ed9edc8；非 GPL 产品 MPVKit |

两个本地包已随源码完整提供，不需要下载。MPVKit 首次解析需要从 GitHub 下载源码和发行版中的 XCFramework；Git 仓库可连接后，二进制下载也必须成功。

## 在 Mac 上准备

在源码根目录运行：

    bash scripts/prepare-mac.sh

该工具检查本地文件、完整 Xcode 和 GitHub 连接，再调用 xcodebuild 解析工程中的固定版本。不会修改全局 Git 配置或关闭 TLS 验证。若需要代理，将 `PRISM_HTTP_PROXY` 设置为代理软件实际提供的 HTTP／SOCKS 地址后运行；工具只对本次进程和子进程设置代理环境。

日志在 `.prism/logs/`；此目录不随源码发布。若解析失败，查看日志中首条 fetch、download、checksum 或 SSL 错误。`Missing package product` 是解析失败后的结果，不能据此判断包源码不存在。

也可在 Xcode 使用 File → Packages → Resolve Package Versions。若此前缓存解析异常，再执行 Reset Package Caches 后重试。

## 本地完整性检查

    bash scripts/prepare-mac.sh --check-files
    python3 scripts/validate-project.py

第二条检查还需要 openstep-parser、FontTools、Node.js 和 ffprobe。正常使用 Xcode 构建不依赖这些 Python 检查工具。

## 覆盖安装

继续使用之前的 Team 和实际 Bundle Identifier，保留现有安装及媒体沙盒。默认标识为 com.playit.app；如果曾改成自己的值，请填回原值。原有隐藏索引和文件路径未迁移。
