# 设备验收记录

## 1. 已完成（模拟器）

| 项 | 环境 | 结果 | 证据 |
|---|---|---|---|
| iOS 应用构建 | Xcode 27.1，iOS Simulator SDK 27.1，Debug | 构建成功 | `xcodebuild … build` 日志 |
| 安装与启动 | iPhone 18 Pro 模拟器，iOS 27.0 | 启动进入书库，导入示例书、打开阅读器正常 | UI 测试与录屏 |
| iOS 交互自动化 | 同上，确定性模型响应（`-uitest`） | 24/24 通过（提交 `77da5c4`），见 [TestReport.md](TestReport.md) | `Docs/reports/ui-tests-20261018T140150.log` |
| Release 构建与本地时延采样 | Xcode 27.1，Release，iPhone 18 Pro 模拟器 iOS 27.0（Apple M5 Mac） | 构建、安装成功；各项 30 次采样（见第 4 节） | [reports/perf-sim-20261018T135819.md](reports/perf-sim-20261018T135819.md)；**模拟器参考值，不作为设备验收 D-13 依据** |
| 模拟器流程录屏 | 同上，录制 UI-12（引用跳回原文）、UI-16（记忆修订与来源）、UI-17（自测）、UI-19（备份恢复）自动化运行过程 | 已录制 | [media/simulator-demo.mp4](media/simulator-demo.mp4)（960×540；确定性模型，**不是**含真实模型的完整演示录像） |

## 2. 未完成（需要真机或用户条件）

| 项 | 需要 | 状态 |
|---|---|---|
| 真机安装运行（签名） | iPhone；Team 已在 `project.yml` 设为 `DNK2Q5668X`（自动签名），Bundle ID 如被占用需改为自己的 | **未验收** |
| iOS 18 最低系统 | iOS 18 模拟器运行时或 iOS 18 设备 | **未验收**：Xcode 27.1 运行时目录不提供 iOS 18.x（尝试记录见第 5 节）；本机只有 iOS 27.0/27.1 运行时，也没有 iOS 18 设备 |
| 语音：真实麦克风权限、录音、Apple Speech 转写（中文/英文） | 真机 | **未验收**（自动化使用确定性语音桩） |
| 来电/后台中断 | 真机 | **未验收**（状态机已单元测试） |
| Release 构建性能（冷启动、重开书籍、本地保存、取消响应、5k/20k 子块召回、30 分钟稳定性与内存） | 固定 iPhone、Instruments | **未验收**；模拟器 Release 采样见第 4 节，开发机 macOS 上的本地召回时延见 [Evaluation.md](Evaluation.md) 规模探测，二者都是参考值，不作为验收数据 |
| 含真实模型的完整演示与录像 | 密钥 + 真机/模拟器录屏 | **未验收** |

## 3. 真机验收操作清单（供执行时填写）

| 编号 | 操作 | 预期 | 实际 | 记录人/日期 |
|---|---|---|---|---|
| D-01 | 首次启动，导入一本 EPUB | 书库显示封面、标题、作者 | | |
| D-02 | 阅读 3 页后锁屏 2 分钟再解锁 | 会话暂停后继续，阅读位置不丢失 | | |
| D-03 | 选段高亮、批注；杀进程重开 | 批注仍在并可定位 | | |
| D-04 | 记录语音反思（中文），停止后修改转写并保存 | 转写可编辑，保存后在“思考与记忆”中可见 | | |
| D-05 | 录音时拨入电话 | 录音停止，提示“被中断”，已录内容可转写或改用文字 | | |
| D-06 | 设置中拒绝麦克风权限后录音 | 明确提示，可继续文字输入 | | |
| D-07 | 配置百炼对话/向量/重排密钥并检测连接 | 三项分别显示可用、延迟 | | |
| D-08 | 真实模型讨论：已读范围内问题 | 流式草稿 → 核查中 → 结果状态；引用可跳回原文 | | |
| D-09 | 飞行模式下提问 | 显示离线失败、问题保留；联网后重试成功 | | |
| D-10 | 讨论中途取消 | 0.5 秒内退出等待状态，草稿保留 | | |
| D-11 | 生成自测题并作答 | 提交前不显示参考答案；提交后显示反馈、证据、下次复习日期 | | |
| D-12 | 导出备份并在另一台设备恢复 | 关键记录与引用关系一致；未包含的附件标记缺失 | | |
| D-13 | Release 构建：冷启动 30 次、重开书籍 30 次、保存批注 30 次 | P95 分别 ≤3 s、≤2 s、≤300 ms | | |
| D-14 | 30 分钟混合操作 + Instruments Leaks/Allocations | 无崩溃，无持续增长 | | |

## 4. 模拟器 Release 本地时延（参考）

> **模拟器参考值，不作为设备验收 D-13 依据。** D-13 仍需在固定 iPhone 上按第 3 节口径执行。

| 指标（模拟器参考值，不作为设备验收 D-13 依据） | 次数 | P50 (ms) | P95 (ms) | 最大 (ms) |
|---|---:|---:|---:|---:|
| 冷启动至书库可操作（宿主发起启动 → 就绪） | 30 | 620.4 | 668.1 | 748.8 |
| 冷启动（进程创建 → 就绪） | 30 | 514.4 | 555.9 | 649.4 |
| 已导入书籍重新打开（读库 + 定位 + 首屏排版） | 30 | 1.7 | 14.4 | 80.2 |
| 批注本地保存 | 30 | 0.2 | 0.2 | 5.6 |
| 反思本地保存（更新草稿 + 提交） | 30 | 0.2 | 0.3 | 0.5 |
| 取消后退出等待状态 | 30 | 1.0 | 1.7 | 1.7 |

- 取消后再等待 1.7 秒，迟到响应改变界面状态（等待状态、草稿文本、消息状态）的次数：0/30。
- 方法：`Scripts/perf-sim.sh` 以 Release 构建安装到模拟器，先在干净数据中导入示例书，并用 `-perf-suite` 在应用内采样重开、保存、取消；再结束进程、冷启动 30 次（`-perf-launch-at`）。原始数据：`perf-sim-20261018T135819-suite.json`、`-coldstart.jsonl`。采样在提交 `6432624` 上运行；该提交与 `77da5c4` 的差别只在测试文件，应用代码相同。
- 探针开销：`PerfProbe` 只在带 `-perf-launch-at` / `-perf-suite` 参数时工作；不带参数时只做两次启动参数数组查找，且位于 `model.start()` 之后，不在启动关键路径上（已验证：不带参数启动不写任何采样文件）。冷启动“就绪”时间点在 `model.start()` 完成后、再经过一次主线程循环时记录，所以**包含**这次主线程循环（有意为之，近似“界面已渲染可操作”），**不包含**采样文件写入与进程时间查询（二者在记录时间点之后）。
- 局限：
  - 模拟器运行在 Apple M5 Mac 上，CPU、存储与内存都与 iPhone 不同。
  - 冷启动指进程冷启动，磁盘缓存是热的。
  - “重开书籍”在应用内测量模型加载与 UITextView 首屏排版，不含 SwiftUI 导航转场动画；示例书首个正文章只有 113 个 UTF-16 单元，不能代表长章节排版。
  - “取消”测的是从取消调用到界面状态退出等待，不含绘制。
  - 模型响应为确定性桩。

## 5. iOS 18 最低系统：尝试记录

本机 Xcode 27.1（27A9275），`xcrun simctl list runtimes` 只有 iOS 27.0、27.1。下载 iOS 18 模拟器运行时的尝试（2026-10-18）：

```
xcodebuild -downloadPlatform iOS -buildVersion 18.6 -architectureVariant arm64 2>&1 | tail -15
→ Finding content...
→ iOS 18.6 (arm64Only) is not available for download.

for v in 18.5 18.4 18.3.1 18.2 18.1 18.0; do echo "== $v"; xcodebuild -downloadPlatform iOS -buildVersion $v 2>&1 | grep -vE "^\s*$" | head -3 | tail -2 & P=$!; sleep 25; if kill -0 $P 2>/dev/null; then echo "$v 正在下载"; wait $P; break; fi; done
（每个版本均输出 “Finding content...”，随后：）
→ iOS 18.5 is not available for download.
→ iOS 18.4 is not available for download.
→ iOS 18.3.1 is not available for download.
→ iOS 18.2 is not available for download.
→ iOS 18.1 is not available for download.
→ iOS 18.0 is not available for download.
```

结论：**未验收**。工程 `IPHONEOS_DEPLOYMENT_TARGET = 18.0`，在该 deployment target 下编译通过，只能证明代码没有无条件调用 iOS 18 之后才有的 API（编译器的可用性检查），**不等于运行期行为**（系统框架行为差异、SwiftUI 布局、TextKit、Speech 权限流程等）已在 iOS 18 上验证。需要 iOS 18 设备，或能提供 18.x 运行时的 Xcode 版本，按第 3 节清单执行。
