#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE="$ROOT/scripts/ci/prepare_defconfig_fragment.sh"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/defconfig-fragment-test.XXXXXX")"
trap 'rm -f -- "$FIXTURE_DIR"/baseline "$FIXTURE_DIR"/defconfig "$FIXTURE_DIR"/fragment "$FIXTURE_DIR"/expected "$FIXTURE_DIR"/first-fragment "$FIXTURE_DIR"/err; find "$FIXTURE_DIR/state" -type f -delete; find "$FIXTURE_DIR/state" -depth -type d -empty -delete; rmdir -- "$FIXTURE_DIR"' EXIT

BASELINE="$FIXTURE_DIR/baseline"
DEFCONFIG="$FIXTURE_DIR/defconfig"
FRAGMENT="$FIXTURE_DIR/fragment"
STATE_DIR="$FIXTURE_DIR/state"
mkdir "$STATE_DIR"

printf '%s\n' 'CONFIG_ARM64_4K_PAGES=y' 'CONFIG_ZRAM=m' '# CONFIG_KPM is not set' 'CONFIG_TEST=y' > "$BASELINE"
printf '%s\n' 'CONFIG_ARM64_4K_PAGES=y' 'CONFIG_ZRAM=m' 'CONFIG_KPM=y' '# CONFIG_TEST is not set' 'CONFIG_ZRAM_BACKEND_LZ4KD=y' > "$DEFCONFIG"
printf '%s\n' 'CONFIG_KPM=y' '# CONFIG_TEST is not set' 'CONFIG_ZRAM_BACKEND_LZ4KD=y' > "$FIXTURE_DIR/expected"

# The first attempt extracts feature changes and restores the untouched base.
bash "$PREPARE" "$BASELINE" "$DEFCONFIG" "$FRAGMENT" "$STATE_DIR" run-1-attempt-1-job
cmp "$BASELINE" "$DEFCONFIG"
cmp "$FIXTURE_DIR/expected" "$FRAGMENT"
cp "$FRAGMENT" "$FIXTURE_DIR/first-fragment"

# Bazel times out after the base has been restored. A retry must keep all
# features, and must also recreate a lost/overwritten fragment deterministically.
printf '%s\n' 'stale fragment' > "$FRAGMENT"
bash "$PREPARE" "$BASELINE" "$DEFCONFIG" "$FRAGMENT" "$STATE_DIR" run-1-attempt-1-job
cmp "$BASELINE" "$DEFCONFIG"
cmp "$FIXTURE_DIR/first-fragment" "$FRAGMENT"
grep -qx 'CONFIG_KPM=y' "$FRAGMENT"
grep -qx 'CONFIG_ZRAM_BACKEND_LZ4KD=y' "$FRAGMENT"

# An unrelated job/run attempt sharing the state directory captures its own
# prepared input instead of reviving the previous run's KPM/ZRAM options.
cp "$BASELINE" "$DEFCONFIG"
printf '%s\n' 'CONFIG_FRESH_BUILD=y' >> "$DEFCONFIG"
printf '%s\n' 'CONFIG_FRESH_BUILD=y' > "$FIXTURE_DIR/expected"
bash "$PREPARE" "$BASELINE" "$DEFCONFIG" "$FRAGMENT" "$STATE_DIR" run-1-attempt-2-job
cmp "$BASELINE" "$DEFCONFIG"
cmp "$FIXTURE_DIR/expected" "$FRAGMENT"

# Reject changes made after capture rather than silently discard new options.
printf '%s\n' 'CONFIG_UNEXPECTED=y' >> "$DEFCONFIG"
if bash "$PREPARE" "$BASELINE" "$DEFCONFIG" "$FRAGMENT" "$STATE_DIR" run-1-attempt-2-job 2> "$FIXTURE_DIR/err"; then
  echo "Accepted modified prepared defconfig" >&2
  exit 1
fi
grep -q 'Prepared defconfig changed' "$FIXTURE_DIR/err"
grep -qx 'CONFIG_UNEXPECTED=y' "$DEFCONFIG"
cmp "$FIXTURE_DIR/expected" "$FRAGMENT"

# Detect drift of the original baseline before reusing cached preparation.
cp "$BASELINE" "$DEFCONFIG"
printf '%s\n' 'CONFIG_BASELINE_CHANGED=y' >> "$BASELINE"
if bash "$PREPARE" "$BASELINE" "$DEFCONFIG" "$FRAGMENT" "$STATE_DIR" run-1-attempt-2-job 2> "$FIXTURE_DIR/err"; then
  echo "Accepted modified baseline defconfig" >&2
  exit 1
fi
grep -q 'Baseline defconfig changed' "$FIXTURE_DIR/err"
cmp "$FIXTURE_DIR/expected" "$FRAGMENT"

echo "defconfig fragment retry tests passed"
