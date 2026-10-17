#!/usr/bin/env bash
# 三类真实接口联调（显式触发）。需要环境变量 DASHSCOPE_API_KEY，可选 TT_CHAT_MODEL 等，见 README。
set -euo pipefail
cd "$(dirname "$0")/.."
swift run tt-live-check
