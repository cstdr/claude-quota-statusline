#!/usr/bin/env bash
# test_time_marker.sh — marker_pos / elapsed_pct / overlay_marker / format_delta_piece 测试

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
STATUSLINE_LIB_MODE=1 source "$SCRIPT_DIR/../statusline.sh" 2>/dev/null || {
  echo "FAIL: 无法 source statusline.sh" >&2
  exit 1
}

PASS=0; FAIL=0

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS+1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  \033[32m✗\033[0m %s\n     expected: %q\n     got:      %q\n' "$desc" "$expected" "$actual" >&2
  fi
}

# ============ marker_pos ============
echo "marker_pos:"

# 数据缺失 / 越界 → 输出空
assert_eq "$(marker_pos ''     18000000 8)" "" "空 reset_ms → 空"
assert_eq "$(marker_pos 'abc'   18000000 8)" "" "非数字 reset_ms → 空"
assert_eq "$(marker_pos 0       18000000 8)" "" "reset_ms=0（即将 reset）→ 空"
assert_eq "$(marker_pos 18000000 18000000 8)" "" "reset_ms=period（刚 reset）→ 空"
assert_eq "$(marker_pos 20000000 18000000 8)" "" "reset_ms>period（异常）→ 空"
assert_eq "$(marker_pos 7200000  0        8)" "" "period=0（defensive）→ 空"

# 正常情况（5h 周期，width=8）
# elapsed = (18M - 7.2M) × 100 / 18M = 60；marker = 60 × 8 / 100 = 4
assert_eq "$(marker_pos 7200000  18000000 8)" "4" "reset=2h/5h → marker=4"
# elapsed = 30%；marker = 30 × 8 / 100 = 2
assert_eq "$(marker_pos 12600000 18000000 8)" "2" "reset=3.5h/5h → marker=2"
# elapsed = 100%（减 1ms 兜底）；marker = 7
assert_eq "$(marker_pos 1        18000000 8)" "7" "reset≈0/5h → marker=7（不是 width）"

# 周周期（width=8）
# elapsed = (604.8M - 302.4M) × 100 / 604.8M = 50；marker = 50 × 8 / 100 = 4
assert_eq "$(marker_pos 302400000 604800000 8)" "4" "周 3.5d/7d → marker=4"

# ============ elapsed_pct ============
echo
echo "elapsed_pct:"

# 不画条件（与 marker_pos 对齐）→ 空
assert_eq "$(elapsed_pct ''     18000000)" "" "空 reset_ms → 空"
assert_eq "$(elapsed_pct 0       18000000)" "" "reset=0 → 空"
assert_eq "$(elapsed_pct 18000000 18000000)" "" "reset=period → 空"
assert_eq "$(elapsed_pct 20000000 18000000)" "" "reset>period → 空"
assert_eq "$(elapsed_pct 7200000  0       )" "" "period=0 → 空"

# 正常情况
# (18M - 7.2M) × 100 / 18M = 60
assert_eq "$(elapsed_pct 7200000  18000000)" "60" "reset=2h/5h → 60"
# (18M - 12.6M) × 100 / 18M = 30
assert_eq "$(elapsed_pct 12600000 18000000)" "30" "reset=3.5h/5h → 30"
# (18M - 1) × 100 / 18M = 99
assert_eq "$(elapsed_pct 1        18000000)" "99" "reset≈0/5h → 99（不是 100）"

# 周周期
# (604.8M - 302.4M) × 100 / 604.8M = 50
assert_eq "$(elapsed_pct 302400000 604800000)" "50" "周 3.5d/7d → 50"

# ============ overlay_marker ============
echo
echo "overlay_marker:"

# DIM 颜色码用于断言（statusline.sh 已定义 DIM=$'\033[2m'，RST=$'\033[0m'）
DIM_CODE=$'\033[2m'
RST_CODE=$'\033[0m'
GRN_CODE=$'\033[32m'

# marker_pos 越界 → bar 整段用 bar_color 包，无 ┊
# 8 char bar, marker=0 → 不变
actual=$(overlay_marker "▆▆░░░░░░" 0 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆░░░░░░${RST_CODE}"
assert_eq "$actual" "$expected" "marker=0 → 无 ┊"

# marker=width → 不变
actual=$(overlay_marker "▆▆▆▆▆▆▆░" 8 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆▆▆▆▆▆░${RST_CODE}"
assert_eq "$actual" "$expected" "marker=8 → 无 ┊"

# marker=4 over empty（5h 持平）→ 第 5 字符是 ┊ (dim)
# bar "▆▆▆▆░░░░" (4 filled + 4 empty)，marker=4 → "▆▆▆▆┊░░░" (replace 5th char)
actual=$(overlay_marker "▆▆▆▆░░░░" 4 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆▆▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}░░░${RST_CODE}"
assert_eq "$actual" "$expected" "marker=4 over empty → ┊ dim，pre/post 用 bar_color"

# marker=2 over filled（5h 快烧）→ 第 3 字符是 ┊ (dim)
# bar "▆▆▆▆▆▆░░" (6 filled + 2 empty)，marker=2 → "▆▆┊▆▆▆░░" (replace 3rd char，REPLACE 模式 post=5 chars)
actual=$(overlay_marker "▆▆▆▆▆▆░░" 2 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}▆▆▆░░${RST_CODE}"
assert_eq "$actual" "$expected" "marker=2 over filled → ┊ dim 替换 filled 字符（REPLACE 丢 1 char）"

# 边界：marker=1（最左，REPLACE 模式 post=6 chars）
actual=$(overlay_marker "▆▆▆▆▆▆▆▆" 1 8 "$GRN_CODE")
expected="${GRN_CODE}▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}▆▆▆▆▆▆${RST_CODE}"
assert_eq "$actual" "$expected" "marker=1 → pre 1 char，post 6 char（REPLACE 丢 1 char）"

# 边界：marker=7（最右有效位，REPLACE 模式 post=0 char 即空）
actual=$(overlay_marker "▆▆▆▆▆▆▆▆" 7 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆▆▆▆▆▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}${RST_CODE}"
assert_eq "$actual" "$expected" "marker=7 → pre 7 char，post 0 char（REPLACE 丢 1 char）"

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
