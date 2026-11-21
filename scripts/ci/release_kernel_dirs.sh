#!/usr/bin/env bash
# 打印应上传到 Release 的内核产物目录，每行一个绝对或原样路径。
# 跳过日志、冲突、管理器和模块目录。调用前应先运行
# normalize_single_artifact_dir.sh，这样单个产物被摊平后仍能被找到。

set -euo pipefail

root="${1:-./downloaded-artifacts}"
[ -d "$root" ] || exit 0

shopt -s nullglob
for dir in "$root"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  case "$dir/" in
    *-Build-Logs/|*-Rejects/|*Manager*/|*susfs-*/|*nomount-*/) continue ;;
  esac
  if [ -f "$dir/anykernel.sh" ] || compgen -G "$dir/*-AnyKernel3.zip" >/dev/null; then
    printf '%s\n' "$dir"
  fi
done
