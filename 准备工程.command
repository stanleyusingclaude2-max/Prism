#!/bin/bash
PRISM_ROOT="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$PRISM_ROOT/scripts/prepare-mac.sh"
PRISM_STATUS=$?
if [[ "$PRISM_STATUS" -ne 0 ]]; then
  printf '\n准备未完成。请保留错误日志，按回车关闭窗口。\n'
  read -r _
fi
exit "$PRISM_STATUS"
