#!/usr/bin/env bash
# Query MiniMax Token Plan remaining quota.
# Endpoint per docs: https://www.minimaxi.com/docs/token-plan/faq

set -euo pipefail

ENDPOINT="${MINIMAX_REMAINS_URL:-https://www.minimaxi.com/v1/token_plan/remains}"

# 优先从专用 env 取；没有就用 ANTHROPIC_AUTH_TOKEN 兜底（同账号体系通常通用）
TOKEN="${MINIMAX_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: no API key found. Set MINIMAX_API_KEY or ANTHROPIC_AUTH_TOKEN." >&2
  exit 2
fi

response=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}" \
  --location "$ENDPOINT" \
  --header "Authorization: Bearer $TOKEN" \
  --header "Content-Type: application/json")

body="${response%__HTTP_STATUS__:*}"
status="${response##*:}"

echo "HTTP $status"
echo "---"
if command -v jq >/dev/null 2>&1; then
  echo "$body" | jq .
else
  echo "$body"
fi
