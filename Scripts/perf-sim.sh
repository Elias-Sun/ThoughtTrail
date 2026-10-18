#!/usr/bin/env bash
# 模拟器 Release 构建的本地时延采样（10.1 指标的开发参考，不代替固定 iPhone 验收）。
# 用法：Scripts/perf-sim.sh [模拟器名称或 UDID，默认 "iPhone 18 Pro"] [采样次数，默认 30]
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${1:-iPhone 18 Pro}"
N="${2:-30}"
BUNDLE=app.thoughttrail.ThoughtTrail
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT=".build/perf-$STAMP"
mkdir -p "$OUT" Docs/reports

xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project ThoughtTrail.xcodeproj -scheme ThoughtTrail -configuration Release \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath .build/xcode-release \
  -skipPackagePluginValidation build > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
APP=".build/xcode-release/Build/Products/Release-iphonesimulator/ThoughtTrail.app"
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
DATA="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)"
rm -rf "$DATA/Documents/perf"

# 1. 重开书籍 / 本地保存 / 取消：干净数据 + 导入示例书后在应用内采样
xcrun simctl launch "$SIM" "$BUNDLE" -demo -uitest-reset -uitest-import sample-zh -perf-suite > /dev/null
for _ in $(seq 1 600); do [ -f "$DATA/Documents/perf/suite.json" ] && break; sleep 1; done
[ -f "$DATA/Documents/perf/suite.json" ] || { echo "suite.json 未生成"; exit 1; }
cp "$DATA/Documents/perf/suite.json" "$OUT/"
xcrun simctl terminate "$SIM" "$BUNDLE" || true

# 2. 冷启动：每次先结束进程，记录宿主时间后启动，应用在书库就绪时写一行
for i in $(seq 1 "$N"); do
  xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  sleep 1
  T=$(python3 -c 'import time; print(f"{time.time():.4f}")')
  xcrun simctl launch "$SIM" "$BUNDLE" -demo -perf-launch-at "$T" > /dev/null
  for _ in $(seq 1 100); do
    [ "$(wc -l < "$DATA/Documents/perf/coldstart.jsonl" 2>/dev/null || echo 0)" -ge "$i" ] && break; sleep 0.1
  done
done
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
cp "$DATA/Documents/perf/coldstart.jsonl" "$OUT/"

ENV="$(sw_vers -productName) $(sw_vers -productVersion)，$(sysctl -n machdep.cpu.brand_string)；$(xcodebuild -version | head -1)；模拟器 $SIM（$(xcrun simctl list devices | grep -m1 "$SIM" | sed 's/^ *//')）"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 未提交)$(git diff --quiet HEAD 2>/dev/null || echo '（工作区有未提交改动）')"
python3 Scripts/perf_report.py "$OUT" "$ENV" "$COMMIT" > "Docs/reports/perf-sim-$STAMP.md"
cp "$OUT/suite.json" "Docs/reports/perf-sim-$STAMP-suite.json"
cp "$OUT/coldstart.jsonl" "Docs/reports/perf-sim-$STAMP-coldstart.jsonl"
cat "Docs/reports/perf-sim-$STAMP.md"
