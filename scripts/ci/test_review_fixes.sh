#!/usr/bin/env bash
# 轻量回归：数据推送分支、无 workflow 权限时的回退、零/单/多产物布局、
# SUSFS 非致命 grep。不使用真实 secret，不访问 GitHub。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
assert() {
  local ok="$1"
  local msg="$2"
  if [ "$ok" = "1" ]; then
    echo "ok  $msg"
  else
    echo "FAIL $msg" >&2
    fail=1
  fi
}

bash -n "$ROOT/scripts/ci/publish_data_update.sh"
bash -n "$ROOT/scripts/ci/aggregate_rejects.sh"
bash -n "$ROOT/scripts/ci/normalize_single_artifact_dir.sh"
bash -n "$ROOT/scripts/ci/release_kernel_dirs.sh"
bash -n "$ROOT/scripts/susfs_fixes/apply.sh"
echo "ok  bash -n"

python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
files = [
    root / ".github/workflows/update-data.yml",
    root / ".github/workflows/main.yml",
    root / ".github/workflows/build.yml",
]
text = "\n".join(path.read_text(encoding="utf-8") for path in files)
# 只做结构检查：禁止残留的 origin main，并确认关键调用还在。
update = (root / ".github/workflows/update-data.yml").read_text(encoding="utf-8")
if "origin main" in update or "branches: [main]" in update:
    sys.exit("update-data.yml still references main")
for needle in (
    "branches: [dev]",
    "publish_data_update.sh",
    "HAS_WORKFLOW_PUSH_TOKEN",
    "secrets.WORKFLOW_PUSH_TOKEN != ''",
):
    if needle not in update:
        sys.exit(f"missing {needle}")
main = (root / ".github/workflows/main.yml").read_text(encoding="utf-8")
for needle in (
    "aggregate_rejects.sh",
    "normalize_single_artifact_dir.sh",
    "release_kernel_dirs.sh",
):
    if needle not in main:
        sys.exit(f"main.yml missing {needle}")
if "for dir in ./downloaded-artifacts/*/" in main:
    sys.exit("release upload still iterates raw download directories")
build = (root / ".github/workflows/build.yml").read_text(encoding="utf-8")
if "artifact-name.txt" not in build:
    sys.exit("build.yml does not record reject artifact name")
print("ok  workflow text checks")
PY

# --- SUSFS grep 无匹配不能中断 ---
sus_dir="$TMP/susfs"
mkdir -p "$sus_dir/fs"
printf '%s\n' 'void susfs_add_sus_path(void __user **user_info) { return; }' > "$sus_dir/fs/susfs.c"
set +e
(
  cd "$sus_dir"
  sed -n '535,578p' "$ROOT/scripts/susfs_fixes/apply.sh" | bash -eo pipefail
) >"$TMP/susfs.out" 2>&1
sus_status=$?
set -e
assert "$([ "$sus_status" -eq 0 ] && echo 1 || echo 0)" "susfs 函数体不匹配时补丁片段退出码为 0（实际 $sus_status）"
if grep -q '跳过回退' "$TMP/susfs.out"; then
  assert 1 "susfs 无匹配时打印跳过而不是失败"
else
  assert 0 "susfs 无匹配时打印跳过而不是失败"
fi
if grep -q '|| true' <(sed -n '575p' "$ROOT/scripts/susfs_fixes/apply.sh"); then
  assert 1 "apply.sh 第 575 行的 grep 带 || true"
else
  assert 0 "apply.sh 第 575 行的 grep 带 || true"
fi

# --- 产物布局 ---
layout="$TMP/layout"
mkdir -p "$layout/zero" "$layout/many/Aaa-AnyKernel3" "$layout/many/Bbb-Rejects" \
  "$layout/one-loose" "$layout/one-zip" "$layout/one-named" "$layout/module" "$layout/mixed"
printf 'boot\n' > "$layout/many/Aaa-AnyKernel3/anykernel.sh"
printf 'rej\n' > "$layout/many/Bbb-Rejects/index.txt"
printf 'boot\n' > "$layout/one-loose/anykernel.sh"
printf 'img\n' > "$layout/one-loose/Image"
printf 'zipbytes\n' > "$layout/one-zip/Foo-AnyKernel3.zip"
printf 'img\n' > "$layout/one-zip/boot.img"
printf 'boot\n' > "$layout/one-named/anykernel.sh"
printf 'prop\n' > "$layout/module/module.prop"
mkdir -p "$layout/mixed/Already-AnyKernel3"
printf 'boot\n' > "$layout/mixed/Already-AnyKernel3/anykernel.sh"
printf 'loose\n' > "$layout/mixed/loose.txt"

bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/zero"
assert "$([ ! -d "$layout/zero/kernel-AnyKernel3" ] && echo 1 || echo 0)" "零产物目录不被改写"

bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/many"
assert "$([ -f "$layout/many/Aaa-AnyKernel3/anykernel.sh" ] && [ -f "$layout/many/Bbb-Rejects/index.txt" ] && echo 1 || echo 0)" "多产物子目录保持不变"
many_kernels="$(bash "$ROOT/scripts/ci/release_kernel_dirs.sh" "$layout/many")"
assert "$([ "$many_kernels" = "$layout/many/Aaa-AnyKernel3" ] && echo 1 || echo 0)" "多产物时只列出内核目录（实际: $many_kernels）"

unset SINGLE_ARTIFACT_NAME GITHUB_RUN_ID GITHUB_REPOSITORY || true
bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/one-loose" >"$TMP/loose.out" 2>&1
assert "$([ -f "$layout/one-loose/kernel-AnyKernel3/anykernel.sh" ] && [ -f "$layout/one-loose/kernel-AnyKernel3/Image" ] && echo 1 || echo 0)" "单个散装内核产物被放进 kernel-AnyKernel3/"
loose_kernels="$(bash "$ROOT/scripts/ci/release_kernel_dirs.sh" "$layout/one-loose")"
assert "$([ "$loose_kernels" = "$layout/one-loose/kernel-AnyKernel3" ] && echo 1 || echo 0)" "摊平后的散装内核能被 Release 选中"

bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/one-zip"
assert "$([ -f "$layout/one-zip/Foo-AnyKernel3/Foo-AnyKernel3.zip" ] && [ -f "$layout/one-zip/Foo-AnyKernel3/boot.img" ] && echo 1 || echo 0)" "单个 zip 产物用 zip 文件名作为目录"
zip_kernels="$(bash "$ROOT/scripts/ci/release_kernel_dirs.sh" "$layout/one-zip")"
assert "$([ "$zip_kernels" = "$layout/one-zip/Foo-AnyKernel3" ] && echo 1 || echo 0)" "摊平后的 zip 内核能被 Release 选中"

SINGLE_ARTIFACT_NAME="Suki-AnyKernel3" bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/one-named"
assert "$([ -f "$layout/one-named/Suki-AnyKernel3/anykernel.sh" ] && echo 1 || echo 0)" "SINGLE_ARTIFACT_NAME 覆盖目录名"

SINGLE_ARTIFACT_NAME="susfs-1.2.3" bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/module"
assert "$([ -f "$layout/module/susfs-1.2.3/module.prop" ] && echo 1 || echo 0)" "摊平的单个模块目录使用给定产物名"

bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/mixed" >"$TMP/mixed.out" 2>&1
assert "$([ -f "$layout/mixed/Already-AnyKernel3/anykernel.sh" ] && [ -f "$layout/mixed/loose.txt" ] && echo 1 || echo 0)" "文件和产物子目录混在一起时不搬动"

fake_bin="$TMP/fakebin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "One" "Two"
EOF
chmod +x "$fake_bin/gh"
mkdir -p "$layout/gh-many"
printf 'boot\n' > "$layout/gh-many/anykernel.sh"
set +e
env PATH="$fake_bin:$PATH" GITHUB_RUN_ID="1" GITHUB_REPOSITORY="example/repo" SINGLE_ARTIFACT_NAME="" \
  bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/gh-many" >"$TMP/gh-many.out" 2>&1
gh_many_status=$?
set -e
assert "$([ "$gh_many_status" -eq 0 ] && [ -f "$layout/gh-many/anykernel.sh" ] && echo 1 || echo 0)" "gh 返回多个产物名时不搬动摊平目录"

cat > "$fake_bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "FromGh-AnyKernel3"
EOF
mkdir -p "$layout/gh-one"
printf 'boot\n' > "$layout/gh-one/anykernel.sh"
env PATH="$fake_bin:$PATH" GITHUB_RUN_ID="1" GITHUB_REPOSITORY="example/repo" SINGLE_ARTIFACT_NAME="" \
  bash "$ROOT/scripts/ci/normalize_single_artifact_dir.sh" "$layout/gh-one" >"$TMP/gh-one.out" 2>&1
assert "$([ -f "$layout/gh-one/FromGh-AnyKernel3/anykernel.sh" ] && echo 1 || echo 0)" "gh 返回唯一产物名时用该名称收拢目录"

# --- Rejects 汇总 ---
rej="$TMP/rej"
mkdir -p "$rej/none" "$rej/one" "$rej/multi/Ksu_kernel-a-Rejects" "$rej/multi/Ksu_kernel-b-Rejects"
printf 'fs/a.c\n' > "$rej/one/index.txt"
mkdir -p "$rej/one/fs"
printf 'conflict\n' > "$rej/one/fs/a.c.rej"
printf '%s\n' "Ksu_kernel-only-Rejects" > "$rej/one/artifact-name.txt"
printf 'a\n' > "$rej/multi/Ksu_kernel-a-Rejects/index.txt"
printf 'b\n' > "$rej/multi/Ksu_kernel-b-Rejects/index.txt"

bash "$ROOT/scripts/ci/aggregate_rejects.sh" "$rej/none" "$rej/none-out" "$rej/none.zip"
assert "$([ ! -f "$rej/none.zip" ] && echo 1 || echo 0)" "零个冲突产物不生成 zip"

bash "$ROOT/scripts/ci/aggregate_rejects.sh" "$rej/one" "$rej/one-out" "$rej/one.zip"
assert "$([ -f "$rej/one.zip" ] && echo 1 || echo 0)" "单个摊平冲突产物生成 zip"
if python3 - "$rej/one.zip" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
ok = any(n.startswith("Ksu_kernel-only/") and n.endswith("index.txt") for n in names)
sys.exit(0 if ok else 1)
PY
then
  assert 1 "单个冲突 zip 使用 artifact-name.txt 去掉 -Rejects 后的目录名"
else
  assert 0 "单个冲突 zip 使用 artifact-name.txt 去掉 -Rejects 后的目录名"
fi

bash "$ROOT/scripts/ci/aggregate_rejects.sh" "$rej/multi" "$rej/multi-out" "$rej/multi.zip"
if python3 - "$rej/multi.zip" <<'PY'
import sys, zipfile
names = set(zipfile.ZipFile(sys.argv[1]).namelist())
need = {"Ksu_kernel-a/index.txt", "Ksu_kernel-b/index.txt"}
sys.exit(0 if need <= names else 1)
PY
then
  assert 1 "多个冲突产物都进入同一个 zip"
else
  assert 0 "多个冲突产物都进入同一个 zip"
fi

# --- 数据推送：令牌缺失 / 存在，以及权限被拒绝 ---
init_repo() {
  local remote="$1" work="$2"
  git init --bare -q "$remote"
  git clone -q "$remote" "$work"
  git -C "$work" checkout -q -b dev
  mkdir -p "$work/data" "$work/.github/workflows"
  printf 'old\n' > "$work/data/version.txt"
  printf 'name: old\n' > "$work/.github/workflows/kernel-custom.yml"
  local wf
  for wf in kernel-a12-5-10 kernel-a13-5-10 kernel-a13-5-15 kernel-a14-5-15 \
            kernel-a14-6-1 kernel-a15-6-6 kernel-a16-6-12 kernel-a17-6-18; do
    printf 'name: old\n' > "$work/.github/workflows/$wf.yml"
  done
  git -C "$work" add data .github/workflows
  git -C "$work" -c user.email="t@example.com" -c user.name="t" commit -q -m init
  git -C "$work" push -q -u origin dev
}

install_deny_hook() {
  local remote="$1"
  cat > "$remote/hooks/pre-receive" <<'EOF'
#!/bin/bash
while read -r old new ref; do
  if git diff --name-only "$old" "$new" | grep -q '^\.github/workflows/'; then
    echo "refusing to allow a GitHub App to create or update workflow .github/workflows/kernel-a12-5-10.yml without workflows permission" >&2
    exit 1
  fi
done
EOF
  chmod +x "$remote/hooks/pre-receive"
}

dirty_both() {
  local work="$1"
  printf 'new\n' > "$work/data/version.txt"
  printf 'name: new\n' > "$work/.github/workflows/kernel-custom.yml"
}

run_publish() {
  local work="$1" token="$2" out="$3"
  (
    cd "$work"
    HAS_WORKFLOW_PUSH_TOKEN="$token" GIT_REMOTE=origin GIT_BRANCH=dev \
      bash "$ROOT/scripts/ci/publish_data_update.sh"
  ) >"$out" 2>&1
}

pub="$TMP/pub"
mkdir -p "$pub"

# 令牌缺失：data 推上去，workflow 保持旧内容
init_repo "$pub/no-token.git" "$pub/no-token"
dirty_both "$pub/no-token"
set +e
run_publish "$pub/no-token" false "$pub/no-token.out"
no_token_status=$?
set -e
assert "$([ "$no_token_status" -eq 0 ] && echo 1 || echo 0)" "未配置令牌时推送退出码为 0（实际 $no_token_status）"
git --git-dir="$pub/no-token.git" show dev:data/version.txt > "$pub/no-token-data.txt"
git --git-dir="$pub/no-token.git" show dev:.github/workflows/kernel-custom.yml > "$pub/no-token-wf.txt"
assert "$([ "$(cat "$pub/no-token-data.txt")" = "new" ] && echo 1 || echo 0)" "未配置令牌时 data/ 已更新"
assert "$([ "$(cat "$pub/no-token-wf.txt")" = "name: old" ] && echo 1 || echo 0)" "未配置令牌时 workflow 文件保持原样"
if grep -q 'WORKFLOW_PUSH_TOKEN' "$pub/no-token.out"; then
  assert 1 "未配置令牌时日志说明需要 WORKFLOW_PUSH_TOKEN"
else
  assert 0 "未配置令牌时日志说明需要 WORKFLOW_PUSH_TOKEN"
fi

# 令牌存在且远端接受 workflow
init_repo "$pub/with-token.git" "$pub/with-token"
dirty_both "$pub/with-token"
set +e
run_publish "$pub/with-token" true "$pub/with-token.out"
with_token_status=$?
set -e
assert "$([ "$with_token_status" -eq 0 ] && echo 1 || echo 0)" "有令牌且远端接受时退出码为 0（实际 $with_token_status）"
git --git-dir="$pub/with-token.git" show dev:data/version.txt > "$pub/with-token-data.txt"
git --git-dir="$pub/with-token.git" show dev:.github/workflows/kernel-custom.yml > "$pub/with-token-wf.txt"
assert "$([ "$(cat "$pub/with-token-data.txt")" = "new" ] && [ "$(cat "$pub/with-token-wf.txt")" = "name: new" ] && echo 1 || echo 0)" "有令牌时 data 和 workflow 都推送"

# 令牌存在但远端拒绝 workflow：回退为只推 data
init_repo "$pub/deny.git" "$pub/deny"
install_deny_hook "$pub/deny.git"
dirty_both "$pub/deny"
set +e
run_publish "$pub/deny" true "$pub/deny.out"
deny_status=$?
set -e
assert "$([ "$deny_status" -eq 0 ] && echo 1 || echo 0)" "令牌无 workflow 权限时回退推送退出码为 0（实际 $deny_status）"
git --git-dir="$pub/deny.git" show dev:data/version.txt > "$pub/deny-data.txt"
git --git-dir="$pub/deny.git" show dev:.github/workflows/kernel-custom.yml > "$pub/deny-wf.txt"
assert "$([ "$(cat "$pub/deny-data.txt")" = "new" ] && echo 1 || echo 0)" "权限被拒绝后 data/ 仍然更新"
assert "$([ "$(cat "$pub/deny-wf.txt")" = "name: old" ] && echo 1 || echo 0)" "权限被拒绝后 workflow 文件没有被推送"
if grep -q '改为只推送 data' "$pub/deny.out"; then
  assert 1 "权限被拒绝时日志说明已改为只推送 data"
else
  assert 0 "权限被拒绝时日志说明已改为只推送 data"
fi

# 没有变更
init_repo "$pub/clean.git" "$pub/clean"
set +e
run_publish "$pub/clean" false "$pub/clean.out"
clean_status=$?
set -e
assert "$([ "$clean_status" -eq 0 ] && echo 1 || echo 0)" "没有变更时退出码为 0"
if grep -q 'No data changes to commit.' "$pub/clean.out"; then
  assert 1 "没有变更时打印 No data changes to commit."
else
  assert 0 "没有变更时打印 No data changes to commit."
fi

if [ "$fail" -ne 0 ]; then
  echo "有测试失败" >&2
  exit 1
fi
echo "全部检查通过"
