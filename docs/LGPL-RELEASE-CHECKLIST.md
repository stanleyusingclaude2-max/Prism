# 上架前的 LGPL 合规清单

Prism 链接的是 MPVKit 的非 GPL 产品，其中 libmpv、FFmpeg 等组件使用 LGPL。LGPL 允许在收费 App 中使用，但分发二进制时要满足几项义务。下面是准备上架时需要逐项完成的事情。这份清单不是法律意见；有疑问时请咨询熟悉开源许可的律师。

## 1. 确认实际打包的组件与许可证

- 在 Xcode 的 Archive 中确认 MPVKit 实际链接的 framework 清单（libmpv、FFmpeg 各库、libplacebo、MoltenVK、libass、freetype 等）。
- 逐一记录每个组件的版本和许可证。MPVKit 的 `Package.swift` 列出了每个二进制的下载地址和校验值，可作为版本依据。
- 确认没有误选 `MPVKit-GPL` 产品；当前工程链接的是 `MPVKit`。

0.3.2（Build 16）在 GitHub Actions 上用 Xcode 26.6 构建的 IPA，`Prism.app/Frameworks` 里实际有 27 个动态库。下表的许可证是这些项目常见的许可，发布前请以对应版本上游的 LICENSE 为准：

| Framework | 上游项目 | 常见许可证 |
| --- | --- | --- |
| Libmpv | mpv | LGPL-2.1+（非 GPL 构建） |
| Libavcodec、Libavdevice、Libavfilter、Libavformat、Libavutil、Libswresample、Libswscale | FFmpeg | LGPL-2.1+（非 GPL 构建） |
| Libplacebo | libplacebo | LGPL-2.1+ |
| Libbluray | libbluray | LGPL-2.1+ |
| Libfribidi | FriBidi | LGPL-2.1+ |
| gnutls | GnuTLS | LGPL-2.1+ |
| nettle、hogweed | Nettle | LGPL-3.0+ 或 GPL-2.0+ 双许可 |
| gmp | GMP | LGPL-3.0+ 或 GPL-2.0+ 双许可 |
| Libuchardet | uchardet | MPL-1.1 / GPL-2.0 / LGPL-2.1 三许可 |
| Libssl、Libcrypto | OpenSSL | Apache-2.0 |
| Libass | libass | ISC |
| Libdav1d | dav1d | BSD-2-Clause |
| Libuavs3d | uavs3d | BSD 类许可 |
| Libdovi | libdovi（dovi_tool） | MIT |
| Libfreetype | FreeType | FreeType License 或 GPL-2.0 双许可 |
| Libharfbuzz | HarfBuzz | MIT |
| Libunibreak | libunibreak | zlib |
| lcms2 | Little CMS | MIT |
| Libshaderc_combined | shaderc（含 glslang、SPIRV-Tools） | Apache-2.0 等 |

现有的 `THIRD-PARTY-NOTICES.txt` 只写了 MPVKit、mpv、FFmpeg、MoltenVK 和 libplacebo，需要按上表补齐各组件的版权声明和许可文本。

## 2. 在 App 内展示许可声明（已完成基础部分）

- 0.3.1 已在“媒体库 → + → 关于与开源许可”中展示第三方组件说明、LGPL 全文和 D-DIN 字体许可。
- 如果第 1 步发现其他组件（例如 libass、freetype 等各自的许可），把它们的许可文本追加到 `Playit/Resources/THIRD-PARTY-NOTICES.txt`，或作为新的 `.txt` 资源加入“关于”页。

## 3. 提供对应源码

- 为本次上架所用的每个 LGPL 组件，保存对应版本的完整源码（含你自己的修改，如果有）。
- 选择一种提供方式：在 App 说明或网站上放下载链接，或在许可说明中写明“可向开发者索取”。
- `THIRD-PARTY-NOTICES.txt` 末尾现在写的是“可通过 s7anleyzn@gmail.com 向开发者索取”。这是一项承诺：上架后要确实能按请求提供。如果改用下载链接，请同步修改这段文字。

## 4. 准备重新链接材料

LGPL 要求用户能够用修改过的库重新链接你的 App。iOS 上通常做法是：

- 保存每个上架版本的 App 目标文件（`.o`／静态库）或可重新链接的工程材料，以及对应的构建说明；
- 在源码提供方式中一并说明如何获取这些材料。

具体可接受的形式存在不同解读，建议在第一次上架前确认一次。

## 5. 每次发布时

- 版本号（`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`）与保存的源码、重新链接材料一一对应。
- MPVKit 固定提交变化时，重新执行第 1 步。
