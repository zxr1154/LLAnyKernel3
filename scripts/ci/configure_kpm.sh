#!/usr/bin/env bash
# Configure KPM only when the selected KernelSU implementation is installed.
set -euo pipefail

ROOT="${1:?kernel root}"
DEFCONFIG="${2:?defconfig}"
VARIANT="${3:?KernelSU variant}"
KSU_MODE="${4:?KernelSU mode}"
USE_KPM="${5:?KPM requested}"
SKIP_INCOMPATIBLE="${6:?skip incompatible}"

if [[ "$KSU_MODE" == "禁用KSU" ]]; then
  echo "KernelSU 已禁用，不添加 KPM 配置"
  exit 0
fi
[[ "$USE_KPM" == "true" ]] || exit 0

case "$VARIANT" in
  SukiSU-Nova|BakaSU)
    if grep -RqsE '^[[:space:]]*config[[:space:]]+KPM([[:space:]]|$)' \
      "$ROOT/common" "$ROOT/KernelSU" 2>/dev/null; then
      grep -qx 'CONFIG_KPM=y' "$DEFCONFIG" || echo 'CONFIG_KPM=y' >> "$DEFCONFIG"
    elif [[ "$SKIP_INCOMPATIBLE" == "true" ]]; then
      echo '::warning title=KPM 已跳过::当前 KernelSU 代码未声明 CONFIG_KPM'
      if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '\n> KPM 已自动跳过：当前 KernelSU 代码未声明 CONFIG_KPM。\n' >> "$GITHUB_STEP_SUMMARY"
      fi
    else
      echo '::error::已请求启用 KPM，但当前 KernelSU 代码未声明 CONFIG_KPM' >&2
      exit 1
    fi
    ;;
  FinaSU)
    echo '::warning title=KPM 不适用::FinaSU 不支持 KPM，已忽略该选项'
    ;;
  *)
    echo "::error::未知 KernelSU 变体: $VARIANT" >&2
    exit 1
    ;;
esac
