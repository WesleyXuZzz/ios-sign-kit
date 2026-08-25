#!/bin/zsh

set -euo pipefail

export LC_ALL=C
export GIT_NO_LAZY_FETCH=1
export GIT_NO_REPLACE_OBJECTS=1

SCRIPT_DIRECTORY="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
PUBLIC_REMOTE="origin"
PRIVATE_REMOTE="private"
TARGET_BRANCH="master"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./scripts/push-source-mirrors.sh [options]

将当前 master 的同一提交依次推送到私有镜像 remote `private` 和 GitHub
remote `origin`，随后重新读取两端 master OID。两端都等于本地 HEAD 时才成功。

Options:
  --dry-run                 只执行公开源码检查和两端 push 预检
  --repository DIRECTORY    指定仓库根目录，主要用于测试
  -h, --help                显示帮助

脚本不配置 remote，不执行 force、pull、fetch、merge 或 rebase。
EOF
}

fail() {
  echo "双镜像推送失败：$1" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --repository)
      (( $# >= 2 )) || fail "--repository 缺少目录参数。"
      REPOSITORY_ROOT="${2:A}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数 $1。使用 --help 查看用法。"
      ;;
  esac
done

[[ -d "$REPOSITORY_ROOT" ]] || fail "仓库目录不存在。"
[[ -f "$SCRIPT_DIRECTORY/verify-public-source.sh" \
  && ! -L "$SCRIPT_DIRECTORY/verify-public-source.sh" ]] \
  || fail "缺少 scripts/verify-public-source.sh。"
command -v git >/dev/null 2>&1 || fail "找不到 git。"

git_repository() {
  command git -C "$REPOSITORY_ROOT" "$@"
}

TOP_LEVEL="$(git_repository rev-parse --show-toplevel 2>/dev/null)" \
  || fail "指定目录不是 Git 仓库。"
[[ "${TOP_LEVEL:A}" == "${REPOSITORY_ROOT:A}" ]] \
  || fail "--repository 必须指向仓库根目录。"

if [[ -n "$(git_repository status --porcelain --untracked-files=all)" ]]; then
  fail "工作区不干净；拒绝执行检查器或推送。"
fi

CURRENT_BRANCH="$(git_repository branch --show-current)"
[[ "$CURRENT_BRANCH" == "$TARGET_BRANCH" ]] \
  || fail "只能从本地 master 推送；当前分支为 ${CURRENT_BRANCH:-<detached>}。"

LOCAL_COMMIT="$(
  git_repository rev-parse --verify "refs/heads/${TARGET_BRANCH}^{commit}"
)" || fail "无法解析本地 master 提交。"

count_nonempty_lines() {
  print -r -- "$1" \
    | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
}

resolve_remote_urls() {
  local REMOTE_NAME="$1"
  local CONFIGURED_FETCH_URL=""
  local FETCH_URL_COUNT=""
  local EFFECTIVE_FETCH_URL=""
  local EFFECTIVE_FETCH_URL_COUNT=""
  local CONFIGURED_PUSH_URL=""
  local PUSH_URL_COUNT=""
  local EFFECTIVE_PUSH_URL=""
  local EFFECTIVE_PUSH_URL_COUNT=""

  CONFIGURED_FETCH_URL="$(
    git_repository config --get-all "remote.${REMOTE_NAME}.url" 2>/dev/null || true
  )"
  FETCH_URL_COUNT="$(count_nonempty_lines "$CONFIGURED_FETCH_URL")"
  [[ "$FETCH_URL_COUNT" == "1" ]] \
    || fail "$REMOTE_NAME 必须且只能配置一个 fetch URL。"

  EFFECTIVE_FETCH_URL="$(
    git_repository remote get-url --all "$REMOTE_NAME" 2>/dev/null || true
  )"
  EFFECTIVE_FETCH_URL_COUNT="$(count_nonempty_lines "$EFFECTIVE_FETCH_URL")"
  [[ "$EFFECTIVE_FETCH_URL_COUNT" == "1" ]] \
    || fail "$REMOTE_NAME 必须且只能解析出一个有效 fetch URL。"
  [[ "$EFFECTIVE_FETCH_URL" == "$CONFIGURED_FETCH_URL" ]] \
    || fail "$REMOTE_NAME 的 fetch URL 被 url.*.insteadOf 重写；拒绝推送。"

  CONFIGURED_PUSH_URL="$(
    git_repository config --get-all "remote.${REMOTE_NAME}.pushurl" 2>/dev/null || true
  )"
  if [[ -z "$CONFIGURED_PUSH_URL" ]]; then
    CONFIGURED_PUSH_URL="$CONFIGURED_FETCH_URL"
  fi
  PUSH_URL_COUNT="$(count_nonempty_lines "$CONFIGURED_PUSH_URL")"
  [[ "$PUSH_URL_COUNT" == "1" ]] \
    || fail "$REMOTE_NAME 必须且只能配置一个 push URL。"

  EFFECTIVE_PUSH_URL="$(
    git_repository remote get-url --push --all "$REMOTE_NAME" 2>/dev/null || true
  )"
  EFFECTIVE_PUSH_URL_COUNT="$(count_nonempty_lines "$EFFECTIVE_PUSH_URL")"
  [[ "$EFFECTIVE_PUSH_URL_COUNT" == "1" ]] \
    || fail "$REMOTE_NAME 必须且只能解析出一个有效 push URL。"
  [[ "$EFFECTIVE_PUSH_URL" == "$CONFIGURED_PUSH_URL" ]] \
    || fail "$REMOTE_NAME 的 push URL 被 url.*.insteadOf 或 pushInsteadOf 重写；拒绝推送。"

  REPLY_FETCH_URL="$EFFECTIVE_FETCH_URL"
  REPLY_PUSH_URL="$EFFECTIVE_PUSH_URL"
}

for REMOTE_NAME in "$PUBLIC_REMOTE" "$PRIVATE_REMOTE"; do
  resolve_remote_urls "$REMOTE_NAME"
  if [[ "$REMOTE_NAME" == "$PUBLIC_REMOTE" ]]; then
    PUBLIC_FETCH_URL="$REPLY_FETCH_URL"
    PUBLIC_PUSH_URL="$REPLY_PUSH_URL"
  else
    PRIVATE_FETCH_URL="$REPLY_FETCH_URL"
    PRIVATE_PUSH_URL="$REPLY_PUSH_URL"
  fi
done

canonical_public_repository_key() {
  local NORMALIZED_URL="${(L)1}"
  local REPOSITORY_PATH=""

  while [[ "$NORMALIZED_URL" == */ ]]; do
    NORMALIZED_URL="${NORMALIZED_URL%/}"
  done

  case "$NORMALIZED_URL" in
    git@github.com:*|git@github.com.:*)
      REPOSITORY_PATH="${NORMALIZED_URL#*:}"
      ;;
    https://github.com/*)
      REPOSITORY_PATH="${NORMALIZED_URL#https://github.com/}"
      ;;
    https://github.com./*)
      REPOSITORY_PATH="${NORMALIZED_URL#https://github.com./}"
      ;;
    https://github.com:443/*)
      REPOSITORY_PATH="${NORMALIZED_URL#https://github.com:443/}"
      ;;
    https://github.com.:443/*)
      REPOSITORY_PATH="${NORMALIZED_URL#https://github.com.:443/}"
      ;;
    ssh://git@github.com/*)
      REPOSITORY_PATH="${NORMALIZED_URL#ssh://git@github.com/}"
      ;;
    ssh://git@github.com./*)
      REPOSITORY_PATH="${NORMALIZED_URL#ssh://git@github.com./}"
      ;;
    ssh://git@github.com:22/*)
      REPOSITORY_PATH="${NORMALIZED_URL#ssh://git@github.com:22/}"
      ;;
    ssh://git@github.com.:22/*)
      REPOSITORY_PATH="${NORMALIZED_URL#ssh://git@github.com.:22/}"
      ;;
    *)
      return 1
      ;;
  esac

  while [[ "$REPOSITORY_PATH" == /* ]]; do
    REPOSITORY_PATH="${REPOSITORY_PATH#/}"
  done
  REPOSITORY_PATH="${REPOSITORY_PATH%.git}"
  [[ "$REPOSITORY_PATH" == "wesleyxuzzz/ios-sign-kit" ]] || return 1

  print -r -- "github.com/wesleyxuzzz/ios-sign-kit"
}

is_canonical_public_url() {
  canonical_public_repository_key "$1" >/dev/null
}

is_canonical_public_url "$PUBLIC_FETCH_URL" \
  || fail "origin 的唯一 fetch URL 必须指向 GitHub WesleyXuZzz/ios-sign-kit。"
is_canonical_public_url "$PUBLIC_PUSH_URL" \
  || fail "origin 的唯一 push URL 必须指向 GitHub WesleyXuZzz/ios-sign-kit。"
if is_canonical_public_url "$PRIVATE_FETCH_URL" \
  || is_canonical_public_url "$PRIVATE_PUSH_URL"; then
  fail "private 必须指向独立私有镜像，不能再次指向公开 GitHub 仓库。"
fi
[[ "$PUBLIC_PUSH_URL" != "$PRIVATE_PUSH_URL" ]] \
  || fail "origin 与 private 不能指向同一个 push URL。"

"$SCRIPT_DIRECTORY/verify-public-source.sh" \
  --repository "$REPOSITORY_ROOT" \
  --ref "$LOCAL_COMMIT"

REFSPEC="${LOCAL_COMMIT}:refs/heads/${TARGET_BRANCH}"

network_git() {
  GIT_CONFIG=/dev/null \
  GIT_CONFIG_COUNT=0 \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_PARAMETERS='' \
  command git -C "$REPOSITORY_ROOT" \
    -c core.hooksPath=/dev/null \
    "$@"
}

assert_local_master_unchanged() {
  local OBSERVED_BRANCH=""
  local OBSERVED_COMMIT=""

  OBSERVED_BRANCH="$(git_repository branch --show-current)"
  [[ "$OBSERVED_BRANCH" == "$TARGET_BRANCH" ]] \
    || fail "公开源码验证后当前分支发生变化；拒绝继续推送。"

  OBSERVED_COMMIT="$(
    git_repository rev-parse --verify "refs/heads/${TARGET_BRANCH}^{commit}" 2>/dev/null
  )" || fail "公开源码验证后无法解析本地 master。"
  [[ "$OBSERVED_COMMIT" == "$LOCAL_COMMIT" ]] \
    || fail "公开源码验证后本地 master 已发生变化；拒绝继续推送。"

  [[ -z "$(git_repository status --porcelain --untracked-files=all)" ]] \
    || fail "公开源码验证后工作区发生变化；拒绝继续推送。"
}

assert_remote_configuration_unchanged() {
  resolve_remote_urls "$PUBLIC_REMOTE"
  [[ "$REPLY_FETCH_URL" == "$PUBLIC_FETCH_URL" \
    && "$REPLY_PUSH_URL" == "$PUBLIC_PUSH_URL" ]] \
    || fail "公开源码验证后 origin URL 配置发生变化；拒绝继续推送。"

  resolve_remote_urls "$PRIVATE_REMOTE"
  [[ "$REPLY_FETCH_URL" == "$PRIVATE_FETCH_URL" \
    && "$REPLY_PUSH_URL" == "$PRIVATE_PUSH_URL" ]] \
    || fail "公开源码验证后 private URL 配置发生变化；拒绝继续推送。"
}

assert_publication_state_unchanged() {
  assert_local_master_unchanged
  assert_remote_configuration_unchanged
}

assert_publication_state_unchanged

preflight_remote() {
  local REMOTE_NAME="$1"
  local REMOTE_PUSH_URL="$2"
  local PREFLIGHT_OUTPUT=""

  if ! PREFLIGHT_OUTPUT="$(
    network_git push \
      --dry-run \
      --porcelain \
      --no-follow-tags \
      --recurse-submodules=no \
      -- \
      "$REMOTE_PUSH_URL" \
      "$REFSPEC" \
      2>&1
  )"; then
    echo "$PREFLIGHT_OUTPUT" >&2
    fail "$REMOTE_NAME 拒绝 fast-forward 预检；两端均未执行实际推送。"
  fi
  echo "- $REMOTE_NAME: push 预检通过"
}

push_remote() {
  local REMOTE_NAME="$1"
  local REMOTE_PUSH_URL="$2"
  local PUSH_OUTPUT=""

  if ! PUSH_OUTPUT="$(
    network_git push \
      --porcelain \
      --no-follow-tags \
      --recurse-submodules=no \
      -- \
      "$REMOTE_PUSH_URL" \
      "$REFSPEC" \
      2>&1
  )"; then
    echo "$PUSH_OUTPUT" >&2
    return 1
  fi
  echo "- $REMOTE_NAME: 推送完成"
}

read_remote_oid() {
  local REMOTE_PUSH_URL="$1"
  local REMOTE_OUTPUT=""

  if ! REMOTE_OUTPUT="$(
    network_git ls-remote \
      --heads \
      -- \
      "$REMOTE_PUSH_URL" \
      "refs/heads/$TARGET_BRANCH" \
      2>/dev/null
  )"; then
    REPLY="<unavailable>"
    return
  fi

  if [[ -z "$REMOTE_OUTPUT" ]]; then
    REPLY="<missing>"
  else
    REPLY="${REMOTE_OUTPUT%%[[:space:]]*}"
  fi
}

report_oid_state() {
  local PUBLIC_OID=""
  local PRIVATE_OID=""

  assert_remote_configuration_unchanged
  read_remote_oid "$PUBLIC_PUSH_URL"
  PUBLIC_OID="$REPLY"
  read_remote_oid "$PRIVATE_PUSH_URL"
  PRIVATE_OID="$REPLY"

  echo "- local/$TARGET_BRANCH: $LOCAL_COMMIT" >&2
  echo "- $PUBLIC_REMOTE/$TARGET_BRANCH: $PUBLIC_OID" >&2
  echo "- $PRIVATE_REMOTE/$TARGET_BRANCH: $PRIVATE_OID" >&2
}

echo "双镜像推送预检"
echo "- 本地提交: $LOCAL_COMMIT"
assert_publication_state_unchanged
preflight_remote "$PRIVATE_REMOTE" "$PRIVATE_PUSH_URL"
assert_publication_state_unchanged
preflight_remote "$PUBLIC_REMOTE" "$PUBLIC_PUSH_URL"
assert_publication_state_unchanged

if $DRY_RUN; then
  echo "Dry run completed：两端均未执行实际推送。"
  exit 0
fi

assert_publication_state_unchanged
if ! push_remote "$PRIVATE_REMOTE" "$PRIVATE_PUSH_URL"; then
  report_oid_state
  fail "私有镜像推送失败；GitHub 未执行实际推送。"
fi

assert_publication_state_unchanged
if ! push_remote "$PUBLIC_REMOTE" "$PUBLIC_PUSH_URL"; then
  report_oid_state
  fail "GitHub 推送失败；私有镜像可能已经更新，请修复后重试并核对两端 OID。"
fi

assert_publication_state_unchanged
read_remote_oid "$PUBLIC_PUSH_URL"
FINAL_PUBLIC_OID="$REPLY"
assert_publication_state_unchanged
read_remote_oid "$PRIVATE_PUSH_URL"
FINAL_PRIVATE_OID="$REPLY"
assert_publication_state_unchanged

if [[ "$FINAL_PUBLIC_OID" != "$LOCAL_COMMIT" \
  || "$FINAL_PRIVATE_OID" != "$LOCAL_COMMIT" ]]; then
  report_oid_state
  fail "推送后两端 OID 未同时等于本地提交。"
fi

echo "双镜像推送完成"
echo "- origin/master: $FINAL_PUBLIC_OID"
echo "- private/master: $FINAL_PRIVATE_OID"
