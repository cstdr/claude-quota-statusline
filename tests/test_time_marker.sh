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

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
