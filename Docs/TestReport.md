# 自动化测试报告

2026-10-18 独立复核：原有 552 个核心用例再次全部通过；改为 iOS 27.0 后，模拟器交互测试一次连续执行 24/24 通过，现有基线合计 576 个通过。另有两个不在原基线中的探针在原标准下未通过：R-01/R-02 均按用户授权调整后的标准接受为限制，不再阻塞验收；原始结果保留，未改记为测试通过。详见 [Review-20261018.md](Review-20261018.md)。下面表格保留原提交的历史结果，不代表新增场景已通过。

## 1. 汇总

| 类别 | 唯一用例 | 通过 | 失败 | 跳过 | 运行环境 | 原始结果 |
|---|---:|---:|---:|---:|---|---|
| 核心单元 + 集成（Swift Testing） | **552** | 552 | 0 | 0 | macOS 27.0.1，Swift 6.4，`swift test --parallel` | [core-tests-20261018T140134.log](reports/core-tests-20261018T140134.log)、`.xml`（xUnit）、[清单](reports/core-tests-latest-inventory.md) |
| iOS 交互自动化（XCUITest） | **24** | 24 | 0 | 0 | Xcode 27.1，iPhone 18 Pro 模拟器 iOS 27.0，确定性模型响应 | [ui-tests-20261018T140150.log](reports/ui-tests-20261018T140150.log) |
| 合计 | **576** | 576 | 0 | 0 | | |

- 两次运行都在同一源码提交 **`77da5c4`** 上执行（两份日志的开头都记录了提交号）。日志里如出现“工作区有未提交改动”，只来自测试运行自身生成的 `Docs/reports/` 报告文件，源码、测试与工程文件与该提交一致。
- 上一轮（提交 `1bc5d7f`）为核心 529/529、UI 24/24。本轮核心净增 23 条（529 → 552）：缺陷修复提交 `6b1f0f8` 带 1 条回归测试，测试补充提交 `94b6043` 加 23 条，审查后 `77da5c4` 删除 1 条与已有用例重复的；逐条理由见第 5 节。
- **真机运行（补充）**：同样 24 条在 iPhone 15 Pro Max（iOS 27.0.1）上都通过过，但分多次运行（中间有设备连接中断、测试运行器重装、一次系统通知遮挡导致的失败并单独重跑），详见 [DeviceAcceptance.md](DeviceAcceptance.md) 1.1。上表的 24/24 仍以模拟器的一次连续运行为准。
- 统计口径（8.1）：每个 `@Test` / XCTest 方法计 1 个；没有参数化展开计数；没有跳过、禁用或预期失败；重名 0。核心测试不访问网络、不依赖收费服务（HTTP 用可编排桩，时钟用 `ManualClock`）。
- **系统范围更新（2026-10-18）**：用户将最低支持与验收系统改为 iOS 27，iOS 18 不再是未完成项。上述测试为历史提交的运行结果；变更后的复测结果单独记录，不覆盖原始报告。

## 2. 核心测试分布

| 测试 target | 用例 | 预算（第 4 节） | 说明 |
|---|---:|---:|---|
| LibraryCoreTests | 40 | 24 | EPUB 正常/异常样本、导入/重复/删除/恢复/并发 |
| ReaderCoreTests | 27 | 26 | 定位、重新定位、分页、批注、书签 |
| ReadingSessionCoreTests | 16 | 16 | 区间合并、跳读、会话、中断恢复 |
| ReflectionCoreTests | 23 | 22 | 草稿、提交幂等、修改留痕、消息状态机 |
| SpeechCoreTests | 16 | 16 | 权限、中断、取消、无语音、时长上限 |
| RetrievalCoreTests | 63 | 60 | 分词、切块、BM25、向量、RRF、重排映射、扩展、降级、索引生命周期 |
| ContextRoutingTests | 34 | 34 | 计划解析、规则编译、降级、注入防护 |
| ContextEngineeringTests | 34 | 34 | 组装、去重、裁剪、提示词、引用 |
| BrainCoreTests | 39 | 38 | 条目、修订、提议、关系、失效、召回 |
| AgentRuntimeTests | 34 | 34 | 预算、重试、超时、取消、完成门、任务登记、脱敏 |
| ReaderAgentTests | 29 | 28 | 完整讨论链路、边界、取消、失败重试、幂等、记忆提议 |
| ModelProvidersTests | 30 | 30 | 对话/SSE、Embedding、Rerank、错误映射 |
| PersistenceTests | 32 | 32 | 迁移（含 v1 旧库样本）、删除级联、FTS5、向量、事务、备份 |
| AppInfrastructureTests | 15 | 12 | 密钥（含真实钥匙串往返）、配置、启动恢复、策略、装配 |
| AchievementCoreTests | 12 | 10 | 日历/时区/跨午夜、成就去重 |
| BenchCoreTests | 17 | 14 | 指标分母、数据冻结、结果比较、运行器 |
| EvidenceVerificationCoreTests | 34 | 32 | 陈述拆分、结构检查、裁判、失败语义、数字归一化 |
| LearningCoreTests | 39 | 38 | 出题校验、评分、掌握、调度（固定时钟、时区） |
| IntegrationTests | 18 | — | 跨模块：EPUB→定位、SQLite 重启、中文检索、HTTP 协议→讨论、恢复写入、记忆/学习/备份闭环、5k 子块性能冒烟 |
| **合计** | **552** | 500 | |

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
| 上下文截断讨论历史/反思/记忆后追加“…”，省略号的 token 未预留，组装用量可超过预算（CTX-03） | 边界测试（预算 200 时用量超出） | 截断到“剩余预算 − 省略号”后再追加；回归测试“CTX-03 讨论历史可截断以装入剩余预算”（提交 `6b1f0f8`） |

## 5. 本轮新增用例与各自防范的缺陷（529 → 552）

每条新增用例都对应一个具体失效方式。审查时删除了 2 条：
- `ReaderNavigator` 未知章节回退（提交前删除）：应用不使用 `ReaderNavigator`，真实回退逻辑在 `ReaderModel.load`，该用例只测到无调用方的代码；
- “未结束会话列表不含已结束会话”（`77da5c4` 删除）：`ReadingSessionCoreTests` 的中断恢复用例已在 SQLite 仓储上断言恢复后 `openSessions()` 为空，防的是同一缺陷。

| 模块 | 用例 | 防范的缺陷 |
|---|---|---|
| ContextEngineering | 讨论历史可截断以装入剩余预算 | 截断后追加省略号使用量超出预算（本轮实际发现并修复） |
| ContextEngineering | 丢弃中间候选后标签仍连续编号 | 先编号后过滤导致 E1、E3 跳号，模型引用的标签与证据错位 |
| ContextEngineering | 同文本出现在原文与反思时保留原文 | 去重保留先出现的低优先级来源（反思），原文证据被当作重复丢弃；标点差异导致漏去重 |
| ContextEngineering | 同一来源内按分数从高到低排序 | 按输入顺序装入，预算不足时高分证据被裁掉 |
| ContextEngineering | 大量候选时估算用量始终不超过预算 | 多种预算（0～3000）下组装超预算，或候选既未入选也未记入丢弃清单 |
| ContextEngineering | 只有反思与记忆时不算书籍证据 | 只凭个人材料就被当作“有原文依据”，跳过证据不足提示 |
| ContextEngineering | 证据头部标注章节标题与“当前选段” | 提示词丢失章节/选段标记，模型无法区分当前选段与其他证据 |
| ContextEngineering | 证据与问题中伪造的开始标签同样被转义 | 原文或问题里的 `<evidence>` 伪造新证据块（提示注入） |
| ContextEngineering | 引用标签允许逗号两侧空格与顿号分隔 | `[E1 , E2]`、`[E3、E4]` 解析不到，陈述丢失引用被误判证据不足 |
| ContextEngineering | 组合引用中只剔除伪造部分 | `[E1、E9]` 整组删除（丢掉有效引用）或整组保留（保留伪造引用） |
| ContextEngineering | 证据来源映射 | 证据类型与上下文来源对应错误，来源过滤放行/拦截了错误的证据类型 |
| ContextRouting | 已授权但没有阅读状态的书被拒绝 | 已删除的书仍在授权列表中，得到空或不受限的检索范围 |
| ContextRouting | 全书范围允许未读章节但锁定版本 | 用户切换全书后仍拦截未读章节，或放行其他版本的旧内容 |
| ContextRouting | needs_retrieval=false 被解析并保留 | 解析时默认值覆盖 false，选段解释类问题被强制检索 |
| ContextRouting | 英文章节关键词识别为章节理解 | 规则规划只认中文“本章”，英文书的章节问题走错意图 |
| ReaderCore | 章首/章尾锚点前后文为空不越界 | 取锚点前后文时字符串越界崩溃 |
| ReaderCore | 空锚点无法重新定位，报告失效 | 空字符串在任意位置“匹配”，失效定位被错误重新定位到章首 |
| ReaderCore | 超出章节末尾的偏移落在最后一页 | 页码查找返回越界下标或 -1 |
| Persistence | 书签保存、按书列出与删除（SQLite） | 书签查询不按书过滤：另一本书同章节的书签显示为“已加书签”（已有的切换用例只有一本书，测不到过滤） |
| Persistence | 另一提议使用相同幂等键时被拒绝且不覆盖 | `INSERT OR REPLACE` 类问题：重复键静默覆盖原提议 |
| Persistence | Markdown 导出标注来源不可访问与失效证据 | 导出丢失“阅读文件已删除”“来源已失效”标记，读者误以为证据仍有效 |
| ReaderAgent | 未读章节上的批注不进入讨论证据 | 未读区间的批注把后文内容带进讨论（剧透，READ-05） |
| ReaderAgent | 阅读现场位于未读区间的反思不进入讨论证据 | 同上，经反思泄露未读内容 |

## 6. 模拟器本地时延（参考）

见 [reports/perf-sim-20261018T135819.md](reports/perf-sim-20261018T135819.md)。**模拟器参考值，不作为设备验收 D-13 依据。**
