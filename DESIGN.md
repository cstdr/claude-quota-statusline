# Statusline v2 — 设计文档

> 配套脚本：`~/.claude/statusline.sh`
> 文档目的：把这次迭代的设计取舍沉淀下来，作为后续博客 / 分享的素材。
> 配套代码变更（4 个）见文末"落地差异"小节。

## 背景

Claude Code 的 statusline 是每个 tick 调用一次的 shell 脚本，数据源有两份：

1. **stdin** = Claude Code 注入的 session JSON（model / context_window / session_id）
2. **MiniMax `/v1/token_plan/remains`** = 5h / 周配额（每 session 一个 cache 文件，60s 刷新）

之前的迭代已经做了：颜色阈值、进度条、cache + atomic rename、graceful degradation。
这次针对三处明显瓶颈继续优化。

## 改动 1：合并 jq 调用 + 给周也加 ↻ reset

### 问题

抽 4 个字段（5h 剩余 %、5h 剩余 ms、周剩余 %、周剩余 ms）原本要 4 次独立 `jq -r`，每次 fork 一个进程。
statusline 每 60s 跑一次，多 session 场景下累加起来可观。

另外，周配额当时只显示了 %，没有 ↻ 重置倒计时——5h 有周没有，视觉不对称。

### 方案

合并成一次 jq 调用，用 `@tsv` 把 4 个字段拼成一行再读进 bash：

```bash
FIELDS=$(jq -r '
  (.model_remains // [])
  | map(select(.model_name=="general"))
  | .[0] // empty
  | [.current_interval_remaining_percent // empty,
     .remains_time // empty,
     .current_weekly_remaining_percent // empty,
     .weekly_remains_time // empty]
  | @tsv
' "$CACHE_FILE" 2>/dev/null)
```

然后 `IFS=$'\t' read -r FIVE_REM FIVE_RESET_MS WEEK_REM WEEK_RESET_MS <<<"$FIELDS"` 一次拆完。

复用同一份 `format_remaining_ms` 处理 weekly ↻。

### 收益

- ~3 次进程 fork → 1 次，省 ~60-90ms / refresh
- 视觉对称：5h ↔ 周 都有 `label bar pct% ↻ reset`

## 改动 2：跨 session 共享 cache

### 问题

cache 文件命名是 `/tmp/claude-statusline-minimax-$SESSION_ID`，每个 Claude Code session 独立一份。
多开几个 session = 几倍 HTTP 频率，对 MiniMax API 不友好，本机也无谓。

### 方案

把 cache 文件路径从 `$SESSION_ID` 切到一个固定名字：

```bash
CACHE_FILE="/tmp/claude-statusline-minimax-shared"
```

所有 session 共读一份，所有 statusline 进程靠 `mktemp` + `mv` 做 atomic rename（原有逻辑）来避免写竞态。

### 收益

- N 个 session × 1 次/分钟 → 1 次/分钟
- HTTP 流量降到 1/N

### 取舍

- 假设本机单用户、单 Anthropic 账号——Claude Code 的现实约束满足
- 不引入 per-user/per-key 维度，保持简单
- 60s 内任意 session 看到的数字都是同一个 cache 内的"快照"，无一致性问题

## 改动 3：reset 时间按紧迫度染色

### 问题

`↻ 1h45m` 永远是灰色（dim）。用户想判断"还剩多久能再用"得读数字、心算。

### 方案

新增 `colorize_reset` 函数（值越小越紧迫）：

```bash
colorize_reset() {
  local ms="${1:-0}"
  if   (( ms < 1800000 ));  then printf '%b' "$RED"   # < 30min
  elif (( ms < 7200000 ));  then printf '%b' "$YEL"   # < 2h
  else                          printf '%b' "$DIM"   # 否则保留 dim
  fi
}
```

阈值选择的理由：
- 30min：一般人一个 round-trip 长任务的平均耗时
- 2h：午休 / 短会议结束时常问"剩多少"的心理关口

### 收益

扫一眼就看出 panic time，不用读数字。

### 取舍

- 阈值是经验值，不做用户可配置（statusline 不该有配置文件）
- 没改 `bar()` 的 8 列宽——保持视觉稳定

## 设计上不做的

| 想法 | 不做的理由 |
|---|---|
| Powerline 箭头（❯）做分隔符 | 跨字体渲染宽度不一致，跨机器不通用 |
| 用 `end_time` 显示时刻（"12:34"）而非倒计时 | locale 复杂，倒计时更直接 |
| `stale-while-revalidate` + `(stale)` 标记 | 60s refresh 下视觉噪音大于价值；refresh 失败的兜底已经做了 |
| `current_interval_total_count` burn rate | 当前账号 API 返回的 count 是 0，没数据可算 |
| token 绝对数（`12k/200k`） | 本期范围外，power user feature 单独迭代 |

## 改动 4（迭代中发现）：ctx 改成 CC 同口径百分比

### 问题

原本的 statusline 用 `.context_window.used_percentage`，分母是 `total_tokens`。
CC 右下角的 "X% context used" 用的是 `used_tokens / max_tokens`，分母是给输入的预算
（`max_tokens = total_tokens - 给输出预留的 token`，通常预留 ~10%）。

实测对账：用户截图里 CC 显示 95%，旧 statusline 显示 85%，差距正好 ~10%。
原因正是分母不同，**不是脚本错了，是字段语义不同**。

### 方案

不再读 `used_percentage`，改读 `used_tokens` + `max_tokens`，自己算：

```bash
CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))
```

字段缺失时回落到原 `used_percentage` 兜底，保证向前兼容（老版本 Claude Code 没有 max_tokens 也不会崩）。

### 收益

statusline 的 ctx 数字与 CC 右下角完全一致，不再"看着不一样以为有 bug"。

## 改动 5（上线后用户反馈）：5h/周统一为"已使用%"

### 问题

ctx 是"已使用%"，5h/周原本显示"剩余%"。同一行里两种语义，读起来歧义——
`5h 65%` 是"还剩 65%"还是"已经用了 65%"？心智负担。

### 方案

API 字段是 remaining（这是 MiniMax 给的，没法改），所以**显示**时翻转：

```bash
FIVE_USED=$(( 100 - FIVE_REM ))
FIVE_COL=$(colorize_used "$FIVE_USED")    # 用 ctx 同口径的染色
FIVE_BAR=$(bar "$FIVE_USED")              # bar 也按 used 填充
FIVE_PIECE="... ${FIVE_USED}% ..."
```

颜色阈值从"remaining 视角"翻成"used 视角"，与 ctx 完全一致：
- ≥ 85% used → 红
- ≥ 60% used → 黄
- 其余 → 绿

旧的 `colorize_remaining` 函数随之删除——只剩 `colorize_used` 一份，ctx / 5h / 周 共用。

### 收益

- 三段输出语义统一：`ctx X%` / `5h X%` / `周 X%` 全是"已使用"
- 染色逻辑收敛到一处（`colorize_used`），阈值调整只改一行

### 取舍

- API 字段还是读 remaining（`current_interval_remaining_percent`），翻转在 bash 端做；
  字段是远程给的、不能假设有 `used_percent` 对偶字段
- bar 方向反过来：低配额时原本 `█████░░░`（剩余多=满），现在 `██░░░░░░░`（用得少=空）。
  视觉变化需要适应一下，但更贴合"已用"的直觉

## 改动 6（用户实测发现）：周配额有 boost，简单 `100 - REM` 算不对

### 问题

改动 5 之后用户实测发现：dashboard "周 已用 69%"，statusline 显示 "周 已用 46%"，对不上。
对账 API 实际返回：

```json
"current_weekly_remaining_percent": 54,
"weekly_boost_permille": 1500
```

**根因**：周配额有 boost。`weekly_boost_permille: 1500` = 1.5× = +50% boost。
API 的 `current_weekly_remaining_percent` 是以"含 boost 的 total"为分母的剩余%。

简单 `100 - REM` 算的是"基础配额内的 used"（=46%），但 dashboard 显示的是"含 boost 的绝对 used"（=69%）。

### 方案

提取 `weekly_boost_permille`，按含 boost 的 total 算 USED：

```bash
# boost_permille 1500 → total = 150%
# USED = total - REM% × total / 100 = 150 - 54 × 150 / 100 = 150 - 81 = 69
WEEK_TOTAL=$(( WEEK_BOOST_PERMILLE / 10 ))
WEEK_USED=$(( WEEK_TOTAL - WEEK_REM * WEEK_TOTAL / 100 ))
```

5h 没有 boost（API 没返回 `current_interval_boost_permille`），保持 `100 - REM` 不动。

### 收益

statusline 周配额的数字与 dashboard 完全一致。

### 取舍

- boost 字段缺失或 `< 1000` 时回落到 `100 - REM`（旧公式），向前兼容老版本/没有 boost 的账号
- **边界无缝**：boost=999 走旧公式（如 REM=54 → USED=46），boost=1000 走新公式（REM=54, total=100 → USED=46）。
  两路数值一致，不会因为阈值切换跳变
- bar 还是按 `WEEK_USED`（绝对值）填充，不算 `USED/TOTAL`。理由：bar 与 label 同口径比与 dashboard 视觉一致更重要；用户主要读数字
- 周配额的"用得少还是多"颜色判断仍按 `WEEK_USED` 绝对值染色（≥85 红），不看 used/total 比例。
  这是 UX 取舍：周配额被 boost 后变得宽松，69% used 时颜色是黄而非红，提醒"还在安全区但要注意"
  ——比 strict 的 used/total = 46% 绿更直观
- **历史限制**：若 API 返回 REM > 100（异常数据），WEEK_USED 会变负数。5h 旧公式 `100 - REM` 也有同样问题，
  不在本期修；上游 `=~ ^[0-9]+$` 守卫保证不会有非数字，但 0-100 范围靠 API 自己守

### 关键对账（实测）

| | API REM | boost | 我的脚本 USED | dashboard 已用 |
|---|---|---|---|---|
| 5h | 52 | - | 48% | 48% ✓ |
| 周 | 54 | 1500 | 150 − 54×150/100 = 69% | 69% ✓ |

## 改动 7：对话余量估算（"≈Xh / ≈Ym"）

### 问题

statusline 显示的 `↻ 32m` 是"距离配额 reset 还有多久"，但用户真正想问的是
**"我按现在的烧速还能撑多久"**——这两个数独立：reset 时间固定，但烧速变。

如果烧速 > 配额总量/剩余时间，会在 reset 前就耗光；反之闲置用户 reset 前都用不完。
光看 `↻` 看不出来。

### 方案

把"烧速"显式算出来，单独显示在 `↻` 后面：

```text
5h ███░░░░░ 48% ↻ 32m ≈ 13m
                 └──┘ └──┘
                reset  按 burn rate 推算
```

**burn rate 怎么算**：

1. 每次 statusline 刷新（60s）写一行历史到 `/tmp/claude-statusline-minimax-burn`：
   `epoch FIVE_USED WEEK_USED`
2. 读最近 5 分钟（≥ 3 个数据点）的窗口，按 `awk` 算：
   - `delta_used = last - first`（绝对单位）
   - `dt = last_ts - first_ts`（秒）
   - `rate = delta_used / dt`（%/s）
   - `minutes_left = (total - current_used) / rate / 60`
3. 输出格式：`≈Xh`（≥60 分钟）或 `≈Ym`（< 60 分钟）

### 关键设计：账户级 vs session 级

burn rate 是**账户级**的，不是某个 session 的。理由：
- API 给的 quota 是账户级（API key = 账户），不是 session-scoped
- 同一 API key 下开 5 个 CC 窗口 + 跑 curl + SDK 脚本，全都从同一份扣
- statusline 看到的是这份账户总量，所以"对话余量"也是按账户 burn rate 算

如果将来想精确到 session，需要在每次 API 调用时给请求打 session 标签（API 端不支持），所以现状是**最优近似**。

**用户该知道什么**：开 10 个 session 跑同一份 quota，每个 session 看到的 burn rate 是相同的（账户级），
看到的"对话余量"也是同一个数。这是 feature 不是 bug——你希望知道"我整个账户还能撑多久"，
而不是"当前这个 session 还能撑多久"（后者对决策没帮助：其他 9 个 session 也在烧）。

### 边界处理（不瞎猜）

| 情况 | 输出 |
|---|---|
| 历史 < 3 个数据点 | 不显示 `≈` |
| rate ≤ 0（闲置 / 反向 / 数据全相同） | 不显示 `≈` |
| 数据点超过 5 分钟窗口（被时间过滤掉） | 不显示 `≈` |
| `remaining ≤ 0`（已耗尽） | 不显示 `≈` |
| HIST_FILE 不存在（首次启动 / 手动 rm） | 不显示 `≈` |
| HIST_FILE 存在但为空 | 不显示 `≈` |
| 末尾行被截断（写中断） | awk 静默 coerce → delta=0 → 走 rate≤0 兜底 |
| boost 中途变化 | 历史 USED 按写入时 total 口径，total 变后 rate 仍按**当前** total 算 |
| `minutes < 60` | `≈Ym` |
| `minutes ≥ 60`（无上限） | `≈Xh`（整数除，e.g. 130m → ≈2h） |
| `minutes ≤ 0` | 不显示 `≈` |

### 收益

用户一眼能看出"按这个速度还够不够撑到 reset"：
- `5h 48% ↻ 32m ≈ 13m` → 13m 内烧完，reset 还有 32m，能撑过 reset ✓
- `5h 88% ↻ 5m ≈ 12m` → 12m 内烧完，reset 还有 5m，要爆 ⚠

### 取舍

- **颜色策略**：`≈Xm` 用 DIM 灰，不跟随 ↻ / bar 的颜色变化。理由：估算本身就是"次要信息"，
  颜色再变会让主信息（used%）被稀释；用户应主动对比 `↻ X` 和 `≈ Y` 哪个小
- **窗口选 5 分钟**：太短（1-2min）数据点不够、太长（15-30min）包含太多旧数据；
  5 分钟平衡了响应速度和稳定性
- **历史文件位置**：放 `/tmp`，macOS 上 `/tmp` 是 APFS（不是 tmpfs），**重启不清空**——
  首次安装需要 3 分钟 warm-up，之后永远 warm；HIST_FILE 内容（epoch + 百分比）非敏感
- **POSIX `>>` 原子（仅 append）**：单行 < 20B << PIPE_BUF (4KB)，POSIX 保证 append 原子；
  5 writer × 1000 appends 实测无丢行无交错，不需要 flock（顺手避开 macOS 默认没装 flock 的坑）
- **轮转非原子**：`tail -n 60 + mv` 是 read-modify-rename 复合操作；多 session 高并发时
  偶发丢 1 行（实测很难触发，POSIX rename 在 APFS 上 serialize）。影响：估算精度 ±1 个数据点，
  可接受。如果哪天丢行变成问题，再补 flock

## 踩过的坑（值得在博客里点出来）

### 坑 1：`@tsv` + `IFS=$'\t' read` 看似合理实则错

原本想把 3/4 个字段压成一行，用 jq `@tsv` 输出 tab 分隔，再用 `IFS=$'\t' read` 切。
**错的。** bash 的 `read` 在 IFS 包含 whitespace（tab 是 whitespace）时，会**先剥离前导 whitespace**，
导致连续空字段被塌成单个：

```
输入:  \t\t42
read 后: CTX_USED="42"  CTX_MAX=""  CTX_PCT_FALLBACK=""
        （预期 CTX_USED=""  CTX_MAX=""  CTX_PCT_FALLBACK="42"）
```

更隐蔽的是，`jq '// empty | tostring'` 在字段缺失时不会输出空字符串占位，而是直接不 emit，
让 `@tsv` 输出少一列——这两个坑叠加，read 拿到的值会**错位**而不是简单的字段缺失。

修法：
- jq 端用 `(... // "" | tostring)` 而不是 `(// empty | tostring)`
- bash 端用 `IFS='|'` 而不是 `IFS=$'\t'`，pipe 不是 whitespace
- 用 `join("|")` 输出而不是 `@tsv`

### 坑 2：bash 算术对空串的处理

`(( CTX_MAX > 0 ))` 当 CTX_MAX 是空串时，bash 把它当 0，0 > 0 是 false，走 fallback 分支——OK。
但 `[[ "$CTX_MAX" =~ ^[0-9]+$ ]]` 对空串返回 false，**不会**意外匹配。
两套防御都生效才稳，单用一套都有漏。

### 防御层级（更新时容易漏看）

`colorize_reset` / `format_remaining_ms` / `colorize_used` 三个函数本身**不**做输入校验：
- `(( ... < 1800000 ))` 对非数字串会被算术上下文静默 coerce 成 0
- `local ms="${1:-0}"` + `(( ms < 60000 ))` 对负数会被 `((` ) 当成 `--` 标志解析（bash 3.2 输出 syntax error 然后当 0 处理）

看起来是 bug，实际**不可达**：上游 `IFS='|' read` 之后都有
`[[ "$FIVE_RESET_MS" =~ ^[0-9]+$ ]]` 之类的正则守卫，
把负数、字母、空串**全**挡在门外。函数保持纯，
把校验收敛在调用点；不加 `10x4` 行 `if ! [[ ... =~ ]]`，靠共识维持简洁。

## 落地差异（代码层面）

| # | 改动 | 涉及位置 |
|---|---|---|
| 1 | 合并 jq + 周 ↻ | 顶部 ctx 解析 + 配额 jq 调用块；`FIVE_PIECE` / `WEEK_PIECE` 拼接；`format_remaining_ms` 周配额复用 |
| 2 | 共享 cache | `CACHE_FILE="/tmp/claude-statusline-minimax-shared"`（去掉 `$SESSION_ID` 后缀） |
| 3 | reset 染色 | 新增 `colorize_reset`（30min / 2h 阈值），`FIVE_PIECE` / `WEEK_PIECE` 染色 |
| 4 | ctx CC 同口径 | 顶部 stdin 解析：改读 `used_tokens` / `max_tokens`，`used_percentage` 兜底 |
| 5 | 5h/周 统一 used% | 删除 `colorize_remaining`，新增 `colorize_used`（与 ctx 同口径）；`FIVE_USED = 100 - FIVE_REM`；bar/% 都用 USED |
| 6 | 周配额 boost 修正 | jq 多抽 `weekly_boost_permille`；`WEEK_USED = WEEK_TOTAL - WEEK_REM × WEEK_TOTAL / 100`，`WEEK_TOTAL = boost / 10` |
| 7 | 对话余量估算 | 新增 `HIST_FILE`（账户级，跨 session）；`format_burn_estimate` 从最近 5min 数据点推算；POSIX `>>` 原子写不需要 flock；cutoff 时间戳从 shell 传入（macOS BSD awk 无 systime） |

## 评审对照

| 改动 | 设计文档 vs 实际代码 |
|---|---|
| 1 | 文档 "方案" 用 `@tsv` + `IFS=$'\t'`，实际用 `join("|")` + `IFS='\|'`——修复版即"坑 1"所述，文档代码块保留了"原始尝试"作为对照 |
| 2 | 一致；`CACHE_FILE` 路径在两处对齐 |
| 3 | 一致；`colorize_reset` 函数体与文档 code block 完全一致 |
| 4 | 一致；顶层 stdin 解析块按文档"方案"小节实现，`used_percentage` 兜底分支保留 |
| 5 | 一致；`colorize_used` 阈值（≥85 / ≥60）与 ctx 内联旧实现完全相同，等价替换；`FIVE_USED = 100 - FIVE_REM` 是简单算术 |
| 6 | 一致；`weekly_boost_permille` 加入 jq 抽取列，`WEEK_USED` 公式按文档"方案"小节实现；boost 缺失/为 0 时回落到旧公式 |
| 7 | 一致；`HIST_FILE` 持久化 60 条滚动；`format_burn_estimate` 用 `$col` 参数支持 5h/周两个数据列；cutoff 在 shell 算好传入 awk |