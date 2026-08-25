#!/bin/zsh

set -euo pipefail

export LC_ALL=C
export GIT_NO_LAZY_FETCH=1
export GIT_NO_REPLACE_OBJECTS=1

SCRIPT_DIRECTORY="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
SOURCE_REF="HEAD"

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-public-source.sh [options]

验证准备公开的 Git 提交及其全部可达历史只包含可公开的源码、文档和
项目自有资产。脚本只读，不创建提交、不修改分支，也不访问网络。

Options:
  --ref REF                 要验证的提交或 ref，默认 HEAD
  --repository DIRECTORY    指定仓库根目录，主要用于测试
  -h, --help                显示帮助
EOF
}

fail() {
  echo "公开源码检查失败：$1" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --ref)
      (( $# >= 2 )) || fail "--ref 缺少参数。"
      SOURCE_REF="$2"
      shift 2
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
command -v git >/dev/null 2>&1 || fail "找不到 git。"

git_repository() {
  command git -C "$REPOSITORY_ROOT" "$@"
}

TOP_LEVEL="$(git_repository rev-parse --show-toplevel 2>/dev/null)" \
  || fail "指定目录不是 Git 仓库。"
[[ "${TOP_LEVEL:A}" == "${REPOSITORY_ROOT:A}" ]] \
  || fail "--repository 必须指向仓库根目录。"

[[ "$(git_repository rev-parse --is-shallow-repository 2>/dev/null)" == "false" ]] \
  || fail "拒绝检查 shallow 仓库；必须先取得完整历史。"

REPLACE_REFS="$(
  git_repository for-each-ref --format='%(refname)' refs/replace
)" || fail "无法检查 Git replacement refs。"
[[ -z "$REPLACE_REFS" ]] \
  || fail "仓库包含 Git replacement refs；拒绝检查被替换的历史视图。"

GRAFTS_PATH="$(git_repository rev-parse --git-path info/grafts 2>/dev/null)" \
  || fail "无法定位 Git grafts 文件。"
[[ "$GRAFTS_PATH" == /* ]] || GRAFTS_PATH="$REPOSITORY_ROOT/$GRAFTS_PATH"
[[ ! -s "${GRAFTS_PATH:A}" ]] \
  || fail "仓库包含 legacy grafts；拒绝检查被改写的历史视图。"

if [[ -n "$(git_repository status --porcelain --untracked-files=all)" ]]; then
  fail "工作区不干净；请先提交或移走全部改动再检查公开源码。"
fi

SOURCE_COMMIT="$(
  git_repository rev-parse --verify --end-of-options "${SOURCE_REF}^{commit}" 2>/dev/null
)" \
  || fail "$SOURCE_REF 不存在或不是提交。"

typeset -a REQUIRED_ROOT_PATHS
REQUIRED_ROOT_PATHS=(
  .gitignore
  ASSET_PROVENANCE.md
  LICENSE
  Package.swift
  README.md
  SECURITY.md
)

for REQUIRED_PATH in "${REQUIRED_ROOT_PATHS[@]}"; do
  REQUIRED_TYPE="$(
    git_repository cat-file -t "${SOURCE_COMMIT}:${REQUIRED_PATH}" 2>/dev/null || true
  )"
  [[ "$REQUIRED_TYPE" == "blob" ]] \
    || fail "根目录缺少公开治理文件或文件类型非法：$REQUIRED_PATH"
done

typeset -a HISTORY_COMMITS
HISTORY_COMMITS=("${(@f)$(git_repository rev-list "$SOURCE_COMMIT")}")
(( ${#HISTORY_COMMITS[@]} > 0 )) || fail "没有可验证的提交。"

HOME_PATH_PREFIX='/'"Users/"
HOME_PATH_PATTERN="${HOME_PATH_PREFIX}[^/[:space:]]+"
PRIVATE_REMOTE_PATTERN='forgejo'"-nas:"
PRIVATE_KEY_PATTERN='-----BEGIN[[:space:]][A-Z0-9 ]*PRIVATE[[:space:]]KEY-----'
TOKEN_PATTERN='github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+'
DEFAULT_DENY_PATTERN="(${HOME_PATH_PATTERN}|${PRIVATE_REMOTE_PATTERN}|${PRIVATE_KEY_PATTERN}|${TOKEN_PATTERN})"
PUBLIC_EMAIL_PATTERN='^([^@[:space:]]+@users\.noreply\.github\.com|noreply@github\.com)$'

typeset -a RETIRED_WORKFLOW_MARKERS
RETIRED_WORKFLOW_MARKERS=(
  "github""-master"
  "update-github-public-""snapshot"
  "github-public-""files"
  "public""Snapshot"
)

TRACKED_FILE_COUNT=0

is_public_commit_email() {
  print -r -- "$1" | /usr/bin/grep -Eq "$PUBLIC_EMAIL_PATTERN"
}

for HISTORY_COMMIT in "${HISTORY_COMMITS[@]}"; do
  typeset -a BLOCKED_PATHS
  BLOCKED_PATHS=()

  while IFS= read -r -d '' TRACKED_PATH; do
    TRACKED_FILE_COUNT=$(( TRACKED_FILE_COUNT + 1 ))
    NORMALIZED_TRACKED_PATH="${(L)TRACKED_PATH}"
    case "$NORMALIZED_TRACKED_PATH" in
      .env.example|*/.env.example)
        ;;
      .env|.env.*|*/.env|*/.env.*|*.p12|*.pfx|*.mobileprovision|*.pem|*.key|*.p8)
        BLOCKED_PATHS+=("$TRACKED_PATH")
        ;;
      .build|.build/*|dist|dist/*|runtime|runtime/*|*.app|*.app/*|*.dmg|*.ipa|*.pkg|*.xcarchive|*.xcarchive/*|*/xcuserdata|*/xcuserdata/*)
        BLOCKED_PATHS+=("$TRACKED_PATH")
        ;;
    esac
  done < <(git_repository ls-tree -r -z --name-only "$HISTORY_COMMIT")

  if (( ${#BLOCKED_PATHS[@]} > 0 )); then
    echo "提交 $HISTORY_COMMIT 包含不能进入源码发布的路径：" >&2
    printf '  - %s\n' "${BLOCKED_PATHS[@]}" >&2
    exit 1
  fi

  set +e
  DENY_MATCHES="$(
    git_repository grep -n -I -E "$DEFAULT_DENY_PATTERN" "$HISTORY_COMMIT" --
  )"
  DENY_STATUS=$?
  set -e

  if (( DENY_STATUS == 0 )); then
    echo "提交 $HISTORY_COMMIT 命中凭据、本机路径或私有远端规则：" >&2
    echo "$DENY_MATCHES" | /usr/bin/sed 's/^/  /' >&2
    exit 1
  elif (( DENY_STATUS != 1 )); then
    fail "无法扫描提交 $HISTORY_COMMIT 的文本内容。"
  fi

  AUTHOR_EMAIL="$(
    git_repository show -s --format='%ae' "$HISTORY_COMMIT"
  )" || fail "无法读取提交 $HISTORY_COMMIT 的作者邮箱。"
  COMMITTER_EMAIL="$(
    git_repository show -s --format='%ce' "$HISTORY_COMMIT"
  )" || fail "无法读取提交 $HISTORY_COMMIT 的提交者邮箱。"

  is_public_commit_email "$AUTHOR_EMAIL" \
    || fail "提交 $HISTORY_COMMIT 的作者邮箱不是 GitHub noreply 地址。"
  is_public_commit_email "$COMMITTER_EMAIL" \
    || fail "提交 $HISTORY_COMMIT 的提交者邮箱不是 GitHub noreply 地址。"

  COMMIT_METADATA="$(
    git_repository show -s \
      --format='%an%n%ae%n%cn%n%ce%n%B' \
      "$HISTORY_COMMIT"
  )" || fail "无法读取提交 $HISTORY_COMMIT 的元数据。"

  set +e
  METADATA_DENY_MATCHES="$(
    print -r -- "$COMMIT_METADATA" \
      | /usr/bin/grep -n -E "$DEFAULT_DENY_PATTERN"
  )"
  METADATA_DENY_STATUS=$?
  set -e

  if (( METADATA_DENY_STATUS == 0 )); then
    echo "提交 $HISTORY_COMMIT 的身份或消息命中凭据、本机路径或私有远端规则：" >&2
    echo "$METADATA_DENY_MATCHES" | /usr/bin/sed 's/^/  /' >&2
    exit 1
  elif (( METADATA_DENY_STATUS != 1 )); then
    fail "无法扫描提交 $HISTORY_COMMIT 的身份与消息。"
  fi

  for RETIRED_MARKER in "${RETIRED_WORKFLOW_MARKERS[@]}"; do
    set +e
    RETIRED_MATCHES="$(
      git_repository grep -n -I -F "$RETIRED_MARKER" "$HISTORY_COMMIT" --
    )"
    RETIRED_STATUS=$?
    set -e

    if (( RETIRED_STATUS == 0 )); then
      echo "提交 $HISTORY_COMMIT 仍包含已退出的公开快照流程标记：$RETIRED_MARKER" >&2
      echo "$RETIRED_MATCHES" | /usr/bin/sed 's/^/  /' >&2
      exit 1
    elif (( RETIRED_STATUS != 1 )); then
      fail "无法扫描提交 $HISTORY_COMMIT 的旧流程标记。"
    fi

    set +e
    METADATA_RETIRED_MATCHES="$(
      print -r -- "$COMMIT_METADATA" \
        | /usr/bin/grep -n -F "$RETIRED_MARKER"
    )"
    METADATA_RETIRED_STATUS=$?
    set -e

    if (( METADATA_RETIRED_STATUS == 0 )); then
      echo "提交 $HISTORY_COMMIT 的身份或消息仍包含已退出的公开快照流程标记：$RETIRED_MARKER" >&2
      echo "$METADATA_RETIRED_MATCHES" | /usr/bin/sed 's/^/  /' >&2
      exit 1
    elif (( METADATA_RETIRED_STATUS != 1 )); then
      fail "无法扫描提交 $HISTORY_COMMIT 的身份与消息旧流程标记。"
    fi
  done
done

echo "公开源码检查通过"
echo "- 目标提交: $SOURCE_COMMIT"
echo "- 已检查历史提交: ${#HISTORY_COMMITS[@]}"
echo "- 已检查文件版本: $TRACKED_FILE_COUNT"
echo "- 发布边界: 源码、文档和已授权项目资产；不含预编译 App/DMG"
