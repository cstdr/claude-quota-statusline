#!/usr/bin/env bash
# test_count_piece.sh — 单元测试 for count-based model 显示
# TDD: 先 FAIL 再实现

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
STATUSLINE_LIB_MODE=1 source "$SCRIPT_DIR/../statusline.sh" 2>/dev/null || {
  echo "FAIL: 无法 source statusline.sh" >&2
  exit 1
}

# --- assertion helpers ---
PASS=0; FAIL=0

# 去 ANSI escape 后比较，避免 ESC 字节比对坑
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g' <<< "$1"; }

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS+1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31m✗\033[0m %s\n     expected: %q\n     got:      %q\n' "$desc" "$expected" "$actual"
  fi
}

# --- 测试 format_count_piece ---
echo "format_count_piece:"

# 正常：usage 0/3，reset 12min → 红（< 30min）
actual=$(strip_ansi "$(format_count_piece video 0 3 600000)")  # 10min → 红
assert_eq "$actual" "video 0/3 ↻ 10m" "video 0/3 ↻ 10m (红)"

# 正常：usage 1/3，reset 2h
actual=$(strip_ansi "$(format_count_piece video 1 3 7200000)")  # 2h → 黄
assert_eq "$actual" "video 1/3 ↻ 2h0m" "video 1/3 ↻ 2h0m (黄)"

# 正常：usage 3/3（已用完），reset 长
actual=$(strip_ansi "$(format_count_piece video 3 3 10800000)")  # 3h → dim
assert_eq "$actual" "video 3/3 ↻ 3h0m" "video 3/3 ↻ 3h0m (dim)"

# 无 reset
actual=$(strip_ansi "$(format_count_piece video 1 5 "")")
assert_eq "$actual" "video 1/5" "video 1/5 (无 reset)"

# total = 0 → 不显示
actual=$(format_count_piece video 0 0 7200000)
assert_eq "$actual" "" "total=0 → 空"

# total 空 → 不显示
actual=$(format_count_piece video 0 "" 7200000)
assert_eq "$actual" "" "total='' → 空"

# total 非数字 → 不显示
actual=$(format_count_piece video 0 "abc" 7200000)
assert_eq "$actual" "" "total 非数字 → 空"

# usage 可以是 0
actual=$(strip_ansi "$(format_count_piece image 0 10 3600000)")
assert_eq "$actual" "image 0/10 ↻ 1h0m" "image 0/10 (label 通用)"

# 用法：超过 total（异常）
actual=$(strip_ansi "$(format_count_piece video 5 3 7200000)")
assert_eq "$actual" "video 5/3 ↻ 2h0m" "usage > total 仍显示（不替用户判断）"

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
