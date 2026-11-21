#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/real/common/kernel_aarch64" \
  "$TMP/real/common/kernel_aarch64_dist" \
  "$TMP/tree" \
  "$TMP/out"
ln -s "$TMP/real" "$TMP/tree/bazel-bin"
printf 'unstripped lz4k_encode lz4kd_encode lz4k_compress\n' \
  > "$TMP/real/common/kernel_aarch64/zram.ko"
printf 'dist lz4k_encode lz4kd_encode lz4k_compress\n' \
  > "$TMP/real/common/kernel_aarch64_dist/zram.ko"
printf 'zsmalloc zs_malloc\n' \
  > "$TMP/real/common/kernel_aarch64/zsmalloc.ko"
if find "$TMP/tree" -type f -name zram.ko | grep -q .; then
  echo "plain find unexpectedly followed bazel-bin" >&2
  exit 1
fi

bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out"
grep -q 'kernel_aarch64_dist/zram.ko' "$TMP/out/manifest.txt"
grep -q 'lz4k_encode lz4kd_encode lz4k_compress' "$TMP/out/manifest.txt"
cmp "$TMP/real/common/kernel_aarch64_dist/zram.ko" "$TMP/out/zram.ko"

printf 'no codec here\n' > "$TMP/real/common/kernel_aarch64/zram.ko"
rm -f "$TMP/real/common/kernel_aarch64_dist/zram.ko"
rm -rf "$TMP/out"
mkdir -p "$TMP/out"
if bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out" 2>"$TMP/err"; then
  echo "accepted zram.ko without codec strings" >&2
  exit 1
fi
grep -q 'lz4k_encode' "$TMP/err"

echo "zram module collector test passed"
