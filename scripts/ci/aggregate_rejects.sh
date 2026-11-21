#!/usr/bin/env bash
# 把 download-artifact 得到的 *-Rejects 汇总为 AIO-REJ.zip。
# download-artifact 在只命中一个产物时会把内容直接解压到目标目录，
# 多个产物时才会各自放入以产物名命名的子目录。两种布局以及空目录都要能处理。
#
# 用法: aggregate_rejects.sh <下载目录> <汇总目录> <zip 输出路径>

set -euo pipefail

src="${1:-./downloaded-artifacts}"
out="${2:-./aio-rejects}"
zip_path="${3:-./AIO-REJ.zip}"

mkdir -p "$out"
rm -f "$zip_path"

copy_tree() {
  local from="$1"
  local name="$2"
  mkdir -p "$out/$name"
  cp -a "$from"/. "$out/$name/"
}

found=0
if [ -d "$src" ]; then
  shopt -s nullglob
  for dir in "$src"/*-Rejects; do
    [ -d "$dir" ] || continue
    base="$(basename "$dir")"
    copy_tree "$dir" "${base%-Rejects}"
    found=1
  done
  shopt -u nullglob
fi

if [ "$found" -eq 0 ] && [ -d "$src" ]; then
  has_rej=false
  if [ -f "$src/index.txt" ]; then
    has_rej=true
  elif find "$src" -type f -name '*.rej' -print -quit | grep -q .; then
    has_rej=true
  fi
  if [ "$has_rej" = true ]; then
    name="Rejects"
    if [ -f "$src/artifact-name.txt" ]; then
      name="$(head -n 1 "$src/artifact-name.txt")"
      name="$(basename "$name")"
      name="${name%-Rejects}"
      [ -n "$name" ] || name="Rejects"
    fi
    copy_tree "$src" "$name"
    echo "单产物冲突目录已摊平，按 ${name} 汇总"
  fi
fi

if [ -n "$(ls -A "$out" 2>/dev/null || true)" ]; then
  mkdir -p "$(dirname "$zip_path")"
  zip_abs="$(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"
  (
    cd "$out"
    zip -r -q -9 "$zip_abs" .
  )
  echo "已生成 $(basename "$zip_abs")"
else
  echo "没有冲突文件需要汇总"
fi
