#!/usr/bin/env bash
# 生成 Xcode 工程（XcodeGen 2.46.0）。未安装时从源码构建到 .build/tools。
set -euo pipefail
cd "$(dirname "$0")/.."
XG="$(command -v xcodegen || true)"
if [ -z "$XG" ]; then
  if [ ! -x .build/tools/XcodeGen/.build/release/xcodegen ]; then
    mkdir -p .build/tools
    git clone --depth 1 --branch 2.46.0 https://github.com/yonaskolb/XcodeGen.git .build/tools/XcodeGen
    (cd .build/tools/XcodeGen && swift build -c release --product xcodegen)
  fi
  XG=.build/tools/XcodeGen/.build/release/xcodegen
fi
swift run tt-bench fixtures App/Resources/Samples
"$XG" generate --spec project.yml
