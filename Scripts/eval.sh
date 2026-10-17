#!/usr/bin/env bash
# 固定评测：重新生成语料与开发集（如源文件变化），运行离线评测；加 --live 追加真实模型评测（产生费用）。
set -euo pipefail
cd "$(dirname "$0")/.."
swift run -c release tt-bench corpus Evaluation
swift run -c release tt-bench eval Evaluation Evaluation/results "$@"
