#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
HELPER="$ROOT/scripts/ci/integrate_rekernel.sh"
GIT="$(command -v git)"
CP="$(command -v cp)"
export REAL_GIT="$GIT" REAL_CP="$CP"

make_kernel() {
  mkdir -p "$1/common/drivers/rekernel" "$1/common/arch/arm64/configs"
  printf 'menu "Drivers"\nendmenu\n# user change\n' > "$1/common/drivers/Kconfig"
  printf '# user Makefile\n' > "$1/common/drivers/Makefile"
  printf '# user config\nCONFIG_REKERNEL=n\n' > "$1/common/arch/arm64/configs/gki_defconfig"
  printf 'preserve my old driver\n' > "$1/common/drivers/rekernel/user.txt"
}

make_source() {
  mkdir -p "$1/LKM-Source"
  printf 'obj-m := rekernel.o\nrekernel-y := rekernel_main.o rekernel_binder.o\n' > "$1/LKM-Source/Makefile"
  printf 'config REKERNEL\n\ttristate "Re-Kernel"\n\tdepends on MODULES\nconfig REKERNEL_NETWORK\n\tbool "Network"\n' > "$1/LKM-Source/Kconfig"
  printf '#include <linux/kprobes.h>\n#include <../android/binder_internal.h>\n' > "$1/LKM-Source/rekernel_binder.c"
  printf '/* main source */\n' > "$1/LKM-Source/rekernel_main.c"
  "$GIT" -C "$1" init -q
  "$GIT" -C "$1" -c user.name=test -c user.email=test@example.invalid add .
  "$GIT" -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
}

assert_original() {
  diff -ru "$TMP/original/common" "$1/common"
  if find "$1" -maxdepth 1 -name '.rekernel-integration.*' | grep -q .; then
    echo 'integration temporary directory leaked' >&2
    exit 1
  fi
}

make_kernel "$TMP/original"
make_source "$TMP/source"
mkdir -p "$TMP/fake-bin"
printf '#!/usr/bin/env bash\nif [ "${FAIL_CLONE:-0}" = 1 ]; then exit 73; fi\nexec "$REAL_GIT" "$@"\n' > "$TMP/fake-bin/git"
chmod +x "$TMP/fake-bin/git"

cp -a "$TMP/original" "$TMP/failed"
if PATH="$TMP/fake-bin:$PATH" FAIL_CLONE=1 SKIP_INCOMPATIBLE=false GITHUB_ENV="$TMP/failed.env" bash "$HELPER" "$TMP/failed" "$TMP/failed/common/arch/arm64/configs/gki_defconfig" > "$TMP/failed.log" 2>&1; then
  echo 'failed clone was accepted' >&2
  exit 1
fi
assert_original "$TMP/failed"
test ! -e "$TMP/failed.env"
echo 'ok failed clone is fatal and preserves all existing files'

cp -a "$TMP/original" "$TMP/skipped"
PATH="$TMP/fake-bin:$PATH" FAIL_CLONE=1 SKIP_INCOMPATIBLE=true GITHUB_ENV="$TMP/skipped.env" bash "$HELPER" "$TMP/skipped" "$TMP/skipped/common/arch/arm64/configs/gki_defconfig" > "$TMP/skipped.log" 2>&1
assert_original "$TMP/skipped"
grep -qx 'REKERNEL_SKIPPED=true' "$TMP/skipped.env"
echo 'ok allowed skip reports skipped only after restoring original files'

mkdir -p "$TMP/invalid"
"$GIT" -C "$TMP/invalid" init -q
printf 'bad upstream layout\n' > "$TMP/invalid/README"
"$GIT" -C "$TMP/invalid" add .
"$GIT" -C "$TMP/invalid" -c user.name=test -c user.email=test@example.invalid commit -qm invalid
cp -a "$TMP/original" "$TMP/layout"
if REKERNEL_REPO="$TMP/invalid" SKIP_INCOMPATIBLE=false GITHUB_ENV="$TMP/layout.env" bash "$HELPER" "$TMP/layout" "$TMP/layout/common/arch/arm64/configs/gki_defconfig" > "$TMP/layout.log" 2>&1; then
  echo 'invalid LKM-Source layout was accepted' >&2
  exit 1
fi
assert_original "$TMP/layout"
test ! -e "$TMP/layout.env"
echo 'ok invalid upstream layout cannot introduce dangling Kconfig references'

"$GIT" clone -q "$TMP/source" "$TMP/incomplete-source"
rm -- "$TMP/incomplete-source/LKM-Source/rekernel_main.c"
"$GIT" -C "$TMP/incomplete-source" -c user.name=test -c user.email=test@example.invalid commit -qam incomplete
cp -a "$TMP/original" "$TMP/incomplete"
if REKERNEL_REPO="$TMP/incomplete-source" SKIP_INCOMPATIBLE=false bash "$HELPER" "$TMP/incomplete" "$TMP/incomplete/common/arch/arm64/configs/gki_defconfig" > "$TMP/incomplete.log" 2>&1; then
  echo 'missing source file from the upstream object list was accepted' >&2
  exit 1
fi
assert_original "$TMP/incomplete"
echo 'ok all driver objects must have corresponding source files'

# Simulate a copy failure after the driver and Kconfig have already been changed.
printf '#!/usr/bin/env bash\ncase "${3:-}" in */makefile.new) exit 74 ;; esac\nexec "$REAL_CP" "$@"\n' > "$TMP/fake-bin/cp"
chmod +x "$TMP/fake-bin/cp"
cp -a "$TMP/original" "$TMP/rollback"
if PATH="$TMP/fake-bin:$PATH" REKERNEL_REPO="$TMP/source" SKIP_INCOMPATIBLE=false GITHUB_ENV="$TMP/rollback.env" bash "$HELPER" "$TMP/rollback" "$TMP/rollback/common/arch/arm64/configs/gki_defconfig" > "$TMP/rollback.log" 2>&1; then
  echo 'injected mid-install copy failure was accepted' >&2
  exit 1
fi
assert_original "$TMP/rollback"
test ! -e "$TMP/rollback.env"
echo 'ok mid-install failure restores the old driver and pre-existing user changes'

cp -a "$TMP/original" "$TMP/success"
REKERNEL_REPO="$TMP/source" SKIP_INCOMPATIBLE=false GITHUB_ENV="$TMP/success.env" bash "$HELPER" "$TMP/success" "$TMP/success/common/arch/arm64/configs/gki_defconfig"
grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel.o' "$TMP/success/common/drivers/rekernel/Makefile"
grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' "$TMP/success/common/drivers/rekernel/Makefile"
! grep -q 'depends on MODULES' "$TMP/success/common/drivers/rekernel/Kconfig"
grep -qF '#include "../android/binder_internal.h"' "$TMP/success/common/drivers/rekernel/rekernel_binder.c"
grep -qF '#include <linux/seq_file.h>' "$TMP/success/common/drivers/rekernel/rekernel_binder.c"
grep -qx 'CONFIG_REKERNEL=y' "$TMP/success/common/arch/arm64/configs/gki_defconfig"
grep -qx 'CONFIG_REKERNEL_NETWORK=y' "$TMP/success/common/arch/arm64/configs/gki_defconfig"
test ! -e "$TMP/success.env"
# Running the integration again does not duplicate tree references or options.
REKERNEL_REPO="$TMP/source" bash "$HELPER" "$TMP/success" "$TMP/success/common/arch/arm64/configs/gki_defconfig"
test "$(grep -cF 'source "drivers/rekernel/Kconfig"' "$TMP/success/common/drivers/Kconfig")" -eq 1
test "$(grep -cF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$TMP/success/common/drivers/Makefile")" -eq 1
test "$(grep -c '^CONFIG_REKERNEL=y$' "$TMP/success/common/arch/arm64/configs/gki_defconfig")" -eq 1
echo 'ok successful integration is in-tree, enables the requested options, and is idempotent'
