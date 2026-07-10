# 一行 statusline 改 7 次后，我学到了什么

> 草稿（v0.1）—— 等用户拍板"发"再改 final + 投稿
> 字数：~2200 / 预计阅读 8 分钟

---

我有一个不到 300 行的 bash 脚本，在过去两周里被改了 7 次。

不是 7 个 feature，是同一个问题反复回炉：为什么 statusline 上的数字和 MiniMax 后台 dashboard 总是对不上？

这个故事没有漂亮的开局，也没有戏剧性的结局。但每次迭代都让我对"用户看到的数字"这件事有更深的理解。

## 第一天：脚本能跑，但数字怪

Claude Code 的 statusline 是个简单的钩子：每 tick 调一次 shell 脚本，往 stdin 喂 session JSON，stdout 输出你想看的状态条。文档推荐的实现是 bash + jq，起动开销最小。

我照着写了个 v0：把 model 名、context window 百分比、MiniMax 5h 配额、周配额拼成一行。能跑。

但第二天打开 Claude Code 看了一眼，眉头皱了起来。

context 窗口显示 85%。我看右下角，明明是 95%。差了 10 个百分点。

第一反应：脚本错了。

## 第一个坑：分母不同，不是脚本错

打开 Claude Code 注入的 JSON，`context_window` 里有两个字段：`used_tokens` / `max_tokens`，还有一个现成的 `used_percentage`。

我用的是 `used_percentage`（方便嘛）。但 Claude Code 右下角显示的是 `used_tokens / max_tokens` 自己算的。

区别在哪？

`max_tokens` 是给**输入**的预算。
`total_tokens = max_tokens + 给输出预留的 ~10%`。

我用的 `used_percentage` 分母是 total，右下角用的 max。

分母不同，差的就是那 10% 预留。脚本没错，但字段语义不同。

**改 v1.0**：改读 `used_tokens` + `max_tokens`，自己算百分比。字段缺失时回落到 `used_percentage` 兜底（向前兼容老版本 CC）。

第二天复测：85% → 95%。对上了。

## 第二个故事：改完 ctx，又对不上 5h 和周

5h 配额和周配额显示的是"剩余百分比"。ctx 显示的是"已用百分比"。同一行里两种语义。

`5h 65%` —— 还剩 65%？还是已经用了 65%？心智负担爆炸。

最直接的修法：把 5h 和周也翻成"已用"。API 给的字段是 `current_interval_remaining_percent`（剩余），没有对偶的 `used_percent`。那就在 bash 端翻：

```bash
FIVE_USED=$(( 100 - FIVE_REM ))
```

颜色阈值也跟着翻：高占用 = 红。原来 65% 是"剩得多" = 绿，翻完后 65% 是"用得不少" = 黄。

**改 v1.1**：删除 `colorize_remaining`，新增 `colorize_used`，ctx / 5h / 周 共用同一份染色。

视觉变化需要适应（bar 的方向反了，原本 `█████░░░` 表示剩得多 = 满，现在 `██░░░░░░` 表示用得少 = 空），但跟 dashboard 完全对齐。

## 第三个故事：周配额有个不存在的"boost"

改了 v1.1 后过几天又对不上账了。dashboard 显示"周 已用 69%"，我的 statusline 显示"周 已用 46%"。

差距 23 个百分点，不是简单 bug。

翻 API 响应：

```json
"current_weekly_remaining_percent": 54,
"weekly_boost_permille": 1500
```

`weekly_boost_permille: 1500` —— +50% boost。`100 - 54 = 46` 算的是"基础配额内的 used"；dashboard 显示的是"含 boost 的绝对 used"。

公式修正：

```bash
WEEK_TOTAL=$(( WEEK_BOOST_PERMILLE / 10 ))   # 1500 → 150
WEEK_USED=$(( WEEK_TOTAL - WEEK_REM * WEEK_TOTAL / 100 ))  # 150 - 81 = 69
```

边界无缝：boost 字段缺失或 < 1000 时回落到旧公式（`100 - REM`），两路在 boost=1000 处数值一致，不会跳变。

**改 v1.2**：jq 多抽 `weekly_boost_permille` 字段，5h 没有 boost 保持原公式不动。

## 第四个故事：光看"reset 倒计时"不够

改完 v1.2，数字终于完全对上了。我以为这就结束了。

但用了一周后，新问题浮上来：`↻ 32m` 显示"距离 reset 还有 32 分钟"，但我真正想问的是"我按现在的烧速还能撑多久"。

这两个数独立：reset 时间是固定的，但我的烧速是变的。如果烧速 > 配额总量/剩余时间，会在 reset 前就耗光。

光看 `↻` 看不出来。

**改 v1.3**：把"烧速"显式算出来。

```text
5h ███░░░░░ 48% ↻ 32m ≈ 13m
                └──┘ └──┘
              reset  按 burn rate 推算
```

burn rate 怎么算：

1. 每次 statusline 刷新（60s）写一行历史到 `/tmp/...-burn`：`epoch FIVE_USED WEEK_USED`
2. 读最近 5 分钟（≥ 3 个数据点）的窗口
3. delta / dt = rate（%/秒）
4. `(total - current_used) / rate / 60` = 还能撑几分钟

边界一长串：历史 < 3 点不显示、rate ≤ 0 不显示、已耗尽不显示、boost 中途变化怎么办。每一行都有 if 兜底，但绝不瞎猜。

**为什么是账户级而不是 session 级**：API key = 账户，quota 扣的是账户总量。你开 10 个 session 跑同一份 quota，看到的 burn rate 都一样。这是 feature 不是 bug——你想知道的是"我整个账户还能撑多久"，不是"当前这个 session"（其他 9 个也在烧，对决策没帮助）。

## 第五个故事：跨 session 共享 cache

早期版本每个 session 一个 cache 文件，路径是 `/tmp/...-$SESSION_ID`。

多开几个 session = 几倍 HTTP 频率。浪费 MiniMax 的 API，也浪费本机。

**改 v1.4**：cache 路径切到固定名字 `/tmp/...-shared`，所有 session 共读。

N 个 session × 1 次/分钟 → 1 次/分钟。

这个改动小，但意义大：你的脚本不再是"一个 session 的工具"，而是"账户级状态显示"。

## 第六个故事：reset 时间要不要染色

`↻ 1h45m` 永远是灰色（dim）。每次想判断"还剩多久能再用"得读数字、心算。

阈值选 30min / 2h：30min 是一般人一个 round-trip 长任务的平均耗时；2h 是午休结束时常问"剩多少"的心理关口。

```bash
if   (( ms < 1800000 ));  then RED   # < 30min
elif (( ms < 7200000 ));  then YEL   # < 2h
else                          DIM
fi
```

**改 v1.5**：扫一眼就看出 panic time。

## 第七个故事：合并 jq 调用

之前抽 4 个字段要 4 次独立 `jq -r`，每次 fork 一个进程。60s 跑一次，多 session 累加起来可观。

合并成一次：

```bash
IFS='|' read -r FIVE_REM FIVE_RESET_MS WEEK_REM WEEK_RESET_MS WEEK_BOOST_PERMILLE < <(
  jq -r '
    (.model_remains // [])
    | map(select(.model_name=="general"))
    | .[0] // empty
    | [.. fields ..]
    | join("|")
  ' "$CACHE_FILE" 2>/dev/null
)
```

但有个**坑**：bash `read` 在 IFS 包含 whitespace（tab 是 whitespace）时会先剥离前导空白，导致连续空字段塌成单个。`@tsv` + `IFS=$'\t' read` 看似合理实则错。

修法：分隔符用 `|`（不是 whitespace），jq 端用 `(... // "" | tostring)`（不是 `// empty | tostring`，后者在字段缺失时不输出占位，让 `@tsv` 少一列）。这两个错叠加，read 拿到的值会**错位**而不是简单的字段缺失，bug 极难发现。

**改 v1.6**：3-4 次 jq → 1 次，省 ~60-90ms / refresh。

## 我从这 7 次迭代里学到的

**1. "数字对得上"不是细节，是基础**

statusline 的核心价值就是"看一眼知道现在怎么样"。如果数字跟 dashboard 对不上，每次看 statusline 都要怀疑一下"这是真的吗"，那就废了。

数字对得上比任何花哨 feature 都重要。

**2. API 字段语义 ≠ 显示语义**

API 给的是 `remaining_percent`，但用户和 dashboard 都用 `used_percent`。中间差一个语义转换。这个转换在客户端做（不要假设 API 会改）。

**3. 边界比 happy path 多花 10 倍时间**

burn rate 那个功能，核心公式就 3 行（delta/dt/rate/remaining/rate/60）。但边界（n<3、rate≤0、已耗尽、boost 变化、空文件、截断）写了一长串。

**不瞎猜**是 statusline 的设计原则：宁可空着不显示，也不要给个错的估算。

**4. "脚本级产品"也能用 TDD**

240 行 bash 看起来不值得写测试。但颜色阈值、reset 染色、burn rate 公式，每个都是 if 链里的边界，refactor 时一改就容易破。60+ 单测覆盖所有纯函数，每次改之前先跑 `tests/run_all.sh` —— 0 警告 0 失败才敢 commit。

**5. 性能优化要在能感知到的时候做**

合并 jq 调用是性能优化（3-4 次 → 1 次），但实际用户感知不到（60s 一次，省 60-90ms）。做这个是因为代码更整洁，不是为了快。

反过来：跨 session 共享 cache 也是性能优化（HTTP 流量降到 1/N），这个用户能感知到（5 个 session 一起开，dashboard 数字会跳得不一样），更值得做。

## 这个脚本现在在哪

代码开源在 [github.com/cstdr/minimax-claude-statusline](https://github.com/cstdr/minimax-claude-statusline)（**草稿：repo 目前 private，公开前会更新链接**）。

如果你用 Claude Code + MiniMax（也欢迎非 MiniMax 用户 fork），3 步装上：

1. `cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh`
2. `~/.claude/settings.json` 加 `statusLine` 配置
3. 设一下 `ANTHROPIC_AUTH_TOKEN`（或 `MINIMAX_API_KEY`）

完整 README、设计文档、踩坑记录都在 repo 里。

## 还没做的（也许 v2）

- ~~**多模型拆解**~~ — 实现了但默认关闭（`STATUSLINE_MULTI_MODEL=0`）；当前工作流 90%+ 走 `general`，video 段让 1 行变长 30% 用不到，需要时一键开
- ~~**配额 sparkline**~~ — 实现了又回滚了。技术 100% 对（17 个测试 + shellcheck 0），但"趋势"对单调递增的 USED% 没信息量，纯占地方

下次再写新东西前会先打 5+3 框架自检（"用户 5 维 + 我们 3 维"）+ 3 道 feature-utility 自检（"用户在什么场景下用？看/不看会改什么决定？场景占比多少？"），避免再做出"技术上对但没人用"的东西。

---

**关于这个系列**：这个博客没有固定更新频率。我只在做完一个值得讲的东西时写。如果你也折腾过 statusline / 配额监控 / Claude Code 工具定制，欢迎评论交流。
