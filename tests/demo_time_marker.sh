#!/usr/bin/env bash
# demo_time_marker.sh — 跑 6 个场景展示 ┊ 虚线 + Δ 的实际渲染效果
# 不修改主 statusline，只用临时 cache 注入假数据

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 临时 cache / hist（不污染 /tmp 实际状态）
TMP_CACHE=$(mktemp "${ROOT}/.demo-time-marker-XXXXXX")
TMP_HIST=$(mktemp  "${ROOT}/.demo-hist-XXXXXX")
trap 'rm -f "$TMP_CACHE" "$TMP_HIST" "$TMP_CACHE"* "${TMP_HIST}"*' EXIT
touch "$TMP_HIST"  # format_burn_estimate 看到空文件走"数据 <3"分支 → 不显 ≈Xh

# session JSON（实际 CC 注入；model + context_window 都要有）
STDIN='{"model":{"display_name":"opus-4"},"context_window":{"used_tokens":780000,"max_tokens":1000000}}'

# 场景工厂：$1=reset5h_ms, $2=rem5h%, $3=resetW_ms, $4=remW%, $5=boost
write_cache() {
  local r5h="$1" p5h="$2" rW="$3" pW="$4" bst="$5"
  cat > "$TMP_CACHE" <<EOF
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": ${p5h},
      "remains_time": ${r5h},
      "current_weekly_remaining_percent": ${pW},
      "weekly_remains_time": ${rW},
      "weekly_boost_permille": ${bst}
    }
  ]
}
EOF
}

# 单行 demo：cache_file + 标签
# 真实环境的 statusline 会同时写 HIST_FILE 并据此推算 ≈Xh；
# 临时 HIST 是空的，所以 ≈Xh 不显 → 视觉更干净，只看 ┊ + Δ
run_scenario() {
  local label="$1"
  STATUSLINE_CACHE_FILE="$TMP_CACHE" STATUSLINE_HIST_FILE="$TMP_HIST" \
    bash "$ROOT/statusline.sh" <<< "$STDIN" 2>/dev/null \
    | sed "s|^|$label  |"
}

echo "================================================================"
echo "time marker 虚线 + Δ 差值 — 6 场景实际渲染"
echo "================================================================"
echo
echo "图例：┊ = 当前时间位置（dim 灰 强制可见）"
echo "      ↑ = 烧得比时间快（color 跟 used%：绿 < 黄 < 红）"
echo "      ↓ = 烧得比时间慢 / 持平（color 同上）"
echo "      █ = filled（color 跟 used%），░ = empty（dim）"
echo
echo "提示：色码是真实 ANSI——终端里 ctx/5h/周 三段 bar 与 ↑↓ 数字会"
echo "      真的染上对应颜色，dim ┊ 灰比正常字符淡一档。"
echo

# 场景 1：5h 慢烧 — filled=30% (pos 2), elapsed=60% (marker 4) → ┊ 在 filled 右
#         5h USED=30, elapsed=60, Δ=-30 (↓ 绿)
#         周 USED=13, elapsed=50, Δ=-37 (↓ 绿)
write_cache  7200000 70  302400000 87  1000
run_scenario "[1] 5h 慢烧   "

# 场景 2：5h 持平 — filled=60% (pos 4), marker=4 → 同一列，↓0%
#         5h USED=60, elapsed=60, Δ=0 (↓ 黄)
#         周 USED=50, elapsed=50, Δ=0 (↓ 黄)
write_cache  7200000 40  302400000 50  1000
run_scenario "[2] 5h 持平   "

# 场景 3：5h 快烧 — filled=75% (pos 6), elapsed=30% (marker 2) → ┊ 在 filled 左
#         5h USED=75, elapsed=30, Δ=+45 (↑ 黄)
#         周 USED=80, elapsed=14% (marker=1), elapsed=14 → ┊ 隐 + ↑ 隐
write_cache 12600000 25  518400000 0  1000
run_scenario "[3] 5h 快烧   "

# 场景 4：5h 临界 — used=90% (pos 7), elapsed=60% (marker 4) → ┊ 在 filled 内
#         5h USED=90, elapsed=60, Δ=+30 (↑ 红)
#         周 USED=120/150, elapsed=50, Δ=+70 (↑ 红)
write_cache  7200000 10  302400000 30  1500
run_scenario "[4] 5h 临界+周 boost "

# 场景 5：5h 50% 用量；周 USED=91/150（REM=39 ⇒ USED=150*61/100=91），elapsed=50%, Δ=+41 ↑
#         5h 5h USED=50, reset=17M, elapsed=5% → marker_pos=0 ⇒ ┊ 隐 + Δ 隐（与 spec 一致）
#         周 USED=91, elapsed=50%, marker_pos=4 ⇒ ┊ 显 + ↑+41%（红，因为 91≥85 红阈值）
write_cache 17280000  50  302400000  39  1500
run_scenario "[5] 周 boost 高用  "

# 场景 6：reset_ms 字段缺失（用 jq 删字段模拟 API 没返回）→ bar 保留无 ┊ 无 Δ
# 直接写 cache 且略过字段，让 jq 走 "" 占位 → marker_pos 空 → overlay_marker 走"无 ┊"分支
cat > "$TMP_CACHE" <<'EOF'
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 40,
      "current_weekly_remaining_percent": 50,
      "weekly_remains_time": 302400000,
      "weekly_boost_permille": 1000
    }
  ]
}
EOF
run_scenario "[6] 5h 无 reset  "

echo
echo "================================================================"
echo "对照解读（只看每行的中间 '┊' 位置与末尾 ↑↓ 数字）"
echo "================================================================"
echo
echo "  [1] 慢烧：┊ 在 ▆▆ 右边 + 末尾 ↓-30% / ↓-37% → 时间走得比用量快"
echo "  [2] 持平：┊ 跟 ▆▆▆▆ 对齐 + 末尾 ↓0% / ↓0% → 用量与时间同步"
echo "  [3] 快烧：┊ 在 ▆▆▆▆▆▆ 左边 + 末尾 ↑+45% → 用量跑赢时间"
echo "  [4] 临界：5h 黄 红 + ↑+30% / 周 ↑+70% 红 → 双红警告"
echo "  [5] 周 X/Y：91/150 显示分母 + ↑+41% 红 → 配额吃紧 + 烧快"
echo "  [6] 缺数据：bar 完整无 ┊ 无 Δ → 数据缺失静默回落"
