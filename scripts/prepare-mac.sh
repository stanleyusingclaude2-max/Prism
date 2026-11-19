#!/bin/bash
# Resolve this project's dependencies without changing Git's global settings.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for required in \
  Prism.xcodeproj/project.pbxproj \
  Prism.xcodeproj/xcshareddata/xcschemes/Prism.xcscheme \
  Packages/PlayitCore/Package.swift \
  Packages/PlayitTransferCore/Package.swift \
  Playit/App/PlayitApp.swift \
  Playit/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png; do
  if [[ ! -f "$required" ]]; then
    printf '缺少文件：%s\n请完整解压源码，并保持工程与 Packages 文件夹同级。\n' "$required" >&2
    exit 2
  fi
done
printf '工程目录与本地依赖文件检查通过。\n'
if [[ "${1:-}" == "--check-files" ]]; then exit 0; fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '依赖解析需要在安装了完整 Xcode 的 Mac 上运行。\n' >&2
  exit 2
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  printf '未找到 Xcode。请安装完整 Xcode，并在 Xcode → Settings → Locations 选择 Command Line Tools。\n' >&2
  exit 2
fi
if [[ -n "${PRISM_HTTP_PROXY:-}" ]]; then
  export https_proxy="$PRISM_HTTP_PROXY" http_proxy="$PRISM_HTTP_PROXY"
fi
LOG_DIR="$ROOT_DIR/.prism/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/dependencies-$(date +%Y%m%d-%H%M%S)-$$.log"
printf '日志：%s\n' "$LOG_FILE"
xcodebuild -version 2>&1 | tee "$LOG_FILE"
printf '\n检查 GitHub HTTPS 连接…\n' | tee -a "$LOG_FILE"
if ! git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
  ls-remote https://github.com/mpvkit/MPVKit.git HEAD >>"$LOG_FILE" 2>&1; then
  tail -n 12 "$LOG_FILE"
  printf '\nGitHub 连接失败。SSL_ERROR_SYSCALL 属于连接/TLS错误，请先切换网络或配置实际代理地址。\n'
  printf '指定代理时：PRISM_HTTP_PROXY=实际代理地址 bash scripts/prepare-mac.sh\n'
  printf '修复网络后重新运行本工具；请保留上面的日志。\n'
  exit 3
fi
printf '\n解析固定版本依赖，首次需要下载视频解码库…\n' | tee -a "$LOG_FILE"
set +e
xcodebuild -resolvePackageDependencies \
  -project "$ROOT_DIR/Prism.xcodeproj" -scheme Prism 2>&1 | tee -a "$LOG_FILE"
RESOLVE_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$RESOLVE_STATUS" -ne 0 ]]; then
  printf '\n依赖解析失败（退出码 %s）。详细原因见：%s\n' "$RESOLVE_STATUS" "$LOG_FILE" >&2
  exit "$RESOLVE_STATUS"
fi
printf '\n依赖解析完成。请在 Xcode 选择原 Team 与 Bundle Identifier 后运行。\n'
open "$ROOT_DIR/Prism.xcodeproj"
