#!/usr/bin/env bash
# Apply the 6.12 ZRAM adapter to the real android16-6.12-2026-03 zram
# sources plus the SukiSU-Nova codec tree. Fails if zram/zsmalloc would be
# built in, or if the backend table cannot be recognized.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -m py_compile "$ROOT/scripts/zram_612/apply.py"

python3 - <<PY
import base64, pathlib, urllib.request
base = "https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12-2026-03"
dest = pathlib.Path("$TMP/kernel/drivers/block/zram")
dest.mkdir(parents=True)
for name in ("Kconfig", "Makefile", "zcomp.c"):
    url = f"{base}/drivers/block/zram/{name}?format=TEXT"
    with urllib.request.urlopen(url, timeout=60) as resp:
        (dest / name).write_bytes(base64.b64decode(resp.read()))
print("fetched zram sources", dest)
PY

mkdir -p "$TMP/src"
curl -fsSL -o "$TMP/zram.tgz" https://codeload.github.com/SukiSU-Nova/SukiSU_patch/tar.gz/refs/heads/main
set +o pipefail
top="$(tar -tzf "$TMP/zram.tgz" | head -n 1 | cut -d/ -f1)"
set -o pipefail
[ -n "$top" ]
tar -xzf "$TMP/zram.tgz" -C "$TMP/src" "$top/other/zram"
PATCHES="$TMP/src/$top"

DEF="$TMP/kernel/arch/arm64/configs/gki_defconfig"
mkdir -p "$(dirname "$DEF")"
printf '%s\n' 'CONFIG_ZRAM=m' 'CONFIG_LOCALVERSION="-4k"' > "$DEF"
cp "$DEF" "$DEF.orig"
printf '%s\n' '"drivers/block/zram/zram.ko",' '"mm/zsmalloc.ko",' > "$TMP/kernel/modules.bzl"

python3 "$ROOT/scripts/zram_612/apply.py" \
  --kernel-root "$TMP/kernel" \
  --patches "$PATCHES" \
  --defconfig "$DEF"
python3 "$ROOT/scripts/zram_612/apply.py" \
  --kernel-root "$TMP/kernel" \
  --patches "$PATCHES" \
  --defconfig "$DEF"

zram="$TMP/kernel/drivers/block/zram"
grep -q 'backend_lz4kd' "$zram/zcomp.c" || { echo "missing backend in zcomp.c"; exit 1; }
grep -q 'config ZRAM_BACKEND_LZ4KD' "$zram/Kconfig" || { echo "missing kconfig symbol"; exit 1; }
grep -q 'lz4k_embed/huawei/lz4kd/lz4kd_encode.o' "$zram/Makefile" || { echo "missing object"; sed -n '1,40p' "$zram/Makefile"; exit 1; }
grep -q 'CFLAGS_lz4k_embed/huawei/lz4kd/lz4kd_encode.o += -DLZ4K_DELTA' "$zram/Makefile" || { echo "missing delta flag"; exit 1; }
test ! -f "$zram/lz4k_embed/oplus/lz4k.c" || { echo "crypto wrapper was copied"; exit 1; }
if grep -R --include='*.c' -n -E 'MODULE_LICENSE|module_init' "$zram/lz4k_embed" >/dev/null; then
  echo "codec copies still contain module metadata" >&2
  exit 1
fi
grep -q '^CONFIG_ZRAM=m$' "$DEF"
if grep -q '^CONFIG_ZRAM=y$' "$DEF"; then
  echo "defconfig built ZRAM in" >&2
  exit 1
fi
grep -q '^CONFIG_ZRAM_BACKEND_LZ4KD=y$' "$DEF"
grep -q '^CONFIG_ARM64_4K_PAGES=y$' "$DEF"
grep -q 'zram.ko' "$TMP/kernel/modules.bzl"
grep -q 'zsmalloc.ko' "$TMP/kernel/modules.bzl"

# The workflow fragment is the added defconfig lines. ZRAM=m must not appear there.
diff -u "$DEF.orig" "$DEF" > "$TMP/diff" || true
grep '^+' "$TMP/diff" | grep -v '^+++' > "$TMP/fragment" || true
if grep -q '^+CONFIG_ZRAM=y$' "$TMP/fragment" || grep -q '^+CONFIG_ZSMALLOC=y$' "$TMP/fragment"; then
  echo "fragment would builtin zram/zsmalloc" >&2
  exit 1
fi
grep -q '^+CONFIG_ARM64_4K_PAGES=y$' "$TMP/fragment"
grep -q '^+CONFIG_ZRAM_BACKEND_LZ4KD=y$' "$TMP/fragment"

bad="$TMP/bad"
mkdir -p "$bad/drivers/block/zram" "$bad/other"
cp "$zram/Kconfig" "$bad/drivers/block/zram/Kconfig"
printf '%s\n' 'not a backend table' > "$bad/drivers/block/zram/zcomp.c"
cp "$zram/Makefile" "$bad/drivers/block/zram/Makefile"
if python3 "$ROOT/scripts/zram_612/apply.py" --kernel-root "$bad" --patches "$PATCHES"; then
  echo "broken zcomp.c was accepted" >&2
  exit 1
fi

echo "zram 6.12 adapter test passed"
