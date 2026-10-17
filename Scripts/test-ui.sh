#!/usr/bin/env bash
# iOS 交互自动化：在模拟器上运行 ThoughtTrailUITests（确定性模型响应）。
# 用法：Scripts/test-ui.sh ["platform=iOS Simulator,name=iPhone 18 Pro"]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-platform=iOS Simulator,name=iPhone 18 Pro}"
STAMP="$(date +%Y%m%dT%H%M%S)"
mkdir -p Docs/reports
xcodebuild -project ThoughtTrail.xcodeproj -scheme ThoughtTrail -destination "$DEST" -derivedDataPath .build/xcode \
  -skipPackagePluginValidation -resultBundlePath ".build/ui-$STAMP.xcresult" test 2>&1 | tee "Docs/reports/ui-tests-$STAMP.log"
