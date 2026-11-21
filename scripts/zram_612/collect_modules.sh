#!/usr/bin/env bash
# Copy the modular zram.ko and zsmalloc.ko produced by a 6.12 GKI build.
# The kernel Image stays modular; this only publishes the companion modules.
set -euo pipefail

ROOT="${1:?kernel root}"
OUT="${2:?output directory}"
mkdir -p "$OUT"

pick() {
  local name="$1"
  local path best=""
  local candidate
  local -a roots=()
  for candidate in "$ROOT/bazel-bin" "$ROOT/bazel-out" "$ROOT/out"; do
    if [[ -e "$candidate" ]]; then
      roots+=("$candidate")
    fi
  done
  if [[ ${#roots[@]} -eq 0 ]]; then
    roots+=("$ROOT")
  fi
  # bazel-bin 和 bazel-out 是符号链接。从这些起点用 -H 进入，
  # 避免 find 在遍历内核树时跳过它们。
  while IFS= read -r path; do
    case "$path" in
      *.unstripped|*.ko.debug) continue ;;
    esac
    if [[ "$path" == *"/kernel_aarch64_dist/"* ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    if [[ -z "$best" ]]; then
      best="$path"
    fi
  done < <(find -H "${roots[@]}" -type f -name "$name" 2>/dev/null | sort)
  if [[ -z "$best" ]]; then
    echo "::error::未找到 ${name}。内核配置是模块，但 dist 没有产出该文件。" >&2
    return 1
  fi
  printf '%s\n' "$best"
}

require_string() {
  local file="$1"
  local symbol="$2"
  if ! strings -a "$file" | grep -q -F "$symbol"; then
    echo "::error::${file} 没有 ${symbol}，不能证明额外 ZRAM 算法已链进模块。" >&2
    return 1
  fi
}

zram="$(pick zram.ko)"
zsmalloc="$(pick zsmalloc.ko)"
cp -f "$zram" "$OUT/zram.ko"
cp -f "$zsmalloc" "$OUT/zsmalloc.ko"
require_string "$OUT/zram.ko" lz4k_encode
require_string "$OUT/zram.ko" lz4kd_encode
require_string "$OUT/zram.ko" lz4k_compress
require_string "$OUT/zsmalloc.ko" zsmalloc

{
  echo "zram.ko_source=${zram}"
  echo "zsmalloc.ko_source=${zsmalloc}"
  sha256sum "$OUT/zram.ko" "$OUT/zsmalloc.ko"
  echo "zram.ko strings: lz4k_encode lz4kd_encode lz4k_compress"
  echo "zsmalloc.ko strings: zsmalloc"
} | tee "$OUT/manifest.txt"
