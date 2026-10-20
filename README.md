# 思迹 ThoughtTrail

项目状态：**按调整后的个人项目范围完成**。采用 iOS 27、纯文本 EPUB 阅读与中文语音，以已有核心/交互测试、接口联调和设备记录交付；额外真实案例检查、量化效果评测和完整演示材料为可选。详见 [验收要求](ThoughtTrail_项目验收要求.md) 和 [验收记录](Docs/Acceptance.md)。

已知限制：历史会话未逐轮重新校验来源，删除书籍文件并保留笔记后，旧回答摘录仍可能用于后续模型请求；历史也不计入 6,000 Token 证据预算。

原生 iOS 阅读与个人思考 Agent：导入 EPUB → 阅读与批注 → 文字或语音反思 → 基于证据讨论 → 核查回答 → 确认长期记忆 → 自测与复习 → 在后续阅读中重新关联。

- 18 个 Swift 库模块（`Sources/`），可在 macOS 上运行全部离线测试；
- iOS 27+ SwiftUI 应用（`App/`），由 `project.yml`（XcodeGen）生成工程；
- 本地 SQLite（GRDB）存储，用户自行配置模型服务（默认阿里云百炼：千问对话、`text-embedding-v4`、`qwen3-rerank`），密钥保存在系统钥匙串。

当前完成度与未完成项见 [Docs/Acceptance.md](Docs/Acceptance.md)。

## 目录

```text
App/            SwiftUI 页面、平台适配（录音/语音识别/网络）、资源（图标、内置示例书）
Sources/        18 个库模块（M01–M18），说明见 Docs/Architecture.md
Tests/          每个模块的单元测试 + IntegrationTests（跨模块集成）+ TestSupport（确定性桩、EPUB 夹具生成器）
UITests/        iOS 交互自动化（XCUITest）
Benchmarks/     tt-bench（语料/数据集生成与离线评测）、tt-live-check（三类真实接口联调）
Evaluation/     语料源文本、开发集数据、评测结果
Scripts/        测试、评测、工程生成脚本
Docs/           架构、数据与接口、验收表、测试与评测报告、演示与讲解材料
project.yml     XcodeGen 工程描述
Package.swift   核心包（依赖：GRDB 7.11.1、ZIPFoundation 0.9.20，版本锁定见 Package.resolved）
```

## 环境

| 项 | 已验证版本 |
|---|---|
| macOS | 27.0（Apple Silicon） |
| Xcode / Swift | Xcode 27.1，Swift 6.4（Swift 6 语言模式，完整并发检查） |
| iOS 模拟器 | iPhone 18 Pro，iOS 27.0 |
| 最低系统与验收范围 | iOS 27.0 起；按用户 2026-10-18 的要求取消 iOS 18 验收，采用 iOS 27 模拟器与 iOS 27.0.1 真机；历史结果和本次配置变更后的验证分别记录 |

## 构建与测试

```bash
# 1. 核心包：构建并运行全部离线测试（不访问网络、不需要密钥），输出日志、xUnit 与用例清单到 Docs/reports
Scripts/test-core.sh
```

```bash
# 2. 生成 Xcode 工程（首次会从源码构建 XcodeGen 2.46.0），同时生成内置示例书
Scripts/generate-project.sh
```

```bash
# 3. iOS 交互自动化（确定性模型响应）
Scripts/test-ui.sh "platform=iOS Simulator,name=iPhone 18 Pro"
```

```bash
# 4. 固定评测（离线）；加 --live 追加真实模型评测（会产生费用）
Scripts/eval.sh
```

在 Xcode 中打开 `ThoughtTrail.xcodeproj`，选择 `ThoughtTrail` scheme 即可在模拟器或真机运行。真机运行需在 Signing 中选择自己的 Team，并把 `PRODUCT_BUNDLE_IDENTIFIER` 改成自己的前缀。

### 演示模式

启动参数 `-demo`（或 UI 测试使用的 `-uitest`）使用独立数据目录和**本地规则生成的确定性模型响应**，用于离线演示与自动化测试；设置页会明确标注“不代表真实模型效果”。可加 `-uitest-import sample-zh` 在启动时导入内置示例书。

## 配置模型服务

在 App「设置」中分别填写对话、向量、重排的接口地址、模型 ID 与密钥，点击「检测连接」分别检测三类接口。默认（北京地域）：

| 用途 | 接口地址 | 模型 |
|---|---|---|
| 对话 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 自选千问模型（如 `qwen-plus`），联调时冻结 |
| 向量 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `text-embedding-v4`（1024 维） |
| 重排 | `https://dashscope.aliyuncs.com/api/v1`（原生协议） | `qwen3-rerank` |

新加坡地域把域名换为 `dashscope-intl.aliyuncs.com`。也可以把对话指向其他 OpenAI 兼容服务（如 DeepSeek）。

### 命令行联调（显式触发）

```bash
DASHSCOPE_API_KEY=你的密钥 TT_CHAT_MODEL=qwen-plus Scripts/live-check.sh
```

结果（已脱敏，不含密钥与正文）写入 `Evaluation/live/`。可用环境变量：`TT_CHAT_BASE_URL`、`TT_CHAT_MODEL`、`TT_EMBED_BASE_URL`、`TT_EMBED_MODEL`、`TT_EMBED_DIMS`、`TT_RERANK_BASE_URL`、`TT_RERANK_MODEL`、`TT_RERANK_PROTOCOL`（`native`/`compatible`），以及分别的 `TT_CHAT_KEY`、`TT_EMBED_KEY`、`TT_RERANK_KEY`。

## 数据处理说明

- EPUB、批注、反思、记忆和数据库保存在设备；
- 使用云向量时，**已读范围内**待索引的文本会发送到配置的模型服务；讨论、重排、复核、出题会发送该任务所需的文本与上下文；
- 本地解析全书结构并建立词法索引，但召回与组装始终受阅读范围限制；
- 密钥只在钥匙串中；结构化备份与 Markdown 导出不含密钥；
- 本项目不需要独立业务服务器或云向量数据库。

## 文档

- [Docs/Architecture.md](Docs/Architecture.md)：18 个模块、依赖图、主调用链与关键取舍
- [Docs/DataAndInterfaces.md](Docs/DataAndInterfaces.md)：实体、迁移、索引版本、Provider 配置与错误语义、备份格式、复习规则
- [Docs/Acceptance.md](Docs/Acceptance.md)：需求—实现—验证映射与验收状态
- [Docs/TestReport.md](Docs/TestReport.md)：自动化测试报告
- [Docs/Evaluation.md](Docs/Evaluation.md)：评测方法、数据与结果
- [Docs/DeviceAcceptance.md](Docs/DeviceAcceptance.md)：模拟器/真机验收记录与待办
- [Docs/Presentation.md](Docs/Presentation.md)：项目讲解材料
