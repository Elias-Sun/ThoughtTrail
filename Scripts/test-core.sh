#!/usr/bin/env bash
# 核心离线测试（18 个模块 + 集成测试）。输出原始日志、xUnit 报告与唯一用例清单。
# 用法：Scripts/test-core.sh [输出目录，默认 Docs/reports]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-Docs/reports}"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%dT%H%M%S)"
LOG="$OUT/core-tests-$STAMP.log"
XUNIT="$OUT/core-tests-$STAMP.xml"
echo "环境：$(sw_vers -productName) $(sw_vers -productVersion)；$(swift --version 2>&1 | head -1)" | tee "$LOG"
echo "提交：$(git rev-parse --short HEAD 2>/dev/null || echo '未提交')" | tee -a "$LOG"
set +e
swift test --parallel --xunit-output "$XUNIT" 2>&1 | tee -a "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
python3 Scripts/test_inventory.py "$OUT" "$LOG" "$OUT/core-tests-$STAMP-inventory.md"
cp "$OUT/core-tests-$STAMP-inventory.md" "$OUT/core-tests-latest-inventory.md"
exit $STATUS
