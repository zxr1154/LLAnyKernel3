#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q source
git -C "$TMP/source" config user.email "pin@example.com"
git -C "$TMP/source" config user.name "pin"
printf 'VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 1\n' > "$TMP/source/Makefile"
git -C "$TMP/source" add Makefile
git -C "$TMP/source" commit -q -m base
OLD="$(git -C "$TMP/source" rev-parse HEAD)"
printf 'VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 69\n' > "$TMP/source/Makefile"
git -C "$TMP/source" commit -q -am tip
TIP="$(git -C "$TMP/source" rev-parse HEAD)"

git -C "$TMP" clone -q "$TMP/source" common
test "$(git -C "$TMP/common" rev-parse HEAD)" = "$TIP"

bash "$ROOT/scripts/ci/pin_gki_commit.sh" "$TMP/common" "$OLD"
test "$(git -C "$TMP/common" rev-parse HEAD)" = "$OLD"
grep -q 'SUBLEVEL = 1' "$TMP/common/Makefile"

if bash "$ROOT/scripts/ci/pin_gki_commit.sh" "$TMP/common" abc 2>"$TMP/err"; then
  echo "accepted a short commit" >&2
  exit 1
fi
grep -q '40' "$TMP/err"

echo "gki commit pin test passed"
