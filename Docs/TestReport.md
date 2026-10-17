# 自动化测试报告

## 1. 汇总

| 类别 | 唯一用例 | 通过 | 失败 | 跳过 | 运行环境 | 原始结果 |
|---|---:|---:|---:|---:|---|---|
| 核心单元 + 集成（Swift Testing） | **529** | 529 | 0 | 0 | macOS 27.0.1，Swift 6.4，`swift test --parallel` | [core-tests-20261018T092221.log](reports/core-tests-20261018T092221.log)、`.xml`（xUnit）、[清单](reports/core-tests-latest-inventory.md) |
| iOS 交互自动化（XCUITest） | **24** | 24 | 0 | 0 | Xcode 27.1，iPhone 18 Pro 模拟器 iOS 27.0，确定性模型响应 | [ui-tests-20261018T092238.log](reports/ui-tests-20261018T092238.log) |
| 合计 | **553** | 553 | 0 | 0 | | |

- 两次运行都在同一源码提交 **`1bc5d7f`** 上执行（核心日志首行记录了提交号；UI 运行时工作区与该提交一致，之后 `test-ui.sh` 也会在日志开头写入提交号）。
- 统计口径（8.1）：每个 `@Test` / XCTest 方法计 1 个；没有参数化展开计数；没有跳过、禁用或预期失败；重名 0。核心测试不访问网络、不依赖收费服务（HTTP 用可编排桩，时钟用 `ManualClock`）。
- **iOS 18 最低系统未实测**：本机只有 iOS 27 模拟器运行时。

## 2. 核心测试分布

| 测试 target | 用例 | 预算（第 4 节） | 说明 |
|---|---:|---:|---|
| LibraryCoreTests | 40 | 24 | EPUB 正常/异常样本、导入/重复/删除/恢复/并发 |
| ReaderCoreTests | 24 | 26 | 定位、重新定位、分页、批注、书签 |
| ReadingSessionCoreTests | 16 | 16 | 区间合并、跳读、会话、中断恢复 |
| ReflectionCoreTests | 23 | 22 | 草稿、提交幂等、修改留痕、消息状态机 |
| SpeechCoreTests | 16 | 16 | 权限、中断、取消、无语音、时长上限 |
| RetrievalCoreTests | 63 | 60 | 分词、切块、BM25、向量、RRF、重排映射、扩展、降级、索引生命周期 |
| ContextRoutingTests | 30 | 34 | 计划解析、规则编译、降级、注入防护 |
| ContextEngineeringTests | 23 | 34 | 组装、去重、裁剪、提示词、引用 |
| BrainCoreTests | 39 | 38 | 条目、修订、提议、关系、失效、召回 |
| AgentRuntimeTests | 34 | 34 | 预算、重试、超时、取消、完成门、任务登记、脱敏 |
| ReaderAgentTests | 27 | 28 | 完整讨论链路、边界、取消、失败重试、幂等、记忆提议 |
| ModelProvidersTests | 30 | 30 | 对话/SSE、Embedding、Rerank、错误映射 |
| PersistenceTests | 29 | 32 | 迁移（含 v1 旧库样本）、删除级联、FTS5、向量、事务、备份 |
| AppInfrastructureTests | 15 | 12 | 密钥（含真实钥匙串往返）、配置、启动恢复、策略、装配 |
| AchievementCoreTests | 12 | 10 | 日历/时区/跨午夜、成就去重 |
| BenchCoreTests | 17 | 14 | 指标分母、数据冻结、结果比较、运行器 |
| EvidenceVerificationCoreTests | 34 | 32 | 陈述拆分、结构检查、裁判、失败语义、数字归一化 |
| LearningCoreTests | 39 | 38 | 出题校验、评分、掌握、调度（固定时钟、时区） |
| IntegrationTests | 18 | — | 跨模块：EPUB→定位、SQLite 重启、中文检索、HTTP 协议→讨论、恢复写入、记忆/学习/备份闭环、5k 子块性能冒烟 |
| **合计** | **529** | 500 | |

## 3. iOS 交互用例

| 编号 | 用例 | 结果 |
|---|---|---|
| UI-01 | `test_UI01_firstLaunchEmptyState` | 通过 |
| UI-02 | `test_UI02_importValidEPUB` | 通过 |
| UI-03 | `test_UI03_duplicateImport` | 通过 |
| UI-04 | `test_UI04_corruptImport` | 通过 |
| UI-05 | `test_UI05_restorePosition` | 通过 |
| UI-06 | `test_UI06_fontAndTheme` | 通过 |
| UI-07 | `test_UI07_highlightPersists` | 通过 |
| UI-08 | `test_UI08_editAndDeleteAnnotation` | 通过 |
| UI-09 | `test_UI09_reflectionDraftSurvivesRestart` | 通过 |
| UI-10 | `test_UI10_discussFromSelection` | 通过 |
| UI-11 | `test_UI11_streamingAndVerification` | 通过 |
| UI-12 | `test_UI12_citationJumpsToSource` | 通过 |
| UI-13 | `test_UI13_cancelAndRetry` | 通过 |
| UI-14 | `test_UI14_offlineErrorKeepsQuestion` | 通过 |
| UI-15 | `test_UI15_confirmAndRejectProposals` | 通过 |
| UI-16 | `test_UI16_revisionHistoryAndSource` | 通过 |
| UI-17 | `test_UI17_quizHidesAnswerUntilSubmit` | 通过 |
| UI-18 | `test_UI18_dueReviewFlow`（以 `-uitest-clock-offset-days 1` 重启模拟次日） | 通过 |
| UI-19 | `test_UI19_backupAndRestore`（自动化无法操作系统文件选择器，使用“恢复刚才导出的备份”入口） | 通过 |
| UI-20 | `test_UI20_settingsProtectSecrets` | 通过 |
| 补充 | `test_LIB04_deleteKeepNotes`、`test_REF03_voiceReflection`、`test_REF03_microphoneDeniedFallsBackToText`、`test_scopeSwitchVisible` | 通过 |

交互测试使用 `-uitest` 确定性环境：独立数据目录、内存密钥、按关键词响应的本地模型（问题含“慢”时缓慢流式、含“断网”时离线错误）、确定性语音桩。**这些用例验证界面流程与状态，不代表真实模型或真实语音识别效果。**

## 4. 测试过程中发现并修复的缺陷

| 缺陷 | 发现方式 | 修复 |
|---|---|---|
| `INSERT OR REPLACE` 在次级唯一键冲突时静默删除旧行；更新会话会级联删除其消息 | 单元测试（反思提交键唯一） | 全部改为按主键 UPSERT，新增两条回归测试 |
| 子块 ID 不含书籍 ID，两本书同版本前缀会冲突 | 跨书检索测试 | ID 加入书籍 ID |
| 去重合并可使扩展区间超过长度上限 | 扩展长度测试 | 合并时检查上限 |
| 回答把引用写在句末标点之后（`……。[E1]`）时，陈述丢失引用、被判“证据不足” | UI 测试（核查状态） | 句末/句首引用归入前一陈述，新增回归测试 |
| 复核器不识别中文/英文数字词，矛盾漏检 | 开发集评测 | 数字归一化（排除章节编号） |
| “通用”意图默认不检索批注 | ReaderAgent 测试 | 默认来源加入批注 |
| 全局提示条遮挡导航栏按钮（目录、更多） | UI 测试 | 提示条下移到导航栏下方 |
| 同一表单行两个按钮：点“停止并转写”同时触发“取消” | UI 测试（语音） | `.borderless` 按钮样式 |
| 阅读器首屏不上报可见区间：首页不会记为已读，“记为已读”无效 | UI 测试（讨论无证据） | 布局完成后上报可见区间 |
| 换章后可见区间偏移相同则不上报，位置不保存 | UI 测试（位置恢复） | 比较章节 |
| 重新打开阅读器时首屏上报覆盖已保存位置（竞态） | UI 测试（全量运行偶发失败） | 先读位置再填充章节 |
| 设置保存后密钥掩码不刷新 | UI 测试 | 掩码改为显式状态 |
