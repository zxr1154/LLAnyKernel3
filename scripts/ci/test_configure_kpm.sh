#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/common"
DEFCONFIG="$TMP/defconfig"
printf '%s\n' 'CONFIG_TMPFS=y' > "$DEFCONFIG"
cp "$DEFCONFIG" "$TMP/baseline"

# Disabling KSU takes precedence over the form's default KPM=true, even
# with no KernelSU checkout and strict incompatible-feature handling.
bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" SukiSU-Nova 禁用KSU true false
cmp "$DEFCONFIG" "$TMP/baseline"
if bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" SukiSU-Nova 关闭 true false; then
  echo 'accepted KPM without an implementation' >&2
  exit 1
fi
bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" SukiSU-Nova 关闭 true true
cmp "$DEFCONFIG" "$TMP/baseline"
mkdir -p "$TMP/KernelSU/kernel"
printf '%s\n' 'config KPM' '  bool "KPM"' > "$TMP/KernelSU/kernel/Kconfig"
for variant in SukiSU-Nova BakaSU; do
  bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" "$variant" 关闭 true false
done
test "$(grep -xc 'CONFIG_KPM=y' "$DEFCONFIG")" = 1
cp "$TMP/baseline" "$DEFCONFIG"
bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" FinaSU 关闭 true false
bash "$ROOT/scripts/ci/configure_kpm.sh" "$TMP" "$DEFCONFIG" SukiSU-Nova 关闭 false false
cmp "$DEFCONFIG" "$TMP/baseline"
echo 'KPM mode handling tests passed'
