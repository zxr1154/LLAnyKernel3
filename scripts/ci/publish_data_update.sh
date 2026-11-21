#!/usr/bin/env bash
# 提交并推送 GKI 版本数据。
#
# .github/workflows 只有带 workflow 权限的 PAT（secret: WORKFLOW_PUSH_TOKEN）
# 才能推送。未配置时，或令牌被 GitHub 以缺少 workflows 权限拒绝时，仍推送 data/，
# 并在日志里说明 workflow 选择/矩阵没有上传。
#
# 环境变量:
#   HAS_WORKFLOW_PUSH_TOKEN  true 表示配置了 WORKFLOW_PUSH_TOKEN；其他值视为未配置
#   GIT_REMOTE               默认 origin
#   GIT_BRANCH               默认 dev
#
# 必须在仓库根目录执行。不读取、不打印任何 secret。

set -euo pipefail

REMOTE="${GIT_REMOTE:-origin}"
BRANCH="${GIT_BRANCH:-dev}"
HAS_TOKEN="${HAS_WORKFLOW_PUSH_TOKEN:-false}"

WORKFLOW_PATHS=(
  .github/workflows/kernel-custom.yml
  .github/workflows/kernel-a12-5-10.yml
  .github/workflows/kernel-a13-5-10.yml
  .github/workflows/kernel-a13-5-15.yml
  .github/workflows/kernel-a14-5-15.yml
  .github/workflows/kernel-a14-6-1.yml
  .github/workflows/kernel-a15-6-6.yml
  .github/workflows/kernel-a16-6-12.yml
  .github/workflows/kernel-a17-6-18.yml
)

notice() {
  echo "::notice title=GKI 数据更新::$1"
}

warn() {
  echo "::warning title=GKI 数据更新::$1"
}

token_hint() {
  warn "未推送 workflow 选择/矩阵。GITHUB_TOKEN 不能修改 .github/workflows，本次只处理 data/。WORKFLOW_PUSH_TOKEN 是可选项；本次运行没有使用它。若要一并推送 kernel-custom 下拉和构建矩阵，请配置具有 workflow 权限的 PAT，secret 名仍为 WORKFLOW_PUSH_TOKEN。"
}

workflow_dirty() {
  if ! git diff --quiet -- "${WORKFLOW_PATHS[@]}"; then
    return 0
  fi
  if ! git diff --cached --quiet -- "${WORKFLOW_PATHS[@]}"; then
    return 0
  fi
  return 1
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

workflows_changed=false
if workflow_dirty; then
  workflows_changed=true
fi

git add -- data/

included_workflows=false
if [ "$HAS_TOKEN" = "true" ]; then
  git add -- "${WORKFLOW_PATHS[@]}"
  included_workflows=true
  notice "已配置 WORKFLOW_PUSH_TOKEN，将尝试同时推送 data/ 与 workflow 选择/矩阵。"
else
  notice "未配置 WORKFLOW_PUSH_TOKEN，本次只暂存 data/。"
fi

if git diff --cached --quiet; then
  if [ "$workflows_changed" = "true" ] && [ "$HAS_TOKEN" != "true" ]; then
    token_hint
  else
    echo "No data changes to commit."
  fi
  exit 0
fi

git commit -m "chore: update GKI kernel version data"

try_publish() {
  local log="$1"
  if ! git pull --rebase --autostash "$REMOTE" "$BRANCH" >"$log" 2>&1; then
    return 2
  fi
  if ! git push "$REMOTE" "HEAD:${BRANCH}" >>"$log" 2>&1; then
    return 1
  fi
  return 0
}

is_workflow_permission_denial() {
  grep -Eq 'workflows permission|without `?workflow' "$1"
}

publish_log="$(mktemp)"
set +e
try_publish "$publish_log"
publish_status=$?
set -e
cat "$publish_log"

if [ "$publish_status" -eq 0 ]; then
  if [ "$included_workflows" = "true" ] && [ "$workflows_changed" = "true" ]; then
    notice "已推送 data/ 与 workflow 选择/矩阵。"
  else
    notice "已推送 data/。"
    if [ "$workflows_changed" = "true" ]; then
      token_hint
    fi
  fi
  rm -f "$publish_log"
  exit 0
fi

if [ "$publish_status" -eq 2 ] || [ "$included_workflows" != "true" ] || ! is_workflow_permission_denial "$publish_log"; then
  echo "::error::推送 data/ 到 ${REMOTE}/${BRANCH} 失败"
  rm -f "$publish_log"
  exit 1
fi

warn "WORKFLOW_PUSH_TOKEN 无法修改 workflow 文件，改为只推送 data/。请改用带 workflow 权限的 PAT。"
rm -f "$publish_log"

git reset --soft HEAD~1
git reset -q HEAD -- .github/workflows
git checkout -q -- .github/workflows
git add -- data/

if git diff --cached --quiet; then
  token_hint
  echo "没有可单独推送的 data/ 变更。"
  exit 0
fi

git commit -m "chore: update GKI kernel version data"
data_log="$(mktemp)"
set +e
try_publish "$data_log"
data_status=$?
set -e
cat "$data_log"
rm -f "$data_log"
if [ "$data_status" -ne 0 ]; then
  echo "::error::回退后推送 data/ 仍然失败"
  exit 1
fi
notice "已只推送 data/。workflow 选择/矩阵未更新。"
exit 0
