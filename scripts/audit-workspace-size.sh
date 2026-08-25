#!/bin/zsh

set -euo pipefail

export LC_ALL=C

SCRIPT_DIRECTORY="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
REPORT_ROOT="$REPOSITORY_ROOT"
ITEM_LIMIT=12

usage() {
  cat <<'EOF'
Usage: ./scripts/audit-workspace-size.sh [--root DIRECTORY] [--limit COUNT]

只读盘点项目、.build、Git 对象、dist 和 runtime 的磁盘占用。
脚本只报告，不删除、压缩或修改任何文件。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --root)
      if (( $# < 2 )); then
        echo "错误：--root 缺少目录参数。" >&2
        exit 2
      fi
      REPORT_ROOT="${2:A}"
      shift 2
      ;;
    --limit)
      if (( $# < 2 )) || [[ "$2" != <-> ]] || (( $2 < 1 || $2 > 100 )); then
        echo "错误：--limit 必须是 1 至 100 的整数。" >&2
        exit 2
      fi
      ITEM_LIMIT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数。使用 --help 查看用法。" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$REPORT_ROOT" ]]; then
  echo "错误：审计目录不存在。" >&2
  exit 2
fi

format_kib() {
  local kib="${1:-0}"
  awk -v kib="$kib" '
    BEGIN {
      bytes = kib * 1024
      if (bytes >= 1073741824) {
        printf "%.2f GiB", bytes / 1073741824
      } else if (bytes >= 1048576) {
        printf "%.2f MiB", bytes / 1048576
      } else if (bytes >= 1024) {
        printf "%.2f KiB", bytes / 1024
      } else {
        printf "%d bytes", bytes
      }
    }
  '
}

size_kib() {
  local target="$1"
  local result
  result="$(du -sk "$target" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  echo "${result:-0}"
}

sum_kib() {
  local total=0
  local target
  local value

  for target in "$@"; do
    value="$(size_kib "$target")"
    (( total += value ))
  done
  echo "$total"
}

print_top_level_items() {
  local directory="$1"
  local prefix="$2"
  local -a items

  if [[ ! -d "$directory" ]]; then
    echo "- 未发现"
    return
  fi

  items=("$directory"/*(DN))
  if (( ${#items[@]} == 0 )); then
    echo "- 目录为空"
    return
  fi

  du -sk "${items[@]}" 2>/dev/null \
    | sort -nr \
    | head -n "$ITEM_LIMIT" \
    | while IFS=$' \t' read -r item_kib item_path; do
        local relative_path="${item_path#"$REPORT_ROOT"/}"
        echo "- ${prefix}${relative_path}: $(format_kib "$item_kib")"
      done
}

echo "工作区磁盘占用审计"
echo "说明：本脚本只报告，不删除、压缩或修改任何文件。"
echo

echo "[项目总量]"
echo "- 项目目录（含 Git、构建缓存和本地产物）: $(format_kib "$(size_kib "$REPORT_ROOT")")"
echo

echo "[.build 关键层级]"
if [[ -d "$REPORT_ROOT/.build" ]]; then
  echo "- 合计: $(format_kib "$(size_kib "$REPORT_ROOT/.build")")"
  print_top_level_items "$REPORT_ROOT/.build" ""
else
  echo "- 未发现 .build"
fi
echo

echo "[Git 对象]"
if [[ -e "$REPORT_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
  echo "- git count-objects -vH:"
  (
    cd "$REPORT_ROOT"
    git count-objects -vH 2>/dev/null
  ) | sed 's/^/  /'
else
  echo "- 未发现可审计的 Git 仓库"
fi
echo

echo "[dist 关键遗留项]"
if [[ -d "$REPORT_ROOT/dist" ]]; then
  echo "- 合计: $(format_kib "$(size_kib "$REPORT_ROOT/dist")")"

  staging_items=("$REPORT_ROOT"/dist/.iOSSignKit.staging.*(DN))
  debug_apps=("$REPORT_ROOT"/dist/*-Debug.app(DN))

  if (( ${#staging_items[@]} > 0 )); then
    echo "- 未完成 staging 目录: ${#staging_items[@]} 项 / $(format_kib "$(sum_kib "${staging_items[@]}")")"
  else
    echo "- 未完成 staging 目录: 0 项"
  fi

  if (( ${#debug_apps[@]} > 0 )); then
    echo "- Debug App 产物: ${#debug_apps[@]} 项 / $(format_kib "$(sum_kib "${debug_apps[@]}")")"
  else
    echo "- Debug App 产物: 0 项"
  fi

  print_top_level_items "$REPORT_ROOT/dist" ""
else
  echo "- 未发现 dist"
fi
echo

echo "[runtime 关键遗留项]"
if [[ -d "$REPORT_ROOT/runtime" ]]; then
  echo "- 合计: $(format_kib "$(size_kib "$REPORT_ROOT/runtime")")"
  print_top_level_items "$REPORT_ROOT/runtime" ""
else
  echo "- 未发现 runtime"
fi
echo

echo "审计完成：以上结果仅用于判断清理候选；脚本未删除或修改任何文件。"
