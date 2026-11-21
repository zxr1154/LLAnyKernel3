#!/usr/bin/env bash
# Layout test for the 6.12 module collector. It builds real ELF objects and
# strip --strip-debug them. It does not compile a kernel or prove the modules load.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd /tmp

cat > "$TMP/zram.c" << 'EOF'
const int backend_lz4k = 1;
const int backend_lz4kd = 2;
const int backend_lz4k_oplus = 3;
int lz4k_encode(void) { return 1; }
int lz4kd_encode(void) { return 2; }
int lz4k_compress(void) { return 3; }
static const char modinfo[] __attribute__((used, section(".modinfo"))) =
    "name=zram\0"
    "vermagic=6.12.69-android16-6-gtest SMP preempt mod_unload \0"
    "depends=zsmalloc\0";
EOF
cat > "$TMP/zsmalloc.c" << 'EOF'
int zs_malloc(void) { return 4; }
static const char modinfo[] __attribute__((used, section(".modinfo"))) =
    "name=zsmalloc\0"
    "vermagic=6.12.69-android16-6-gtest SMP preempt mod_unload \0"
    "depends=\0";
EOF
cat > "$TMP/decoy.c" << 'EOF'
static const char text[] =
    "lz4k_encode lz4kd_encode lz4k_compress backend_lz4k backend_lz4kd backend_lz4k_oplus";
int decoy(void) { return text[0]; }
EOF

gcc -c -fPIC -O2 -o "$TMP/zram.o" "$TMP/zram.c"
gcc -c -fPIC -O2 -o "$TMP/zsmalloc.o" "$TMP/zsmalloc.c"
gcc -c -fPIC -O2 -o "$TMP/decoy.o" "$TMP/decoy.c"
strip --strip-debug -o "$TMP/zram.ko" "$TMP/zram.o"
strip --strip-debug -o "$TMP/zsmalloc.ko" "$TMP/zsmalloc.o"
cp "$TMP/decoy.o" "$TMP/decoy.ko"

# bazel-bin is a symlink. The installed module is a symlink to the stripped file.
mkdir -p "$TMP/real/common/kernel_aarch64" "$TMP/tree" "$TMP/out"
ln -s "$TMP/real" "$TMP/tree/bazel-bin"
ln -s "$TMP/zram.ko" "$TMP/real/common/kernel_aarch64/zram.ko"
ln -s "$TMP/zsmalloc.ko" "$TMP/real/common/kernel_aarch64/zsmalloc.ko"
printf 'Linux version 6.12.69-android16-6-gtest (kleaf@build-host) #1 SMP PREEMPT\n' \
  > "$TMP/real/common/kernel_aarch64/Image"
# A same-named text file and an unstripped decoy must lose to the ELF module.
mkdir -p "$TMP/real/common/kernel_aarch64/unstripped" "$TMP/tree/out/kernel_aarch64/dist"
printf 'lz4k_encode backend_lz4k\n' > "$TMP/tree/out/kernel_aarch64/dist/zram.ko"
cp "$TMP/decoy.ko" "$TMP/real/common/kernel_aarch64/unstripped/zram.ko"

if find "$TMP/tree" -type f -name zram.ko | grep -q '/bazel-bin/'; then
  echo "plain find unexpectedly entered bazel-bin" >&2
  exit 1
fi

bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out"
grep -q 'kernel_aarch64/zram.ko' "$TMP/out/manifest.txt"
grep -q 'image_release=6.12.69-android16-6-gtest' "$TMP/out/manifest.txt"
grep -q 'vermagic=6.12.69-android16-6-gtest SMP preempt mod_unload ' "$TMP/out/manifest.txt"
grep -q 'zram_depends=zsmalloc' "$TMP/out/manifest.txt"
grep -q 'vendor_modules_checked=no' "$TMP/out/manifest.txt"
cmp "$TMP/zram.ko" "$TMP/out/zram.ko"
nm --defined-only "$TMP/out/zram.ko" | grep -q ' backend_lz4k$'
nm --defined-only "$TMP/out/zram.ko" | grep -q ' lz4k_encode$'

# A stripped-looking decoy at the preferred path must lose to the real unstripped module.
mkdir -p "$TMP/real/common/kernel_aarch64/unstripped"
cp "$TMP/zram.ko" "$TMP/real/common/kernel_aarch64/unstripped/zram.ko"
rm -f "$TMP/real/common/kernel_aarch64/zram.ko"
cp "$TMP/decoy.ko" "$TMP/real/common/kernel_aarch64/zram.ko"
rm -rf "$TMP/out2"
mkdir -p "$TMP/out2"
bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out2"
grep -q '/unstripped/zram.ko' "$TMP/out2/manifest.txt"
cmp "$TMP/zram.ko" "$TMP/out2/zram.ko"
ln -sfn "$TMP/zram.ko" "$TMP/real/common/kernel_aarch64/zram.ko"

# vermagic that does not match Image must fail
printf 'Linux version 6.12.69-other (kleaf@build-host)\n' > "$TMP/real/common/kernel_aarch64/Image"
rm -rf "$TMP/out"
mkdir -p "$TMP/out"
if bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out" 2>"$TMP/err"; then
  echo "accepted mismatched vermagic" >&2
  exit 1
fi
grep -q 'vermagic' "$TMP/err"

# string names without defined symbols must fail
printf 'Linux version 6.12.69-android16-6-gtest (kleaf@build-host)\n' \
  > "$TMP/real/common/kernel_aarch64/Image"
rm -f "$TMP/real/common/kernel_aarch64/zram.ko" \
  "$TMP/real/common/kernel_aarch64/unstripped/zram.ko"
cp "$TMP/decoy.ko" "$TMP/real/common/kernel_aarch64/zram.ko"
rm -rf "$TMP/out"
mkdir -p "$TMP/out"
if bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/tree" "$TMP/out" 2>"$TMP/err"; then
  echo "accepted a module without backend symbols" >&2
  exit 1
fi
grep -q 'backend_lz4k' "$TMP/err"

# no output directories means do not scan the source tree
rm -rf "$TMP/empty/src"
mkdir -p "$TMP/empty/src" "$TMP/out"
cp "$TMP/zram.ko" "$TMP/empty/src/zram.ko"
if bash "$ROOT/scripts/zram_612/collect_modules.sh" "$TMP/empty" "$TMP/out" 2>"$TMP/err"; then
  echo "searched the source tree for a module" >&2
  exit 1
fi
grep -q 'bazel-bin' "$TMP/err"

echo "zram module collector test passed"
