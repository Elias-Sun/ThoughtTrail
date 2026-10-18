#!/usr/bin/env bash
# 真机本地召回采样（10.1：5,000 子块 P95 ≤500 ms；20,000 子块规模检查）。Release 构建签名安装后以 -perf-recall 启动，
# 应用在独立 SQLite 文件中写入合成子块、FTS5 与 1024 维向量，用正式 HybridRetriever 各检索 30 次（另记首个冷查询），
# 记录内存与索引体积，结束后删除这些临时库。
# 用法：Scripts/recall-device.sh <设备 UDID>
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$1"
BUNDLE=app.thoughttrail.ThoughtTrail
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT=".build/recall-device-$STAMP"
mkdir -p "$OUT" Docs/reports
xcodebuild -project ThoughtTrail.xcodeproj -scheme ThoughtTrail -configuration Release -destination "id=$DEV" \
  -derivedDataPath .build/xcode-device -allowProvisioningUpdates -skipPackagePluginValidation build > "$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; exit 1; }
xcrun devicectl device install app --device "$DEV" .build/xcode-device/Build/Products/Release-iphoneos/ThoughtTrail.app > /dev/null
xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" -- -demo -perf-reset -perf-recall > /dev/null
for _ in $(seq 1 180); do
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents/perf/recall.json --destination "$OUT/recall.json" > /dev/null 2>&1 && break
  sleep 5
done
[ -f "$OUT/recall.json" ] || { echo "recall.json 未生成"; exit 1; }
XCODE="$(xcodebuild -version | sed -n 1p)"
ENV="$(xcrun devicectl device info details --device "$DEV" 2>/dev/null | awk -F': ' '/Marketing Name/{m=$2} /OS Version/{v=$2} /OS Build Update/{b=$2} END{print m"，iOS "v"（"b"）"}' || true)；$XCODE"
COMMIT="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- App Sources Scripts/recall-device.sh Scripts/recall_report.py project.yml || echo '（源码有未提交改动）')"
python3 Scripts/recall_report.py "$OUT/recall.json" "$ENV" "$COMMIT" > "Docs/reports/recall-device-$STAMP.md"
cp "$OUT/recall.json" "Docs/reports/recall-device-$STAMP.json"
cat "Docs/reports/recall-device-$STAMP.md"
