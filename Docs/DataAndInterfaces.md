# 数据与接口说明

## 1. 实体与存储

所有表在 `Sources/Persistence/AppDatabase.swift` 的迁移中定义。关键字段建列（主键、外键、唯一键、筛选字段），领域对象完整内容以 JSON 存于 `payload` 列；日期统一为 Unix 秒（UTC），界面按用户时区显示。

| 数据组 | 实体（Swift 类型） | 表 | 关键约束 |
|---|---|---|---|
| 书籍与阅读 | `Book`、`Chapter`、`TOCEntry` | `book`、`chapter`、`toc_entry` | `book.fingerprint` 唯一（文件 SHA-256 = 书籍版本）；章节随书级联删除 |
| | `Locator`（嵌入批注、位置、引用） | — | 版本 + 章节资源 + UTF-16 区间 + 前后文锚点 |
| | `ReadingPosition`、`Annotation`、`Bookmark` | `reading_position`、`annotation`、`bookmark` | 批注不随“仅删除文件”删除 |
| | 已读区间 `BookReadState` | `read_range` | 按（书, 版本, 章）合并后整体替换，重复写入幂等 |
| | `ReadingSession` | `reading_session` | 启动时把未结束会话以最后活动时间结束 |
| 阅读内容 | `Reflection`、`ReflectionEdit` | `reflection`、`reflection_edit` | `commitKey` 唯一（重复提交不产生第二条） |
| | `Conversation`、`Message`（含 `CitationSnapshot`、`ClaimCheckSnapshot`） | `conversation`、`message` | 消息随会话级联删除；v2 增加 `message.status` 列 |
| 检索 | `ParentChunk`、`ChildChunk` | `parent_chunk`、`child_chunk`、`child_fts`（FTS5） | 子块 ID = `书/版本前缀:章:父:子`；FTS 文档为预分词 token |
| | 向量 | `embedding` | 主键（childID, model, dims）；按 (model, dims, fingerprint) 复用 |
| | `IndexManifest` | `index_manifest` | 记录切块策略版本、向量模型/维度、内容版本、向量状态 |
| 记忆 | `BrainItem`（Thought/Question/Memory）、`EvidenceRef` | `brain_item` | 证据可标记失效（`isValid`、`invalidReason`） |
| | `Relation`、`Revision`、`MemoryProposal` | `relation`、`revision`、`proposal` | `proposal.idempotencyKey` 唯一；确认时在一个事务内检查仍为 pending |
| 学习 | `LearningItem`、`Attempt`、`Feedback`、`MasteryRecord`、`ReviewSchedule` | `learning_item`、`attempt`、`feedback`、`mastery`、`review_schedule` | `attempt.idempotencyKey` 唯一；作答/反馈/掌握/排期一个事务写入；v2 增加 `review_schedule.dueDay` |
| 执行与设置 | `AgentTaskRecord`、`TraceEvent` | `agent_task`、`trace_event` | 任务以幂等键为主键；追踪默认不含正文 |
| | 成就、设置（不含密钥） | `achievement`、`app_setting` | 成就 `INSERT OR IGNORE` 防重复解锁 |
| 凭据 | `SecretReference` | 系统 Keychain | 配置中只存引用，密钥不进数据库、日志、导出包 |

### 迁移

| 版本 | 内容 | 验证 |
|---|---|---|
| v1 | 全部基础表 | `MigrationTests.freshDatabase` |
| v2 | `message.status` 列与 `review_schedule.dueDay` 列及索引，并从 payload 回填 | `MigrationTests.legacyMigration`（构造 v1 旧库样本后迁移）、`migrationIdempotent` |

## 2. 一致性规则落实

| 规则 | 落实位置 |
|---|---|
| 证据与书籍版本绑定；重新导入不同内容不沿用旧定位 | `LocatorResolver`（版本不同只按锚点文本重定位，找不到报告失效）；`StructuralChecker` 检查版本 |
| 已读权限以文本区间为依据 | `AccessScope`、`RetrievalScope`；展示进度 `displayFraction` 不参与权限 |
| 删除/修订后引用和记忆能发现来源失效 | `LibraryLifecycleBridge` → `BrainService.invalidateBookSources`；`RepositoryEvidenceValidator`；反思 `sourceUnavailable` |
| 模型内容先作为候选保存 | `MemoryProposal`（pending → 确认才写入）、`QuestionGenerator.parse` 校验后才入库 |
| 网络任务持久化状态与幂等键 | `TaskRegistry` + `agent_task`；启动时 running → interrupted；进行中的回答 → failed（保留草稿） |
| 时间统一格式，按日历规则计算 | `DayKey`、`ReviewScheduler`、`HabitCalculator`（固定时钟测试） |

## 3. 索引版本

`IndexCompatibility.check` 比较清单与当前状态：
- 书籍内容指纹或切块策略版本（`pc1-p1200-c320-m24-seg-v1-cjk-bigram`）变化 → `needsRechunk`：重新切块并清除该书全部向量；
- 向量模型或维度变化 → `needsReembed`：只删除不一致的向量；
- 检索时只对清单 `embeddingProfile` 与当前向量服务一致的书使用向量路，否则记录 `vector_index_incompatible:<书>` 并降级。

## 4. 模型服务接口

| 用途 | 适配器 | 默认端点（北京） | 校验 |
|---|---|---|---|
| 对话（规划/生成/复核/记忆提议/出题/评分） | `OpenAICompatibleChatProvider` | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` | 非流式：choices/finish_reason/usage；流式：SSE `data:`、`[DONE]`、错误帧、缺少结束原因 → `streamTruncated`；JSON 模式 `response_format` |
| 向量 | `DashScopeEmbeddingProvider` | `…/compatible-mode/v1/embeddings`，`text-embedding-v4`，默认 1024 维，每批 ≤10 | 数量一致、按 `index` 重排、index 唯一、维度一致、数值有限；输入保守截断 |
| 重排 | `DashScopeRerankProvider` | 原生：`https://dashscope.aliyuncs.com/api/v1/services/rerank/text-rerank/text-rerank`；兼容：`…/reranks`，`qwen3-rerank` | 解析 `output.results` / `results`；index 越界或重复 → `invalidRerankIndex` |

地域（北京/新加坡）、业务空间与模型权限在设置页配置；对话供应商可替换为其他 OpenAI 兼容服务（如 DeepSeek），只需改接口地址与模型 ID。

### 错误语义（`ProviderError`）

| 错误 | 来源 | 可重试 | 用户提示 |
|---|---|---|---|
| `offline` / `timeout` | URLError、超时竞争 | 是 | 问题已保留，可重试 |
| `unauthorized`（401、InvalidApiKey） / `forbidden`（403、AccessDenied） | HTTP | 否 | 检查密钥、地域、业务空间与模型授权 |
| `rateLimited(retryAfter)`（429、Throttling） | HTTP | 是（按 Retry-After） | 稍后重试 |
| `server(status)` | 5xx | 是 | 服务暂时不可用 |
| `badRequest` / `contextTooLong` | 400/413/422 | 否 | 信息经脱敏 |
| `emptyResponse` / `invalidResponse` / `streamTruncated` | 解析 | 空响应与截断可重试 | 结果不完整，不标记成功 |
| `dimensionMismatch` / `invalidRerankIndex` | 协议校验 | 否 | 向量批次整批不写入；重排失败保留融合排序 |
| `notConfigured` | 缺少密钥 | 否 | 不发请求 |

所有重试都计入所属任务的 `TaskBudget`。

## 5. 结构化备份格式

```json
{ "format": "thoughttrail-backup", "schemaVersion": 2, "createdAt": 1790000000,
  "includesEPUB": true, "includesAudio": false, "checksum": "<payload 规范 JSON 的 SHA-256>",
  "payload": { "books": [{ "book": {...}, "chapters": [...], "toc": [...], "epubBase64": "..." }],
               "annotations": [...], "reflections": [...], "messages": [...], "brainItems": [...], "relations": [...],
               "revisions": [...], "proposals": [...], "learningItems": [...], "attempts": [...], "feedback": [...],
               "mastery": [...], "schedules": [...], "readRanges": [...], "sessions": [...], "achievements": [...], "settings": {...} } }
```

- 不含密钥（键名含 key/secret/token/password 的设置被排除）、不含音频、不含派生索引（恢复后按需重建）。
- `includesEPUB=false` 时恢复的书标记为“来源不可访问”，重新导入同一文件即可恢复正文。
- 恢复在单个事务中执行：校验和不符、格式错误、版本不支持都在写入前拒绝；按主键 UPSERT，重复导入不产生重复记录。
- v1 备份（反思字段名为 `notes`）由 `BackupMigrator.v1ToV2` 迁移后恢复。

## 6. 复习间隔规则（LEARN-04）

间隔序列 `[1, 3, 7, 14, 30]` 天（可配置）。每次作答根据评分与自评得出：
- **前进**：得分 ≥ 0.8（自评“吃力”时改为保持）；评分不确定时自评“基本掌握/很轻松”。
- **保持**：0.5 ≤ 得分 < 0.8；评分不确定且无自评或自评“吃力”。
- **回退一级**（最低第一级）：得分 < 0.5，或自评“没想起来”。

到期日 = 作答当日（用户时区的日历日）+ 当前级别间隔。同一作答幂等键重复提交不会重复排期。掌握等级至少需要最近两次独立作答通过才为“掌握”，人工修正在下一次作答前有效。
