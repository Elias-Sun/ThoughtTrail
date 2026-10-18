# 核心自动化测试清单

- 源码中声明的唯一用例：**552**（重名 0 个）
- 本次运行：通过 552，失败 0，跳过 0，未执行 0
- 原始日志：`core-tests-20261018T140134.log`

## 按测试 target 统计

| Target | 用例数 |
|---|---:|
| AchievementCoreTests | 12 |
| AgentRuntimeTests | 34 |
| AppInfrastructureTests | 15 |
| BenchCoreTests | 17 |
| BrainCoreTests | 39 |
| ContextEngineeringTests | 34 |
| ContextRoutingTests | 34 |
| EvidenceVerificationCoreTests | 34 |
| IntegrationTests | 18 |
| LearningCoreTests | 39 |
| LibraryCoreTests | 40 |
| ModelProvidersTests | 30 |
| PersistenceTests | 32 |
| ReaderAgentTests | 29 |
| ReaderCoreTests | 27 |
| ReadingSessionCoreTests | 16 |
| ReflectionCoreTests | 23 |
| RetrievalCoreTests | 63 |
| SpeechCoreTests | 16 |

## 需求 → 用例数

| 需求 | 用例数 |
|---|---:|
| 02 | 1 |
| 10.1 | 2 |
| 10.2 | 4 |
| 10.3 | 20 |
| 13.2-5 | 1 |
| 13.2-6 | 1 |
| 13.2-7 | 1 |
| 13.2-8 | 1 |
| 5.2 | 5 |
| 5.5 | 6 |
| 5.6 | 3 |
| 7.3 | 3 |
| 9.1 | 3 |
| 9.2 | 14 |
| 9.3 | 1 |
| CHAT-01 | 14 |
| CHAT-02 | 6 |
| CHAT-03 | 8 |
| CHAT-04 | 8 |
| CTX-01 | 12 |
| CTX-02 | 8 |
| CTX-03 | 24 |
| CTX-04 | 8 |
| DATA-01 | 8 |
| DATA-02 | 8 |
| DATA-03 | 12 |
| DATA-04 | 1 |
| EVID-01 | 7 |
| EVID-02 | 19 |
| EVID-03 | 3 |
| EVID-04 | 5 |
| HABIT-01 | 14 |
| LEARN-01 | 11 |
| LEARN-02 | 6 |
| LEARN-03 | 7 |
| LEARN-04 | 5 |
| LEARN-05 | 10 |
| LIB-01 | 11 |
| LIB-02 | 13 |
| LIB-03 | 6 |
| LIB-04 | 9 |
| M12 | 13 |
| MEM-01 | 5 |
| MEM-02 | 15 |
| MEM-03 | 5 |
| MEM-04 | 11 |
| MEM-05 | 9 |
| RAG-01 | 13 |
| RAG-02 | 17 |
| RAG-03 | 12 |
| RAG-04 | 3 |
| RAG-05 | 16 |
| RAG-06 | 8 |
| READ-01 | 12 |
| READ-02 | 8 |
| READ-03 | 13 |
| READ-04 | 15 |
| READ-05 | 15 |
| REF-01 | 2 |
| REF-02 | 10 |
| REF-03 | 19 |
| RUN-01 | 10 |
| RUN-02 | 7 |
| RUN-03 | 7 |
| 统一规则1 | 1 |

## 全部用例

| # | Target | 套件 | 用例 | 结果 |
|---:|---|---|---|---|
| 1 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 连续阅读按日历日计算；当天未达标时从昨天起算 | 通过 |
| 2 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 当天不足 5 分钟不计为有效阅读日 | 通过 |
| 3 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 重复事件（同一会话 ID）不重复累计 | 通过 |
| 4 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 跨午夜会话按墙钟跨度在两天间按比例分配 | 通过 |
| 5 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 跨时区：同一会话在不同时区归属不同日历日 | 通过 |
| 6 | AchievementCoreTests | M15 阅读习惯统计 | HABIT-01 跨月份的连续天数正确 | 通过 |
| 7 | AchievementCoreTests | M15 成就 | HABIT-01 规则可解释：返回解锁原因 | 通过 |
| 8 | AchievementCoreTests | M15 成就 | HABIT-01 已解锁的成就不会重复解锁 | 通过 |
| 9 | AchievementCoreTests | M15 成就 | HABIT-01 计数类成就与读完一本书 | 通过 |
| 10 | AchievementCoreTests | M15 成就 | HABIT-01 服务刷新：持久化且重复刷新不重复插入 | 通过 |
| 11 | AchievementCoreTests | M15 成就 | HABIT-01 统计与成就一致：十小时成就基于累计时长 | 通过 |
| 12 | AchievementCoreTests | M15 成就 | HABIT-01 没有活动时长的会话不计入 | 通过 |
| 13 | AgentRuntimeTests | M10 边界情况 | RUN-01 剩余时间不足时单次调用的超时以剩余时间为准 | 通过 |
| 14 | AgentRuntimeTests | M10 边界情况 | RUN-01 canAfford 同时检查次数与时间 | 通过 |
| 15 | AgentRuntimeTests | M10 边界情况 | RUN-03 预算快照记录耗时与分阶段次数 | 通过 |
| 16 | AgentRuntimeTests | M10 边界情况 | RUN-03 追踪记录器容量受限并转发到持久化接收端 | 通过 |
| 17 | AgentRuntimeTests | M10 边界情况 | RUN-02 同一幂等键并发开始只有一个获得执行权 | 通过 |
| 18 | AgentRuntimeTests | M10 边界情况 | 10.3 重试等待期间被取消：停止重试并报告取消 | 通过 |
| 19 | AgentRuntimeTests | M10 边界情况 | CTX-01 从模型输出中提取 JSON 数组 | 通过 |
| 20 | AgentRuntimeTests | M10 边界情况 | RUN-03 错误码彼此唯一，便于统计 | 通过 |
| 21 | AgentRuntimeTests | M10 预算 | RUN-01 调用次数达到上限后拒绝 | 通过 |
| 22 | AgentRuntimeTests | M10 预算 | RUN-01 超过总时限后拒绝新调用 | 通过 |
| 23 | AgentRuntimeTests | M10 预算 | 10.2 初始执行预算：讨论 6 次/60 秒，记忆 2 次/30 秒，学习 6 次/60 秒 | 通过 |
| 24 | AgentRuntimeTests | M10 预算 | RUN-03 区分服务端实际用量、估算用量与未知用量 | 通过 |
| 25 | AgentRuntimeTests | M10 预算 | RUN-01 负数配置被规整为 0 | 通过 |
| 26 | AgentRuntimeTests | M10 有界执行 | RUN-01 重试计入同一预算：预算耗尽后停止重试 | 通过 |
| 27 | AgentRuntimeTests | M10 有界执行 | RUN-01 可重试错误重试后成功 | 通过 |
| 28 | AgentRuntimeTests | M10 有界执行 | 10.3 401/403/请求错误不重试 | 通过 |
| 29 | AgentRuntimeTests | M10 有界执行 | 10.3 超时返回 timeout 错误 | 通过 |
| 30 | AgentRuntimeTests | M10 有界执行 | 10.3 取消后不再发起调用，错误为 cancelled | 通过 |
| 31 | AgentRuntimeTests | M10 有界执行 | RUN-03 每次调用记录追踪事件：阶段、模型、用量、结果与错误码 | 通过 |
| 32 | AgentRuntimeTests | M10 有界执行 | RUN-01 退避：限流使用 Retry-After，其余指数增长且有上限 | 通过 |
| 33 | AgentRuntimeTests | M10 完成门与任务登记 | RUN-02 完成后取消无效；取消后迟到的完成被丢弃 | 通过 |
| 34 | AgentRuntimeTests | M10 完成门与任务登记 | RUN-02 并发完成只有一个生效 | 通过 |
| 35 | AgentRuntimeTests | M10 完成门与任务登记 | RUN-02 重复触发：进行中返回 alreadyRunning，成功后返回 alreadySucceeded | 通过 |
| 36 | AgentRuntimeTests | M10 完成门与任务登记 | CHAT-04 失败后可重试：尝试次数递增并换新 traceID | 通过 |
| 37 | AgentRuntimeTests | M10 完成门与任务登记 | RUN-02 迟到的第二次结束被忽略 | 通过 |
| 38 | AgentRuntimeTests | M10 完成门与任务登记 | 10.3 进程终止后启动时把运行中的任务标记为中断 | 通过 |
| 39 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | DATA-03 日志中的密钥与授权头被脱敏 | 通过 |
| 40 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | RUN-03 追踪属性默认不记录敏感正文 | 通过 |
| 41 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | DATA-03 设置页密钥只显示掩码 | 通过 |
| 42 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | 5.5 保守 Token 估算：中文按字、其他字符按 3 字符 1 token | 通过 |
| 43 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | CTX-03 按估算截断不超过预算 | 通过 |
| 44 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | CTX-01 从模型输出中提取 JSON：围栏、前置说明与字符串中的括号 | 通过 |
| 45 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | CHAT-02 流式消费逐段回调；缺少结束帧视为截断 | 通过 |
| 46 | AgentRuntimeTests | M10 脱敏、估算与结构化输出 | 10.3 错误语义：可重试分类与用户提示 | 通过 |
| 47 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 内存密钥存储读写删除，空值被拒绝，设置页只显示掩码 | 通过 |
| 48 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 系统 Keychain 存储往返（本机钥匙串） | 通过 |
| 49 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 配置校验：必须 HTTPS、模型非空、维度合理 | 通过 |
| 50 | AppInfrastructureTests | M14 凭据与配置 | RAG-05 判断向量模型/维度是否变化 | 通过 |
| 51 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 Provider 按需从密钥存储读取密钥；三类接口分别构造 | 通过 |
| 52 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 规划/复核模型可单独指定；关闭的接口不构造 | 通过 |
| 53 | AppInfrastructureTests | M14 凭据与配置 | DATA-03 保存配置不包含密钥；非法配置被拒绝；向量维度变化提示重建 | 通过 |
| 54 | AppInfrastructureTests | M14 装配、生命周期与策略 | 10.3 启动恢复：结束遗留会话、标记中断任务、进行中回答标记失败 | 通过 |
| 55 | AppInfrastructureTests | M14 装配、生命周期与策略 | LIB-04 删除书籍后记忆中的原文证据被标记失效 | 通过 |
| 56 | AppInfrastructureTests | M14 装配、生命周期与策略 | DATA-04 离线时本地操作可用，在线模型操作显示待处理；未配置时显示不可用 | 通过 |
| 57 | AppInfrastructureTests | M14 装配、生命周期与策略 | REF-03 权限状态映射为用户指引，始终允许文字降级 | 通过 |
| 58 | AppInfrastructureTests | M14 装配、生命周期与策略 | 7.3 数据处理说明覆盖云向量、讨论上传与密钥存放 | 通过 |
| 59 | AppInfrastructureTests | M14 装配、生命周期与策略 | CHAT-01 装配的讨论编排器使用当前（覆盖的）模型配置完成一次讨论 | 通过 |
| 60 | AppInfrastructureTests | M14 装配、生命周期与策略 | 7.3 索引协调：只对已读范围向量化，同一本书并发触发只执行一次 | 通过 |
| 61 | AppInfrastructureTests | M14 装配、生命周期与策略 | DATA-02 Markdown 导出汇总全部书籍与记录 | 通过 |
| 62 | BenchCoreTests | M16 指标 | 9.2 Recall@K 按标注相关证据总数计算，不是命中任意一条 | 通过 |
| 63 | BenchCoreTests | M16 指标 | 9.2 命中需同书同章且重叠足够 | 通过 |
| 64 | BenchCoreTests | M16 指标 | 9.2 nDCG@K：理想排序为 1，高等级证据靠后时降低 | 通过 |
| 65 | BenchCoreTests | M16 指标 | 9.2 nDCG 中同一相关证据只计一次 | 通过 |
| 66 | BenchCoreTests | M16 指标 | 9.2 问题类别 Precision/Recall：无法判断的正类计入未检出 | 通过 |
| 67 | BenchCoreTests | M16 指标 | 9.2 指标同时给出分子与分母；空样本不除零 | 通过 |
| 68 | BenchCoreTests | M16 数据集与结果 | 9.1 JSONL 载入：坏行记录行号，不静默丢弃 | 通过 |
| 69 | BenchCoreTests | M16 数据集与结果 | 9.1 验收集冻结：哈希变化则拒绝评测；开发集可不冻结 | 通过 |
| 70 | BenchCoreTests | M16 数据集与结果 | 9.2 结果保存、读取与比较；数据版本不同拒绝比较 | 通过 |
| 71 | BenchCoreTests | M16 数据集与结果 | 9.2 重复运行保存为不同记录；配置哈希可复现 | 通过 |
| 72 | BenchCoreTests | M16 数据集与结果 | 9.3 Markdown 报告包含数据版本、分母、混淆矩阵与失败样本 | 通过 |
| 73 | BenchCoreTests | M16 评测运行器 | 9.2 检索运行器按类别汇总并跳过不可回答问题 | 通过 |
| 74 | BenchCoreTests | M16 评测运行器 | 9.2 复核运行器：裁判报错的样本计为无法判断 | 通过 |
| 75 | BenchCoreTests | M16 评测运行器 | 9.2 记忆运行器：来源、重复与冲突规则判定 | 通过 |
| 76 | BenchCoreTests | M16 评测运行器 | 9.2 自测运行器：越界证据判为不可作答，反馈与参考分比较 | 通过 |
| 77 | BenchCoreTests | M16 评测运行器 | 9.1 范围设定：整章、章内区间与全书 | 通过 |
| 78 | BenchCoreTests | M16 评测运行器 | 9.2 边界运行器：违规计数与样本 | 通过 |
| 79 | BrainCoreTests | M09 边界情况 | MEM-03 证据来源比较：同书同章重叠区间或同一记录视为同源 | 通过 |
| 80 | BrainCoreTests | M09 边界情况 | MEM-01 归档条目不出现在搜索与召回中 | 通过 |
| 81 | BrainCoreTests | M09 边界情况 | MEM-05 来源失效的条目仍可查看，但标记为来源失效 | 通过 |
| 82 | BrainCoreTests | M09 边界情况 | MEM-03 删除关系后不再出现 | 通过 |
| 83 | BrainCoreTests | M09 边界情况 | MEM-02 提议摘要可读，动作指纹对空白与标点不敏感 | 通过 |
| 84 | BrainCoreTests | M09 边界情况 | MEM-02 按状态列出提议 | 通过 |
| 85 | BrainCoreTests | M09 边界情况 | MEM-04 修订提议缺少原因或内容未变化时无效 | 通过 |
| 86 | BrainCoreTests | M09 条目与修订 | MEM-01 分别创建观点、问题与记忆，可按类型筛选 | 通过 |
| 87 | BrainCoreTests | M09 条目与修订 | MEM-01 空内容与超长内容被拒绝 | 通过 |
| 88 | BrainCoreTests | M09 条目与修订 | MEM-04 编辑保留前后内容、时间与原因 | 通过 |
| 89 | BrainCoreTests | M09 条目与修订 | MEM-04 基于过期版本的编辑被拒绝，不静默覆盖 | 通过 |
| 90 | BrainCoreTests | M09 条目与修订 | MEM-04 内容未变化时不产生修订 | 通过 |
| 91 | BrainCoreTests | M09 条目与修订 | MEM-01 按内容搜索，删除的条目不出现 | 通过 |
| 92 | BrainCoreTests | M09 条目与修订 | MEM-01 问题可标记为已解决 | 通过 |
| 93 | BrainCoreTests | M09 条目与修订 | MEM-03 用户建立关系；重复建立返回同一关系；不能自关联 | 通过 |
| 94 | BrainCoreTests | M09 记忆提议 | MEM-02 合法提议保存为待确认，不直接写入条目 | 通过 |
| 95 | BrainCoreTests | M09 记忆提议 | MEM-02 确认后才生效，条目标记为来自确认的提议 | 通过 |
| 96 | BrainCoreTests | M09 记忆提议 | MEM-02 拒绝不会暗中写入 | 通过 |
| 97 | BrainCoreTests | M09 记忆提议 | MEM-04 重复处理同一讨论不会生成重复提议 | 通过 |
| 98 | BrainCoreTests | M09 记忆提议 | MEM-04 与已有条目重复的提议被标记为无效 | 通过 |
| 99 | BrainCoreTests | M09 记忆提议 | MEM-02 来源不是本次讨论证据的提议无效 | 通过 |
| 100 | BrainCoreTests | M09 记忆提议 | MEM-05 证据超出阅读范围的提议无效 | 通过 |
| 101 | BrainCoreTests | M09 记忆提议 | MEM-02 记忆类提议缺少证据无效；问题类可以没有证据 | 通过 |
| 102 | BrainCoreTests | M09 记忆提议 | MEM-03 关联提议确认后关系标记为“建议”来源 | 通过 |
| 103 | BrainCoreTests | M09 记忆提议 | MEM-03 关联不存在的条目或已存在的关系无效 | 通过 |
| 104 | BrainCoreTests | M09 记忆提议 | MEM-04 修订提议确认后记录修订历史 | 通过 |
| 105 | BrainCoreTests | M09 记忆提议 | MEM-04 修订提议基于的版本过期时确认失败，不覆盖用户修改 | 通过 |
| 106 | BrainCoreTests | M09 记忆提议 | MEM-04 两个相似提议依次确认：第二个因重复失效 | 通过 |
| 107 | BrainCoreTests | M09 记忆提议 | MEM-02 重复确认同一提议是幂等的 | 通过 |
| 108 | BrainCoreTests | M09 记忆提议 | MEM-02 待确认列表按时间排序 | 通过 |
| 109 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 书籍删除后原文证据标记失效，恢复后重新生效 | 通过 |
| 110 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 反思被删除后对应证据失效 | 通过 |
| 111 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 越界来源的记忆整条排除，避免摘要泄露未读内容 | 通过 |
| 112 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 来源失效或已删除的记忆不伪装成有效证据 | 通过 |
| 113 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 仅有个人来源的观点被标记为个人记忆而非书籍证据 | 通过 |
| 114 | BrainCoreTests | M09 来源失效与再关联 | MEM-05 召回按相关度排序并受 limit 限制 | 通过 |
| 115 | BrainCoreTests | M09 来源失效与再关联 | MEM-02 解析模型提议：标签映射为证据，未知动作被丢弃 | 通过 |
| 116 | BrainCoreTests | M09 来源失效与再关联 | MEM-02 畸形提议输出抛出解析错误 | 通过 |
| 117 | BrainCoreTests | M09 来源失效与再关联 | MEM-04 文本相似度用于重复检测 | 通过 |
| 118 | ContextEngineeringTests | M08 边界情况 | CTX-03 丢弃中间候选后标签仍连续编号 | 通过 |
| 119 | ContextEngineeringTests | M08 边界情况 | CTX-03 同文本出现在原文与反思时保留优先级更高的原文 | 通过 |
| 120 | ContextEngineeringTests | M08 边界情况 | CTX-03 同一来源内按分数从高到低排序 | 通过 |
| 121 | ContextEngineeringTests | M08 边界情况 | CTX-03 大量候选时估算用量始终不超过预算 | 通过 |
| 122 | ContextEngineeringTests | M08 边界情况 | CTX-03 讨论历史可截断以装入剩余预算 | 通过 |
| 123 | ContextEngineeringTests | M08 边界情况 | CHAT-01 只有反思与记忆时不算书籍证据 | 通过 |
| 124 | ContextEngineeringTests | M08 边界情况 | CHAT-01 证据头部标注章节标题与“当前选段” | 通过 |
| 125 | ContextEngineeringTests | M08 边界情况 | 5.5 证据与问题中伪造的开始标签同样被转义 | 通过 |
| 126 | ContextEngineeringTests | M08 边界情况 | CHAT-01 引用标签允许逗号两侧空格与顿号分隔 | 通过 |
| 127 | ContextEngineeringTests | M08 边界情况 | CHAT-03 组合引用中只剔除伪造部分 | 通过 |
| 128 | ContextEngineeringTests | M08 边界情况 | CTX-03 证据来源映射：选段、批注、记忆对应各自的上下文来源 | 通过 |
| 129 | ContextEngineeringTests | M08 上下文组装 | CTX-03 按来源优先级排序并顺序分配 E 标签 | 通过 |
| 130 | ContextEngineeringTests | M08 上下文组装 | CTX-03 选段排在最前 | 通过 |
| 131 | ContextEngineeringTests | M08 上下文组装 | CTX-03 同 ID 与同文本（规范化后）去重并记录 | 通过 |
| 132 | ContextEngineeringTests | M08 上下文组装 | CTX-03 被选段完全覆盖的原文片段视为重复 | 通过 |
| 133 | ContextEngineeringTests | M08 上下文组装 | CTX-03 超预算按优先级裁剪低优先级来源 | 通过 |
| 134 | ContextEngineeringTests | M08 上下文组装 | CTX-03 历史/反思/记忆可截断以装入剩余预算，原文不截断 | 通过 |
| 135 | ContextEngineeringTests | M08 上下文组装 | CTX-03 不允许的来源被隔离并记录 | 通过 |
| 136 | ContextEngineeringTests | M08 上下文组装 | CTX-03 空白证据被丢弃 | 通过 |
| 137 | ContextEngineeringTests | M08 上下文组装 | CTX-03 预算为 0 时不放入任何证据 | 通过 |
| 138 | ContextEngineeringTests | M08 上下文组装 | CTX-03 证据映射：按标签查回来源与位置 | 通过 |
| 139 | ContextEngineeringTests | M08 上下文组装 | CTX-03 同分数时保持输入顺序（稳定） | 通过 |
| 140 | ContextEngineeringTests | M08 上下文组装 | CTX-03 检索单元转换为证据保留书籍版本、章节与区间 | 通过 |
| 141 | ContextEngineeringTests | M08 上下文组装 | 5.6 只有原文与批注属于书籍证据 | 通过 |
| 142 | ContextEngineeringTests | M08 提示词与引用 | CHAT-01 证据块标注编号、来源类别与章节 | 通过 |
| 143 | ContextEngineeringTests | M08 提示词与引用 | CHAT-03 系统规则要求区分一般知识并禁止伪造引用 | 通过 |
| 144 | ContextEngineeringTests | M08 提示词与引用 | 5.2 全书范围在提示词中明确说明 | 通过 |
| 145 | ContextEngineeringTests | M08 提示词与引用 | 5.5 证据中的伪造结束标签被转义，不能跳出数据块 | 通过 |
| 146 | ContextEngineeringTests | M08 提示词与引用 | CHAT-03 没有证据时提示词明确说明 | 通过 |
| 147 | ContextEngineeringTests | M08 提示词与引用 | CHAT-01 多轮追问时历史消息位于证据与问题之前 | 通过 |
| 148 | ContextEngineeringTests | M08 提示词与引用 | CHAT-01 提取单个与逗号分隔的引用标签并去重 | 通过 |
| 149 | ContextEngineeringTests | M08 提示词与引用 | CHAT-03 删除伪造的引用标签，保留合法部分 | 通过 |
| 150 | ContextEngineeringTests | M08 提示词与引用 | CHAT-03 全部合法时文本不变 | 通过 |
| 151 | ContextEngineeringTests | M08 提示词与引用 | CHAT-01 证据类别中文名用于界面展示 | 通过 |
| 152 | ContextRoutingTests | M07 边界情况 | CTX-02 已授权但没有阅读状态（如已删除）的书被拒绝 | 通过 |
| 153 | ContextRoutingTests | M07 边界情况 | 5.2 用户切换全书范围后，策略允许访问未读章节 | 通过 |
| 154 | ContextRoutingTests | M07 边界情况 | CTX-01 needs_retrieval=false 被解析并保留 | 通过 |
| 155 | ContextRoutingTests | M07 边界情况 | CTX-04 英文章节关键词识别为章节理解 | 通过 |
| 156 | ContextRoutingTests | M07 语义计划解析 | CTX-01 解析合法计划 JSON | 通过 |
| 157 | ContextRoutingTests | M07 语义计划解析 | CTX-01 容忍 ```json 围栏与前后说明文字 | 通过 |
| 158 | ContextRoutingTests | M07 语义计划解析 | CTX-01 未知意图不能执行 | 通过 |
| 159 | ContextRoutingTests | M07 语义计划解析 | CTX-01 未知数据来源不能执行 | 通过 |
| 160 | ContextRoutingTests | M07 语义计划解析 | CTX-01 未知范围值不能执行 | 通过 |
| 161 | ContextRoutingTests | M07 语义计划解析 | CTX-01 没有 JSON 的输出被拒绝 | 通过 |
| 162 | ContextRoutingTests | M07 语义计划解析 | CTX-01 缺少必填字段视为畸形 | 通过 |
| 163 | ContextRoutingTests | M07 语义计划解析 | CTX-01 字段类型错误视为畸形 | 通过 |
| 164 | ContextRoutingTests | M07 规则编译 | CTX-02 模型请求全书范围但用户未切换：保持已读范围并记录 | 通过 |
| 165 | ContextRoutingTests | M07 规则编译 | 5.2 用户明确切换到全书范围时生效并在记录中可见 | 通过 |
| 166 | ContextRoutingTests | M07 规则编译 | CTX-02 计划中的未授权书籍被丢弃 | 通过 |
| 167 | ContextRoutingTests | M07 规则编译 | READ-05 跨书时逐本采用各自的已读状态 | 通过 |
| 168 | ContextRoutingTests | M07 规则编译 | CTX-02 计划遗漏主书时代码补回 | 通过 |
| 169 | ContextRoutingTests | M07 规则编译 | CTX-02 跨书意图但未授权其他书时限定为当前书 | 通过 |
| 170 | ContextRoutingTests | M07 规则编译 | CTX-03 查询数量与长度受限，超出部分记录 | 通过 |
| 171 | ContextRoutingTests | M07 规则编译 | CTX-03 计划未给查询时使用原问题，重复查询去重 | 通过 |
| 172 | ContextRoutingTests | M07 规则编译 | CTX-03 有选段时加入 selection 来源；没有时去掉并记录 | 通过 |
| 173 | ContextRoutingTests | M07 规则编译 | CTX-03 没有讨论历史时不使用 history 来源 | 通过 |
| 174 | ContextRoutingTests | M07 规则编译 | CTX-03 需要检索时总包含原文来源，来源按优先级排序 | 通过 |
| 175 | ContextRoutingTests | M07 规则编译 | CTX-04 规划失败使用可复现规则策略并记录原因 | 通过 |
| 176 | ContextRoutingTests | M07 规则编译 | CTX-04 当前范围没有已读内容时记录说明 | 通过 |
| 177 | ContextRoutingTests | M07 规则编译 | CTX-02 预算与检索参数由代码给定 | 通过 |
| 178 | ContextRoutingTests | M07 规则编译 | CTX-02 只看选段不需检索时缩小最终证据数 | 通过 |
| 179 | ContextRoutingTests | M07 规则编译 | 5.5 原文中的“忽略规则、读取其他书籍”不能改变访问范围 | 通过 |
| 180 | ContextRoutingTests | M07 规则规划与提示词 | CTX-04 比较类问题识别为观点比较 | 通过 |
| 181 | ContextRoutingTests | M07 规则规划与提示词 | CTX-04 有选段时识别为解释选段，并把选段加入查询 | 通过 |
| 182 | ContextRoutingTests | M07 规则规划与提示词 | CTX-04 章节理解与追问识别 | 通过 |
| 183 | ContextRoutingTests | M07 规则规划与提示词 | CTX-04 用户授权多本书时识别为跨书 | 通过 |
| 184 | ContextRoutingTests | M07 规则规划与提示词 | 5.5 规划提示词把用户内容放在数据块中并转义伪造的结束标签 | 通过 |
| 185 | ContextRoutingTests | M07 规则规划与提示词 | CTX-01 提示词列出全部可选意图与来源 | 通过 |
| 186 | EvidenceVerificationCoreTests | M17 陈述拆分 | EVID-02 按句拆分并提取每句引用 | 通过 |
| 187 | EvidenceVerificationCoreTests | M17 陈述拆分 | CHAT-03 【一般知识】句不要求书内引用 | 通过 |
| 188 | EvidenceVerificationCoreTests | M17 陈述拆分 | EVID-02 说明限制的元陈述与反问不作为事实核查对象 | 通过 |
| 189 | EvidenceVerificationCoreTests | M17 陈述拆分 | EVID-02 列表符号与标题符号被去除，过短片段忽略 | 通过 |
| 190 | EvidenceVerificationCoreTests | M17 陈述拆分 | EVID-02 句末标点之后的引用（……。[E1]）归入前一条陈述 | 通过 |
| 191 | EvidenceVerificationCoreTests | M17 陈述拆分 | EVID-02 英文回答同样拆分 | 通过 |
| 192 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 未知标签判为无效 | 通过 |
| 193 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 超出阅读范围的原文证据判为无效 | 通过 |
| 194 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 书籍版本不符或书籍不在范围内判为无效 | 通过 |
| 195 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 缺少定位信息的原文证据判为无效 | 通过 |
| 196 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 外部校验发现来源已删除 | 通过 |
| 197 | EvidenceVerificationCoreTests | M17 结构检查 | EVID-01 范围内的有效原文与个人反思通过结构检查 | 通过 |
| 198 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-02 全部陈述获支持时总体为通过 | 通过 |
| 199 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-02 存在矛盾或证据不足时总体为需处理，并给出理由 | 通过 |
| 200 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-02 没有引用的事实陈述判为证据不足（不调用裁判） | 通过 |
| 201 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-01 引用了无效证据的陈述不能显示为已核查 | 通过 |
| 202 | EvidenceVerificationCoreTests | M17 语义复核 | 5.6 只引用个人反思却断言书中内容：判为证据不足 | 通过 |
| 203 | EvidenceVerificationCoreTests | M17 语义复核 | 5.6 个人看法引用反思可以获支持（不涉及书中内容） | 通过 |
| 204 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-04 复核超时/失败不能显示为通过 | 通过 |
| 205 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-04 未配置复核器时报告不可用 | 通过 |
| 206 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-04 裁判漏掉某条陈述时记为无法判断 | 通过 |
| 207 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-02 只有一般知识与说明时总体为“无事实陈述” | 通过 |
| 208 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-03 修正策略：剩余预算≥2 且存在问题时至多修正一轮 | 通过 |
| 209 | EvidenceVerificationCoreTests | M17 语义复核 | EVID-03 只有“无法判断”时不触发修正 | 通过 |
| 210 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：高覆盖判为支持 | 通过 |
| 211 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：数字不一致判为矛盾 | 通过 |
| 212 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 数字抽取统一阿拉伯数字、中文数字与英文数字词 | 通过 |
| 213 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：中文数字改写判为矛盾 | 通过 |
| 214 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：否定极性相反判为矛盾 | 通过 |
| 215 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：低覆盖判为证据不足 | 通过 |
| 216 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 启发式：证据未提及陈述中的数字判为证据不足 | 通过 |
| 217 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 模型裁判：解析 JSON 并忽略未请求的陈述 ID | 通过 |
| 218 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-04 模型裁判：解析失败与空响应抛错，并计入预算 | 通过 |
| 219 | EvidenceVerificationCoreTests | M17 裁判实现 | EVID-02 模型裁判提示词把陈述与证据放在数据块中 | 通过 |
| 220 | IntegrationTests | 集成：EPUB → 定位 → 检索 | RAG-01 导入→切块→FTS 召回→证据区间可回查阅读器原文 | 通过 |
| 221 | IntegrationTests | 集成：EPUB → 定位 → 检索 | READ-02 批注关闭并重开后仍存在，点击可回到原文（磁盘数据库） | 通过 |
| 222 | IntegrationTests | 集成：EPUB → 定位 → 检索 | READ-01 阅读位置在重启后恢复 | 通过 |
| 223 | IntegrationTests | 集成：EPUB → 定位 → 检索 | 统一规则1 书籍内容变化后旧定位不沿用旧偏移：能找到则重新定位，否则报告失效 | 通过 |
| 224 | IntegrationTests | 集成：EPUB → 定位 → 检索 | READ-04 页面停留→已读区间（SQLite）→讨论范围随之扩大 | 通过 |
| 225 | IntegrationTests | 集成：EPUB → 定位 → 检索 | 5.5 书中“忽略规则、读取其他书籍”的文字被当作数据，不改变访问范围 | 通过 |
| 226 | IntegrationTests | 集成：Provider 协议 → 讨论链路 | M12/RUN-01 经 HTTP 适配器（SSE、Embedding、Rerank）完成讨论，外部请求不超过 6 次 | 通过 |
| 227 | IntegrationTests | 集成：Provider 协议 → 讨论链路 | RAG-06 讨论中 Embedding 断网：降级词法检索，回答仍完成并记录降级 | 通过 |
| 228 | IntegrationTests | 集成：Provider 协议 → 讨论链路 | RAG-05 更换向量模型后旧向量不再参与检索 | 通过 |
| 229 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | 13.2-6 确认记忆→修订→查看来源与历史→备份恢复后关系一致 | 通过 |
| 230 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | 13.2-7 基于已读内容出题→作答→反馈与证据→下一次复习时间 | 通过 |
| 231 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | 13.2-8 断网/重启后的恢复：进行中回答标记失败，重试成功 | 通过 |
| 232 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | 13.2-5 未读范围不进入检索、记忆与历史；跨书时各自遵守边界 | 通过 |
| 233 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | LIB-04 删除阅读文件后：笔记保留，相关记忆不再作为有效书籍证据 | 通过 |
| 234 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | REF-03 语音转写→人工修改→提交为反思→作为反思证据参与讨论 | 通过 |
| 235 | IntegrationTests | 集成：记忆、学习、备份闭环（13.2 演示流程） | HABIT-01 会话记录（SQLite）→统计→成就，可从记录解释 | 通过 |
| 236 | IntegrationTests | 集成：评测与性能冒烟 | 9.2 检索评测运行器驱动真实混合检索（固定夹具） | 通过 |
| 237 | IntegrationTests | 集成：评测与性能冒烟 | 10.1 5,000 子块本地召回 P95 ≤ 500 ms（词法 + 向量，不含网络） | 通过 |
| 238 | LearningCoreTests | M18 边界情况 | LEARN-04 间隔规则可配置且文档化 | 通过 |
| 239 | LearningCoreTests | M18 边界情况 | LEARN-05 用户更换时区后按新时区计算下一次到期日 | 通过 |
| 240 | LearningCoreTests | M18 边界情况 | LEARN-01 一题多证据中任一越界则整题拒绝 | 通过 |
| 241 | LearningCoreTests | M18 边界情况 | LEARN-01 同一批次内重复的题目只保留一题 | 通过 |
| 242 | LearningCoreTests | M18 边界情况 | LEARN-01 展示视图的章节列表去重排序；去重键稳定 | 通过 |
| 243 | LearningCoreTests | M18 边界情况 | LEARN-05 已停用的题目不出现在到期列表 | 通过 |
| 244 | LearningCoreTests | M18 边界情况 | LEARN-02 没有证据的题目不作确定评分 | 通过 |
| 245 | LearningCoreTests | M18 边界情况 | LEARN-03 掌握记录按书籍与知识点分开 | 通过 |
| 246 | LearningCoreTests | M18 边界情况 | LEARN-03 自评与等级有中文展示名 | 通过 |
| 247 | LearningCoreTests | M18 边界情况 | LEARN-05 作答不存在的题目报错，不产生记录 | 通过 |
| 248 | LearningCoreTests | M18 复习调度 | LEARN-04 新题第 1 天到期 | 通过 |
| 249 | LearningCoreTests | M18 复习调度 | LEARN-04 表现良好按 1/3/7/14/30 前进并在 30 天封顶 | 通过 |
| 250 | LearningCoreTests | M18 复习调度 | LEARN-04 部分掌握保持间隔，遗忘回退一级且不低于第一级 | 通过 |
| 251 | LearningCoreTests | M18 复习调度 | LEARN-05 同一次作答重复提交不重复排期 | 通过 |
| 252 | LearningCoreTests | M18 复习调度 | LEARN-05 到期按用户时区的日历日计算（固定时钟） | 通过 |
| 253 | LearningCoreTests | M18 复习调度 | LEARN-05 到期列表包含逾期项，逾期最久的在前 | 通过 |
| 254 | LearningCoreTests | M18 复习调度 | LEARN-04 评分与自评决定前进、保持或回退 | 通过 |
| 255 | LearningCoreTests | M18 掌握记录 | LEARN-03 一次高分不算永久掌握，需要连续两次通过 | 通过 |
| 256 | LearningCoreTests | M18 掌握记录 | LEARN-03 人工修正优先，下一次作答后恢复按记录计算 | 通过 |
| 257 | LearningCoreTests | M18 掌握记录 | LEARN-03 只保留最近窗口内的作答事件 | 通过 |
| 258 | LearningCoreTests | M18 掌握记录 | LEARN-03 评分不确定时按自评计算错误 | 通过 |
| 259 | LearningCoreTests | M18 出题与校验 | LEARN-01 合法题目带证据与参考要点；越界证据、非原文证据与未知题型被拒绝 | 通过 |
| 260 | LearningCoreTests | M18 出题与校验 | LEARN-01 作答前的展示视图不包含参考答案与评分依据 | 通过 |
| 261 | LearningCoreTests | M18 出题与校验 | LEARN-01 题干泄露参考答案的题目被拒绝 | 通过 |
| 262 | LearningCoreTests | M18 出题与校验 | LEARN-01 与已有题目重复的题被拒绝 | 通过 |
| 263 | LearningCoreTests | M18 出题与校验 | LEARN-01 缺少参考要点或题干过短被拒绝；畸形输出抛错 | 通过 |
| 264 | LearningCoreTests | M18 出题与校验 | LEARN-01 出题提示词只包含书内证据并列出已有题目 | 通过 |
| 265 | LearningCoreTests | M18 作答与反馈 | LEARN-01 生成的题目与初始排期一起保存 | 通过 |
| 266 | LearningCoreTests | M18 作答与反馈 | 10.2 输出被截断时不保存不完整的题目 | 通过 |
| 267 | LearningCoreTests | M18 作答与反馈 | LEARN-01 没有已读原文证据时不出题 | 通过 |
| 268 | LearningCoreTests | M18 作答与反馈 | LEARN-02 保存原始答案；反馈包含正确点、遗漏点与证据 | 通过 |
| 269 | LearningCoreTests | M18 作答与反馈 | LEARN-05 重复提交同一答案不产生重复作答与复习记录 | 通过 |
| 270 | LearningCoreTests | M18 作答与反馈 | LEARN-02 依据不足时不作确定评分 | 通过 |
| 271 | LearningCoreTests | M18 作答与反馈 | LEARN-02 空答案不调用评分器，记为 0 分且列出全部遗漏点 | 通过 |
| 272 | LearningCoreTests | M18 作答与反馈 | DATA-01 评分失败时不写入作答、掌握或排期（事务完整） | 通过 |
| 273 | LearningCoreTests | M18 作答与反馈 | LEARN-03 人工修正掌握等级 | 通过 |
| 274 | LearningCoreTests | M18 作答与反馈 | LEARN-05 时间推进后题目出现在到期列表，完成后移出 | 通过 |
| 275 | LearningCoreTests | M18 作答与反馈 | LEARN-02 模型评分解析：分数裁剪到 0–1，缺分或 uncertain 视为不确定 | 通过 |
| 276 | LearningCoreTests | M18 作答与反馈 | LEARN-02 模型评分提示词包含参考要点、证据与答案 | 通过 |
| 277 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 解析中文 EPUB 的标题、作者与语言 | 通过 |
| 278 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 章节按 spine 顺序提取，标题取自 h1 | 通过 |
| 279 | LibraryCoreTests | M01 EPUB 解析 | RAG-01 正文提取为规范段落，不含标签且可回查原文 | 通过 |
| 280 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 EPUB3 nav 目录包含嵌套锚点并解析出偏移 | 通过 |
| 281 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 没有 nav 时使用 NCX 目录 | 通过 |
| 282 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 缺少目录时按章节生成默认目录并给出警告 | 通过 |
| 283 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 提取封面图片 | 通过 |
| 284 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 缺少标题时使用文件名作为默认值 | 通过 |
| 285 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 缺少作者时展示“佚名” | 通过 |
| 286 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 空文件明确提示 | 通过 |
| 287 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 非 ZIP 文件判定为损坏 | 通过 |
| 288 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 缺少 container.xml 判定为损坏 | 通过 |
| 289 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 缺少 OPF 包文档 | 通过 |
| 290 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 内容加密的 EPUB 被识别为受保护 | 通过 |
| 291 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 仅字体混淆不视为 DRM | 通过 |
| 292 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 含 rights.xml 的 EPUB 被识别为受保护 | 通过 |
| 293 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 不支持的扩展名明确提示 | 通过 |
| 294 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 HTML 命名实体（&nbsp; &mdash;）不导致解析失败 | 通过 |
| 295 | LibraryCoreTests | M01 EPUB 解析 | LIB-01 非良构章节走退化提取路径仍有正文 | 通过 |
| 296 | LibraryCoreTests | M01 EPUB 解析 | LIB-02 spine 为空视为没有可阅读内容 | 通过 |
| 297 | LibraryCoreTests | M01 正文提取 | RAG-01 跳过 head/script/style，块级元素分段 | 通过 |
| 298 | LibraryCoreTests | M01 正文提取 | READ-03 锚点偏移指向锚点后第一个字符 | 通过 |
| 299 | LibraryCoreTests | M01 正文提取 | RAG-01 退化路径解码数字实体 | 通过 |
| 300 | LibraryCoreTests | M01 书库服务 | LIB-01 导入有效 EPUB 后书籍、章节、目录与文件均已保存 | 通过 |
| 301 | LibraryCoreTests | M01 书库服务 | LIB-02 相同文件再次导入识别为重复，不产生第二本书 | 通过 |
| 302 | LibraryCoreTests | M01 书库服务 | LIB-02 损坏文件导入失败且不残留书籍或文件 | 通过 |
| 303 | LibraryCoreTests | M01 书库服务 | LIB-02 存储失败时清理已写入部分，不留下半成品 | 通过 |
| 304 | LibraryCoreTests | M01 书库服务 | LIB-02 空文件导入给出明确错误 | 通过 |
| 305 | LibraryCoreTests | M01 书库服务 | LIB-04 删除阅读文件保留笔记：书籍标记来源不可访问并通知观察者 | 通过 |
| 306 | LibraryCoreTests | M01 书库服务 | LIB-04 彻底删除移除书籍并通知观察者 | 通过 |
| 307 | LibraryCoreTests | M01 书库服务 | LIB-04 仅删除文件后重新导入同一 EPUB 恢复来源并沿用原 ID | 通过 |
| 308 | LibraryCoreTests | M01 书库服务 | LIB-03 并发导入同一文件只产生一本书 | 通过 |
| 309 | LibraryCoreTests | M01 书库服务 | LIB-03 书籍被删除后，迟到的索引状态更新不会复活记录 | 通过 |
| 310 | LibraryCoreTests | M01 书库服务 | LIB-03 进度更新被限制在 0...1 | 通过 |
| 311 | LibraryCoreTests | M01 书库服务 | LIB-03 打开书籍更新最近打开时间并影响默认排序 | 通过 |
| 312 | LibraryCoreTests | M01 书库查询 | LIB-03 按标题或作者搜索（不区分大小写） | 通过 |
| 313 | LibraryCoreTests | M01 书库查询 | LIB-03 按进度与导入时间排序 | 通过 |
| 314 | LibraryCoreTests | M01 基础类型 | READ-03 TextSpan 交集、并集与裁剪 | 通过 |
| 315 | LibraryCoreTests | M01 基础类型 | READ-03 UTF-16 截取正确处理中文与表情 | 通过 |
| 316 | LibraryCoreTests | M01 基础类型 | LEARN-05 DayKey 按时区计算日历日并支持跨月加减 | 通过 |
| 317 | ModelProvidersTests | M12 错误映射与传输 | 10.3 413/422 与超长提示映射为 contextTooLong；普通 400 保留脱敏信息 | 通过 |
| 318 | ModelProvidersTests | M12 错误映射与传输 | 10.3 非 JSON 错误体与未知状态码 | 通过 |
| 319 | ModelProvidersTests | M12 错误映射与传输 | 10.3 系统网络错误映射：断网、超时、取消 | 通过 |
| 320 | ModelProvidersTests | M12 错误映射与传输 | M12 内容过滤结束原因与缺失用量 | 通过 |
| 321 | ModelProvidersTests | M12 错误映射与传输 | M12 预置地址区分北京与新加坡地域，默认模型为 text-embedding-v4 / qwen3-rerank | 通过 |
| 322 | ModelProvidersTests | M12 错误映射与传输 | DATA-03 请求超时取自端点配置，鉴权头不出现在请求描述日志 | 通过 |
| 323 | ModelProvidersTests | M12 对话适配器 | M12 非流式响应解析内容、结束原因与服务端用量 | 通过 |
| 324 | ModelProvidersTests | M12 对话适配器 | M12 请求体包含模型、消息、输出上限；JSON 模式设置 response_format；携带 Bearer 鉴权 | 通过 |
| 325 | ModelProvidersTests | M12 对话适配器 | 10.3 长度截断的结束原因被保留 | 通过 |
| 326 | ModelProvidersTests | M12 对话适配器 | 10.3 401/403/429/5xx 映射为统一错误；429 读取 Retry-After | 通过 |
| 327 | ModelProvidersTests | M12 对话适配器 | 10.3 模型超长错误被识别为 contextTooLong | 通过 |
| 328 | ModelProvidersTests | M12 对话适配器 | 10.3 DashScope 原生错误码 InvalidApiKey 映射为 unauthorized | 通过 |
| 329 | ModelProvidersTests | M12 对话适配器 | 10.3 空响应与无效 JSON | 通过 |
| 330 | ModelProvidersTests | M12 对话适配器 | DATA-03 未配置密钥时不发请求，返回 notConfigured | 通过 |
| 331 | ModelProvidersTests | M12 对话适配器 | CHAT-02 流式帧逐段输出，结束帧携带用量 | 通过 |
| 332 | ModelProvidersTests | M12 对话适配器 | 10.3 流式截断：没有结束原因即报错，不当作完整结果 | 通过 |
| 333 | ModelProvidersTests | M12 对话适配器 | 10.3 流中出现错误帧时报错 | 通过 |
| 334 | ModelProvidersTests | M12 对话适配器 | 10.3 流式请求返回非 2xx 时读取错误体 | 通过 |
| 335 | ModelProvidersTests | M12 对话适配器 | 10.3 流式无效帧与断网 | 通过 |
| 336 | ModelProvidersTests | M12 对话适配器 | M12 SSE 行解析：注释、数据、结束 | 通过 |
| 337 | ModelProvidersTests | M12 向量与重排适配器 | M12 向量按 index 重新排序（服务端乱序返回） | 通过 |
| 338 | ModelProvidersTests | M12 向量与重排适配器 | RAG-05 返回维度与配置不符时报错 | 通过 |
| 339 | ModelProvidersTests | M12 向量与重排适配器 | M12 向量数量与输入不一致、index 重复时报错 | 通过 |
| 340 | ModelProvidersTests | M12 向量与重排适配器 | M12 按批次上限拆分请求（text-embedding-v4 默认 10 条/批） | 通过 |
| 341 | ModelProvidersTests | M12 向量与重排适配器 | M12 空白输入以占位符发送，过长输入被截断 | 通过 |
| 342 | ModelProvidersTests | M12 向量与重排适配器 | M12 原生重排协议：请求形状与 output.results 解析 | 通过 |
| 343 | ModelProvidersTests | M12 向量与重排适配器 | M12 兼容重排协议：/reranks 与顶层 results | 通过 |
| 344 | ModelProvidersTests | M12 向量与重排适配器 | RAG-03 重排索引越界或重复时报 invalidRerankIndex | 通过 |
| 345 | ModelProvidersTests | M12 向量与重排适配器 | M12 文档数超过上限时截断，空文档列表不发请求 | 通过 |
| 346 | ModelProvidersTests | M12 向量与重排适配器 | DATA-03 连接检测分别报告三类接口，失败信息脱敏 | 通过 |
| 347 | PersistenceTests | M13 迁移 | DATA-01 新库应用全部迁移 | 通过 |
| 348 | PersistenceTests | M13 迁移 | DATA-01 旧库样本（v1）迁移到最新并回填新列 | 通过 |
| 349 | PersistenceTests | M13 迁移 | DATA-01 重复执行迁移是幂等的 | 通过 |
| 350 | PersistenceTests | M13 迁移 | DATA-01 磁盘数据库可重开并保留数据（模拟重启） | 通过 |
| 351 | PersistenceTests | M13 书籍仓储与删除 | DATA-01 写入失败时整体回滚（同指纹第二本书不留下章节） | 通过 |
| 352 | PersistenceTests | M13 书籍仓储与删除 | LIB-04 仅删除文件：清除正文与索引，保留批注与反思并标记来源不可访问 | 通过 |
| 353 | PersistenceTests | M13 书籍仓储与删除 | LIB-04 彻底删除：清理正文、索引、批注、会话、反思、讨论与练习，不影响其他书 | 通过 |
| 354 | PersistenceTests | M13 书籍仓储与删除 | LIB-04 重新挂接正文恢复书籍与反思可访问状态 | 通过 |
| 355 | PersistenceTests | M13 讨论与反思仓储 | REF-02 提交键唯一：同一键不能产生第二条反思 | 通过 |
| 356 | PersistenceTests | M13 讨论与反思仓储 | DATA-01 更新会话（如切换范围）不会级联删除其消息 | 通过 |
| 357 | PersistenceTests | M13 讨论与反思仓储 | DATA-01 备份恢复覆盖已有书籍时不丢失其章节 | 通过 |
| 358 | PersistenceTests | M13 讨论与反思仓储 | 10.3 启动时把进行中的回答标记为失败并保留内容 | 通过 |
| 359 | PersistenceTests | M13 讨论与反思仓储 | RUN-02 按请求键取最近一次回答，消息按时间排序 | 通过 |
| 360 | PersistenceTests | M13 检索存储 | RAG-02 FTS5 中文词语召回，结果映射到子块 | 通过 |
| 361 | PersistenceTests | M13 检索存储 | READ-05 FTS5 召回在范围过滤后凑满结果，不返回未读子块 | 通过 |
| 362 | PersistenceTests | M13 检索存储 | RAG-05 向量写入、检索与按模型失效 | 通过 |
| 363 | PersistenceTests | M13 检索存储 | RAG-02 含异常值的向量批次整批拒绝写入 | 通过 |
| 364 | PersistenceTests | M13 检索存储 | RAG-06 按内容指纹查已有向量 | 通过 |
| 365 | PersistenceTests | M13 事务与运行时存储 | MEM-02 并发确认：提议已非 pending 时原子写入被拒绝 | 通过 |
| 366 | PersistenceTests | M13 事务与运行时存储 | LEARN-05 同一作答键第二次写入整体回滚 | 通过 |
| 367 | PersistenceTests | M13 事务与运行时存储 | HABIT-01 成就重复插入被忽略；设置与追踪可读写 | 通过 |
| 368 | PersistenceTests | M13 备份与导出 | DATA-02 导出后恢复到新库：关键记录与引用关系一致 | 通过 |
| 369 | PersistenceTests | M13 备份与导出 | DATA-02 包含 EPUB 的备份恢复后书籍可直接阅读 | 通过 |
| 370 | PersistenceTests | M13 备份与导出 | DATA-03 结构化备份不包含密钥类设置 | 通过 |
| 371 | PersistenceTests | M13 备份与导出 | DATA-02 重复导入同一备份不产生重复记录 | 通过 |
| 372 | PersistenceTests | M13 备份与导出 | DATA-02 篡改内容导致校验和不符，恢复被拒绝且不修改数据 | 通过 |
| 373 | PersistenceTests | M13 备份与导出 | DATA-02 损坏文件、非备份文件与不支持的版本给出明确错误 | 通过 |
| 374 | PersistenceTests | M13 备份与导出 | DATA-02 旧版本（v1）备份迁移后可恢复 | 通过 |
| 375 | PersistenceTests | M13 备份与导出 | DATA-02 Markdown 导出包含书籍、批注、讨论与记忆，便于阅读 | 通过 |
| 376 | PersistenceTests | M13 补充 | READ-01 书签保存、按书列出与删除 | 通过 |
| 377 | PersistenceTests | M13 补充 | MEM-04 另一个提议使用相同幂等键时写入被拒绝，不覆盖原提议 | 通过 |
| 378 | PersistenceTests | M13 补充 | LIB-04 Markdown 导出标注来源不可访问的书与失效证据 | 通过 |
| 379 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-01/02 完整链路：检索→流式草稿→核查→已核查，并保存证据快照 | 通过 |
| 380 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-02 引用写在句末标点之后（……。[E1]）也能完成核查并通过结构校验 | 通过 |
| 381 | ReaderAgentTests | M11 阅读讨论链路 | READ-05 未读章节不进入检索与上下文：证据不足且不调用模型 | 通过 |
| 382 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-03 范围内没有任何依据时说明限制并给出补充方式，不伪造引用 | 通过 |
| 383 | ReaderAgentTests | M11 阅读讨论链路 | 5.2 用户切换全书范围后可检索未读章节，且范围在执行记录中可见 | 通过 |
| 384 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-03 回答中伪造的引用标签被移除并记录 | 通过 |
| 385 | ReaderAgentTests | M11 阅读讨论链路 | EVID-02 与证据矛盾的陈述被识别：状态为需处理 | 通过 |
| 386 | ReaderAgentTests | M11 阅读讨论链路 | EVID-04 复核模型失败时显示“未能核查”，不是“已核查” | 通过 |
| 387 | ReaderAgentTests | M11 阅读讨论链路 | EVID-03 证据不足/矛盾时在预算内修正一轮，修正后通过 | 通过 |
| 388 | ReaderAgentTests | M11 阅读讨论链路 | 10.2 回答达到长度上限：标记不完整，不显示为完整成功 | 通过 |
| 389 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-01 选段作为当前阅读现场进入证据，并记为已读 | 通过 |
| 390 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-04 断网失败：保留用户问题与草稿，可用同一请求重试并成功 | 通过 |
| 391 | ReaderAgentTests | M11 阅读讨论链路 | RUN-02 同一请求重复触发不产生重复回答，也不重复调用模型 | 通过 |
| 392 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-04/10.1 取消立即生效并保留草稿；迟到的生成结果不会改变已取消状态 | 通过 |
| 393 | ReaderAgentTests | M11 阅读讨论链路 | RUN-01 规划、生成等共享 6 次调用预算；预算耗尽以明确状态结束 | 通过 |
| 394 | ReaderAgentTests | M11 阅读讨论链路 | CTX-04 规划输出畸形时使用规则策略并在记录中说明 | 通过 |
| 395 | ReaderAgentTests | M11 阅读讨论链路 | CTX-02 规划要求放开到全书范围被拒绝，证据仍限于已读 | 通过 |
| 396 | ReaderAgentTests | M11 阅读讨论链路 | CHAT-04 未配置对话模型时以明确失败结束并保留问题 | 通过 |
| 397 | ReaderAgentTests | M11 阅读讨论链路 | RUN-03 同一 traceID 关联规划、检索、上下文、核查与存储 | 通过 |
| 398 | ReaderAgentTests | M11 多来源与多轮 | CHAT-01 追问时历史问答进入生成请求 | 通过 |
| 399 | ReaderAgentTests | M11 多来源与多轮 | READ-05 全书范围下的历史回答不会进入之后的已读范围讨论 | 通过 |
| 400 | ReaderAgentTests | M11 多来源与多轮 | CHAT-01 相关的批注与反思作为单独来源进入证据 | 通过 |
| 401 | ReaderAgentTests | M11 多来源与多轮 | MEM-05 越界来源的记忆不进入讨论上下文 | 通过 |
| 402 | ReaderAgentTests | M11 多来源与多轮 | READ-05 跨书讨论逐本遵守各自的已读边界 | 通过 |
| 403 | ReaderAgentTests | M11 异步记忆提议 | MEM-02 讨论完成后生成待确认提议，引用映射到回答中的有效证据 | 通过 |
| 404 | ReaderAgentTests | M11 异步记忆提议 | MEM-02 提议失败可重试，不影响已保存讨论 | 通过 |
| 405 | ReaderAgentTests | M11 异步记忆提议 | MEM-02 失败或取消的回答不生成提议 | 通过 |
| 406 | ReaderAgentTests | M11 补充 | READ-05 未读章节上的批注不进入讨论证据 | 通过 |
| 407 | ReaderAgentTests | M11 补充 | READ-05 阅读现场位于未读区间的反思不进入讨论证据 | 通过 |
| 408 | ReaderCoreTests | M02 稳定定位 | READ-03 定位包含书籍版本、章节资源、区间与前后文锚点 | 通过 |
| 409 | ReaderCoreTests | M02 稳定定位 | READ-03 同版本且偏移文本一致时精确解析 | 通过 |
| 410 | ReaderCoreTests | M02 稳定定位 | READ-03 重复出现的文本依靠前后文选中正确位置 | 通过 |
| 411 | ReaderCoreTests | M02 稳定定位 | READ-03 版本变化后不沿用旧偏移，找不到原文时报告失效 | 通过 |
| 412 | ReaderCoreTests | M02 稳定定位 | READ-03 章节顺序变化时跨章重新定位 | 通过 |
| 413 | ReaderCoreTests | M02 稳定定位 | READ-03 同版本但偏移被篡改时用锚点纠正 | 通过 |
| 414 | ReaderCoreTests | M02 稳定定位 | READ-03 越界区间在创建定位时被裁剪 | 通过 |
| 415 | ReaderCoreTests | M02 分页与导航 | READ-01 分页区间首尾相接且覆盖整章 | 通过 |
| 416 | ReaderCoreTests | M02 分页与导航 | READ-03 字号变化后同一偏移仍能定位到包含它的页 | 通过 |
| 417 | ReaderCoreTests | M02 分页与导航 | READ-01 翻页在章末跨入下一章，首页不能再向前 | 通过 |
| 418 | ReaderCoreTests | M02 分页与导航 | READ-01 目录跳转到锚点所在页 | 通过 |
| 419 | ReaderCoreTests | M02 分页与导航 | READ-01 以保存的定位重新打开时恢复到对应页 | 通过 |
| 420 | ReaderCoreTests | M02 分页与导航 | READ-01 字号有上下限，主题可切换 | 通过 |
| 421 | ReaderCoreTests | M02 分页与导航 | READ-01 视口与字号推导每页行数与字数 | 通过 |
| 422 | ReaderCoreTests | M02 分页与导航 | READ-01 空章节也有一页，不崩溃 | 通过 |
| 423 | ReaderCoreTests | M02 批注与书签 | READ-02 新增高亮立即保存，可在重新读取后找到 | 通过 |
| 424 | ReaderCoreTests | M02 批注与书签 | READ-02 带笔记的高亮记为笔记；修改与清空笔记切换类型 | 通过 |
| 425 | ReaderCoreTests | M02 批注与书签 | READ-02 删除批注后列表同步 | 通过 |
| 426 | ReaderCoreTests | M02 批注与书签 | READ-02 空选择与越界选择被拒绝 | 通过 |
| 427 | ReaderCoreTests | M02 批注与书签 | READ-02 批注列表按章节与位置排序 | 通过 |
| 428 | ReaderCoreTests | M02 批注与书签 | READ-02 点击批注通过定位回到原文 | 通过 |
| 429 | ReaderCoreTests | M02 批注与书签 | READ-01 书签在同一页切换：再次点击移除 | 通过 |
| 430 | ReaderCoreTests | M02 批注与书签 | READ-01 阅读位置保存后重新打开可恢复 | 通过 |
| 431 | ReaderCoreTests | M02 批注与书签 | READ-02 修改颜色立即保存 | 通过 |
| 432 | ReaderCoreTests | M02 边界情况 | READ-03 章首/章尾的锚点前后文为空，不越界 | 通过 |
| 433 | ReaderCoreTests | M02 边界情况 | READ-03 锚点文本为空的定位无法重新定位，报告失效 | 通过 |
| 434 | ReaderCoreTests | M02 边界情况 | READ-01 超出章节末尾的偏移落在最后一页 | 通过 |
| 435 | ReadingSessionCoreTests | M03 已读区间 | READ-04 相交与相接的区间合并 | 通过 |
| 436 | ReadingSessionCoreTests | M03 已读区间 | READ-04 不相交区间保持有序且分离 | 通过 |
| 437 | ReadingSessionCoreTests | M03 已读区间 | READ-04 只有被完全覆盖的区间才算已读 | 通过 |
| 438 | ReadingSessionCoreTests | M03 已读区间 | READ-04 直接跳到后章不会自动放开中间未读章节 | 通过 |
| 439 | ReadingSessionCoreTests | M03 已读区间 | READ-04 回看已读章节不丢失历史区间 | 通过 |
| 440 | ReadingSessionCoreTests | M03 已读区间 | READ-05 版本不同的访问一律拒绝 | 通过 |
| 441 | ReadingSessionCoreTests | M03 已读区间 | READ-05 全书范围需显式选择，且仍绑定版本 | 通过 |
| 442 | ReadingSessionCoreTests | M03 已读区间 | READ-04 展示进度只统计已读字符，不决定检索范围 | 通过 |
| 443 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 页面停留达到阈值才记为已读 | 通过 |
| 444 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 前台时长累计，空闲超过阈值只计到阈值 | 通过 |
| 445 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 转入后台暂停计时并提交当前页，回到前台继续 | 通过 |
| 446 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 显式标记已读立即写入 | 通过 |
| 447 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 结束会话后保存结束时间，后续事件被忽略 | 通过 |
| 448 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 中断恢复：进程被杀后遗留会话以最后活动时间结束 | 通过 |
| 449 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 打开另一本书会结束上一本书的会话 | 通过 |
| 450 | ReadingSessionCoreTests | M03 阅读会话 | READ-04 重复提交相同区间不会产生重复区间记录 | 通过 |
| 451 | ReflectionCoreTests | M04 边界情况 | REF-02 已保存反思按时间倒序列出，草稿不在其中，可按书筛选 | 通过 |
| 452 | ReflectionCoreTests | M04 边界情况 | CHAT-02 每种消息状态都有区分的展示名 | 通过 |
| 453 | ReflectionCoreTests | M04 边界情况 | CHAT-04 不存在的消息无法迁移状态 | 通过 |
| 454 | ReflectionCoreTests | M04 边界情况 | CHAT-01 按书籍列出讨论，删除讨论同时删除消息 | 通过 |
| 455 | ReflectionCoreTests | M04 边界情况 | REF-02 编辑空白内容被拒绝；不存在的反思报错 | 通过 |
| 456 | ReflectionCoreTests | M04 反思 | REF-01 反思关联书籍、位置、选段、会话和时间 | 通过 |
| 457 | ReflectionCoreTests | M04 反思 | REF-01 之后更换阅读位置不覆盖当时的证据快照 | 通过 |
| 458 | ReflectionCoreTests | M04 反思 | REF-02 草稿自动保存，重启后可恢复 | 通过 |
| 459 | ReflectionCoreTests | M04 反思 | REF-02 连续点击保存只产生一条记录 | 通过 |
| 460 | ReflectionCoreTests | M04 反思 | REF-02 空白内容不能提交 | 通过 |
| 461 | ReflectionCoreTests | M04 反思 | REF-02 已保存反思不能再当作草稿修改 | 通过 |
| 462 | ReflectionCoreTests | M04 反思 | REF-02 修改已保存反思保留前后内容 | 通过 |
| 463 | ReflectionCoreTests | M04 反思 | REF-03 语音转写原文与人工修改分别保存 | 通过 |
| 464 | ReflectionCoreTests | M04 反思 | REF-02 丢弃草稿后不再出现在恢复列表 | 通过 |
| 465 | ReflectionCoreTests | M04 反思 | REF-02 超长文本被截断到上限 | 通过 |
| 466 | ReflectionCoreTests | M04 讨论记录 | CHAT-02 生成完成不等于核查通过：只有 verified 视为已核查 | 通过 |
| 467 | ReflectionCoreTests | M04 讨论记录 | CHAT-04 终态不能被迟到的响应改写 | 通过 |
| 468 | ReflectionCoreTests | M04 讨论记录 | CHAT-02 状态按 准备→草稿→核查→结果 推进 | 通过 |
| 469 | ReflectionCoreTests | M04 讨论记录 | CHAT-04 用户问题先持久化，空问题被拒绝 | 通过 |
| 470 | ReflectionCoreTests | M04 讨论记录 | 5.2 切换到全书范围必须显式记录，并体现在新消息上 | 通过 |
| 471 | ReflectionCoreTests | M04 讨论记录 | CHAT-01 以选段开启的讨论标题与上下文来自选段 | 通过 |
| 472 | ReflectionCoreTests | M04 讨论记录 | READ-05 跨书讨论只包含用户明确添加的书 | 通过 |
| 473 | ReflectionCoreTests | M04 讨论记录 | CHAT-04 同状态重复迁移是幂等的 | 通过 |
| 474 | RetrievalCoreTests | M06 混合检索 | RAG-02 中文问题经词法召回命中对应章节 | 通过 |
| 475 | RetrievalCoreTests | M06 混合检索 | READ-05 未读章节不进入召回（即使最相关） | 通过 |
| 476 | RetrievalCoreTests | M06 混合检索 | RAG-04 父块扩展跨越已读边界时被裁剪，不整体带入 | 通过 |
| 477 | RetrievalCoreTests | M06 混合检索 | RAG-03 词法与向量双路召回后 RRF 融合 | 通过 |
| 478 | RetrievalCoreTests | M06 混合检索 | RAG-06 Embedding 不可用时降级为词法检索并记录原因 | 通过 |
| 479 | RetrievalCoreTests | M06 混合检索 | RAG-06 Rerank 失败时保留融合排序 | 通过 |
| 480 | RetrievalCoreTests | M06 混合检索 | RAG-03 重排结果改变最终顺序并映射回正确子块 | 通过 |
| 481 | RetrievalCoreTests | M06 混合检索 | RAG-03 重排返回异常索引时只采用有效部分并记录 | 通过 |
| 482 | RetrievalCoreTests | M06 混合检索 | RAG-05 向量模型与索引不兼容时不混查，按书降级 | 通过 |
| 483 | RetrievalCoreTests | M06 混合检索 | READ-05 跨书检索逐本使用各自的已读区间 | 通过 |
| 484 | RetrievalCoreTests | M06 混合检索 | RAG-04 扩展后区间不超过长度上限且包含命中子块 | 通过 |
| 485 | RetrievalCoreTests | M06 混合检索 | RAG-04 同一父块的重叠扩展被去重合并 | 通过 |
| 486 | RetrievalCoreTests | M06 混合检索 | READ-05 空查询或空范围直接返回空结果 | 通过 |
| 487 | RetrievalCoreTests | M06 混合检索 | RAG-02 同义表达依靠向量路召回（词法无重叠） | 通过 |
| 488 | RetrievalCoreTests | M06 混合检索 | RAG-06 最终结果数不超过 finalLimit | 通过 |
| 489 | RetrievalCoreTests | M06 BM25 | RAG-02 中文词语召回相关文档排第一 | 通过 |
| 490 | RetrievalCoreTests | M06 BM25 | RAG-02 英文短语召回 | 通过 |
| 491 | RetrievalCoreTests | M06 BM25 | READ-05 过滤函数在召回阶段排除不可见文档 | 通过 |
| 492 | RetrievalCoreTests | M06 BM25 | RAG-05 删除后不再召回；重复添加同 ID 幂等 | 通过 |
| 493 | RetrievalCoreTests | M06 BM25 | RAG-02 空文本不进入索引，空查询无结果 | 通过 |
| 494 | RetrievalCoreTests | M06 BM25 | RAG-03 稀有词的 IDF 权重高于常见词 | 通过 |
| 495 | RetrievalCoreTests | M06 BM25 | RAG-03 同分按 ID 稳定排序，limit 生效 | 通过 |
| 496 | RetrievalCoreTests | M06 向量索引 | RAG-02 余弦相似度排序 | 通过 |
| 497 | RetrievalCoreTests | M06 向量索引 | RAG-05 维度不符的向量被拒绝 | 通过 |
| 498 | RetrievalCoreTests | M06 向量索引 | RAG-02 NaN/无穷与零向量不进入有效索引 | 通过 |
| 499 | RetrievalCoreTests | M06 向量索引 | READ-05 向量检索支持范围过滤 | 通过 |
| 500 | RetrievalCoreTests | M06 向量索引 | RAG-05 同 ID 重新写入替换旧向量，删除后不召回 | 通过 |
| 501 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 RRF 只用名次融合：两路都靠前的结果排第一 | 通过 |
| 502 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 分数尺度差异不影响融合（只看名次） | 通过 |
| 503 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 单路内重复 ID 只计一次，limit 生效 | 通过 |
| 504 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 重排结果正确映射回候选 ID（乱序返回） | 通过 |
| 505 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 越界、重复与非有限分数的重排索引被丢弃并记录 | 通过 |
| 506 | RetrievalCoreTests | M06 融合与重排映射 | RAG-03 重排缺失的候选保持融合顺序排在后面 | 通过 |
| 507 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 清单检查：缺失/内容变化/模型变化/兼容 | 通过 |
| 508 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 首次建立词法索引并记录切块策略与内容版本 | 通过 |
| 509 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 书籍内容版本变化触发重新切块且旧向量失效 | 通过 |
| 510 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 向量模型或维度变化只重建向量 | 通过 |
| 511 | RetrievalCoreTests | M06 索引生命周期 | 7.3 默认只对已读范围的子块生成云向量 | 通过 |
| 512 | RetrievalCoreTests | M06 索引生命周期 | RAG-06 中途失败后暂停并保留进度；续作不重复插入、不重复计数 | 通过 |
| 513 | RetrievalCoreTests | M06 索引生命周期 | RAG-06 相同内容按指纹复用向量，不发远端请求 | 通过 |
| 514 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 维度异常的批次整批不写入 | 通过 |
| 515 | RetrievalCoreTests | M06 索引生命周期 | 10.2 后台索引超出批次预算时暂停，可继续 | 通过 |
| 516 | RetrievalCoreTests | M06 索引生命周期 | RAG-06 任务被取消时停止并标记取消 | 通过 |
| 517 | RetrievalCoreTests | M06 索引生命周期 | RAG-05 删除书籍的索引后检索不到其内容 | 通过 |
| 518 | RetrievalCoreTests | M06 分词 | RAG-02 中文按单字与二元组切分，不依赖英文分词假设 | 通过 |
| 519 | RetrievalCoreTests | M06 分词 | RAG-02 中文虚词单字被过滤，二元组保留 | 通过 |
| 520 | RetrievalCoreTests | M06 分词 | RAG-02 英文小写化、去停用词并做轻量词干化 | 通过 |
| 521 | RetrievalCoreTests | M06 分词 | RAG-02 中英混排与专有名词数字都能切出 | 通过 |
| 522 | RetrievalCoreTests | M06 分词 | RAG-02 所有格与缩写处理 | 通过 |
| 523 | RetrievalCoreTests | M06 分词 | RAG-02 FTS 查询为每个词项加引号并以 OR 连接 | 通过 |
| 524 | RetrievalCoreTests | M06 分词 | RAG-02 FTS 文档形式与分词一致 | 通过 |
| 525 | RetrievalCoreTests | M06 句子切分 | RAG-01 中文句末标点切分并保留绝对偏移 | 通过 |
| 526 | RetrievalCoreTests | M06 句子切分 | RAG-01 英文句点后跟空白才断句，小数不断开 | 通过 |
| 527 | RetrievalCoreTests | M06 句子切分 | RAG-01 句末标点后的右引号归入本句 | 通过 |
| 528 | RetrievalCoreTests | M06 句子切分 | RAG-01 区间参数限定切分范围 | 通过 |
| 529 | RetrievalCoreTests | M06 父子切块 | RAG-01 每个子块区间都能回查到章节原文 | 通过 |
| 530 | RetrievalCoreTests | M06 父子切块 | RAG-01 子块位于其父块区间内，父块不超过上限 | 通过 |
| 531 | RetrievalCoreTests | M06 父子切块 | RAG-05 同一内容与配置切块 ID 稳定 | 通过 |
| 532 | RetrievalCoreTests | M06 父子切块 | RAG-02 空白段落不产生子块 | 通过 |
| 533 | RetrievalCoreTests | M06 父子切块 | RAG-01 超长段落按句切分为多个父块 | 通过 |
| 534 | RetrievalCoreTests | M06 父子切块 | RAG-01 过短的尾块并入前一子块 | 通过 |
| 535 | RetrievalCoreTests | M06 父子切块 | RAG-05 切块策略版本随配置变化 | 通过 |
| 536 | RetrievalCoreTests | M06 父子切块 | RAG-01 无标点的超长句被硬切，不丢字 | 通过 |
| 537 | SpeechCoreTests | M05 语音录入 | REF-03 录音→停止→转写→人工修改→提交 完整流程 | 通过 |
| 538 | SpeechCoreTests | M05 语音录入 | REF-03 首次使用请求麦克风权限，同意后开始录音 | 通过 |
| 539 | SpeechCoreTests | M05 语音录入 | REF-03 麦克风权限被拒绝时可继续文字输入 | 通过 |
| 540 | SpeechCoreTests | M05 语音录入 | REF-03 语音识别权限被拒绝时保留录音，可文字输入 | 通过 |
| 541 | SpeechCoreTests | M05 语音录入 | REF-03 转写不可用（语言/网络）时给出明确状态 | 通过 |
| 542 | SpeechCoreTests | M05 语音录入 | REF-03 没有识别到语音时提示重试或文字输入 | 通过 |
| 543 | SpeechCoreTests | M05 语音录入 | REF-03 转写失败给出错误并允许重新转写 | 通过 |
| 544 | SpeechCoreTests | M05 语音录入 | REF-03 来电中断录音：保留已录内容并允许继续 | 通过 |
| 545 | SpeechCoreTests | M05 语音录入 | REF-03 取消录音删除音频文件并回到空闲 | 通过 |
| 546 | SpeechCoreTests | M05 语音录入 | REF-03 录音启动失败不卡在忙碌状态 | 通过 |
| 547 | SpeechCoreTests | M05 语音录入 | REF-03 忙碌时重复点击录音不会启动第二段录音 | 通过 |
| 548 | SpeechCoreTests | M05 语音录入 | REF-03 超过最长录音时长自动停止并转写 | 通过 |
| 549 | SpeechCoreTests | M05 语音录入 | REF-03 没有内容时提交返回 nil | 通过 |
| 550 | SpeechCoreTests | M05 语音录入 | REF-03 停止前未录音的停止调用不改变状态 | 通过 |
| 551 | SpeechCoreTests | M05 语音录入 | REF-03 转写中被取消，迟到的转写结果不覆盖取消状态 | 通过 |
| 552 | SpeechCoreTests | M05 语音录入 | REF-03 失败状态下编辑文字作为降级输入 | 通过 |
