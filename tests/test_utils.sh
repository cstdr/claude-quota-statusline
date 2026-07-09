#!/usr/bin/env bash
# test_utils.sh — 其他纯函数测试（colorize / format_remaining_ms / format_burn_estimate）

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
STATUSLINE_LIB_MODE=1 source "$SCRIPT_DIR/../statusline.sh" 2>/dev/null || {
  echo "FAIL: 无法 source statusline.sh" >&2
  exit 1
}

# --- helpers ---
PASS=0; FAIL=0

# 提取函数输出的"颜色码"（GRN/YEL/RED/DIM/RST）
# 解析 ESC[Nm 形式
extract_color() {
  if   [[ "$1" == *$'\033[31m'* ]]; then echo "RED"
  elif [[ "$1" == *$'\033[33m'* ]]; then echo "YEL"
  elif [[ "$1" == *$'\033[32m'* ]]; then echo "GRN"
  elif [[ "$1" == *$'\033[2m'*  ]]; then echo "DIM"
  else                                   echo "NONE"
  fi
}

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

assert_match() {
  local actual="$1" pattern="$2" desc="$3"
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS+1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31m✗\033[0m %s\n     pattern: %s\n     got:     %q\n' "$desc" "$pattern" "$actual"
  fi
}

# ============ colorize_used ============
echo "colorize_used:"
assert_eq "$(extract_color "$(colorize_used 0)")"   "GRN" "0%   → 绿"
assert_eq "$(extract_color "$(colorize_used 30)")"  "GRN" "30%  → 绿"
assert_eq "$(extract_color "$(colorize_used 59)")"  "GRN" "59%  → 绿（下界）"
assert_eq "$(extract_color "$(colorize_used 60)")"  "YEL" "60%  → 黄（下界）"
assert_eq "$(extract_color "$(colorize_used 75)")"  "YEL" "75%  → 黄"
assert_eq "$(extract_color "$(colorize_used 84)")"  "YEL" "84%  → 黄（上界）"
assert_eq "$(extract_color "$(colorize_used 85)")"  "RED" "85%  → 红（下界）"
assert_eq "$(extract_color "$(colorize_used 100)")" "RED" "100% → 红"
# 边界
assert_eq "$(extract_color "$(colorize_used '')")"  "GRN" "空串 → 绿（兜底）"
assert_eq "$(extract_color "$(colorize_used 50.7)")" "GRN" "小数 → 50 → 绿"
assert_eq "$(extract_color "$(colorize_used 60.4)")" "YEL" "小数 → 60 → 黄"

# ============ colorize_reset ============
echo
echo "colorize_reset:"
assert_eq "$(extract_color "$(colorize_reset 0)")"         "RED" "0       → 红"
assert_eq "$(extract_color "$(colorize_reset 1799999)")"   "RED" "29:59   → 红（上界）"
assert_eq "$(extract_color "$(colorize_reset 1800000)")"   "YEL" "30:00   → 黄（下界）"
assert_eq "$(extract_color "$(colorize_reset 3600000)")"   "YEL" "1h      → 黄"
assert_eq "$(extract_color "$(colorize_reset 7199999)")"   "YEL" "1h59:59 → 黄（上界）"
assert_eq "$(extract_color "$(colorize_reset 7200000)")"   "DIM" "2h      → dim（下界）"
assert_eq "$(extract_color "$(colorize_reset 99999999)")"  "DIM" "27h     → dim"

# ============ format_remaining_ms ============
echo
echo "format_remaining_ms:"
assert_eq "$(format_remaining_ms 0)"        "<1m"   "0       → <1m"
assert_eq "$(format_remaining_ms 59999)"    "<1m"   "59.999s → <1m（上界）"
assert_eq "$(format_remaining_ms 60000)"    "1m"    "1m      → 1m"
assert_eq "$(format_remaining_ms 120000)"   "2m"    "2m      → 2m"
assert_eq "$(format_remaining_ms 3600000)"  "1h0m"  "1h      → 1h0m"
assert_eq "$(format_remaining_ms 5400000)"  "1h30m" "1h30m   → 1h30m"
assert_eq "$(format_remaining_ms 7200000)"  "2h0m"  "2h      → 2h0m"
assert_eq "$(format_remaining_ms 18000000)" "5h0m"  "5h      → 5h0m（5h 区间最大）"

# ============ format_burn_estimate ============
echo
echo "format_burn_estimate:"

TMP_HIST=$(mktemp)
trap 'rm -f "$TMP_HIST"' EXIT

# 文件不存在
assert_eq "$(format_burn_estimate /tmp/nonexistent 50 100 300 2)" "" "不存在 → 空"

# 只有 1 个点（n<3）
printf '1000 40 60\n' > "$TMP_HIST"
assert_eq "$(format_burn_estimate "$TMP_HIST" 40 100 999999 2)" "" "1 点 → 空（n<3）"

# 3 个点但 stable（delta=0）
NOW=$(date +%s)
printf '%s 40 60\n%s 40 60\n%s 40 60\n' $((NOW-100)) $((NOW-50)) "$NOW" > "$TMP_HIST"
assert_eq "$(format_burn_estimate "$TMP_HIST" 40 100 999999 2)" "" "3 点 stable → 空（delta=0）"

# 3 个点 increasing → 应该有输出（≈\d+[hm]）
printf '%s 40 60\n%s 50 65\n%s 55 70\n' $((NOW-100)) $((NOW-50)) "$NOW" > "$TMP_HIST"
actual=$(format_burn_estimate "$TMP_HIST" 55 100 999999 2)
assert_match "$actual" '^≈[0-9]+[hm]$' "3 点 increasing → ≈Xm（5h% 40→55，60s 内）"

# 3 个点 decreasing（rate < 0）→ 不输出
printf '%s 60 80\n%s 50 70\n%s 40 60\n' $((NOW-100)) $((NOW-50)) "$NOW" > "$TMP_HIST"
assert_eq "$(format_burn_estimate "$TMP_HIST" 40 100 999999 2)" "" "3 点 decreasing → 空（rate<0）"

# 已耗尽（latest >= total）
printf '%s 80 90\n%s 90 95\n%s 100 100\n' $((NOW-100)) $((NOW-50)) "$NOW" > "$TMP_HIST"
assert_eq "$(format_burn_estimate "$TMP_HIST" 100 100 999999 2)" "" "已耗尽 → 空（remaining<=0）"

# col 3（周）也能工作
printf '%s 60 40\n%s 70 50\n%s 80 60\n' $((NOW-100)) $((NOW-50)) "$NOW" > "$TMP_HIST"
actual=$(format_burn_estimate "$TMP_HIST" 80 150 999999 3)
assert_match "$actual" '^≈[0-9]+[hm]$' "col 3（周）→ 输出"

# 窗口外（数据点都在窗口之前）
printf '%s 40 60\n' "$((NOW-99999))" > "$TMP_HIST"
assert_eq "$(format_burn_estimate "$TMP_HIST" 40 100 300 2)" "" "窗口外 → 空"

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
