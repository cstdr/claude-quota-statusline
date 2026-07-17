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
    printf '  \033[31m✗\033[0m %s\n     expected: %q\n     got:      %q\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_match() {
  local actual="$1" pattern="$2" desc="$3"
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS+1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31m✗\033[0m %s\n     pattern: %s\n     got:     %q\n' "$desc" "$pattern" "$actual" >&2
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

# ============ format_delta_piece ============
echo
echo "format_delta_piece:"

# 颜色码
GRN_CODE=$'\033[32m'
YEL_CODE=$'\033[33m'
RED_CODE=$'\033[31m'
RST_CODE=$'\033[0m'

extract_color() {
  if   [[ "$1" == *"$RED_CODE"* ]]; then echo "RED"
  elif [[ "$1" == *"$YEL_CODE"* ]]; then echo "YEL"
  elif [[ "$1" == *"$GRN_CODE"* ]]; then echo "GRN"
  else                                   echo "NONE"
  fi
}

# 正 / 负 / 零
assert_match "$(format_delta_piece 45 50)"  '^.*↑\+45%.*$'   "delta=+45 → ↑+45%"
assert_match "$(format_delta_piece -30 30)" '^.*↓-30%.*$'   "delta=-30 → ↓-30%"
assert_match "$(format_delta_piece 0  60)"  '^.*↓0%.*$'     "delta=0 → ↓0%（不是 →）"

# color 跟随 used% 阈值（与 colorize_used 一致：≥85 红 / ≥60 黄 / 其余 绿）
assert_eq "$(extract_color "$(format_delta_piece 10 30)")"  "GRN" "used=30 → 绿"
assert_eq "$(extract_color "$(format_delta_piece 10 60)")"  "YEL" "used=60 → 黄（下界）"
assert_eq "$(extract_color "$(format_delta_piece 10 84)")"  "YEL" "used=84 → 黄（上界）"
assert_eq "$(extract_color "$(format_delta_piece 10 85)")"  "RED" "used=85 → 红（下界）"
assert_eq "$(extract_color "$(format_delta_piece 10 100)")" "RED" "used=100 → 红"

# 数字正负号 + 内容正确
actual=$(format_delta_piece 45 75)
assert_match "$actual" '↑\+45%' "↑+45% 字面值正确"
actual=$(format_delta_piece -12 25)
assert_match "$actual" '↓-12%' "↓-12% 字面值正确（负号不是短横）"

# ============ 主流程集成测试（Δ 与 ┊ 耦合）============
# 用临时 cache + HIST_FILE 跑 statusline.sh 主流程，验证：
# - elapsed < 12.5%（marker_pos=0）：┊ 和 ↑/↓ 都不显（统一 gate 在 marker_pos）
# - elapsed >= 12.5% 且 <= 87.5%：┊ 和 ↑/↓ 都显
# - elapsed >= 87.5%（marker_pos>=width）：┊ 和 ↑/↓ 都不显
echo
echo "main flow integration:"

# 临时 cache + HIST_FILE（自动清理）
TMP_CACHE=$(mktemp)
TMP_HIST=$(mktemp)
trap 'rm -f "$TMP_CACHE" "$TMP_HIST"' EXIT

# fake stdin（model + context_window）
FAKE_STDIN='{"model":{"display_name":"opus-4"},"context_window":{"used_tokens":780000,"max_tokens":1000000}}'

# 写 cache（包含 model_remains[0] = general model）
# 5h reset = 7200000 ms (2h) → elapsed = 60% → marker_pos = 4
# week reset = 302400000 ms (3.5d) → elapsed = 50% → marker_pos = 4
cat > "$TMP_CACHE" <<'EOF'
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 26,
      "remains_time": 7200000,
      "current_weekly_remaining_percent": 87,
      "weekly_remains_time": 302400000,
      "weekly_boost_permille": 1500
    }
  ]
}
EOF

# 场景 1：5h elapsed=60%（marker_pos=4）→ ┊ + ↑+14% 都显
# （5h USED=74, elapsed=60, Δ=+14；周 USED=19, elapsed=50, Δ=-31）
output=$(STATUSLINE_PROVIDER=minimax STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
assert_match "$output" '┊' "5h elapsed=60% → ┊ 显"
assert_match "$output" '↑\+1[0-9]%' "5h elapsed=60% → ↑+14% 显（Δ = 74 - 60 = +14）"

# 场景 2：5h reset=17000000 (≈10% elapsed) → marker_pos=0（1-12% 量化后 0）
#        → ┊ 隐 + ↑ 隐（spec 第 3 条件 marker_pos>0 才画）
cat > "$TMP_CACHE" <<'EOF'
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 26,
      "remains_time": 17000000,
      "current_weekly_remaining_percent": 87,
      "weekly_remains_time": 302400000,
      "weekly_boost_permille": 1500
    }
  ]
}
EOF
output=$(STATUSLINE_PROVIDER=minimax STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
# 5h 段：marker_pos=0 → overlay_marker 走"无 ┊"分支 → 5h 段无 ┊
# Δ：gate 在 marker_pos，marker_pos 为空 → 5h 段无 ↑/↓
# 但周 段有 marker_pos=4 → 周 段有 ┊ + ↑+9%（19 vs 50 ⇒ +9%）
# 所以用更细粒度断言：5h 段无 ┊、无 ↑，周 段有 ┊、有 ↑
five_piece=$(echo "$output" | grep -oE '5h[^·]*' || true)
week_piece=$(echo "$output" | grep -oE '周[^·]*' || true)
# 5h 段不应含 ┊
if [[ "$five_piece" == *"┊"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     five_piece 含 ┊（elapsed 1-12%% 不应显）\n' "5h elapsed=10% → 5h 段无 ┊" >&2
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h elapsed=10% → 5h 段无 ┊（marker_pos=0 gate）"
fi
# 5h 段不应含 ↑
if [[ "$five_piece" == *"↑"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     five_piece 含 ↑\n' "5h elapsed=10% → 5h 段无 ↑" >&2
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h elapsed=10% → 5h 段无 ↑（与 ┊ 同 gate）"
fi
# 周 段应有 ┊
if [[ "$week_piece" == *"┊"* ]]; then
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h elapsed=10% → 周段仍有 ┊（独立 cycle）"
else
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n' "5h elapsed=10% → 周段应有 ┊" >&2
fi
# 周 段应有 ↓-31%（19 vs 50 ⇒ -31）
if [[ "$week_piece" == *"↓"* ]]; then
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h elapsed=10% → 周段仍有 ↓（WEEK_USED=19 < elapsed=50）"
else
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n' "5h elapsed=10% → 周段应有 ↓" >&2
fi

# 场景 3：reset_ms 缺失（5h cache 里没有 remains_time）→ 5h 段无 ┊、无 ↑
cat > "$TMP_CACHE" <<'EOF'
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 26,
      "current_weekly_remaining_percent": 87,
      "weekly_remains_time": 302400000,
      "weekly_boost_permille": 1500
    }
  ]
}
EOF
output=$(STATUSLINE_PROVIDER=minimax STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
five_piece=$(echo "$output" | grep -oE '5h[^·]*' || true)
# 5h 段不应含 ┊
if [[ "$five_piece" == *"┊"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     five_piece 含 ┊\n' "5h reset_ms 缺失 → 无 ┊" >&2
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h reset_ms 缺失 → 无 ┊"
fi
# 5h 段不应含 ↑/↓
if [[ "$five_piece" == *"↑"* || "$five_piece" == *"↓"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     five_piece 含 ↑/↓\n' "5h reset_ms 缺失 → 无 ↑/↓" >&2
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "5h reset_ms 缺失 → 无 ↑/↓"
fi

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
