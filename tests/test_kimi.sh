#!/usr/bin/env bash
# test_kimi.sh — 单元测试 for Kimi provider（detect_provider / kimi_fields）+ 主流程集成
# TDD: 先 FAIL 再实现
#
# Kimi /coding/v1/usages 真实响应结构（2026-07-17 实测）：
#   usage  = 周窗口（resetTime ≈ 7 天后）
#   limits[duration=300min] = 5h 窗口
#   limit/used/remaining 都是字符串，limit=100 时 used 即百分比

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

assert_match() {
  local actual="$1" pattern="$2" desc="$3"
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS+1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31m✗\033[0m %s\n     pattern: %q\n     got:     %q\n' "$desc" "$pattern" "$actual"
  fi
}

# ============ detect_provider ============
echo "detect_provider:"

actual=$(ANTHROPIC_BASE_URL="https://api.kimi.com/coding/" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "kimi" "api.kimi.com → kimi"

actual=$(ANTHROPIC_BASE_URL="https://api.moonshot.cn/anthropic" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "kimi" "api.moonshot.cn → kimi"

actual=$(ANTHROPIC_BASE_URL="https://www.minimaxi.com/anthropic" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "minimax" "minimaxi.com → minimax"

actual=$(ANTHROPIC_BASE_URL="HTTPS://API.MINIMAXI.COM/anthropic" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "minimax" "大写 host → 照样识别 minimax（大小写不敏感）"

actual=$(ANTHROPIC_BASE_URL="" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "unknown" "BASE_URL 空 → unknown（不往不认识的服务商发 token）"

actual=$(ANTHROPIC_BASE_URL="https://api.anthropic.com" STATUSLINE_PROVIDER='' detect_provider)
assert_eq "$actual" "unknown" "不认识的 URL → unknown"

actual=$(ANTHROPIC_BASE_URL="" STATUSLINE_PROVIDER="kimi" detect_provider)
assert_eq "$actual" "kimi" "BASE_URL 空 + 强制 kimi → kimi（覆盖优先）"

actual=$(ANTHROPIC_BASE_URL="https://api.kimi.com/coding/" STATUSLINE_PROVIDER="minimax" detect_provider)
assert_eq "$actual" "minimax" "STATUSLINE_PROVIDER=minimax 覆盖 kimi URL"

actual=$(ANTHROPIC_BASE_URL="https://www.minimaxi.com/anthropic" STATUSLINE_PROVIDER="kimi" detect_provider)
assert_eq "$actual" "kimi" "STATUSLINE_PROVIDER=kimi 覆盖 minimax URL"

# ============ kimi_fields ============
# 固定 now = 2026-07-17T04:08:41Z = 1784261321，断言确定性
echo
echo "kimi_fields:"

NOW=1784261321

# 真实响应改Fixture：5h reset = 06:08:41Z（+2h → 7200000ms），周 reset = 07-24 04:08:41Z（+7d → 604800000ms）
read -r -d '' FIXTURE <<'EOF' || true
{
  "user": {"userId":"u1","region":"REGION_CN","membership":{"level":"LEVEL_INTERMEDIATE"}},
  "usage": {"limit":"100","used":"2","remaining":"98","resetTime":"2026-07-24T04:08:41.679621Z"},
  "limits": [
    {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
     "detail":{"limit":"100","used":"11","remaining":"89","resetTime":"2026-07-17T06:08:41.679621Z"}}
  ],
  "parallel": {"limit":"20","details":[]},
  "totalQuota": {"limit":"100","remaining":"99"}
}
EOF

actual=$(printf '%s' "$FIXTURE" | kimi_fields "$NOW")
assert_eq "$actual" "89|7200000|98|604800000|" "正常响应 → 5h 剩 89% / 7200000ms，周 剩 98% / 604800000ms"

# used > limit（超用）→ remaining clamp 到 0（下游 USED=100 不溢出 bar）
# 字段序：5h剩余% | 5h剩余ms | 周剩余% | 周剩余ms | boost
actual=$(printf '%s' '{"usage":{"limit":"100","used":"150"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||0||" "周 used>limit → remaining clamp 0"

# limit = "0" → 该字段空（不显示）
actual=$(printf '%s' '{"usage":{"limit":"0","used":"0"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||||" "limit=0 → 字段空"

# limits 空数组 → 5h 字段空，周正常解析
actual=$(printf '%s' '{"usage":{"limit":"100","used":"40","resetTime":"2026-07-20T04:08:41Z"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||60|259200000|" "limits=[] → 5h 空，周 剩 60% / 259200000ms"

# resetTime 在过去 → reset_ms = 0（clamp，下游显示 <1m）
actual=$(printf '%s' '{"usage":{"limit":"100","used":"10","resetTime":"2026-07-16T04:08:41Z"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||90|0|" "resetTime 过去 → reset_ms=0"

# resetTime 非法字符串 → 该字段空，其他字段不受影响
actual=$(printf '%s' '{"usage":{"limit":"100","used":"10","resetTime":"not-a-date"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||90||" "resetTime 非法 → reset 字段空"

# resetTime 缺失 → 空
actual=$(printf '%s' '{"usage":{"limit":"100","used":"10"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||90||" "resetTime 缺失 → 空"

# usage 整个缺失 → 周字段空
actual=$(printf '%s' '{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"30","resetTime":"2026-07-17T06:08:41Z"}}]}' | kimi_fields "$NOW")
assert_eq "$actual" "70|7200000|||" "usage 缺失 → 周空，5h 正常"

# 非 300min 窗口不当作 5h
actual=$(printf '%s' '{"limits":[{"window":{"duration":60,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"30","resetTime":"2026-07-17T06:08:41Z"}}]}' | kimi_fields "$NOW")
assert_eq "$actual" "||||" "duration=60min → 不识别为 5h"

# 垃圾 JSON → 无输出（主流程 read 全空 → piece 静默省略）
actual=$(printf '%s' 'not json at all' | kimi_fields "$NOW" 2>/dev/null)
assert_eq "$actual" "" "垃圾 JSON → 空输出"

# used 是非法字符串 → 该字段空但不崩（try/catch）
actual=$(printf '%s' '{"usage":{"limit":"100","used":"abc"},"limits":[]}' | kimi_fields "$NOW")
assert_eq "$actual" "||||" "used 非法 → 字段空"

# 结构级类型错误：usage 不是 object → 整段不崩，5h 正常解析
actual=$(printf '%s' '{"usage":"not-an-object","limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"30","resetTime":"2026-07-17T06:08:41Z"}}]}' | kimi_fields "$NOW")
assert_eq "$actual" "70|7200000|||" "usage 是 string → 周空，5h 不受影响"

# 结构级类型错误：limits 不是 array → 周字段不陪葬
actual=$(printf '%s' '{"usage":{"limit":"100","used":"40","resetTime":"2026-07-20T04:08:41Z"},"limits":"oops"}' | kimi_fields "$NOW")
assert_eq "$actual" "||60|259200000|" "limits 是 string → 5h 空，周不受影响"

# 顶层是数组 → 全空不崩
actual=$(printf '%s' '[1,2,3]' | kimi_fields "$NOW")
assert_eq "$actual" "||||" "顶层非 object → 全空"

# ============ 主流程集成测试（kimi provider）============
echo
echo "main flow integration (kimi):"

TMP_CACHE=$(mktemp)
TMP_HIST=$(mktemp)
trap 'rm -f "$TMP_CACHE" "$TMP_HIST"' EXIT

FAKE_STDIN='{"model":{"display_name":"k3[1m]"},"context_window":{"used_tokens":780000,"max_tokens":1000000}}'

# 未来 UTC 时间（BSD/GNU date 兼容）
future_utc() {
  local ts=$(( $(date +%s) + $1 ))
  date -u -r "$ts" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$ts" +"%Y-%m-%dT%H:%M:%SZ"
}

# 5h reset +2h（elapsed≈60% → marker_pos=4 → ┊ 显 + Δ 显）
# 周 reset +3d（elapsed≈57% → ┊ 显）
cat > "$TMP_CACHE" <<EOF
{
  "usage": {"limit":"100","used":"2","remaining":"98","resetTime":"$(future_utc 259200)"},
  "limits": [
    {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
     "detail":{"limit":"100","used":"11","remaining":"89","resetTime":"$(future_utc 7200)"}}
  ]
}
EOF

output=$(STATUSLINE_PROVIDER=kimi STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>&1 1>/dev/null | grep -E "DEBUG|input")
output_real=$(STATUSLINE_PROVIDER=kimi STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
echo "=== STDERR DUMP (line by line) ==="
echo "$output" | sed 's/^/  /'
echo "=== END STDERR ==="
output="$output_real"

assert_match "$output" 'k3' "model 名显示"
five_piece=$(echo "$output" | grep -oE '5h[^·]*' || true)
week_piece=$(echo "$output" | grep -oE '周[^·]*' || true)

assert_match "$five_piece" '11%' "5h piece 显 11%（used=11）"
assert_match "$five_piece" '┊' "5h elapsed≈60% → ┊ 显"
assert_match "$five_piece" '↓-4[0-9]%' "5h Δ = 11-60 ≈ ↓-49% 显"
assert_match "$week_piece" '2%' "周 piece 显 2%（used=2）"
assert_match "$week_piece" '┊' "周 elapsed≈57% → ┊ 显"

# provider=minimax + kimi cache → 解析不出 model_remains → 5h/周 piece 都不显（降级）
output=$(STATUSLINE_PROVIDER=minimax STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
if [[ "$output" == *"5h"* || "$output" == *"周"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     got: %q\n' "minimax provider + kimi cache → 5h/周 不显" "$output"
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "minimax provider + kimi cache → 5h/周 静默省略"
fi
# 同时断言主流程活着（防空输出假阳性）
assert_match "$output" 'ctx' "错配时 ctx 段仍显示（主流程没崩）"

# 反方向：provider=kimi + minimax cache → kimi_fields 解析全空 → 同样静默省略
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
output=$(STATUSLINE_PROVIDER=kimi STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
if [[ "$output" == *"5h"* || "$output" == *"周"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     got: %q\n' "kimi provider + minimax cache → 5h/周 不显" "$output"
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "kimi provider + minimax cache → 5h/周 静默省略"
fi
assert_match "$output" 'ctx' "反向错配时 ctx 段仍显示"

# 回归：cache 不存在 + 无 token → 主流程不崩（set -u 下 FIVE_USED/WEEK_USED 未绑定的既有 bug）
# 整条 statusline 变空是第一约定禁止的；这条测试挡该回归
NO_CACHE="$(mktemp -u)"  # 只取路径不建文件
output=$(STATUSLINE_PROVIDER=kimi STATUSLINE_CACHE_FILE="$NO_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
  ANTHROPIC_AUTH_TOKEN='' KIMI_API_KEY='' MINIMAX_API_KEY='' \
  bash "$SCRIPT_DIR/../statusline.sh" <<< "$FAKE_STDIN" 2>/dev/null)
assert_match "$output" 'ctx' "无 cache 无 token → ctx 段仍显示（整条不变空）"
if [[ "$output" == *"5h"* || "$output" == *"周"* ]]; then
  FAIL=$((FAIL+1))
  printf '  \033[31m✗\033[0m %s\n     got: %q\n' "无 cache → 5h/周 不显" "$output"
else
  PASS=$((PASS+1))
  printf '  \033[32m✓\033[0m %s\n' "无 cache → 5h/周 静默省略"
fi

echo
echo "------"
echo "PASS: $PASS, FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
