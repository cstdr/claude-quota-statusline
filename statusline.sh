#!/usr/bin/env bash
# ~/.claude/statusline.sh — Claude Code 自定义 statusline
#
# 数据源有两份：
#   1. stdin = Claude Code 注入的 session JSON（model / context_window / session_id）
#   2. 配额 API = Kimi /coding/v1/usages 或 MiniMax /v1/token_plan/remains（缓存 50s 避免频繁 HTTP）
#      依 ANTHROPIC_BASE_URL 自动识别服务商（STATUSLINE_PROVIDER 可覆盖）
#
# 任意一个失败都不让 statusline 变空——失败的数据源静默省略，已知字段照常显示。
# 用 bash+jq 而非 Python：起动开销更小，符合 docs 推荐的模式。
#
# Source 模式：STATUSLINE_LIB_MODE=1 source 此文件，只定义函数不跑主流程，给单测用。

set -u  # 不要 set -e；statusline 任何非零退出都会让整条变空

# ============ 全局常量 ============
# ANSI 颜色：用 $'\033...' 产生真实 ESC 字节（不是字面 \033 文本）
# 便于函数输出被外部直接处理（如单测 strip_ansi 能匹配到 ESC 字节）
RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'

# --- 服务商识别（kimi / minimax / unknown） ---
# 依 ANTHROPIC_BASE_URL 判断配额 API 是哪家；STATUSLINE_PROVIDER 可强制覆盖（测试/调试）
# 空/不认识的 URL → unknown：不往不认识的服务商转发 token（fetch 直接跳过，配额段静默省略）
detect_provider() {
  local forced="${STATUSLINE_PROVIDER:-}"
  [[ "$forced" == "kimi" || "$forced" == "minimax" ]] && { printf '%s' "$forced"; return; }
  # bash 3.2 无 ${var,,}，用 tr 归一小写，大写 host 也能识别
  local url
  url=$(printf '%s' "${ANTHROPIC_BASE_URL:-}" | tr '[:upper:]' '[:lower:]')
  case "$url" in
    *kimi.com*|*moonshot*) printf 'kimi' ;;
    *minimax*)             printf 'minimax' ;;
    *)                     printf 'unknown' ;;
  esac
}
PROVIDER="$(detect_provider)"

# --- 配额 API（缓存 50s；跨 session 共享） ---
# cache/hist 按 provider 分文件：换服务商不会读到上一家的响应格式
# 允许 STATUSLINE_CACHE_FILE / STATUSLINE_HIST_FILE 覆盖（集成测试用）
CACHE_FILE="${STATUSLINE_CACHE_FILE:-/tmp/claude-statusline-${PROVIDER}-shared}"
CACHE_MAX_AGE=50
# 烧速历史：账户级（API key 代表账户），所有 session 共写一份
# 用于推算"按现在 burn rate 还能撑多久"
HIST_FILE="${STATUSLINE_HIST_FILE:-/tmp/claude-statusline-${PROVIDER}-burn}"
HIST_WINDOW_SECS=300  # 5 分钟窗口

# 配额周期长度（用于算 time marker）
# 5h 区间 = 5 × 3600 × 1000 ms
PERIOD_5H_MS=18000000
# 周区间 = 7 × 24 × 3600 × 1000 ms
PERIOD_WEEK_MS=604800000

# ============ 纯函数（无副作用，可单测） ============

# 用量染色（used 视角：高占用 = 红；与 ctx 同口径）
# 阈值：≥85 红 / ≥60 黄 / 其余 绿
colorize_used() {
  local pct="${1:-0}"
  pct="${pct%.*}"
  [[ -z "$pct" ]] && pct=0
  if   (( pct >= 85 )); then printf '%b' "$RED"
  elif (( pct >= 60 )); then printf '%b' "$YEL"
  else                      printf '%b' "$GRN"
  fi
}

bar() {
  local pct="${1%.*}" width="${2:-8}"
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local f e
  printf -v f '%*s' "$filled" ''
  printf -v e '%*s' "$empty"  ''
  printf '%s' "${f// /█}${e// /░}"
}

# time marker elapsed 百分比：相对周期长度，走了多少 %
# 不画条件（与 spec 一致）：reset_ms 缺失/非数字/<=0/>=period/period<=0/边界
# 返回 1..99 整数；任一不满足返回空串
elapsed_pct() {
  local reset_ms="$1" period_ms="$2"
  [[ ! "$reset_ms"  =~ ^[0-9]+$ ]] && return
  [[ ! "$period_ms" =~ ^[0-9]+$ ]] && return
  (( reset_ms <= 0 ))      && return
  (( period_ms <= 0 ))     && return
  (( reset_ms >= period_ms )) && return
  local pct=$(( (period_ms - reset_ms) * 100 / period_ms ))
  # 边界：刚好 0% 或 100% 不画（marker 在边沿没有信息量；Δ 也隐）
  (( pct <= 0 ))   && return
  (( pct >= 100 )) && return
  printf '%d' "$pct"
}

# time marker 位置：reset_ms 相对 period_ms 的 elapsed 百分比，按 width 量化
# 返回 1..width-1 整数；任一"不画"条件返回空串（与 elapsed_pct 共用同一组条件）
# 不画条件与 elapsed_pct 对齐 ⇒ 主流程可以把 ┊ 和 Δ 共同 gate 在 marker_pos 上
marker_pos() {
  local reset_ms="$1" period_ms="$2" width="$3"
  local pct
  pct=$(elapsed_pct "$reset_ms" "$period_ms") || return
  [[ -z "$pct" ]] && return
  local pos=$(( pct * width / 100 ))
  # 1..width-1 量化后可能落到 0（elapsed=1..12% for width=8）—— 视为不可画
  # 这与 spec "marker_pos>0 才画" 条件一致；主流程同时 gate Δ 在 marker_pos 上
  (( pos <= 0 ))    && return
  (( pos >= width )) && return
  printf '%d' "$pos"
}

# 在 bar_str 的 marker_pos 位置替换 dim 灰 ┊
# bar_str 来自 bar()，是纯字符（不含 ANSI）；替换后整段包上 bar_color
# marker_pos 不在 1..width-1 → 原样包 bar_color 返回
# REPLACE 模式：始终丢弃 bar_str[pos] 字符，插入 ┊；post 只取到 width-1 以保持总长 = width
overlay_marker() {
  local bar_str="$1" pos="$2" width="$3" bar_color="$4"
  # 越界 → 不画 marker
  if (( pos <= 0 || pos >= width )); then
    printf '%s%s%s' "$bar_color" "$bar_str" "$RST"
    return
  fi
  # 切片：pre = bar[0..pos-1]，post = bar[pos+1..width-1]（pos 位被 ┊ 替换；丢弃 bar[width-1] 保持总长 = width）
  local pre="${bar_str:0:pos}"
  local post="${bar_str:pos+1:width-1-pos}"
  printf '%s%s%s%s%s%s%s%s%s' "$bar_color" "$pre" "$RST" "$DIM" '┊' "$RST" "$bar_color" "$post" "$RST"
}

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
    # 用 delta 原值（已含负号）
    printf '%s↓%d%%%s' "$col" "$delta" "$RST"
  fi
}

# 毫秒倒计时 → "XhYm" / "Ym" / "<1m"
# 5h 区间 remains_time 最大 ≈ 18000000ms；显示精度到分钟
format_remaining_ms() {
  local ms="${1:-0}"
  (( ms < 60000 )) && { printf '<1m'; return; }
  local total_sec=$(( ms / 1000 ))
  local h=$(( total_sec / 3600 ))
  local m=$(( (total_sec % 3600) / 60 ))
  if   (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  else                  printf '%dm'   "$m"
  fi
}

# reset 倒计时染色（值越小越紧迫）
# 阈值：30min 红 / 2h 黄 / 其余 dim
colorize_reset() {
  local ms="${1:-0}"
  if   (( ms < 1800000 ));  then printf '%b' "$RED"
  elif (( ms < 7200000 ));  then printf '%b' "$YEL"
  else                          printf '%b' "$DIM"
  fi
}

# 烧速估算："≈Xh" / "≈Ym" / 空
# 入参：$1=hist 文件、$2=当前 USED 绝对值、$3=TOTAL（含 boost）、$4=窗口秒、$5=数据列(2=5h, 3=周)
# 从最近 5 分钟的数据点算 burn rate（%/s），推算"按此速率多久烧完"
# 数据点 < 3 或 rate ≤ 0 或 remaining ≤ 0 → 空（不瞎猜）
# cutoff 时间戳从 shell 算好传入（macOS 默认 awk 是 BSD，无 systime()）
format_burn_estimate() {
  local hist="$1" used="$2" total="$3" window="$4" col="$5"
  [[ ! -f "$hist" ]] && return
  # cutoff 往过去推 30s 作为 buffer，避免 60s 刷新间隔 × 300s 窗口边界上 n=2↔n=3 flicker
  local cutoff=$(( $(date +%s) - window - 30 ))
  local min
  min=$(awk -v latest_used="$used" -v tot="$total" -v cutoff_ts="$cutoff" -v col="$col" '
    $1 >= cutoff_ts {
      val = $col
      if (!first) { first_ts=$1; first_used=val; first=1 }
      last_ts=$1; last_used=val; n++
    }
    END {
      if (n < 3) exit
      delta = last_used - first_used
      dt = last_ts - first_ts
      if (delta <= 0 || dt <= 0) exit
      rate = delta / dt
      remaining = tot - latest_used
      if (remaining <= 0) exit
      printf "%.0f", remaining / rate / 60
    }
  ' "$hist" 2>/dev/null)
  [[ ! "$min" =~ ^[0-9]+$ ]] && return
  (( min <= 0 )) && return
  if (( min >= 60 )); then
    printf '≈%dh' $(( min / 60 ))
  else
    printf '≈%dm' "$min"
  fi
}

# quota 已用部分显示：boost 激活时（total > 100）显示 X/Y 显式标分母，否则 X%
# 例：boost=1500 → "91/150"；boost=1000/缺省 → "91%"
format_quota_label() {
  local used="$1" total="$2"
  if (( total > 100 )); then
    printf '%s/%s' "$used" "$total"
  else
    printf '%s%%' "$used"
  fi
}

# count-based model 显示片段（如 "video 0/3 ↻ 12m"）
# 用途：处理 general 之外的 model（如 video 是次数配额，不是百分比）
# 入参：$1=label, $2=usage, $3=total, $4=reset_ms
# total 缺失/0/非数字 → 返回空（不显示）
# usage > total 等异常：仍原样显示，不替用户判断（用户能看到异常比静默更好）
format_count_piece() {
  local label="$1" usage="$2" total="$3" reset_ms="$4"
  [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]] && return
  (( total <= 0 )) && return
  local out="${DIM}${label}${RST} ${usage}/${total}"
  if [[ "$reset_ms" =~ ^[0-9]+$ ]] && (( reset_ms > 0 )); then
    out="${out} $(colorize_reset "$reset_ms")↻${RST} $(format_remaining_ms "$reset_ms")"
  fi
  printf '%s' "$out"
}

# Kimi /coding/v1/usages → 与 MiniMax 相同的 5 字段（remaining 口径）：
#   5h剩余% | 5h剩余ms | 周剩余% | 周剩余ms | boost(恒空，Kimi 无此概念)
# 归一成同一契约 ⇒ 主流程下游（bar/marker/Δ/burn）零改动复用
# stdin = API 响应 JSON；$1 = now_epoch（测试注入用，缺省取当前时间）
# 字段一律字符串化；缺失/非法 → 空串（下游 regex 判空静默省略）
# 5h 窗口 = limits[] 里 duration=300 TIME_UNIT_MINUTE 的项；周窗口 = usage
kimi_fields() {
  local now="${1:-$(date +%s)}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  jq -r --argjson now "$now" '
    def clamp_pct($p): [0, 100, $p] | sort | .[1];
    def rem_pct($o):
      (try (
        (($o.limit // "0") | tonumber) as $l
        | if $l <= 0 then ""
          else (100 - clamp_pct((($o.used // "0") | tonumber) * 100 / $l | floor)) | tostring
          end
      ) catch "");
    def reset_ms($t):
      (try (
        if ($t // "") == "" then ""
        else [0, (($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now) * 1000] | max | tostring
        end
      ) catch "");
    # 注意 .limits? 对类型错误产 empty（不是 null），必须再接 // [] 兜底，否则整条管道无声中断
    ((.limits? // [] | if type == "array" then . else [] end)
      | map(select(
          type == "object"
          and (.window | type == "object")
          and .window.duration == 300
          and .window.timeUnit == "TIME_UNIT_MINUTE"
        ))
      | .[0].detail // {}
      | if type == "object" then . else {} end) as $five
    | (.usage? // {} | if type == "object" then . else {} end) as $week
    | [
        rem_pct($five),
        reset_ms($five.resetTime),
        rem_pct($week),
        reset_ms($week.resetTime),
        ""
      ]
    | join("|")
  ' 2>/dev/null
}

# ============ 有副作用的函数（依赖 $CACHE_FILE / env） ============

fetch_remains() {
  local token="${ANTHROPIC_AUTH_TOKEN:-}"
  local url
  if [[ "$PROVIDER" == "kimi" ]]; then
    token="${token:-${KIMI_API_KEY:-}}"
    url="${KIMI_USAGES_URL:-https://api.kimi.com/coding/v1/usages}"
  elif [[ "$PROVIDER" == "minimax" ]]; then
    token="${token:-${MINIMAX_API_KEY:-}}"
    url="${MINIMAX_REMAINS_URL:-https://www.minimaxi.com/v1/token_plan/remains}"
  else
    # unknown：不认识的后端不发请求（避免把别家 token 转发给 kimi/minimax 服务器）
    return 1
  fi
  [[ -z "$token" ]] && return 1
  curl -sS --max-time 3 \
    "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" 2>/dev/null
}

cache_is_stale() {
  # 清掉上轮被 SIGKILL 留下的 .tmp，避免下次 fetch 永远拿不到 $CACHE_FILE
  rm -f "$CACHE_FILE.tmp.$$" 2>/dev/null
  [[ ! -s "$CACHE_FILE" ]] && return 0
  local mtime
  mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  (( $(date +%s) - mtime > CACHE_MAX_AGE ))
}

# ============ lib 模式（source 用于单测）============
# 函数已全部定义；如果带 STATUSLINE_LIB_MODE=1 就 return，不跑主流程
[[ "${STATUSLINE_LIB_MODE:-0}" == "1" ]] && return 0 2>/dev/null

# ============ 主流程 ============
input=$(cat)
{ echo "=== input ==="; printf '%s\n' "$input"; echo "=== input len: ${#input} ==="; } >> /tmp/STATUSLINE_DEBUG.txt 2>&1
MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // "?"')

# 一次 jq 抽 3 个字段：used_tokens / max_tokens / used_percentage 兜底
# 注意：CC 右下角的 "X% context used" 用的是 used/max_tokens（max 是给输入的预算）
# 而 JSON 的 used_percentage 用的是 used/total（total 包含给输出预留的部分）
# 这里按 CC 口径计算，与右下角保持一致；字段缺失时回落到 used_percentage
# 用 // "" 占位而非 // empty，保证 join 输出始终 3 字段
# 分隔符用 | 而不是 tab：bash read 在 IFS 包含 whitespace 时会先剥离前导空白，
# 导致连续空字段塌成单个，@tsv 不靠谱
IFS='|' read -r CTX_USED CTX_MAX CTX_PCT_FALLBACK < <(
  printf '%s' "$input" | jq -r '
    .context_window // {} | [
      (.used_tokens // "" | tostring),
      (.max_tokens  // "" | tostring),
      (.used_percentage // "" | tostring)
    ] | join("|")
  ' 2>/dev/null
)
if [[ "$CTX_USED" =~ ^[0-9]+$ ]] && [[ "$CTX_MAX" =~ ^[0-9]+$ ]] && (( CTX_MAX > 0 )); then
  CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))
else
  CTX_PCT="${CTX_PCT_FALLBACK:-0}"
fi

if cache_is_stale; then
  if data=$(fetch_remains); then
    # 用 mktemp，避开并发 statusline 实例共享 .tmp 的竞态
    tmp=$(mktemp "${CACHE_FILE}.XXXXXX")
    printf '%s' "$data" > "$tmp" 2>/dev/null && mv "$tmp" "$CACHE_FILE"
  fi
fi

# 一次 jq 抽 5 个字段：5h剩余% / 5h剩余ms / 周剩余% / 周剩余ms / boost千分比
# Kimi 走 kimi_fields 归一；MiniMax 走 model_remains[general]；unknown 不解析（cache 也不会被刷新）
# 分隔符用 | 而不是 tab：bash read 在 IFS 包含 whitespace 时会先剥离前导空白，
# 导致连续空字段塌成单个；用 join("|") 输出再以 IFS='|' 切分
FIVE_REM=""; FIVE_RESET_MS=""; WEEK_REM=""; WEEK_RESET_MS=""; WEEK_BOOST_PERMILLE=""
# USED 也要先初始化：REM 解析为空时不会进赋值分支，set -u 下未绑定会让整条 statusline 崩空
FIVE_USED=""; WEEK_USED=""
if [[ -s "$CACHE_FILE" ]]; then
  if [[ "$PROVIDER" == "kimi" ]]; then
    if IFS='|' read -r FIVE_REM FIVE_RESET_MS WEEK_REM WEEK_RESET_MS WEEK_BOOST_PERMILLE < <(
      kimi_fields "$(date +%s)" < "$CACHE_FILE" 2>/dev/null
    ); then :; fi
  elif [[ "$PROVIDER" == "minimax" ]] && jq -e '.model_remains | type == "array" and length > 0' "$CACHE_FILE" >/dev/null 2>&1; then
    if IFS='|' read -r FIVE_REM FIVE_RESET_MS WEEK_REM WEEK_RESET_MS WEEK_BOOST_PERMILLE < <(
      jq -r '
        (.model_remains // [])
        | map(select(.model_name=="general"))
        | .[0] // empty
        | [
            (.current_interval_remaining_percent // "" | tostring),
            (.remains_time                  // "" | tostring),
            (.current_weekly_remaining_percent // "" | tostring),
            (.weekly_remains_time           // "" | tostring),
            (.weekly_boost_permille         // "" | tostring)
          ]
        | join("|")
      ' "$CACHE_FILE" 2>/dev/null
    ); then :; fi
  fi
fi

# 多 model 拆解：general 走 percent（已有逻辑），其他 model（如 video）走 count
# 默认关闭——video 字段存在但当前工作流用不到，避免一行太长
# 通过 STATUSLINE_MULTI_MODEL=1 打开
# 这里只硬编码 "video"——通用化需要知道每个 model 的语义，目前只有 video 是 count-based
VIDEO_PIECE=""
if [[ "${STATUSLINE_MULTI_MODEL:-0}" == "1" && -s "$CACHE_FILE" ]]; then
  VIDEO_USAGE=""; VIDEO_TOTAL=""; VIDEO_RESET_MS=""
  if IFS='|' read -r VIDEO_USAGE VIDEO_TOTAL VIDEO_RESET_MS < <(
    jq -r '
      (.model_remains // [])
      | map(select(.model_name=="video"))
      | .[0] // empty
      | [
          (.current_interval_usage_count  // "" | tostring),
          (.current_interval_total_count  // "" | tostring),
          (.remains_time                  // "" | tostring)
        ]
      | join("|")
    ' "$CACHE_FILE" 2>/dev/null
  ); then :; fi
  VIDEO_PIECE=$(format_count_piece "video" "$VIDEO_USAGE" "$VIDEO_TOTAL" "$VIDEO_RESET_MS")
fi

# --- 组装输出 ---
# CTX_PCT 已是 CC 口径的已用百分比（used / max_tokens）——越高越糟
CTX_BAR=$(bar "$CTX_PCT")
CTX_PCT_INT=${CTX_PCT%.*}
CTX_COL=$(colorize_used "$CTX_PCT_INT")

# MiniMax 字段是 *remaining*，但显示统一为已用%——与 ctx 同口径，避免歧义
FIVE_PIECE=""; WEEK_PIECE=""
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
  # Δ 差值（与 ┊ 同一 gate：marker_pos 为空 ⇒ Δ 也不显；满足 spec "5 条件才显"）
  if [[ -n "$FIVE_MARKER_POS" ]]; then
    FIVE_ELAPSED_PCT=$(elapsed_pct "$FIVE_RESET_MS" "$PERIOD_5H_MS")
    FIVE_DELTA=$(format_delta_piece $(( FIVE_USED - FIVE_ELAPSED_PCT )) "$FIVE_USED")
    FIVE_PIECE="${FIVE_PIECE} ${FIVE_DELTA}"
  fi
  FIVE_EST=$(format_burn_estimate "$HIST_FILE" "$FIVE_USED" 100 "$HIST_WINDOW_SECS" 2)
  [[ -n "$FIVE_EST" ]] && FIVE_PIECE="${FIVE_PIECE} ${DIM}${FIVE_EST}${RST}"
fi
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
  # time marker（reset_ms 缺失/越界时 marker_pos 为空，overlay_marker 走"无 ┊"分支）
  WEEK_MARKER_POS=$(marker_pos "$WEEK_RESET_MS" "$PERIOD_WEEK_MS" 8)
  WEEK_BAR=$(overlay_marker "$WEEK_BAR" "${WEEK_MARKER_POS:-0}" 8 "$WEEK_COL")
  WEEK_LABEL=$(format_quota_label "$WEEK_USED" "$WEEK_TOTAL")
  WEEK_PIECE="${DIM}周${RST} ${WEEK_BAR} ${WEEK_LABEL}${RST}"
  if [[ "$WEEK_RESET_MS" =~ ^[0-9]+$ ]]; then
    WEEK_RESET=$(format_remaining_ms "$WEEK_RESET_MS")
    WEEK_RESET_COL=$(colorize_reset "$WEEK_RESET_MS")
    WEEK_PIECE="${WEEK_PIECE} ${WEEK_RESET_COL}↻${RST} ${WEEK_RESET}"
  fi
  # Δ 差值（与 ┊ 同一 gate：marker_pos 为空 ⇒ Δ 也不显）
  if [[ -n "$WEEK_MARKER_POS" ]]; then
    WEEK_ELAPSED_PCT=$(elapsed_pct "$WEEK_RESET_MS" "$PERIOD_WEEK_MS")
    WEEK_DELTA=$(format_delta_piece $(( WEEK_USED - WEEK_ELAPSED_PCT )) "$WEEK_USED")
    WEEK_PIECE="${WEEK_PIECE} ${WEEK_DELTA}"
  fi
  WEEK_EST=$(format_burn_estimate "$HIST_FILE" "$WEEK_USED" "$WEEK_TOTAL" "$HIST_WINDOW_SECS" 3)
  [[ -n "$WEEK_EST" ]] && WEEK_PIECE="${WEEK_PIECE} ${DIM}${WEEK_EST}${RST}"
fi

# 把当前 FIVE_USED/WEEK_USED 写入 burn rate 历史（账户级，所有 session 共写）
# 文件行格式：epoch_seconds FIVE_USED WEEK_USED
# 滚动到 60 条（≈1 小时数据）防止无限增长
# 写并发安全：单行 < 20B << PIPE_BUF，POSIX 保证 >> 原子，不需要 flock（macOS 也没装）
if [[ "$FIVE_USED" =~ ^[0-9]+$ ]] && [[ "$WEEK_USED" =~ ^[0-9]+$ ]]; then
  printf '%s %s %s\n' "$(date +%s)" "$FIVE_USED" "$WEEK_USED" >> "$HIST_FILE"
  if [[ -f "$HIST_FILE" ]] && (( $(wc -l < "$HIST_FILE" 2>/dev/null || echo 0) > 60 )); then
    tmp=$(mktemp "${HIST_FILE}.XXXXXX")
    tail -n 60 "$HIST_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$HIST_FILE"
  fi
fi

# 最终用 %b 输出，让 ${VAR} 里的 ESC 转义被终端正确解释
# ctx 标签放左边，与 5h/周 保持一致的对齐：label bar pct%
OUTPUT="[${MODEL}] ${DIM}ctx${RST} ${CTX_COL}${CTX_BAR} ${CTX_PCT_INT}%"
[[ -n "$FIVE_PIECE" ]] && OUTPUT="${OUTPUT} · ${FIVE_PIECE}"
[[ -n "$WEEK_PIECE" ]] && OUTPUT="${OUTPUT} · ${WEEK_PIECE}"
[[ -n "$VIDEO_PIECE" ]] && OUTPUT="${OUTPUT} · ${VIDEO_PIECE}"
printf '%b\n' "$OUTPUT" > /tmp/STATUSLINE_DEBUG.txt
printf '%b\n' "$OUTPUT"
