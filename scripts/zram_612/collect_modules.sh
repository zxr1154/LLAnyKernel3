#!/usr/bin/env bash
# Publish the zram.ko and zsmalloc.ko built for this kernel.
# Bazel keeps those files behind the bazel-bin symlink, and modules_install
# strips debug info. This checks defined symbols and vermagic; it does not
# treat a successful kernel build as proof that the modules exist.
set -euo pipefail

ROOT="${1:?kernel root}"
OUT="${2:?output directory}"

if ! command -v nm >/dev/null 2>&1; then
  echo "::error::缺少 nm，无法确认模块里的定义符号。" >&2
  exit 1
fi
if ! command -v strings >/dev/null 2>&1; then
  echo "::error::缺少 strings，无法读取 vermagic。" >&2
  exit 1
fi

mkdir -p "$OUT"

is_elf() {
  local file="$1"
  local magic
  magic="$(od -An -t x1 -N 4 -- "$file" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == "7f454c46" ]]
}

defined_symbol() {
  local file="$1"
  local symbol="$2"
  nm --defined-only -- "$file" | awk -v want="$symbol" '$NF == want { found = 1 } END { exit !found }'
}

modinfo_value() {
  local file="$1"
  local key="$2"
  local dump="$OUT/.strings"
  # 先落盘再解析，避免 strings | head 在 pipefail 下因 SIGPIPE 失败。
  strings -a -n 4 -- "$file" > "$dump"
  awk -v key="$key" 'index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$dump"
  rm -f "$dump"
}

declare -a SEARCH_ROOTS=()
add_root() {
  local path="$1"
  if [[ -e "$path" ]]; then
    SEARCH_ROOTS+=("$path")
  fi
}
add_root "$ROOT/bazel-bin"
add_root "$ROOT/bazel-bin/common"
add_root "$ROOT/bazel-bin/common/kernel_aarch64"
add_root "$ROOT/bazel-bin/common/kernel_aarch64_dist"
add_root "$ROOT/bazel-out"
add_root "$ROOT/out"
if [[ ${#SEARCH_ROOTS[@]} -eq 0 ]]; then
  echo "::error::${ROOT} 下没有 bazel-bin、bazel-out 或 out。不把源码树里的同名文件当作已编译模块。" >&2
  exit 1
fi

candidates() {
  local name="$1"
  local root
  for root in "${SEARCH_ROOTS[@]}"; do
    # -H follows only the starting symlink (bazel-bin). -xtype f also
    # accepts a module that is itself a symlink to a regular file.
    find -H "$root" -xtype f -name "$name" 2>/dev/null || true
  done
}

rank() {
  local path="$1"
  case "$path" in
    */unstripped/*|*.ko.unstripped|*.ko.debug) echo 9 ;;
    */kernel_aarch64/zram.ko|*/kernel_aarch64/zsmalloc.ko) echo 0 ;;
    */kernel_aarch64_dist/*) echo 1 ;;
    *) echo 2 ;;
  esac
}

has_symbols() {
  local file="$1"
  shift
  local symbol
  for symbol in "$@"; do
    if ! defined_symbol "$file" "$symbol"; then
      return 1
    fi
  done
}

pick() {
  local name="$1"
  shift
  local path rank_value tried=0
  local best=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      *.ko.gz|*.ko.xz|*.ko.zst|*.ko.unstripped|*.ko.debug) continue ;;
    esac
    if ! is_elf "$path"; then
      echo "跳过非 ELF: $path" >&2
      continue
    fi
    tried=1
    rank_value="$(rank "$path")"
    printf '%s\t%s\n' "$rank_value" "$path"
  done < <(candidates "$name" | sort -u) > "$OUT/.candidates-${name}"
  if [[ "$tried" -eq 0 ]]; then
    echo "::error::未找到 ELF ${name}。bazel build 成功不代表该模块已出现在输出目录。" >&2
    return 1
  fi
  while IFS=$'\t' read -r rank_value path; do
    if has_symbols "$path" "$@"; then
      best="$path"
      break
    fi
    echo "跳过缺少定义符号的 ${path}" >&2
  done < <(sort -n -k1,1 "$OUT/.candidates-${name}")
  rm -f "$OUT/.candidates-${name}"
  if [[ -z "$best" ]]; then
    echo "::error::${name} 里没有所需的已定义符号：$*" >&2
    return 1
  fi
  printf '%s\n' "$best"
}

zram="$(pick zram.ko backend_lz4k backend_lz4kd backend_lz4k_oplus lz4k_encode lz4kd_encode lz4k_compress)"
zsmalloc="$(pick zsmalloc.ko zs_malloc)"
cp -f -- "$zram" "$OUT/zram.ko"
cp -f -- "$zsmalloc" "$OUT/zsmalloc.ko"

zram_vermagic="$(modinfo_value "$OUT/zram.ko" vermagic)"
zsmalloc_vermagic="$(modinfo_value "$OUT/zsmalloc.ko" vermagic)"
zram_depends="$(modinfo_value "$OUT/zram.ko" depends)"
zsmalloc_name="$(modinfo_value "$OUT/zsmalloc.ko" name)"
if [[ -z "$zram_vermagic" || -z "$zsmalloc_vermagic" ]]; then
  echo "::error::模块缺少 vermagic。" >&2
  exit 1
fi
if [[ "$zram_vermagic" != "$zsmalloc_vermagic" ]]; then
  echo "::error::zram.ko 与 zsmalloc.ko 的 vermagic 不一致。" >&2
  exit 1
fi
if [[ "$zram_depends" != *zsmalloc* ]]; then
  echo "::error::zram.ko 的 depends 没有 zsmalloc: ${zram_depends:-<空>}" >&2
  exit 1
fi
if [[ "$zsmalloc_name" != "zsmalloc" ]]; then
  echo "::error::zsmalloc.ko 的模块名不是 zsmalloc: ${zsmalloc_name:-<空>}" >&2
  exit 1
fi

image=""
if [[ -f "$ROOT/bazel-bin/common/kernel_aarch64/Image" ]]; then
  image="$ROOT/bazel-bin/common/kernel_aarch64/Image"
fi
kernel_release=""
if [[ -n "$image" ]]; then
  strings -a -n 12 -- "$image" > "$OUT/.image-strings"
  kernel_release="$(awk '/^Linux version / { print $3; exit }' "$OUT/.image-strings")"
  rm -f "$OUT/.image-strings"
  if [[ -z "$kernel_release" ]]; then
    echo "::error::Image 里没有 Linux version。" >&2
    exit 1
  fi
  case "$zram_vermagic" in
    "$kernel_release"*) ;;
    *)
      echo "::error::vermagic (${zram_vermagic}) 与 Image 发布串 (${kernel_release}) 不一致。" >&2
      exit 1
      ;;
  esac
else
  echo "::error::没有 bazel-bin/common/kernel_aarch64/Image，不能把 vermagic 对到本次内核。" >&2
  exit 1
fi

{
  echo "zram.ko_source=${zram}"
  echo "zsmalloc.ko_source=${zsmalloc}"
  sha256sum "$OUT/zram.ko" "$OUT/zsmalloc.ko"
  echo "defined_symbols=backend_lz4k backend_lz4kd backend_lz4k_oplus lz4k_encode lz4kd_encode lz4k_compress zs_malloc"
  echo "zram_depends=${zram_depends}"
  echo "vermagic=${zram_vermagic}"
  echo "image_release=${kernel_release}"
  echo "vendor_modules_checked=no"
  echo "module_load_tested=no"
} | tee "$OUT/manifest.txt"
