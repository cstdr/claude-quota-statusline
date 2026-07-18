# claude-quota-statusline — Makefile
# 用法：make <target>
#
# 常用：
#   make install   一键装 statusline 到 ~/.claude/
#   make test      跑全部单测
#   make lint      跑 shellcheck（需先 brew install shellcheck）

SCRIPT      := statusline.sh
DEST_DIR    := $(HOME)/.claude
DEST_FILE   := $(DEST_DIR)/statusline.sh
SETTINGS    := $(DEST_DIR)/settings.json
TEST_RUNNER := ./tests/run_all.sh

.PHONY: help install test lint clean uninstall

help:  ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install:  ## 装 statusline 到 ~/.claude/
	@if [ ! -d "$(DEST_DIR)" ]; then \
		echo "❌ $(DEST_DIR) 不存在 —— 装一次 Claude Code 再跑 make install"; \
		exit 1; \
	fi
	cp -f "$(SCRIPT)" "$(DEST_FILE)"
	chmod +x "$(DEST_FILE)"
	@echo "✅ 已装到 $(DEST_FILE)"
	@if [ ! -f "$(SETTINGS)" ] || ! grep -q 'statusline.sh' "$(SETTINGS)" 2>/dev/null; then \
		echo ""; \
		echo "⚠️  下一步：把下面这行加进 $(SETTINGS)："; \
		echo ""; \
		echo '  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }'; \
		echo ""; \
	fi

uninstall:  ## 删 statusline 脚本
	rm -f "$(DEST_FILE)"
	@echo "✅ 已卸（settings.json 里的 statusLine 配置需手动删）"

test:  ## 跑全部单测
	@if [ ! -x "$(TEST_RUNNER)" ]; then \
		echo "❌ $(TEST_RUNNER) 不存在或不可执行"; \
		exit 1; \
	fi
	@command -v jq >/dev/null 2>&1 || { \
		echo "❌ 缺 jq：macOS 跑 'brew install jq'，Ubuntu 跑 'sudo apt-get install -y jq'"; \
		exit 1; \
	}
	bash "$(TEST_RUNNER)"

lint:  ## shellcheck
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "❌ 缺 shellcheck：brew install shellcheck / apt install shellcheck"; \
		exit 1; \
	}
	shellcheck -S warning "$(SCRIPT)" check_remains.sh

clean:  ## 清 /tmp 缓存
	rm -f /tmp/claude-statusline-*-shared /tmp/claude-statusline-*-burn
	@echo "✅ 缓存已清"
