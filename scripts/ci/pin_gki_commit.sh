#!/usr/bin/env bash
# Check out one kernel/common commit after repo sync.
# The caller passes the common project directory and a full 40-character SHA.
set -euo pipefail

COMMON_DIR="${1:?kernel/common directory}"
WANT="$(printf '%s' "${2:?commit}" | tr '[:upper:]' '[:lower:]')"

if [[ ! "$WANT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::gki_commit 必须是 40 位十六进制提交，实际为: ${2}" >&2
  exit 1
fi
if [[ ! -d "$COMMON_DIR/.git" && ! -f "$COMMON_DIR/.git" ]]; then
  echo "::error::${COMMON_DIR} 不是 git 检出，无法固定 kernel/common。" >&2
  exit 1
fi

git -C "$COMMON_DIR" rev-parse --is-inside-work-tree >/dev/null
BEFORE="$(git -C "$COMMON_DIR" rev-parse HEAD)"
echo "同步后的 kernel/common: $BEFORE"

if ! git -C "$COMMON_DIR" cat-file -e "${WANT}^{commit}" 2>/dev/null; then
  REMOTE="$(git -C "$COMMON_DIR" remote | head -n 1)"
  if [[ -z "$REMOTE" ]]; then
    echo "::error::kernel/common 没有远程，无法获取 $WANT" >&2
    exit 1
  fi
  git -C "$COMMON_DIR" fetch --depth=1 "$REMOTE" "$WANT"
fi

git -C "$COMMON_DIR" checkout --detach "$WANT"
AFTER="$(git -C "$COMMON_DIR" rev-parse HEAD)"
if [[ "$AFTER" != "$WANT" ]]; then
  echo "::error::固定失败：HEAD=$AFTER，要求 $WANT" >&2
  exit 1
fi

if [[ -f "$COMMON_DIR/Makefile" ]]; then
  VERSION="$(awk '/^VERSION =/{print $3; exit}' "$COMMON_DIR/Makefile")"
  PATCHLEVEL="$(awk '/^PATCHLEVEL =/{print $3; exit}' "$COMMON_DIR/Makefile")"
  SUBLEVEL="$(awk '/^SUBLEVEL =/{print $3; exit}' "$COMMON_DIR/Makefile")"
  echo "固定后的 Makefile: ${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
fi
echo "已固定 kernel/common: $BEFORE -> $AFTER"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "GKI_COMMON_HEAD=$AFTER" >> "$GITHUB_ENV"
fi
