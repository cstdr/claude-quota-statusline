# 配额进度条时间标记 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 5h / 周额度的进度条上叠加 dim 灰 ┊ 虚线 + Δ 箭头，对比"时间走了多远" vs "quota 用了多少"

**Architecture:** 4 个新纯函数（`marker_pos` / `elapsed_pct` / `overlay_marker` / `format_delta_piece`）+ 2 个常量（`PERIOD_5H_MS` / `PERIOD_WEEK_MS`）。`bar()` 函数零修改。`overlay_marker` 拆 bar 为 pre/post 段，让 marker 走 dim 灰、其余走 used% 颜色。`STATUSLINE_LIB_MODE=1` source 模式可单测。

**Tech Stack:** bash 5+、jq（已有）、POSIX `printf`、bash 整数算术 `(( ))`

---

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `statusline.sh` | 修改 | 加 2 常量 + 4 纯函数 + 主流程 5h/周 piece 各 ~5 行 |
| `tests/test_time_marker.sh` | 新建 | 新加 4 个函数的纯函数测试（~20 个断言） |
| `DESIGN.md` | 修改 | 加 "改动 8" 一节说明本功能（博客素材） |
| `tests/run_all.sh` | 不改 | 自动跑 `test_*.sh`，新建文件自动被捕获 |

---

## Task 1: 加周期常量

**Files:**
- Modify: `statusline.sh:24`（在 `HIST_WINDOW_SECS=300` 后面）

- [ ] **Step 1: 打开 `statusline.sh` 找插入点**

读 `statusline.sh`，确认 `HIST_WINDOW_SECS=300` 在第 26 行附近。

- [ ] **Step 2: 在 `HIST_WINDOW_SECS=300` 后面加 2 行**

在 `HIST_WINDOW_SECS=300  # 5 分钟窗口` 后面追加：

```bash

# 配额周期长度（用于算 time marker）
# 5h 区间 = 5 × 3600 × 1000 ms
PERIOD_5H_MS=18000000
# 周区间 = 7 × 24 × 3600 × 1000 ms
PERIOD_WEEK_MS=604800000
```

- [ ] **Step 3: 验证 shellcheck 通过**

Run: `shellcheck statusline.sh`
Expected: 无新增警告（已有规则下不应该有警告）

- [ ] **Step 4: 验证 statusline 仍可执行**

Run: `STATUSLINE_LIB_MODE=1 bash -c 'source ./statusline.sh && echo "PERIOD_5H_MS=$PERIOD_5H_MS PERIOD_WEEK_MS=$PERIOD_WEEK_MS"'`
Expected: 输出 `PERIOD_5H_MS=18000000 PERIOD_WEEK_MS=604800000`

- [ ] **Step 5: Commit**

```bash
git add statusline.sh
git commit -m "feat: 加 PERIOD_5H_MS / PERIOD_WEEK_MS 常量（time marker 基础）"
```

---

## Task 2: 实现 `marker_pos` + 单测（TDD）

**Files:**
- Modify: `statusline.sh`（在 `bar()` 函数后面插入新函数）
- Create: `tests/test_time_marker.sh`

- [ ] **Step 1: 新建 `tests/test_time_marker.sh` 写第一个测试**

```bash
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
```

- [ ] **Step 2: 跑测试确认失败（marker_pos 未定义）**

Run: `bash tests/test_time_marker.sh`
Expected: 失败，`marker_pos: command not found` 或类似错误

- [ ] **Step 3: 在 `statusline.sh` 的 `bar()` 函数后面实现 `marker_pos`**

在 `bar()` 函数结束的 `}` 后面（`statusline.sh` 第 51 行 `printf '%s' "${f// /█}${e// /░}"` 后面 `}` 之后）插入：

```bash

# time marker 位置：reset_ms 相对 period_ms 的 elapsed 百分比，按 width 量化
# 返回 0..width 之间的整数；满足任一"不画"条件返回空串
# 不画条件（与 spec 一致）：reset_ms 缺失/非数字/<=0/>=period/period<=0
marker_pos() {
  local reset_ms="$1" period_ms="$2" width="$3"
  # 类型 / 范围检查
  [[ ! "$reset_ms"  =~ ^[0-9]+$ ]] && return
  [[ ! "$period_ms" =~ ^[0-9]+$ ]] && return
  (( reset_ms <= 0 ))      && return
  (( period_ms <= 0 ))     && return
  (( reset_ms >= period_ms )) && return
  # 算 elapsed_pct（先乘后除，避大数截断）
  local elapsed_pct=$(( (period_ms - reset_ms) * 100 / period_ms ))
  # 边界：刚好 0% 或 100% 不画（marker 在边沿没有信息量）
  (( elapsed_pct <= 0 ))   && return
  (( elapsed_pct >= 100 )) && return
  local pos=$(( elapsed_pct * width / 100 ))
  # 防御性 clamp（理论上已经在 0..width 范围内）
  (( pos <= 0 ))    && return
  (( pos >= width )) && return
  printf '%d' "$pos"
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_time_marker.sh`
Expected: 全部 PASS（10 个断言）

- [ ] **Step 5: Commit**

```bash
git add statusline.sh tests/test_time_marker.sh
git commit -m "feat: 加 marker_pos() 纯函数 + 10 个单测"
```

---

## Task 3: 实现 `elapsed_pct` + 单测

**Files:**
- Modify: `statusline.sh`（紧跟 `marker_pos` 后面）
- Modify: `tests/test_time_marker.sh`（追加测试）

- [ ] **Step 1: 在 `tests/test_time_marker.sh` 追加 `elapsed_pct` 测试**

在 `marker_pos` 测试块后面、文件末尾的 `[[ $FAIL -eq 0 ]] && exit 0 || exit 1` 前面追加：

```bash

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_time_marker.sh`
Expected: `elapsed_pct: command not found`，前 10 个 PASS，后 9 个 FAIL

- [ ] **Step 3: 在 `statusline.sh` 实现 `elapsed_pct`**

在 `marker_pos` 函数后面追加：

```bash

# time marker elapsed 百分比：相对周期长度，走了多少 %
# 不画条件与 marker_pos 对齐（缺失/越界 → 空）
elapsed_pct() {
  local reset_ms="$1" period_ms="$2"
  [[ ! "$reset_ms"  =~ ^[0-9]+$ ]] && return
  [[ ! "$period_ms" =~ ^[0-9]+$ ]] && return
  (( reset_ms <= 0 ))      && return
  (( period_ms <= 0 ))     && return
  (( reset_ms >= period_ms )) && return
  local pct=$(( (period_ms - reset_ms) * 100 / period_ms ))
  (( pct <= 0 ))   && return
  (( pct >= 100 )) && return
  printf '%d' "$pct"
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_time_marker.sh`
Expected: 全部 PASS（19 个断言）

- [ ] **Step 5: Commit**

```bash
git add statusline.sh tests/test_time_marker.sh
git commit -m "feat: 加 elapsed_pct() 纯函数 + 9 个单测"
```

---

## Task 4: 实现 `overlay_marker` + 单测

**Files:**
- Modify: `statusline.sh`（紧跟 `elapsed_pct` 后面）
- Modify: `tests/test_time_marker.sh`（追加测试）

- [ ] **Step 1: 追加 `overlay_marker` 测试**

在 `elapsed_pct` 测试块后面追加：

```bash

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
# bar "▆▆▆▆▆▆░░" (6 filled + 2 empty)，marker=2 → "▆▆┊▆▆▆▆░" (replace 3rd char)
actual=$(overlay_marker "▆▆▆▆▆▆░░" 2 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}▆▆▆▆░${RST_CODE}"
assert_eq "$actual" "$expected" "marker=2 over filled → ┊ dim 替换 filled 字符"

# 边界：marker=1（最左）
actual=$(overlay_marker "▆▆▆▆▆▆▆▆" 1 8 "$GRN_CODE")
expected="${GRN_CODE}▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}▆▆▆▆▆▆▆${RST_CODE}"
assert_eq "$actual" "$expected" "marker=1 → pre 1 char，post 7 char"

# 边界：marker=7（最右有效位）
actual=$(overlay_marker "▆▆▆▆▆▆▆▆" 7 8 "$GRN_CODE")
expected="${GRN_CODE}▆▆▆▆▆▆▆${RST_CODE}${DIM_CODE}┊${RST_CODE}${GRN_CODE}▆${RST_CODE}"
assert_eq "$actual" "$expected" "marker=7 → pre 7 char，post 1 char"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_time_marker.sh`
Expected: `overlay_marker: command not found`，前 19 个 PASS，6 个 overlay_marker FAIL

- [ ] **Step 3: 在 `statusline.sh` 实现 `overlay_marker`**

在 `elapsed_pct` 后面追加：

```bash

# 在 bar_str 的 marker_pos 位置插入 dim 灰 ┊
# bar_str 来自 bar()，是纯字符（不含 ANSI）；插入后整段包上 bar_color
# marker_pos 不在 1..width-1 → 原样包 bar_color 返回
# 用 bash 内置字符串切片避免 awk 依赖
overlay_marker() {
  local bar_str="$1" pos="$2" width="$3" bar_color="$4"
  # 越界 → 不画 marker
  if (( pos <= 0 || pos >= width )); then
    printf '%s%s%s' "$bar_color" "$bar_str" "$RST"
    return
  fi
  # 切片：0..pos-1 是 pre，pos..end 是 post（bash 字符串索引 0-based）
  local pre="${bar_str:0:pos}"
  local post="${bar_str:pos}"
  printf '%s%s%s%s%s%s%s' "$bar_color" "$pre" "$RST" "$DIM" '┊' "$RST" "$bar_color" "$post"
  # 注意：RST 是 ${RST}=$'\033[0m'（statusline.sh 已定义）
}
```

注意：`statusline.sh` 顶部定义了 `RST=$'\033[0m'`，可直接用。`DIM` 同样已定义。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_time_marker.sh`
Expected: 全部 PASS（25 个断言）

- [ ] **Step 5: Commit**

```bash
git add statusline.sh tests/test_time_marker.sh
git commit -m "feat: 加 overlay_marker() 纯函数 + 6 个单测"
```

---

## Task 5: 实现 `format_delta_piece` + 单测

**Files:**
- Modify: `statusline.sh`（紧跟 `overlay_marker` 后面）
- Modify: `tests/test_time_marker.sh`（追加测试）

- [ ] **Step 1: 追加 `format_delta_piece` 测试**

在 `overlay_marker` 测试块后面追加：

```bash

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test_time_marker.sh`
Expected: `format_delta_piece: command not found`

- [ ] **Step 3: 在 `statusline.sh` 实现 `format_delta_piece`**

在 `overlay_marker` 后面追加：

```bash

# Δ 差值显示：↑+N% / ↓-N% / ↓0%
# color 跟 used%（与 bar 一致）
# delta_pct=0 也保留 ↓ 箭头（便于扫读，与 spec 一致）
format_delta_piece() {
  local delta="$1" used_pct="$2"
  local col
  col=$(colorize_used "$used_pct")
  if (( delta > 0 )); then
    printf '%s↑+%d%%%s' "$col" "$delta" "$RST"
  else
    # delta <= 0 都用 ↓（包含 0 持平、负数慢烧）
    # 用绝对值显示
    printf '%s↓%d%%%s' "$col" "$delta" "$RST"
  fi
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test_time_marker.sh`
Expected: 全部 PASS（35 个断言）

- [ ] **Step 5: Commit**

```bash
git add statusline.sh tests/test_time_marker.sh
git commit -m "feat: 加 format_delta_piece() 纯函数 + 10 个单测"
```

---

## Task 6: 主流程接入 5h piece

**Files:**
- Modify: `statusline.sh:255-263`（5h piece 拼接段）

- [ ] **Step 1: 读 `statusline.sh` 5h piece 段确认改动点**

读 `statusline.sh` 第 250-265 行，结构大致是：
```bash
FIVE_PIECE=""
if [[ "$FIVE_REM" =~ ^[0-9]+$ ]]; then
  FIVE_USED=$(( 100 - FIVE_REM ))
  FIVE_COL=$(colorize_used "$FIVE_USED")
  FIVE_BAR=$(bar "$FIVE_USED")
  FIVE_PIECE="${DIM}5h${RST} ${FIVE_COL}${FIVE_BAR} ${FIVE_USED}%${RST}"
  if [[ "$FIVE_RESET_MS" =~ ^[0-9]+$ ]]; then
    FIVE_RESET=$(format_remaining_ms "$FIVE_RESET_MS")
    FIVE_RESET_COL=$(colorize_reset "$FIVE_RESET_MS")
    FIVE_PIECE="${FIVE_PIECE} ${FIVE_RESET_COL}↻${RST} ${FIVE_RESET}"
  fi
  FIVE_EST=$(format_burn_estimate "$HIST_FILE" "$FIVE_USED" 100 "$HIST_WINDOW_SECS" 2)
  [[ -n "$FIVE_EST" ]] && FIVE_PIECE="${FIVE_PIECE} ${DIM}${FIVE_EST}${RST}"
fi
```

- [ ] **Step 2: 修改 bar 生成 + 加 marker + 加 Δ**

把 `FIVE_BAR=$(bar "$FIVE_USED")` 这一行替换为：
```bash
  FIVE_BAR=$(bar "$FIVE_USED")
  # time marker（reset_ms 缺失时 marker_pos 为空，overlay_marker 走"无 ┊"分支）
  FIVE_MARKER_POS=$(marker_pos "$FIVE_RESET_MS" "$PERIOD_5H_MS" 8)
  FIVE_BAR=$(overlay_marker "$FIVE_BAR" "${FIVE_MARKER_POS:-0}" 8 "$FIVE_COL")
```

并在 `if [[ "$FIVE_RESET_MS" =~ ^[0-9]+$ ]]; then` 块**后面**追加 Δ 计算：
```bash
  # Δ 差值（reset_ms 缺失时不显）
  FIVE_ELAPSED_PCT=$(elapsed_pct "$FIVE_RESET_MS" "$PERIOD_5H_MS")
  if [[ -n "$FIVE_ELAPSED_PCT" ]]; then
    FIVE_DELTA=$(format_delta_piece $(( FIVE_USED - FIVE_ELAPSED_PCT )) "$FIVE_USED")
    FIVE_PIECE="${FIVE_PIECE} ${FIVE_DELTA}"
  fi
```

完整 5h 块改完后长这样：

```bash
FIVE_PIECE=""
if [[ "$FIVE_REM" =~ ^[0-9]+$ ]]; then
  FIVE_USED=$(( 100 - FIVE_REM ))
  FIVE_COL=$(colorize_used "$FIVE_USED")
  FIVE_BAR=$(bar "$FIVE_USED")
  # time marker（reset_ms 缺失时 marker_pos 为空，overlay_marker 走"无 ┊"分支）
  FIVE_MARKER_POS=$(marker_pos "$FIVE_RESET_MS" "$PERIOD_5H_MS" 8)
  FIVE_BAR=$(overlay_marker "$FIVE_BAR" "${FIVE_MARKER_POS:-0}" 8 "$FIVE_COL")
  FIVE_PIECE="${DIM}5h${RST} ${FIVE_BAR} ${FIVE_USED}%${RST}"
  if [[ "$FIVE_RESET_MS" =~ ^[0-9]+$ ]]; then
    FIVE_RESET=$(format_remaining_ms "$FIVE_RESET_MS")
    FIVE_RESET_COL=$(colorize_reset "$FIVE_RESET_MS")
    FIVE_PIECE="${FIVE_PIECE} ${FIVE_RESET_COL}↻${RST} ${FIVE_RESET}"
  fi
  # Δ 差值（reset_ms 缺失时不显）
  FIVE_ELAPSED_PCT=$(elapsed_pct "$FIVE_RESET_MS" "$PERIOD_5H_MS")
  if [[ -n "$FIVE_ELAPSED_PCT" ]]; then
    FIVE_DELTA=$(format_delta_piece $(( FIVE_USED - FIVE_ELAPSED_PCT )) "$FIVE_USED")
    FIVE_PIECE="${FIVE_PIECE} ${FIVE_DELTA}"
  fi
  FIVE_EST=$(format_burn_estimate "$HIST_FILE" "$FIVE_USED" 100 "$HIST_WINDOW_SECS" 2)
  [[ -n "$FIVE_EST" ]] && FIVE_PIECE="${FIVE_PIECE} ${DIM}${FIVE_EST}${RST}"
fi
```

注意：`FIVE_BAR` 现在**已含 color**（由 `overlay_marker` 内部包了 `FIVE_COL`），所以 `${FIVE_COL}${FIVE_BAR}` 重复包会出问题。已用 `${FIVE_BAR}` 直接嵌入（不重复加 `FIVE_COL`）。

- [ ] **Step 3: 跑全测确认没破坏现有**

Run: `bash tests/run_all.sh`
Expected: 全部通过（包括 `test_statusline.sh` 如果存在、`test_utils.sh`、`test_count_piece.sh`、新加的 `test_time_marker.sh`）

- [ ] **Step 4: shellcheck 通过**

Run: `shellcheck statusline.sh`
Expected: 无新增警告

- [ ] **Step 5: Commit**

```bash
git add statusline.sh
git commit -m "feat: 主流程 5h piece 接入 time marker 虚线 + Δ"
```

---

## Task 7: 主流程接入周 piece

**Files:**
- Modify: `statusline.sh:264-291`（周 piece 拼接段）

- [ ] **Step 1: 读周 piece 段确认改动点**

读 `statusline.sh` 第 264-291 行，结构与 5h 块类似但有 `WEEK_TOTAL`（含 boost）和 `format_quota_label`。

- [ ] **Step 2: 加 marker + Δ**

在 `WEEK_BAR=$(bar "$WEEK_USED")` 后面加：
```bash
  WEEK_BAR=$(bar "$WEEK_USED")
  # time marker
  WEEK_MARKER_POS=$(marker_pos "$WEEK_RESET_MS" "$PERIOD_WEEK_MS" 8)
  WEEK_BAR=$(overlay_marker "$WEEK_BAR" "${WEEK_MARKER_POS:-0}" 8 "$WEEK_COL")
```

把 `WEEK_PIECE="${DIM}周${RST} ${WEEK_COL}${WEEK_BAR} ${WEEK_LABEL}${RST}"` 改为：
```bash
  WEEK_PIECE="${DIM}周${RST} ${WEEK_BAR} ${WEEK_LABEL}${RST}"
```

（`WEEK_BAR` 已含 `WEEK_COL`，不再重复包）

在 `if [[ "$WEEK_RESET_MS" =~ ^[0-9]+$ ]]; then` 块**后面**追加 Δ：
```bash
  # Δ 差值
  WEEK_ELAPSED_PCT=$(elapsed_pct "$WEEK_RESET_MS" "$PERIOD_WEEK_MS")
  if [[ -n "$WEEK_ELAPSED_PCT" ]]; then
    WEEK_DELTA=$(format_delta_piece $(( WEEK_USED - WEEK_ELAPSED_PCT )) "$WEEK_USED")
    WEEK_PIECE="${WEEK_PIECE} ${WEEK_DELTA}"
  fi
```

完整周块改完后长这样：

```bash
if [[ "$WEEK_REM" =~ ^[0-9]+$ ]]; then
  # 周配额有 boost：API 字段 current_weekly_remaining_percent 是以"含 boost 的 total"为分母的剩余%
  # weekly_boost_permille: 1500 = +50% boost → total = 150%
  # USED 公式：total - REM% × total / 100（与 dashboard "已用 X%" 的口径一致）
  # boost 字段缺失/为 0 时回落到基础公式（与 5h 一致）
  if [[ "$WEEK_BOOST_PERMILLE" =~ ^[0-9]+$ ]] && (( WEEK_BOOST_PERMILLE >= 1000 )); then
    WEEK_TOTAL=$(( WEEK_BOOST_PERMILLE / 10 ))
    # 公式：USED = TOTAL - REM% × TOTAL / 100。
    # 用 TOTAL * (100 - REM) / 100 形式而非 (TOTAL - REM * TOTAL / 100)，
    # 让 bash 整数除法截断发生在最后一步（避免 REM * TOTAL 中间产物被截断多 +1）。
    # 例：REM=39, TOTAL=150 → 后者 150-58=92，前者 150×61/100=91（与 dashboard 一致）
    WEEK_USED=$(( WEEK_TOTAL * (100 - WEEK_REM) / 100 ))
  else
    WEEK_TOTAL=100
    WEEK_USED=$(( 100 - WEEK_REM ))
  fi
  WEEK_COL=$(colorize_used "$WEEK_USED")
  WEEK_BAR=$(bar "$WEEK_USED")
  # time marker
  WEEK_MARKER_POS=$(marker_pos "$WEEK_RESET_MS" "$PERIOD_WEEK_MS" 8)
  WEEK_BAR=$(overlay_marker "$WEEK_BAR" "${WEEK_MARKER_POS:-0}" 8 "$WEEK_COL")
  WEEK_LABEL=$(format_quota_label "$WEEK_USED" "$WEEK_TOTAL")
  WEEK_PIECE="${DIM}周${RST} ${WEEK_BAR} ${WEEK_LABEL}${RST}"
  if [[ "$WEEK_RESET_MS" =~ ^[0-9]+$ ]]; then
    WEEK_RESET=$(format_remaining_ms "$WEEK_RESET_MS")
    WEEK_RESET_COL=$(colorize_reset "$WEEK_RESET_MS")
    WEEK_PIECE="${WEEK_PIECE} ${WEEK_RESET_COL}↻${RST} ${WEEK_RESET}"
  fi
  # Δ 差值
  WEEK_ELAPSED_PCT=$(elapsed_pct "$WEEK_RESET_MS" "$PERIOD_WEEK_MS")
  if [[ -n "$WEEK_ELAPSED_PCT" ]]; then
    WEEK_DELTA=$(format_delta_piece $(( WEEK_USED - WEEK_ELAPSED_PCT )) "$WEEK_USED")
    WEEK_PIECE="${WEEK_PIECE} ${WEEK_DELTA}"
  fi
  WEEK_EST=$(format_burn_estimate "$HIST_FILE" "$WEEK_USED" "$WEEK_TOTAL" "$HIST_WINDOW_SECS" 3)
  [[ -n "$WEEK_EST" ]] && WEEK_PIECE="${WEEK_PIECE} ${DIM}${WEEK_EST}${RST}"
fi
```

- [ ] **Step 3: 跑全测确认**

Run: `bash tests/run_all.sh`
Expected: 全部通过

- [ ] **Step 4: shellcheck 通过**

Run: `shellcheck statusline.sh`
Expected: 无新增警告

- [ ] **Step 5: 真实 statusline 烟雾测试**

让 statusline 跑一次真实渲染：
Run: `echo '{"model":{"display_name":"opus-4"},"context_window":{"used_tokens":1000,"max_tokens":10000}}' | bash statusline.sh`
Expected: 输出含 `5h` 段（如果 cache 有数据），结构正确。**注意**：cache 文件 `/tmp/claude-statusline-minimax-shared` 半小时内有效；如果想强制刷新就先 `rm` 它再跑。

- [ ] **Step 6: Commit**

```bash
git add statusline.sh
git commit -m "feat: 主流程周 piece 接入 time marker 虚线 + Δ"
```

---

## Task 8: 更新 DESIGN.md

**Files:**
- Modify: `DESIGN.md`（在 "改动 7" 后面追加 "改动 8"）

- [ ] **Step 1: 读 DESIGN.md 找插入点**

读 `DESIGN.md`，找 "改动 7" 章节结束的下一个 `##` 标题位置。

- [ ] **Step 2: 在 "改动 7" 后追加 "改动 8" 章节**

在 "改动 7" 结束后（约第 317 行附近）和 "踩过的坑" 之间插入：

```markdown
## 改动 8：5h/周进度条加 time marker 虚线 + Δ

### 问题

光看 used% 不知道"我烧得快不快"。例如 5h 用了 60%、剩 2h reset——
可能你 60% 烧了 2h（理想节奏），也可能烧了 4h（很慢），也可能烧了 1h（危险）。
但条上没时间维度，全靠用户自己心算。

### 方案

进度条上叠一条 dim 灰 `┊` 虚线，标"当前时间在 cycle 内走到哪"。

数学（先乘后除，否则大数截断）：
```
elapsed_pct = (period_ms - reset_ms) × 100 / period_ms
marker_pos  = elapsed_pct × 8 / 100
```

行末附 `↑+N%` / `↓-N%` / `↓0%` 差值（color 跟 used%）：

- filled 在虚线**右** → 烧得比时间快（警惕）
- filled 在虚线**左** → 烧得比时间慢（富裕）

新增 4 个纯函数（`marker_pos` / `elapsed_pct` / `overlay_marker` / `format_delta_piece`）+ 2 常量。
`bar()` 函数零修改 —— `overlay_marker` 把 bar 拆成 pre/post 段，让 marker 走 dim 灰、其余走 used% 颜色。

### 取舍

- **虚线在 filled 之上**（Y-2 模式）vs 后置隐藏（Y-1）：选 Y-2，强制可见，
  但代价是"marker over filled"时 filled 字符被 `┊` 替换（bar 看起来"破损"）。
  实测过：这是信息密度的必要 trade-off。
- **只显 Δ 不显 T%**（L-4）：行长度控住；用箭头方向承载"快/慢"信息，色块承载
  "严重程度"信息，符号 + 颜色 2 维度比纯数字更易扫读。
- **ctx / video 不画虚线**：ctx 没有 reset 概念，video 是 count-based。

### 渲染示例

```
5h 慢烧:  5h ▆▆░░┊░░░ 30% ↻ 2h ↓-30%
5h 快烧:  5h ▆▆┊▆▆▆▆░ 75% ↻ 1h ↑+45%
周 boost: 周 ▆▆▆▆▆▆┊░ 91/150 ↻ 4d ↑+16%
缺数据:   5h ▆▆▆▆░░░░ 50%          (无虚线无↻无Δ)
```

### 防御层级

- L1：4 个新函数全部纯函数 + `STATUSLINE_LIB_MODE=1` 可单测（`tests/test_time_marker.sh`，35 个断言）
- L2：5 个显示条件显式检查（reset_ms 缺失/越界/边界/period 异常），任意失败回落到"无虚线"
- L3：与 ctx / video 块完全解耦

```

- [ ] **Step 3: 在文末"落地差异（代码层面）"小节也加一行**

找到 "落地差异" 小节，在最后一行加：
```markdown
- 改动 8：5h/周 time marker 虚线 + Δ 箭头（statusline.sh 4 个新纯函数 + 主流程 2 段）
```

- [ ] **Step 4: Commit**

```bash
git add DESIGN.md
git commit -m "docs: DESIGN.md 加改动 8（time marker 虚线 + Δ）"
```

---

## Task 9: 最终回归

**Files:** 无（全测 + shellcheck + 视觉对账）

- [ ] **Step 1: 跑所有测试**

Run: `bash tests/run_all.sh`
Expected: 所有 test_*.sh 文件全过

- [ ] **Step 2: shellcheck**

Run: `shellcheck statusline.sh`
Expected: 无警告

- [ ] **Step 3: 真实 statusline 渲染对账**

Run: `echo '{"model":{"display_name":"opus-4"},"context_window":{"used_tokens":1000,"max_tokens":10000}}' | bash statusline.sh`
Expected: 输出 row 形如 `[opus-4] ctx ▆▆▆░░░░░ 10% · 5h <bar with ┊> N% ↻ Xh ↑/↓N% · 周 <bar with ┊> M/T ↻ Yd ↑/↓N%`

如果 `┊` 不出现：检查 `remains_time` 字段在 cache 里是否正常（`jq '.model_remains[0].remains_time' /tmp/claude-statusline-minimax-shared`）

- [ ] **Step 4: git log 检查提交粒度**

Run: `git log --oneline -10`
Expected: 看到 8 条 feat/docs commit（task 1~8），无合并/回滚

- [ ] **Step 5: 视觉肉眼看 30 秒**

- 看 5h 虚线是否清晰
- 看 Δ 颜色是否合理（绿富裕、黄一般、红危险）
- 看 ctx / video 是否没动

无新增 commit 必要

---

## Self-Review

- [x] **Spec coverage:**
  - 6 个决策：┊ ✓ (overlay_marker 用 '┊') / Y-2 ✓ (overlay_marker 把 marker 放 pre/post 中间) / C-1 dim 灰 ✓ (overlay_marker 用 $DIM) / L-4 Δ only ✓ (Task 6/7) / D-1 ↑↓ 全显 ✓ (format_delta_piece) / E-2 bar 保留 ✓ (overlay_marker 越界时输出无 ┊ 的 bar)
  - 5 个显示条件：marker_pos Task 2 / elapsed_pct Task 3 都实现
  - 边界：marker_pos=0 或 width → overlay_marker 走"无 ┊"分支；reset_ms 缺失 → elapsed_pct/marker_pos 输出空 → 主流程 `[[ -n "$FIVE_ELAPSED_PCT" ]]` 跳过 Δ
  - 公式顺序：先乘后除，spec 已修正（commit a42b82b）
  - ctx / video 不动：明确 out of scope，主流程只改 5h/周两块
  - 测试：35 个断言（10+9+6+10），含 6 个 overlay_marker ANSI 拼接验证
  - 防御层级：L1 纯函数 + 单测 / L2 5 条件显式 / L3 与 ctx/video 解耦

- [x] **Placeholder scan:** 0 个 TBD / TODO / "fill in"

- [x] **Type consistency:**
  - `marker_pos` 返回 0..width 整数 或 空
  - `elapsed_pct` 返回 0..100 整数 或 空
  - `overlay_marker(bar_str, pos, width, bar_color)` — 4 参数，Task 4 定义、Task 6/7 调用一致
  - `format_delta_piece(delta_pct, used_pct)` — 2 参数
  - `bar_str` 是纯字符（来自 `bar()`），不含 ANSI — Task 4 实现基于此
  - `RST` / `DIM` 用 statusline.sh 顶部全局定义

- [x] **文件路径：** 全部绝对或相对仓库根路径

- [x] **代码完整：** 每个 Step 的代码块都是可直接复制的最终代码

- [x] **commits 粒度：** 9 个 commit（task 1~8 各一个，task 9 验证无 commit）
