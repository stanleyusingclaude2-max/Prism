#!/bin/bash
# Build an unsigned Prism .ipa for the iPhone.
#
# The result is not signed. Install it with a tool that signs it with your own
# Apple ID (Sideloadly, AltStore), or re-sign it with your developer account.
# See docs/INSTALL.md. With Xcode and an iPhone at hand, running the project
# from Xcode (⌘R) installs it directly and needs no .ipa.
#
# Optional environment:
#   PRISM_SPM_DIR    directory for downloaded Swift packages (reused by CI)
#   PRISM_HTTP_PROXY HTTP/SOCKS proxy for downloading MPVKit, as in prepare-mac.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != Darwin ]]; then
  printf '需要在安装了完整 Xcode 的 Mac 上运行。\n' >&2
  exit 2
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  printf '未找到 Xcode。请安装完整 Xcode，并在 Xcode → Settings → Locations 选择 Command Line Tools。\n' >&2
  exit 2
fi
if [[ -n "${PRISM_HTTP_PROXY:-}" ]]; then
  export https_proxy="$PRISM_HTTP_PROXY" http_proxy="$PRISM_HTTP_PROXY"
fi

setting() {
  sed -n "s/.*$1 = \"\\(.*\\)\";/\\1/p" Prism.xcodeproj/project.pbxproj | head -n 1
}
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
OUT_DIR="$ROOT_DIR/build"
DERIVED="$OUT_DIR/DerivedData"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-ipa-$(date +%Y%m%d-%H%M%S).log"

PACKAGE_ARGS=()
if [[ -n "${PRISM_SPM_DIR:-}" ]]; then
  PACKAGE_ARGS=(-clonedSourcePackagesDirPath "$PRISM_SPM_DIR")
fi

printf '正在构建 Prism %s（%s），首次构建需要下载 MPVKit，可能要十几分钟。\n日志：%s\n' "$VERSION" "$BUILD" "$LOG_FILE"
xcodebuild -version >"$LOG_FILE" 2>&1
if ! xcodebuild build \
  -project Prism.xcodeproj -scheme Prism -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  ${PACKAGE_ARGS[@]+"${PACKAGE_ARGS[@]}"} \
  CODE_SIGNING_ALLOWED=NO >>"$LOG_FILE" 2>&1; then
  printf '\n构建失败。前几条错误：\n' >&2
  grep -E 'error:' "$LOG_FILE" | head -n 20 >&2 || tail -n 40 "$LOG_FILE" >&2
  printf '\n完整日志：%s\n' "$LOG_FILE" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release-iphoneos/Prism.app"
if [[ ! -d "$APP" ]]; then
  printf '构建完成，但没有找到 %s。\n' "$APP" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$OUT_DIR/Prism-$VERSION-$BUILD-unsigned.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA" Payload)
printf '\n已生成：%s（%s）\n' "$IPA" "$(du -h "$IPA" | cut -f1)"
printf '安装方法见 docs/INSTALL.md。\n'
