#!/usr/bin/env bash
# 真机 Release 验收采样：D-13（冷启动 / 重开书籍 / 保存批注，各 N 次）与 D-14（同一进程混合操作浸泡 + 内存采样 + Leaks）。
# 用法：Scripts/perf-device.sh <设备 UDID 或名称> [采样次数，默认 30] [浸泡分钟，默认 30；0 表示跳过]
# 前提：iPhone 已配对、开启开发者模式；project.yml 中的 Team 可签名。测量期间应用会禁止自动锁屏，请保持设备解锁、连接电源。
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$1"; N="${2:-30}"; SOAK="${3:-30}"
BUNDLE=app.thoughttrail.ThoughtTrail
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT=".build/perf-device-$STAMP"
mkdir -p "$OUT" Docs/reports
fetch() { xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
            --source "Documents/perf/$1" --destination "$OUT/$1" > /dev/null 2>&1; }
launch() { xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" -- "$@" > /dev/null; }

python3 Scripts/make_long_epub.py "$OUT/long-zh.epub" 30 15000
xcodebuild -project ThoughtTrail.xcodeproj -scheme ThoughtTrail -configuration Release -destination "id=$(xcrun devicectl list devices | awk -v d="$DEV" '$0 ~ d && /physical/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)" \
  -derivedDataPath .build/xcode-device -allowProvisioningUpdates -skipPackagePluginValidation build > "$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; exit 1; }
xcrun devicectl device install app --device "$DEV" .build/xcode-device/Build/Products/Release-iphoneos/ThoughtTrail.app > /dev/null
xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "$OUT/long-zh.epub" --destination Documents/long-zh.epub > /dev/null

# D-13 ①：干净数据，正式导入长篇样本后在应用内采样重开、保存、取消
launch -demo -uitest-reset -perf-reset -perf-import long-zh.epub -perf-suite
for _ in $(seq 1 120); do fetch suite.json && break; sleep 5; done
[ -f "$OUT/suite.json" ] || { echo "suite.json 未生成"; exit 1; }

# D-13 ②：冷启动 N 次（每次结束旧进程后启动；就绪时间用设备本地时钟：进程创建 → 书库就绪）
for i in $(seq 1 "$N"); do
  launch -demo -perf-launch-at 0
  for _ in $(seq 1 30); do
    fetch coldstart.jsonl && [ "$(wc -l < "$OUT/coldstart.jsonl")" -ge "$i" ] && break; sleep 1
  done
done

XCODE="$(xcodebuild -version | sed -n 1p)"
ENV="$(xcrun devicectl device info details --device "$DEV" 2>/dev/null | awk -F': ' '/Marketing Name/{m=$2} /OS Version/{v=$2} /OS Build Update/{b=$2} END{print m"，iOS "v"（"b"）"}' || true)；$XCODE"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 未提交)$(git diff --quiet HEAD -- App Sources Scripts project.yml 2>/dev/null || echo '（源码有未提交改动）')"
python3 Scripts/perf_report.py "$OUT" "$ENV" "$COMMIT" device > "Docs/reports/perf-device-$STAMP.md"
cp "$OUT/suite.json" "Docs/reports/perf-device-$STAMP-suite.json"
cp "$OUT/coldstart.jsonl" "Docs/reports/perf-device-$STAMP-coldstart.jsonl"
cat "Docs/reports/perf-device-$STAMP.md"

# D-14：同一进程混合操作浸泡 + 内存采样；同时用 Instruments Leaks 附着记录
if [ "$SOAK" != "0" ]; then
  launch -demo -perf-soak "$SOAK"
  sleep 5
  PID="$(xcrun devicectl device info processes --device "$DEV" 2>/dev/null | awk '/ThoughtTrail.app\/ThoughtTrail/ {print $1; exit}')"
  if [ -n "$PID" ]; then
    xcrun xctrace record --template Leaks --device "$DEV" --attach "$PID" --time-limit "$((SOAK * 60 - 30))s" \
      --output "$OUT/soak-leaks.trace" > "$OUT/xctrace.log" 2>&1 || echo "xctrace 失败，见 $OUT/xctrace.log"
  fi
  for _ in $(seq 1 $((SOAK * 12 + 120))); do fetch soak-summary.json && break; sleep 5; done
  if [ -d "$OUT/soak-leaks.trace" ]; then
    TOCQ='/trace-toc/run[@number="1"]/tracks/track'
    xcrun xctrace export --input "$OUT/soak-leaks.trace" --xpath "$TOCQ[@name=\"Leaks\"]/details/detail[@name=\"Leaks\"]" > "$OUT/leaks.xml" 2>/dev/null || true
    xcrun xctrace export --input "$OUT/soak-leaks.trace" --xpath "$TOCQ[@name=\"Allocations\"]/details/detail[@name=\"Statistics\"]" > "$OUT/alloc-stats.xml" 2>/dev/null || true
    python3 - "$OUT" > "$OUT/leaks-summary.txt" <<'PY'
import re, sys
from pathlib import Path
out = Path(sys.argv[1])
leaks = (out / "leaks.xml").read_text() if (out / "leaks.xml").exists() else ""
rows = re.findall(r"<row\b[^>]*>", leaks)
sizes = [int(x) for x in re.findall(r'size="(\d+)"', leaks)]
alloc = (out / "alloc-stats.xml").read_text() if (out / "alloc-stats.xml").exists() else ""
m = re.search(r'category="All Heap Allocations" persistent-bytes="(\d+)" count-persistent="(\d+)"', alloc)
heap = f"；记录结束时堆上存活 {int(m.group(1)) / 1048576:.1f} MB（{m.group(2)} 个分配）" if m else ""
print(f"泄漏记录 {len(rows)} 条" + (f"，合计约 {sum(sizes) / 1024:.1f} KB" if sizes else "") + heap +
      "（Instruments Leaks 模板附着整个浸泡过程；原始 trace 可用 Instruments 打开复核）")
PY
  fi
  fetch soak.jsonl || true
  [ -f "$OUT/soak-summary.json" ] || echo "soak-summary.json 未生成（进程可能已崩溃）"
  python3 Scripts/soak_report.py "$OUT" "$ENV" "$COMMIT" > "Docs/reports/soak-device-$STAMP.md" || true
  cp "$OUT"/soak.jsonl "Docs/reports/soak-device-$STAMP.jsonl" 2>/dev/null || true
  cp "$OUT"/soak-summary.json "Docs/reports/soak-device-$STAMP-summary.json" 2>/dev/null || true
  cat "Docs/reports/soak-device-$STAMP.md"
fi
echo "原始数据：$OUT"
