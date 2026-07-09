#!/usr/bin/env bash
# test_sparkline.sh — 单元测试 for sparkline 函数
# TDD: 先写测试，FAIL，再写实现，PASS
#
# 运行: ./tests/test_sparkline.sh
# 退出码: 0 = all pass, 1 = any fail

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
STATUSLINE_LIB_MODE=1 source "$SCRIPT_DIR/../statusline.sh" 2>/dev/null || {
  echo "FAIL: 无法 source statusline.sh" >&2
  exit 1
}

# --- assertion helpers ---
PASS=0; FAIL=0
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

# --- 测试 sparkline_char_for_pct ---
echo "sparkline_char_for_pct:"
assert_eq "$(sparkline_char_for_pct 0)"    "▁" "0%   → ▁"
assert_eq "$(sparkline_char_for_pct 12)"   "▁" "12%  → ▁ (上界)"
assert_eq "$(sparkline_char_for_pct 13)"   "▂" "13%  → ▂ (下界)"
assert_eq "$(sparkline_char_for_pct 25)"   "▂" "25%  → ▂"
assert_eq "$(sparkline_char_for_pct 26)"   "▃" "26%  → ▃"
assert_eq "$(sparkline_char_for_pct 50)"   "▄" "50%  → ▄"
assert_eq "$(sparkline_char_for_pct 99)"   "█" "99%  → █ (>= 88 区间)"
assert_eq "$(sparkline_char_for_pct 100)"  "█" "100% → █"
assert_eq "$(sparkline_char_for_pct 150)"  "█" ">100 → █ (clamp)"
assert_eq "$(sparkline_char_for_pct "")"   "▁" "空串 → ▁ (兜底)"
assert_eq "$(sparkline_char_for_pct "abc")" "▁" "非数字 → ▁ (兜底)"

# --- 测试 format_sparkline (需先造 fixture) ---
echo
echo "format_sparkline:"

TMP_HIST=$(mktemp)
trap 'rm -f "$TMP_HIST"' EXIT

# 空文件
assert_eq "$(format_sparkline "$TMP_HIST" 2 6)" "" "空 hist → 空"

# 单点 → 1 数据 + 5 pad
printf '1000 10 20\n' > "$TMP_HIST"
assert_eq "$(format_sparkline "$TMP_HIST" 2 6)" "▁▁▁▁▁▁" "1 点 → 6 字符 (5 pad)"

# 3 点（取 col 2 = 5h used）
printf '1000 10 20\n1100 20 30\n1200 30 40\n' > "$TMP_HIST"
actual=$(format_sparkline "$TMP_HIST" 2 6)
expected="▁▂▃▁▁▁"
assert_eq "$actual" "$expected" "3 点 col 2 → 6 字符 (3 pad)"

# 6 点完整
printf '1000 10 20\n1100 20 30\n1200 30 40\n1300 40 50\n1400 50 60\n1500 60 70\n' > "$TMP_HIST"
actual=$(format_sparkline "$TMP_HIST" 2 6)
expected="▁▂▃▄▄▅"
assert_eq "$actual" "$expected" "6 点 col 2 → 6 字符无 pad"

# col 3 = 周 used
actual=$(format_sparkline "$TMP_HIST" 3 6)
expected="▂▃▄▄▅▆"
assert_eq "$actual" "$expected" "6 点 col 3 → 6 字符无 pad"

# 文件不存在
assert_eq "$(format_sparkline /tmp/nonexistent-xyz 2 6)" "" "不存在 → 空"

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
