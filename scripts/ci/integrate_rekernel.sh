#!/usr/bin/env bash
# Usage: bash integrate_rekernel.sh KERNEL_ROOT DEFCONFIG
# REKERNEL_REPO may override the upstream URL (also useful for offline tests).
set -Eeuo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 KERNEL_ROOT DEFCONFIG" >&2
  exit 2
fi

KERNEL_ROOT="$(realpath -e -- "$1")"
DEFCONFIG="$(realpath -e -- "$2")"
DRIVERS="$KERNEL_ROOT/common/drivers"
TARGET="$DRIVERS/rekernel"
WORK="$(mktemp -d "$KERNEL_ROOT/.rekernel-integration.XXXXXXXX")"
COMMITTED=false
DRIVER_MOVED=false
DRIVER_INSTALLED=false
KCONFIG_CHANGED=false
MAKEFILE_CHANGED=false
DEFCONFIG_CHANGED=false
ERROR_REASON=""

rollback() {
  local failed=0
  if [ "$DEFCONFIG_CHANGED" = true ]; then
    cp -p -- "$WORK/defconfig.original" "$DEFCONFIG" && DEFCONFIG_CHANGED=false || failed=1
  fi
  if [ "$MAKEFILE_CHANGED" = true ]; then
    cp -p -- "$WORK/makefile.original" "$DRIVERS/Makefile" && MAKEFILE_CHANGED=false || failed=1
  fi
  if [ "$KCONFIG_CHANGED" = true ]; then
    cp -p -- "$WORK/kconfig.original" "$DRIVERS/Kconfig" && KCONFIG_CHANGED=false || failed=1
  fi
  if [ "$DRIVER_INSTALLED" = true ]; then
    # TARGET is fixed beneath the verified kernel root, never a user-provided glob.
    rm -rf -- "$TARGET" && DRIVER_INSTALLED=false || failed=1
  fi
  if [ "$DRIVER_MOVED" = true ] && [ "$DRIVER_INSTALLED" = false ]; then
    mv -- "$WORK/driver.original" "$TARGET" && DRIVER_MOVED=false || failed=1
  fi
  return "$failed"
}

on_exit() {
  local status=$?
  trap - ERR EXIT
  set +e
  if [ "$COMMITTED" != true ] && ! rollback; then
    echo "::error::Re-Kernel rollback failed; preserved backup at $WORK" >&2
    exit 1
  fi
  case "$WORK" in
    "$KERNEL_ROOT"/.rekernel-integration.*) rm -rf -- "$WORK" ;;
  esac
  exit "$status"
}

on_error() {
  local status="$1" line="$2"
  trap - ERR
  set +e
  echo "Re-Kernel integration failed at line $line${ERROR_REASON:+: $ERROR_REASON}" >&2
  if ! rollback; then
    # Do not turn an incomplete rollback into a successful skipped feature.
    echo "::error::Re-Kernel rollback failed; preserved backup at $WORK" >&2
    trap - EXIT
    exit 1
  fi
  if [ "${SKIP_INCOMPATIBLE:-false}" = true ]; then
    echo "::warning title=Re-Kernel skipped::Integration failed; original files restored"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf '\n> Re-Kernel was skipped after integration failed; original files were restored.\n' >> "$GITHUB_STEP_SUMMARY" || exit 1
    fi
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'REKERNEL_SKIPPED=true\n' >> "$GITHUB_ENV" || exit 1
    fi
    exit 0
  fi
  echo "::error::Re-Kernel integration failed; original files restored" >&2
  exit "$status"
}

die() {
  ERROR_REASON="$*"
  on_error 1 "${BASH_LINENO[0]}"
}

trap on_exit EXIT
trap 'on_error "$?" "$LINENO"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$DRIVERS" ] || die "missing common/drivers"
case "$DEFCONFIG" in
  "$KERNEL_ROOT"/common/*) ;;
  *) die "DEFCONFIG must be inside KERNEL_ROOT/common" ;;
esac
for file in "$DRIVERS/Kconfig" "$DRIVERS/Makefile" "$DEFCONFIG"; do
  [ -f "$file" ] && [ ! -L "$file" ] || die "not a regular file: $file"
done
[ ! -L "$TARGET" ] || die "refusing to replace a symlink: $TARGET"
[ ! -e "$TARGET" ] || [ -d "$TARGET" ] || die "driver destination is not a directory"

echo "Integrating Re-Kernel..."
# This helper runs in its own Bash process: a failed clone cannot be masked by an
# outer `if ( set -e ... )` conditional disabling errexit throughout the block.
git clone --depth 1 "${REKERNEL_REPO:-https://github.com/Sakion-Team/Re-Kernel.git}" "$WORK/upstream"
SOURCE="$WORK/upstream/LKM-Source"
for file in Makefile Kconfig rekernel_binder.c; do
  [ -f "$SOURCE/$file" ] || die "upstream LKM-Source is missing $file"
done
grep -qE '^obj-m[[:space:]]*[:+]?=[[:space:]]*rekernel\.o[[:space:]]*$' "$SOURCE/Makefile" || die "unsupported upstream Makefile"
OBJECT_LIST="$(sed -nE 's/^rekernel-y[[:space:]]*[:+]?=[[:space:]]*//p' "$SOURCE/Makefile")"
[ -n "$OBJECT_LIST" ] || die "upstream Makefile does not list the driver objects"
read -r -a OBJECTS <<< "${OBJECT_LIST//$'\n'/ }"
for object in "${OBJECTS[@]}"; do
  [[ "$object" =~ ^[[:alnum:]_][[:alnum:]_./-]*\.o$ ]] || die "unsupported upstream object: $object"
  case "$object" in ../*|*/../*) die "upstream object escapes LKM-Source: $object" ;; esac
  [ -f "$SOURCE/${object%.o}.c" ] || [ -f "$SOURCE/${object%.o}.S" ] || die "missing source for upstream object $object"
done
for symbol in REKERNEL REKERNEL_NETWORK; do
  grep -qE "^[[:space:]]*config[[:space:]]+$symbol([[:space:]]|$)" "$SOURCE/Kconfig" || die "missing upstream Kconfig symbol $symbol"
done

# Prepare and validate every changed file before touching the kernel tree.
cp -a -- "$SOURCE" "$WORK/driver.new"
sed -i -E 's/^obj-m[[:space:]]*[:+]?=[[:space:]]*rekernel\.o[[:space:]]*$/obj-$(CONFIG_REKERNEL) += rekernel.o/' "$WORK/driver.new/Makefile"
grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel.o' "$WORK/driver.new/Makefile" || die "failed to adapt upstream Makefile"
if ! grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' "$WORK/driver.new/Makefile"; then
  printf '\n%s\n' 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' >> "$WORK/driver.new/Makefile"
fi
sed -i '/^[[:space:]]*depends on MODULES[[:space:]]*$/d' "$WORK/driver.new/Kconfig"
sed -i 's|#include <../android/binder_internal.h>|#include "../android/binder_internal.h"|g' "$WORK/driver.new/rekernel_binder.c"
if ! grep -qF '#include <linux/seq_file.h>' "$WORK/driver.new/rekernel_binder.c"; then
  sed -i '1i #include <linux/seq_file.h>' "$WORK/driver.new/rekernel_binder.c"
fi

cp -p -- "$DRIVERS/Kconfig" "$WORK/kconfig.original"
cp -p -- "$DRIVERS/Makefile" "$WORK/makefile.original"
cp -p -- "$DEFCONFIG" "$WORK/defconfig.original"
cp -p -- "$WORK/kconfig.original" "$WORK/kconfig.new"
cp -p -- "$WORK/makefile.original" "$WORK/makefile.new"
cp -p -- "$WORK/defconfig.original" "$WORK/defconfig.new"
if ! grep -qE '^[[:space:]]*source[[:space:]]+"drivers/rekernel/Kconfig"([[:space:]]|$)' "$WORK/kconfig.new"; then
  printf '\n%s\n' 'source "drivers/rekernel/Kconfig"' >> "$WORK/kconfig.new"
fi
if ! grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$WORK/makefile.new"; then
  printf '\n%s\n' 'obj-$(CONFIG_REKERNEL) += rekernel/' >> "$WORK/makefile.new"
fi
sed -i '/^CONFIG_REKERNEL=/d; /^CONFIG_REKERNEL_NETWORK=/d; /^# CONFIG_REKERNEL is not set$/d; /^# CONFIG_REKERNEL_NETWORK is not set$/d' "$WORK/defconfig.new"
printf '\nCONFIG_REKERNEL=y\nCONFIG_REKERNEL_NETWORK=y\n' >> "$WORK/defconfig.new"

if [ -e "$TARGET" ]; then
  mv -- "$TARGET" "$WORK/driver.original"
  DRIVER_MOVED=true
fi
mv -- "$WORK/driver.new" "$TARGET"
DRIVER_INSTALLED=true
KCONFIG_CHANGED=true
cp -p -- "$WORK/kconfig.new" "$DRIVERS/Kconfig"
MAKEFILE_CHANGED=true
cp -p -- "$WORK/makefile.new" "$DRIVERS/Makefile"
DEFCONFIG_CHANGED=true
cp -p -- "$WORK/defconfig.new" "$DEFCONFIG"
COMMITTED=true
echo "[+] Re-Kernel integration completed"
