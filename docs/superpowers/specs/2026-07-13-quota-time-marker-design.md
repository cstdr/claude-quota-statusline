# 2026-07-13 — 配额进度条时间标记

## 目标

在 5h 和周额度的进度条上叠加一条 dim 灰虚线 `┊`，标记"当前时间在 cycle 内走到哪"。filled-bar 位置 vs 虚线位置直观对比 quota 烧速 vs 时间流速：

- filled 在虚线**右** → 烧得比时间快（警惕）
- filled 在虚线**左** → 烧得比时间慢（富裕）

行末附 `↑+N%` / `↓-N%` / `↓0%` 差值（color 跟 used%）。

## 范围

**In scope**
- 5h piece 的进度条：加虚线 + Δ
- 周 piece 的进度条：加虚线 + Δ
- 周期长度常量：5h = 18_000_000 ms；周 = 604_800_000 ms（7d）

**Out of scope**
- ctx bar **不**加虚线（context window 无 reset 概念）
- video 计数 piece **不**加虚线（count-based，无百分比）
- 不改 burn estimate（`≈Xh`）的显示逻辑
- 不改 cache / fetch / burn rate 历史的实现

## 设计决策（已与用户确认）

| # | 决策 | 选项 | 选 |
|---|------|------|----|
| 1 | 虚线字符 | A `┊` / B 替换 empty / C ⠂ / D │ / E · | **A `┊`（U+250A）** |
| 2 | 与 filled 重叠时 | Y-1 隐藏 / Y-2 强制可见 / Y-3 颜色延伸 | **Y-2（虚线在前面，强制可见）** |
| 3 | 虚线颜色 | C-1 dim 灰 / C-2 白 / C-3 青色 / C-4 随 used | **C-1 dim 灰** |
| 4 | 数字标签 | L-1 无 / L-2 T% / L-3 X/Y/T / L-4 Δ only | **L-4 只显 Δ** |
| 5 | Δ 方向 | D-1 ↑↓ 全显 / D-2 只显危险 | **D-1 ↑↓ 全显** |
| 6 | reset_ms 缺失 | E-1 整段不显 / E-2 bar 保留无虚线 | **E-2 bar 保留，不画虚线** |

## 行为规范

### 公式

```
elapsed_pct  = (period_ms - reset_ms) / period_ms × 100
marker_pos   = clamp(elapsed_pct × width / 100, 0, width)
delta_pct    = used_pct - elapsed_pct    # 正=快，负=慢，0=持平
```

### 虚线显示条件（全部满足才画）

1. `reset_ms` 存在且为正整数
2. `reset_ms ≤ period_ms`（防止"负 elapsed"）
3. `marker_pos > 0`（不是刚 reset）
4. `marker_pos < width`（不是即将 reset）
5. `period_ms > 0`（defensive）

任一不满足 → bar 不画虚线、不算 Δ。

### 重叠渲染（Y-2 模式）

- 虚线永远在 filled **前面**（覆盖在 bar 字符之上）
- 颜色：dim 灰（DIM）
- 不管 `marker_pos` 与 `filled_pos` 谁大谁小都画（只要在 1..width-1 范围内）

### Δ 显示（D-1）

- `delta > 0` → `↑+N%`（color = used% 同色）
- `delta < 0` → `↓-N%`（color = used% 同色）
- `delta == 0` → `↓0%`（color = used% 同色，保留箭头便于扫读）
- 始终显示（满足上面 5 个条件就一定有 Δ）

### 边界 / 数据缺失

| 场景 | bar | 虚线 | ↻ | Δ |
|------|-----|------|---|---|
| `reset_ms` 缺失 | 显示 | 不画 | 不显示 | 不显示 |
| `reset_ms=period_ms`（刚 reset） | 显示 | 不画（marker_pos=0） | 显示 | 不显示 |
| `reset_ms<period_ms` 但 elapsed=0% | 显示 | 不画 | 显示 | 不显示 |
| `reset_ms=0`（即将 reset） | 显示 | 不画（marker_pos=width） | 显示 | 不显示 |
| `reset_ms>period_ms`（异常） | 显示 | 不画（视为 elapsed=0） | 显示 | 不显示 |

### 完整渲染示例

**marker 替换模式**（推荐）：marker 替换 `bar_str` 在 `marker_pos` 位置的字符，bar 宽度保持 8 不变。
数学：`filled = pct × 8 / 100`（bash 整数除法），`marker = elapsed_pct × 8 / 100`。

```
5h 慢烧:  5h ▆▆░░┊░░░ 30% ↻ 2h ↓-30%   (filled=2, marker=4, 替换位置 4 的 ░)
5h 持平:  5h ▆▆▆▆┊░░░ 60% ↻ 2h ↓0%      (filled=4, marker=4, 替换位置 4 的 ░)
5h 快烧:  5h ▆▆┊▆▆▆▆░ 75% ↻ 1h ↑+45%   (filled=6, marker=2, 替换位置 2 的 ▆)
5h 临界:  5h ▆▆▆▆┊▆▆▆░ 90% ↻ 30m ↑+40% (filled=7, marker=4, 替换位置 4 的 ▆)
周 boost: 周 ▆▆▆▆▆▆┊░ 91/150 ↻ 4d ↑+16% (filled=7, marker=6, 替换位置 6 的 ▆)
缺数据:   5h ▆▆▆▆░░░░ 50%                (无虚线无↻无Δ)
```

## 实现策略

采用方案 **B**（保留 `bar()` 不动，新加 `overlay_marker()` 函数）：

- `bar(used_pct, width)` — 保持现状：只产 `▆▆▆░░░` 这种纯进度条
- `overlay_marker(bar_str, marker_pos, width)` — 在 `bar_str[marker_pos]` 位置覆盖 `┊`（dim 灰）
- `format_elapsed_marker(reset_ms, period_ms, width)` — 算 `marker_pos` 和 `delta_pct`，返回空 / `┊` / `┊`+`Δ`
- 三个新函数都是纯函数（无副作用），可独立单测

### 新增 shell 常量

```bash
PERIOD_5H_MS=18000000           # 5 × 3600 × 1000
PERIOD_WEEK_MS=604800000        # 7 × 24 × 3600 × 1000
```

### 主流程改动点（statusline.sh）

仅改两个地方：
1. 5h piece：`FIVE_BAR=$(bar "$FIVE_USED")` → 计算 marker → `FIVE_BAR=$(overlay_marker "$FIVE_BAR" "$FIVE_MARKER_POS" 8)`；附 Δ
2. 周 piece：同上

ctx / video 块逻辑不变。

## 组件 / 接口

### `overlay_marker(bar_str, marker_pos, width)`

- 入参：bar 字符串（已含 ANSI 颜色码）、marker 位置（0..width）、bar 宽度
- 行为：在 `bar_str` 中找到第 `marker_pos` 个"可见字符位"，用 `${DIM}┊${RST}` 替换
- 不修改 filled / empty 区的颜色
- 返回新的 bar 字符串
- 边界：`marker_pos` 不在 `1..width-1` 范围 → 原样返回

### `format_elapsed_marker(reset_ms, period_ms, used_pct, width)`

- 入参：reset 剩余 ms、周期 ms、used%、bar 宽度
- 输出：形如 `${DIM}┊${RST}`（仅虚线片段，无 Δ）—— 实际拼接由主流程负责
- 行为：5 个显示条件任意不满足 → 输出空
- 同时可由调用方拿 delta_pct 用于拼 Δ

### `format_delta_piece(delta_pct, used_pct)`

- 入参：Δ、used%
- 输出：`${COL}↑+45%${RST}` / `${COL}↓-30%${RST}` / `${COL}↓0%${RST}`
- color = `colorize_used "$used_pct"`（同 used% 染色）

## 数据流

```
CACHE_FILE (5h% / 5h_reset / week% / week_reset / boost)
    ↓
jq 解析（已有）
    ↓
FIVE_USED / FIVE_RESET_MS / WEEK_USED / WEEK_RESET_MS / WEEK_TOTAL
    ↓
[新] FIVE_MARKER_POS = format_elapsed_marker(FIVE_RESET_MS, 5h, FIVE_USED, 8)
[新] FIVE_BAR = overlay_marker(FIVE_BAR, FIVE_MARKER_POS, 8)
[新] FIVE_DELTA = format_delta_piece(used-elapsed, FIVE_USED)
    ↓
FIVE_PIECE 拼接（"5h " + bar + " " + pct% + " ↻ Xh" + " ↑+N%"）
```

## 测试

### 单元测试（bash + assert）

1. `bar()` 行为不变（已有覆盖）
2. `overlay_marker`：
   - 位置 0 / 位置 width → 原样返回
   - 位置 1..width-1 → 该位置字符变为 `┊`
   - 多次调用叠加 = 仍只一个 ┊
3. `format_elapsed_marker`：
   - `reset_ms` 缺失 → 输出空
   - `reset_ms > period_ms` → 输出空
   - `reset_ms = period_ms` → 输出空（marker_pos=0）
   - `reset_ms = 0` → 输出空（marker_pos=width）
   - 正常情况 → 输出 `${DIM}┊${RST}`
4. `format_delta_piece`：
   - 正 → `↑+N%`
   - 负 → `↓-N%`
   - 零 → `↓0%`
   - color 跟 used% 阈值（≥85 红 / ≥60 黄 / 其余 绿）
5. 主流程集成：
   - `STATUSLINE_LIB_MODE=1` 下注入假数据（5h 慢烧 / 快烧 / 持平 / 缺 reset_ms），跑主流程断言 OUTPUT 字符串含/不含 `┊` 和 `↑/↓`
   - 与 `tests/test_statusline.sh` 现有 16+ 用例兼容

### 视觉对账

- 在真实 statusline 上肉眼对比：5h 慢烧场景下虚线在 filled 右边
- reset 后第一个 statusline 调用应跳过虚线（marker_pos=0）

## 风险与对策

| 风险 | 对策 |
|------|------|
| `bar_str` 里有 ANSI 转义码时按"位置"算字符索引会偏 | `overlay_marker` 用 awk 或 sed 剥离 ANSI 后数可见字符 |
| 5h / 周 reset_ms 跨过 0 时负数（应不会发生） | `(( reset_ms < 0 ))` 视为缺失 |
| `remains_time` 字段从 API 缺失时整段逻辑异常 | 5 个显示条件都包含 `reset_ms` 存在性检查 |
| 整数除法截断（与 R5/R6 同样的坑） | `marker_pos = elapsed_pct × width / 100` 用 bash `(( ))` 截断；width=8 ⇒ 1 格 = 12.5% 精度（与 bar 精度一致） |

## 防御层级

- L1：bar / overlay_marker / format_* 全部纯函数 + STATUSLINE_LIB_MODE=1 可单测
- L2：主流程 5 个显示条件显式检查 + 任意失败回落到"无虚线"（不破坏现有显示）
- L3：与 ctx bar 解耦（ctx 走自己的分支），与 video piece 解耦（count-based 不动）

## 落地对照

新增：
- 3 个纯函数（`overlay_marker` / `format_elapsed_marker` / `format_delta_piece`）
- 2 个常量（`PERIOD_5H_MS` / `PERIOD_WEEK_MS`）
- 主流程 2 段（5h / 周）各 ~3 行

修改：
- `statusline.sh` 主流程 5h / 周 piece 拼接段
- `tests/` 加 4-6 个新测试用例
- `DESIGN.md` 加一节说明本功能（便于 blog 取材）

不修改：
- `bar()` 函数
- 任何 ctx / video / cache / fetch / burn rate 相关代码

## 关联 memory

- [[statusline-v2-summary]] — 当前 statusline 状态
- [[feature-utility-check]] — R6 sparkline 回滚教训：本功能用户已经 4 轮逐项确认设计，**用得上**的概率高（vs 抽象"酷炫"功能）
