#!/usr/bin/env bash
# 把「单个产物被 download-artifact 直接解压到目标目录」整理成
# <目录>/<产物名>/...，与多个产物时的布局一致。
# 空目录和已经按产物名分子目录的布局保持不动。
#
# 产物名来源（都不打印 secret）:
#   1. SINGLE_ARTIFACT_NAME（测试或调用方显式指定）
#   2. 目录里唯一的 *-AnyKernel3.zip 文件名
#   3. 当前 run 只有一个 artifact 时，用 gh 查询产物名（需要 GITHUB_RUN_ID）
#   4. 含 anykernel.sh 时回退为 kernel-AnyKernel3
#
# 用法: normalize_single_artifact_dir.sh <下载目录>

set -euo pipefail

root="${1:-./downloaded-artifacts}"
[ -d "$root" ] || exit 0

shopt -s nullglob
top_files=("$root"/*)
top_files+=("$root"/.[!.]*)
top_files+=("$root"/..?*)
shopt -u nullglob

files=()
dirs=()
for entry in "${top_files[@]}"; do
  [ -e "$entry" ] || continue
  if [ -d "$entry" ]; then
    dirs+=("$entry")
  elif [ -f "$entry" ]; then
    files+=("$entry")
  fi
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "下载目录没有顶层文件，保持原布局（空目录或已按产物分子目录）"
  exit 0
fi

for dir in "${dirs[@]}"; do
  base="$(basename "$dir")"
  case "$base" in
    *-Build-Logs|*-Rejects|*-AnyKernel3|susfs-*|nomount-*|*Manager*)
      echo "::warning title=产物布局::下载目录同时有顶层文件和产物子目录 ${base}，不移动文件"
      exit 0
      ;;
  esac
done

resolve_name() {
  if [ -n "${SINGLE_ARTIFACT_NAME:-}" ]; then
    printf '%s\n' "$SINGLE_ARTIFACT_NAME"
    return 0
  fi
  local zips=()
  shopt -s nullglob
  zips=("$root"/*-AnyKernel3.zip)
  shopt -u nullglob
  if [ "${#zips[@]}" -eq 1 ]; then
    basename "${zips[0]}" .zip
    return 0
  fi
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && command -v gh >/dev/null 2>&1; then
    local names count
    names="$(gh api --paginate -H "Accept: application/vnd.github+json" \
      "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts?per_page=100" \
      --jq '.artifacts[].name' 2>/dev/null || true)"
    count="$(printf '%s\n' "$names" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$count" = "1" ]; then
      printf '%s\n' "$names" | sed '/^$/d' | head -n 1
      return 0
    fi
    if [ "$count" != "0" ]; then
      echo "::warning title=产物布局::运行中有 ${count} 个产物，不能把摊平目录改成单一名称" >&2
      return 1
    fi
  fi
  if [ -f "$root/anykernel.sh" ]; then
    echo "::warning title=产物布局::无法查询唯一产物名，内核包目录使用 kernel-AnyKernel3" >&2
    printf '%s\n' "kernel-AnyKernel3"
    return 0
  fi
  echo "::warning title=产物布局::无法确定唯一产物名，目录使用 single-artifact" >&2
  printf '%s\n' "single-artifact"
}

name="$(resolve_name)" || exit 0
name="$(basename "$name")"
name="${name//$'\r'/}"
if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
  echo "::error::产物名无效" >&2
  exit 1
fi

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
find "$root" -mindepth 1 -maxdepth 1 -exec mv {} "$stage"/ \;
mkdir -p "$root/$name"
find "$stage" -mindepth 1 -maxdepth 1 -exec mv {} "$root/$name"/ \;
trap - EXIT
rm -rf "$stage"
echo "已将摊平的单个产物放入 ${name}/"
