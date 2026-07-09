#!/usr/bin/env bash
# tests/run_all.sh — 跑所有 test_*.sh
# 退出码：0 全过，1 有失败

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC2044
for t in "$SCRIPT_DIR"/test_*.sh; do
  echo "==== $(basename "$t") ===="
  if ! bash "$t"; then
    echo "❌ $(basename "$t") 失败"
    exit 1
  fi
  echo
done

echo "✅ 所有测试通过"