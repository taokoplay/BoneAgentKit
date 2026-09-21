# Workflow Host 迁移与发布交接

## 适用范围与当前状态

本文面向从 `0.2.0-alpha.17` 迁移到下一已签发版本的 Host。所述新增能力当前位于 Unreleased 开发线，**不是已发布版本声明**；不要把版本示例中的占位符改成尚未存在的 tag。

2026-09-21 本地已经实现持久化契约澄清、Run 控制器、恢复扫描、取消安全判定、持久预算、工作账本、执行会话及旧工作页对账。各阶段的内存与独立序列化测试不是生产数据库或第二个真实 App 的验收。最终签发依 [发布检查清单](../RELEASE_CHECKLIST.md)，完整语义见 [Workflow 与恢复](WorkflowAndRecovery.md)，测试接入见 [Testing](Testing.md)。

## 先确认升级范围

从 alpha.17 tag 到目标提交的范围，不仅包含新的 Workflow 能力，还包含此前已提交的 Agent Step 提交边界及 Gemini 多轮修复。发布审查应以 **上个发布 tag → 最终候选提交** 为范围，不能只查看当时的工作树 diff。

- 新协议和控制器采用组合方式，不自动替换 Host 原实现或切换默认行为。
- `BoneWorkflowPersistence` 原方法签名保持不变，但语义及验收场景明确化。
- `BoneWorkflowPersistenceContractCase`、Failure 等枚举增加项；穷尽 switch、固定场景数量、报告解析器及差距守卫必须同步。
- Agent Step 事件新增 `recoveryRequired`；该事件不是业务完成或普通失败，相关穷尽处理不能落入默认成功分支。
- Gemini fallback call ID 是不透明标识；不能依赖旧编号形态。continuation 的累计与保留规则变更，敏感内容不得写入普通日志或 checkpoint。
- 顶层 public 类型数量只用于静态差异提示，不证明完整源码或 ABI 兼容。最终仍须编译 Host 的生产目标和测试目标。

## 推荐迁移顺序

先实现薄适配器并验证，再接入控制过程。以下顺序是建议，不要求不使用 Workflow 的 App 接入所有协议。

| 阶段 | SDK 入口 | Host 必须完成 | 验收重点 |
| --- | --- | --- | --- |
| 1. 通用存储 | `BoneWorkflowPersistence` | 将领域 payload 解码移出通用 Store；保留原始合法 JSON 字节与分级；create 保存任意初始 generation | 8 个持久化场景；6 必需，另 2 项连接能力按实际支持执行或明确 skipped |
| 2. 恢复发现 | `BoneWorkflowRecoveryScan` | 实现同一授权 scope 的完整一致扫描；保留业务实体索引和原子绑定事务 | trusted/quarantined 分离、终态过滤、基础设施错误不伪装坏行 |
| 3. Run 控制面 | `BoneWorkflowRunController` | 提供授权、业务状态映射与 Worker 停止闭包，移除重复状态过程 | begin/resume 换 lease；取消意图先持久化；异常后重读，不盲重试 |
| 4. 持久预算 | `BoneWorkflowRunBudgetStore` | 保存真实起点、策略、额度与双时钟事实，原子处理预留 | 跨 session 不重置；参数漂移、时钟异常 fail-closed；拒绝 attempt 不隐去 |
| 5. 工作账本 | `BoneWorkflowWorkLedgerStore` | 不透明领域 plan；Run 级 CAS、原子 split 和版本化恢复日志 | 页号是请求尝试序号；失败不退号；未知在途不释放 |
| 6. session 准入 | `BoneWorkflowExecutionSessionStore` | 领域 admission 放入 Data；可信 nonce；原子准备/消费/创建及安全事实复核 | 序号零基连续；nonce 撤销或消费后不复用；hash 不替代授权 |
| 7. 取消收口 | `BoneWorkflowCancellationReadinessQuery` | 将完整 session/Effect/stage/preflight 事实投影到同一版本；在最终事务重新验证 | ready 不等于完成；unknown、当前 Effect 和证据缺失均拒绝 |
| 8. 旧页恢复 | `BoneWorkflowWorkReconciliationStore` | 取得真实接管权、阻止旧执行新增副作用并确认结果；原子写回原账本 | 精确旧页与当前代绑定；已保存响应不可替换；未知提交先读回 |

第 7 项依赖 Host 已有完整事实查询，不应先接一个“全部为空”的假投影。第 8 项是可选能力；不支持时继续保留 recoveryRequired，不能为通过验收而清空旧页。

## 不透明载荷不是同一种格式

| 数据 | SDK 约束 | Host 不应做什么 |
| --- | --- | --- |
| checkpoint payload | 非空合法 JSON，最多 4 MiB；允许 safeState / opaqueReference；业务 schema 不透明 | Store 不得只接受某个领域 kind；不能把任意二进制当合法 checkpoint |
| Work payload / response / cursor / artifact | 每字段最多 4 MiB 的任意 Data | 不因通用 Store 不识别领域内容而拒绝；不能声称单字段上限等于总历史容量限制 |
| Session admission | 最多 4 MiB 的任意 Data；SHA-256 绑定原始字节 | 不在 hash 前重排/重新编码 JSON；不能将 hash 当签名或权限证明 |

数据分类、加密、访问权限、保留期限与总存储限额仍属于 Host。原始 payload、response、nonce 和完整证据不得进入一般诊断报告。

## 旧数据切换策略

### 不把新 schema 当作自动迁移器

Session/Ledger 和预算的新 schema 校验只能验证它们定义的结构，不会理解旧 Host 数据。工作账本没有任意快照反序列化入口；示例采用可信、版本化命令日志重放。Host 不应通过新增 setter、伪造命令历史或改 generation 绕过校验。

建议 Host 为旧行明确选择并记录一种策略：

1. **先只让新 Run 使用新适配器。** 旧 Run 保留原存储和恢复路径，按版本分流；禁止同一 Run 由两套控制器并发写入。
2. **可证明保真时显式迁移。** 备份原记录，核对完整历史、页号、原 generation、已用预算、起点、session 序列、nonce 墓碑和 Effect 事实；事务提交并回读比对。缺少历史时不凭空补齐“合法值”。
3. **无法确认时隔离。** 保留旧记录与人工决策入口，不归零额度、不重新派发未知请求、不删除 nonce 墓碑。

任何业务 schema 升级都应与 SDK 版本升级分开记录。遇到策略版本或数值漂移，新预算 open 会拒绝，而不是以新版本名重置旧 Run 的额度。

### 版本映射

- 首次 session 映射为 sequence 0；旧 Host 若一基编号，必须显式转换并验证历史连续性。
- 工作 page 从 0 开始，每次 reserve 消耗一个序号；不能把业务 cursor 或“成功页数”写入 page。
- Run revision、session revision、工作账本 revision、预算 revision 和 all-facts evidenceRevision 是不同版本域，不能互换。
- create 保存的 generation 不是执行所有权；真正执行仍需获得当前 Run lease 和 Host 授权。

## 事务与授权责任表

| 操作 | SDK 能检查或表达 | Host 仍必须保证 |
| --- | --- | --- |
| Run 多步控制 | 合法迁移、revision/generation、完整回执 | 多步失败的重读与调和；业务实体绑定；Worker/Effect停止事实 |
| 预算预留 | 计数/时钟/策略不变量 | 真实双时钟来源、存储原子性、预算与实际请求的关联 |
| session consume | nonce/请求绑定与连续序号 | 可信 nonce、调用者权限、业务资源版本、旧 Effect 安全，且与消费处于同一事务屏障 |
| 取消完成 | 一致快照上的只读 readiness | 最终事务复核覆盖所有事实的 evidenceRevision，不能只比较 Run revision |
| 工作页对账 | 精确目标、旧代/当前代、账本 CAS、响应保真 | 证据真实性、旧外部执行 fencing、结果不重复应用及业务/Effect/账本的提交协调 |

没有 Worker、请求超时和进程重启都不是已停止或明确失败的证明。任何提交回执未知都应先读取原身份的结果；不能自动刷新 revision 后重复业务动作。

## Host 验收清单

测试目标链接 `BoneAgentTesting`，生产目标仍只链接实际需要的 Product。

| 套件 | 场景数 | 说明 |
| --- | --- | --- |
| `BoneWorkflowPersistenceContractSuite` | 8 | 两项连接能力可按能力明确 skipped，其余必需 |
| `BoneWorkflowRunControllerContractSuite` | 5 | 全部必需 |
| `BoneWorkflowRecoveryScanContractSuite` | 4 | 缺坏行注入能力须明确 skipped，不伪造污染测试通过 |
| `BoneWorkflowCancellationReadinessContractSuite` | 11 | 全部必需，投影与来源事实均不得被修改 |
| `BoneWorkflowRunBudgetContractSuite` | 7 | 连接重开能力按实际 fixture 验证 |
| `BoneWorkflowWorkLedgerContractSuite` | 7 | 全部必需 |
| `BoneWorkflowExecutionSessionContractSuite` | 5 | 全部必需 |
| `BoneWorkflowWorkReconciliationContractSuite` | 8 | 对选择实现此可选协议的 Host 全部必需 |

在真实持久层额外执行：

- 独立连接/进程竞争以及 lease 接管后旧 Worker 迟到写入；不能只重复同一个 actor 测试。
- 提交前崩溃、提交后回执丢失、重开连接和重启进程；验证没有重复请求或业务应用。
- Run 与业务实体原子绑定、session/nonce 原子消费、工作 split/对账整体提交。
- ready 后新增 Effect 的并发交错，确认最终收口事务拒绝并保留已应用结果。
- 旧数据读取/隔离、预算跨 session 保留、nonce 墓碑恢复、授权 scope 交叉访问拒绝。
- 业务场景 Debug/Release、取消、恢复、无进度与游标上限策略；在实际支持设备上验证。

独立示例可用于编译前检：

```bash
swift run --package-path Examples/MinimalWorkflowHost MinimalWorkflowHost
```

它验证基础恢复和授权合成流程，不覆盖这份表中全部事务，也不是实际 App。

## 发布、pin 与回滚顺序

1. 核对从上一 tag 到候选提交的完整范围，排除本地工作台、缓存、凭据及未审查生成物。
2. 在授权后整理实现提交与版本元数据；版本常量、README、Package 接入说明、Changelog 和 tag 一致。本文不选定新版本，也不自动创建 tag。
3. 在最终候选 SHA 重跑门禁，记录实际工具链；最低 Swift 5.9、真实 Host、Provider 及权利核验缺项不得标成完成。
4. Host 可先针对精确候选 SHA 使用干净检出执行兼容和冻结基线，避免“必须先发布才能验收”的循环；tag 只能在签发授权与适用门禁满足后建立，公开 tag 不重写。
5. Host 固定最终已审核版本或精确 revision，更新锁文件，确认本地 SDK SHA 与解析结果一致且工作树干净，再重跑正式基线。版本改变不应触发重置已有 Run。
6. 失败时停用新适配器入口并保留数据；只在确认旧 decoder 能读取已写数据后切回旧版本，否则保留新 decoder 进行只读恢复/隔离。不要直接回退二进制后删除“不兼容”任务。

当前文档与本地检查只构成迁移准备，不能替代签发负责人、最终 SHA、真实 Host 证据或发布授权。
