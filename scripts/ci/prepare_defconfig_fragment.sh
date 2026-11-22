#!/usr/bin/env bash
# Preserve the prepared defconfig before Kleaf restores its unmodified baseline.
# Usage: prepare_defconfig_fragment.sh BASELINE DEFCONFIG FRAGMENT STATE_DIR BUILD_ID
# BUILD_ID must identify this job/run attempt, and stay the same for timeout retries.
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 BASELINE DEFCONFIG FRAGMENT STATE_DIR BUILD_ID" >&2
  exit 2
fi

BASELINE="$1"
DEFCONFIG="$2"
FRAGMENT="$3"
STATE_DIR="$4"
BUILD_ID="$5"

fail() {
  echo "::error::$*" >&2
  exit 1
}

[[ "$BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid fragment build ID: $BUILD_ID"
[[ -f "$BASELINE" ]] || fail "Missing baseline defconfig: $BASELINE"
[[ -f "$DEFCONFIG" ]] || fail "Missing prepared defconfig: $DEFCONFIG"
[[ "$BASELINE" != "$DEFCONFIG" && "$FRAGMENT" != "$BASELINE" && "$FRAGMENT" != "$DEFCONFIG" ]] || fail "Defconfig and fragment paths must be distinct"

mkdir -p "$STATE_DIR" "$(dirname "$FRAGMENT")"
SNAPSHOT_DIR="$STATE_DIR/$BUILD_ID"
STAGING_DIR=""
FRAGMENT_TMP=""
cleanup() {
  if [[ -n "$STAGING_DIR" ]]; then
    rm -f -- "$STAGING_DIR/baseline" "$STAGING_DIR/prepared"
    rmdir -- "$STAGING_DIR"
  fi
  if [[ -n "$FRAGMENT_TMP" ]]; then
    rm -f -- "$FRAGMENT_TMP"
  fi
}
trap cleanup EXIT

if [[ ! -e "$SNAPSHOT_DIR" ]]; then
  # Publish both snapshots before restoring DEFCONFIG, so a retry always has
  # the feature-bearing input even if the first Bazel invocation times out.
  STAGING_DIR="$(mktemp -d "$STATE_DIR/.prepare-defconfig.XXXXXX")"
  cp -- "$BASELINE" "$STAGING_DIR/baseline"
  cp -- "$DEFCONFIG" "$STAGING_DIR/prepared"
  mv -T -- "$STAGING_DIR" "$SNAPSHOT_DIR"
  STAGING_DIR=""
fi

[[ -f "$SNAPSHOT_DIR/baseline" && -f "$SNAPSHOT_DIR/prepared" ]] || fail "Incomplete fragment state: $SNAPSHOT_DIR"
cmp -s -- "$BASELINE" "$SNAPSHOT_DIR/baseline" || fail "Baseline defconfig changed during this build"
if ! cmp -s -- "$DEFCONFIG" "$SNAPSHOT_DIR/baseline" && ! cmp -s -- "$DEFCONFIG" "$SNAPSHOT_DIR/prepared"; then
  fail "Prepared defconfig changed after its fragment was saved"
fi

# GNU diff's formats select only added/replacement lines, including Kconfig
# unset directives, without diff headers or line-number-dependent output.
FRAGMENT_TMP="$(mktemp "${FRAGMENT}.tmp.XXXXXX")"
DIFF_STATUS=0
diff --old-line-format='' --unchanged-line-format='' --new-line-format='%L' \
  "$SNAPSHOT_DIR/baseline" "$SNAPSHOT_DIR/prepared" > "$FRAGMENT_TMP" || DIFF_STATUS=$?
[[ "$DIFF_STATUS" -le 1 ]] || fail "Could not generate defconfig fragment"
mv -- "$FRAGMENT_TMP" "$FRAGMENT"
FRAGMENT_TMP=""
cp -- "$SNAPSHOT_DIR/baseline" "$DEFCONFIG"
echo "Defconfig fragment preserved for $BUILD_ID: $FRAGMENT"
