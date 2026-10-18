#!/usr/bin/env bash
# iOS 交互自动化：在模拟器上运行 ThoughtTrailUITests（确定性模型响应）。
# 用法：Scripts/test-ui.sh ["platform=iOS Simulator,name=iPhone 18 Pro" 或真机 "id=<UDID>"] [其余 xcodebuild 参数，如 -only-testing:ThoughtTrailUITests/ReaderUITests]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-platform=iOS Simulator,name=iPhone 18 Pro}"
EXTRA=("${@:2}")
STAMP="$(date +%Y%m%dT%H%M%S)"
mkdir -p Docs/reports
LOG="Docs/reports/ui-tests-$STAMP.log"
{ echo "环境：$(sw_vers -productName) $(sw_vers -productVersion)；$(xcodebuild -version | tr '\n' ' ')；目标：$DEST${EXTRA[*]:+；参数：${EXTRA[*]}}"
  echo "提交：$(git rev-parse --short HEAD 2>/dev/null || echo '未提交')$(git diff --quiet HEAD 2>/dev/null || echo '（工作区有未提交改动）')"; } > "$LOG"
xcodebuild -project ThoughtTrail.xcodeproj -scheme ThoughtTrail -destination "$DEST" -derivedDataPath .build/xcode \
  -skipPackagePluginValidation -allowProvisioningUpdates -resultBundlePath ".build/ui-$STAMP.xcresult" test ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee -a "$LOG"
