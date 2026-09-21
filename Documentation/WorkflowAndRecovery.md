# Workflow 与恢复

## 状态和冻结 Plan

首版采用确定性 Workflow + 局部 Agent Step，不支持任意 DAG。Run、Step、Attempt 分层管理，终态不可复活；`committed` Attempt 不得重跑，`outcomeUnknown` 和 `commitUncertain` 需要明确恢复决策。

`BoneWorkflowPlan` 在创建 Run 时冻结 workflow identity/revision、ordered steps、step kind/revision。恢复直接解码冻结 Plan，不重新调用当前版本 builder。Checkpoint compatibility 显式返回 `resumeCompatible`、`requiresRestart` 或 `requiresUserDecision`，未知格式与未来 revision 不静默恢复。

## Persistence

`BoneWorkflowPersistence` 将 Run 与 Checkpoint 作为同一原子提交单元，提供 create、load、CAS commit 和 acquireLease。所有推进同时受单调 revision 与 lease generation fencing 约束。Host Adapter 应在同一原子事务中完成；不能把 Run 和 Checkpoint 拆到两个无法协调的 Store。

### Payload：业务 schema 不透明，格式与分级仍受约束

`BoneWorkflowCheckpoint` 当前要求 payload 是非空、最多 4 MiB 的合法 JSON，允许对象、数组、字符串、数字、布尔和 null；不接受任意二进制。普通持久化只允许 `safeState` / `opaqueReference`。这不是放宽隐私边界：Host 必须在构造 checkpoint 前正确分类，不能仅靠标签把敏感正文变为 safeState。

对所有合法 checkpoint，`BoneWorkflowPersistence` 必须与 payload 的业务结构无关：不能要求 `kind` 或其他 Host 私有字段，不能将 payload 强制解码成某个业务 DTO，也不能重新编码 JSON。create/load/commit 必须保留原始 payload 字节（包括空白和数字表示）、descriptor、dataClassification 与 retention；revision 按提交契约推进。允许内部存储封装，但读取必须无损恢复原信封。

Host typed codec 应放在持久化边界之外：写入前由业务层构造并验证 typed payload，再编码成 JSON；读取后由对应业务层解码。通用 Store 负责信封校验、原子性、CAS 与 fencing，不负责领域 schema。若旧存储格式把领域字段与信封混在一起，Host 需要单独设计兼容读取／数据迁移，不得通过删除历史记录或跳过契约验证规避。

### create 与 acquireLease

- `create` 要求 Run 尚不存在，Run 与 Checkpoint 输入 revision 均为 0，descriptor 与冻结 Plan 匹配；成功时两个 revision 均为 1。
- 初始 `leaseGeneration` 接受任意 `UInt64`（包括 0），原样保存；不强制归零或隐式递增。这是存储契约，不要求 Host 业务入口允许任意初始 generation。
- 创建或持有一个非零 generation 不是 owner 认证，也不是获得执行授权。Host 仍决定何时可接管；执行 Effect 时不能使用 0 代 generation。
- `acquireLease` 使用当前 revision CAS，同时将 Run/Checkpoint revision 与 generation 各加 1，其他字段不变。它是接管操作，不是幂等的“确保持有 lease”，也不是续租接口。同一 expectedRevision 再调用必须以 `revisionConflict` 拒绝，不得再次递增。
- 任一计数溢出必须以 `revisionConflict` 原子拒绝，snapshot 不变。允许创建 generation 为 `UInt64.max` 的记录不意味着该记录还能换代；禁止回绕到 0。
- 接管返回结果未知时，先 load 并结合 Host 所有权事实调和；不能直接用新 revision 重试，否则会再次换代并使已有 worker 失效。只有 generation/revision 无法证明接管者身份。

## Run 控制面

`BoneWorkflowRunController(persistence:)` 组合 `BoneWorkflowPersistence` 与既有 Run 状态机。它不缓存 Run、不持有 Worker、不解释 checkpoint、不管理预算，也不判断业务授权。每个命令显式传入 `expectedRevision`；Worker 相关的停止和终态协调还必须传入 `leaseGeneration`。所有状态修改经过 `transitioned(to:)`，并按当前 revision/generation CAS。

| 方法 | 持久化过程与边界 |
| --- | --- |
| `createRun` | 创建 pending / revision 1 / generation 0；不建立业务实体映射 |
| `bindPreparedExecution` | 仅 pending 时更新已准备的 checkpoint；输入 checkpoint revision 必须匹配当前 revision |
| `beginExecution` | pending → acquireLease → running；原 generation 非零也必须换代 |
| `pauseExecution` | running → pausing → acquireLease → paused；已 pausing 可在 Host 调和后显式继续 |
| `resumePausedExecution` | paused → acquireLease → running |
| `recover` | 对非终态执行一次 acquireLease；不改变状态、Plan、payload、预算或截止时间 |
| `requestCancellation` | 先提交 cancelling；已 cancelling 时只读返回，不停止 Worker、不直接写 cancelled |
| `stopRequestedExecution` | 仅 cancelling/cancelled 且 revision/generation 匹配时调用 Host 的精确 Worker 停止闭包，不写终态 |
| `reconcileTerminal` | Host 确认后提交 completed/failed/cancelled/recoveryRequired；同终态可只读返回，其他转换仍受状态机约束 |

暂停与恢复运行分别换代，防止旧 worker 使用新 revision 但旧 generation 提交。`paused` 仅证明控制面暂停：外部 Effect 仍可能进行或结果未知，generation 不会物理终止外部调用。Host 必须把 fencing 传递到实际 Effect/工作单元存储，并完成自己的停止与对账流程。

取消接受、请求停止、确认终态是三件事。没有 Worker、停止闭包返回或业务任务显示结束，都不能单独证明安全收口。`stopWorker` 收到确切 snapshot，Host 应据 Run ID/generation 找到对应 Worker，不能停止一个已被替换的新实例。读取与外部停止不是跨系统事务。

### 多步过程与故障恢复

这些过程不是整体事务。举例：begin 的 acquire 成功后 running 提交可能失败；pause 的 pausing、换代与 paused 之间都存在持久化边界。控制器验证完整 Store 回执，任一步抛错（包括取消）或返回不匹配快照就停止，不自动重试、不撤销已持久化事实，也不补写失败终态。

控制器不缓存“不确定”标志；**新命令不意味着旧故障已调和**。Host 必须 load、核对所有权与外部事实，再显式选择命令和新的 revision，不能捕获异常后自动换 revision 重试。开始/恢复后的返回 snapshot 是后续执行应绑定的 generation。状态机中的 `recoveryRequired` 当前是不可复活状态；`recover` 不绕过该表，也不等同于处理未知 Effect。

Host 仍负责授权/策略、业务终态映射、Worker 管理、Effect 对账以及业务数据存储。此控制器不新增 Run 索引、恢复扫描或 Run＋业务实体原子绑定；需要这些能力时保留 Host seam，不能把 `createRun` 后另写映射当成原子事务。准备 checkpoint 的绑定也不代表业务映射。

## 恢复扫描与 Host 索引边界

`BoneWorkflowRecoveryScan` 是独立可选协议，不给 `BoneWorkflowPersistence` 增加必需方法。`recoverableRunScan()` 返回 `BoneWorkflowRecoveryScanResult(trustedRuns:quarantinedRunCount:)`。内存参考实现提供该能力；Host Adapter 可组合实现。

### scope、一致性与隔离

- scope 由 Host 创建 Adapter 时固定（例如某一授权存储空间），不能因为恢复扫描扩大租户、项目或账户范围。`trustedRuns` 和计数必须来自同一个完整、一致的读取快照；不得用不同时间的独立查询拼接。
- 当前候选是 pending、running、pausing、paused、waitingForAuthorization、cancelling 和 recoveryRequired；合法 completed/failed/cancelled 不返回，也不计入隔离。结果顺序无保证，不得按数组顺序推导优先级。
- **recoveryRequired 需要发现，不代表可以重新执行。** 它仍受既有不可复活状态表约束；扫描结果不是执行许可、lease 所有权或业务 schema 校验。执行前 load、检查 checkpoint compatibility/授权/Effect 事实，再按 revision/generation CAS。
- 单条存储记录无法解码、未知存储信封版本、Run/Checkpoint revision 或 Plan 绑定不一致时，保留原记录、从 trustedRuns 排除并计数。应先验证记录再按状态筛选；不能因为坏记录的状态也读不出来就静默丢弃。
- `quarantinedRunCount` 是该 scope 当前快照中的不可用记录数量，不是历史错误次数；重复读取不累加。不自动删除、移动或修复坏记录。需要修复/迁移时由 Host 独立授权并执行。
- 数据库连接、权限、事务失败和取消必须向外抛错，不能捕获所有异常后假装扫描成功或统计为坏行。单行解码 catch 与数据库 I/O 边界必须分开。
- 返回模型验证计数非负、ID 唯一、候选状态与信封一致性，但无法证明没有漏行、计数正确或查询 scope 正确。Host 的实际扫描必须保障这些事实。模型包含原 checkpoint，不属于安全日志报告。

本版接口要求完整快照，**不提供分页、不允许静默 limit 截断**。大规模 Host 可在同一数据库快照内分批读取后汇总；无法在资源限制内完整返回时应明确失败，不能返回部分结果。带快照身份、游标生命周期和去重计数的流式/分页能力留待独立协议，不以普通 offset 拼接冒充一致性。

### Host 业务索引 seam 的推荐形状

Kit 不规定业务实体 ID、业务生命周期、一个实体对应多少 Run，也不能替 Host 承诺跨表事务。以下是放在 **Host 模块** 的接口示意，不是 SDK 新协议：

```swift
protocol HostRunIndex: Sendable {
    associatedtype EntityID: Hashable & Sendable
    associatedtype CreationContext: Sendable

    func entityID(runID: BoneRunID) async throws -> EntityID?
    func nonTerminalRun(entityID: EntityID) async throws -> BoneWorkflowRunSnapshot?
    func lifecycleRuns(entityID: EntityID) async throws -> [BoneWorkflowRunSnapshot]
    func createRunAndBind(
        entityID: EntityID,
        run: BoneWorkflowRunRecord,
        checkpoint: BoneWorkflowCheckpoint,
        context: CreationContext
    ) async throws -> BoneWorkflowRunSnapshot
}
```

推荐按能力将只读索引与写入绑定进一步拆开；`CreationContext` 保存 Host 的版本、策略或领域创建信息，不传给 Kit。具体索引协议可以继承 `BoneWorkflowRecoveryScan`，但扫描不需要解释 EntityID。

Host 必须明确并测试：

1. **原子绑定**：Run、Checkpoint、业务映射在同一事务内创建或全部不变。需要此能力时使用 Host 事务入口，不先调用 Controller.createRun 再插映射。
2. **唯一性**：若要求一个实体最多一个非终态 Run，使用事务/唯一约束，不靠“先查询为空再创建”。必须说明 recoveryRequired 是否占据业务活动槽位；Kit 不代替该业务决策。
3. **历史与错误**：不存在的绑定返回 nil；读取失败/坏绑定不能伪装不存在。生命周期查询明确范围和排序；坏记录不得被静默选成唯一活动 Run。
4. **双向一致性**：反查、非终态查找、生命周期列表与扫描必须指向同一授权 scope、同一持久事实；不能维护独立影子状态来替代 Run 状态。

这些绑定/索引规则由 Host 契约验证，本次 SDK 套件只验证恢复扫描。它不证明跨表原子性、租户权限或实际数据库隔离级别。

## 未启动续执行的取消安全判定

`BoneWorkflowCancellationReadiness` 解决的是 Host 重复维护“这次续执行是否从未真正开始，能否安全收口”的判定，不是通用强制取消器。它通过 `BoneWorkflowCancellationReadinessQuery` 一次读取一致事实，输出 `ready` 或固定拒绝原因，不修改 Run、session、Effect、stage 或已应用结果。

### 通过条件与 Host 投影

只有全部满足才返回 ready：取消意图已持久化（Run 为 cancelling/cancelled）；当前 session 有效、sequence > 0、active 且没有 observation；当前 session 没有任何 Effect；完整历史 Effect 均已 committed；当前 session 没有 stage 工作/产物；preflight 通过；Host 领域扩展允许收口。

`Session` / `Effect` / `Checks` 是最小只读投影，不是新的存储模型：

- session.id 应映射为稳定不透明标识，session.revision/sequence 来自持久事实；sequence 为零基（首次为 0，续执行从 1 起），一基编号的 Host 必须转换；不把缺少 observation 当成不存在历史工作的证明。
- Effect.committed 只表示持久化提交已确认，不是“有 Receipt”或“外部调用成功”。其他在途/未确认状态映射为 uncommitted，结果未知映射为 outcomeUnknown；未知状态不能映射为 committed。
- `hasStageActivity` 包括本 session 已有的工作或产物，不只是正在运行的 stage。Host 的领域扩展段归入该事实或额外 `hostAllowsClosure` 否决；Host 允许不能覆盖通用拒绝条件。
- `sessionComplete` / `effectsComplete` / `stagesComplete` 都必须明确提供；分页未读完、读取范围不明不能标为 true。历史 Effect 必须覆盖该 Run 的全历史，而不是仅当前进程或当前 session。

历史或当前 `outcomeUnknown` 一律拒绝安全收口。当前 session 即使只有 committed Effect 也拒绝，因为它已经开始过；历史 uncommitted 同样拒绝。结果报告只返回首个拒绝原因，不表示其余条件通过。

**没有 Worker 不等于执行已停止。** 本接口刻意不接受 isWorkerRunning。新实例丢失 Worker 引用后，缺少 session/完整历史事实仍拒绝；只有持久证据满足上述条件才可能 ready。已有 observation 表示这条“从未开始”路径不适用，不代表所有取消方式都被禁止。

### 一致性与最终收口

Host 查询必须在同一事务或等价读屏障中取得全部事实，I/O 错误和取消向外抛出，不能用空 Effect 数组或默认 true 降级。SDK 校验显式字段，但不能认证 Host 的完整性声明。

每次 evaluation 绑定 runID、runRevision、leaseGeneration 以及 `evidenceRevision`。后者是 Host scope 内覆盖 session、Effect、stage、preflight 及领域否决事实的非零版本；所有相关变化必须在同一写事务推进，禁止回绕/复用。不能直接拿 Run revision 代替，除非 Host 确保每项相关变化都会原子推进它。外部 preflight 不能被版本化时，需要 Host 的等价锁/事务屏障或明确拒绝，不能声明一个虚假的版本。

`ready` 只表示查询时规则通过，**不是持久化完成或可复用授权**。真正收口必须在 Host 同一事务内重新核对 Run revision、generation 与完整证据版本（或者在该事务内重新读取并执行判定），再原子写入 session/业务终态；发生变化就拒绝并重新读取，不能盲目重试。单独调用 `RunController.reconcileTerminal` 只校验 Run CAS，无法防止 Effect/stage 在 Run revision 不变时新增，因此不能直接把 ready 接到该方法就宣称跨事实安全。

这条路径不执行 Effect 对账、不修复 unknown、不重置预算、不改写已应用结果，也不提供完整 execution session/admission 存储。真实 Host 的事务适配与收口仍需独立验收。

## 持久化请求与时间预算

`BoneWorkflowRunBudget` 与 `BoneWorkflowRunBudgetStore` 解决跨 session 恢复时额度和截止被重置、普通阶段耗掉最终阶段保留额度的问题。它与单次进程内 `BoneRunBudgetMeter` 独立，不改变既有 Agent 预算行为，也不自动替换 Host 存储。

### 请求预留与失败

预算以 Run ID 为键，不以 session 为键。Policy 冻结 requestLimit、reservedFinalRequests、durationSeconds、bootEpochToleranceSeconds 与 versionTag。普通阶段只能使用 `requestLimit - reservedFinalRequests` 范围内的库存，final 可用全部剩余额度；阶段由可信 Host 流程决定，不能让模型自行声明 final。

- `usedRequests`：已成功预留的请求数。一旦 granted 即消耗，后续请求失败、取消或业务结果拒绝都不退款。
- `attemptedRequests`：所有已持久化的预留尝试，包括因额度/时间/时钟异常而拒绝的尝试。拒绝也记录，不把它们隐去；但普通阶段的拒绝不能侵占 final 保留库存。
- `reserve` 的业务拒绝返回 rejected，且同事务保存 attemptedRequests/revision 等变化；不能先抛业务异常导致事务回滚，从而丢掉失败尝试记录。
- CAS 冲突、提交前取消或 I/O 错误不伪造成功计数。若提交已经发生但回执丢失，额度可能已经消耗；必须重读调和，不能自动使用新 revision 重试。没有 request-operation 去重账本，不能仅凭一个计数差推断具体哪次请求已预留。
- 计数或 revision 溢出拒绝，不回绕。没有 refund/reset 方法，也不会因新 session 而归零。

### 双时钟与恢复

Host 提供同一时刻的 wallTime、单调 uptime 和稳定 bootID。bootID 在同一次设备启动内保持一致，不能每次启动 App 或 session 重新生成，也不能跨设备/跨重启复用。SDK 不读取系统凭据或伪造跨启动身份。

起点在首次 open 冻结，wall/uptime 两个截止均为 start + duration；**达到任一截止（>=）即拒绝**，这一边界有意不同于原进程内 Meter 的“超过才拒绝”。检查在预留边界执行，不强制中断正在进行的请求或必要 Receipt 提交。

相对 lastObserved 的任意 wall/uptime 回拨、非法数值、bootID 变化、`wallTime - uptime` 相对初始 boot epoch 的漂移超过策略容差，均 fail-closed。容差默认为 1 秒，用于双读数采样抖动；可设为 0，不能用扩大容差代替可靠时钟。校时/休眠引起超容差也会拒绝，不自动解释为安全。时钟读数应在事务线性化点附近取得，Host 不能排队很久后仍使用旧 now 放行。

clockInvalid 或 deadline 一旦持久化便永久阻塞该预算，后来时钟恢复也不会重新放行；原 Run 的起点/截止不被延长。异常读数不写入 lastObserved，避免把 NaN 等不可信值污染持久状态。

`open` 已存在行时逐字段等值校验 policy，包括版本标签，并返回原行；now 只用于新建。open 成功不是当前仍可执行，仍须 reserve 校验当前时钟。任何参数或版本变化都拒绝同 Run，**换版本标签不是扩额/延时权限**。合法新配置用新的执行身份，或由 Host 另行授权、审计与实现迁移，不靠重新 open 清空历史。

### 存储与接入边界

Host 在同一事务中执行 load → expectedRevision 校验 → `state.reserving(phase:now:)` → 完整保存 → 返回回执。`BoneInMemoryWorkflowRunBudgetStore` 是原子语义参考，不是磁盘存储。Codable 使用 schemaVersion 1，并在解码重新验证 Policy、时钟、计数与快照不变量，未知格式拒绝；不提供签名防篡改或预算历史证明。

该协议不管理 Worker lease、Effect 准入、工作单元页序或外部调用身份。成功预留只说明有额度，不代表已获得执行授权；Host 仍需结合 Run generation、工作账本和权限控制。预算行与其他业务写入是否同事务由 Host 明确，不能把多个独立调用宣称为整体原子事务。

## 可分页、可拆分工作单元账本

`BoneWorkflowWorkLedger` / `BoneWorkflowWorkLedgerStore` 统一页序、在途状态和拆分规则，解决 Host 重复实现页序 CAS、旧 Worker 回写、失败后退页号、拆分父节点继续出页等问题。工作单元 payload、response、cursor、artifact 都是最多 4 MiB 的不透明 Data，不要求 JSON，不含领域计划字段；Host 仍负责业务计划、解码、数据分级与敏感数据存储策略。

### 状态与请求身份

单元状态为 pending/partial/completed/split/blocked。每页是一个稳定请求尝试，唯一键为 `(runID, unitID, page)`；页号从 0 连续递增，**不是已成功提交的内容页数**。reserve 立即占用页号、增加 requestCount 并置 partial；knownFailure 也保留页号，后续尝试使用下一号，不回退复用。cursor 表示业务续页位置，不能拿页号替代它。

命令过程是 reserve → dispatch → recordResponse → commit。dispatch 必须先落盘再发外部请求，responseRecorded 必须先落盘再提交 artifact/cursor。reserve/dispatched/responseRecorded 都是在途，禁止继续 reserve、stop 或 split。重复 dispatch、重复响应、越序提交和旧页响应不能覆盖已保存事实。

`finishKnownFailure` 仅允许 reserved/dispatched，由 Host 提供“已确认失败且不存在未知副作用”的事实；它保留 partial 和原 cursor/artifact，不清除已应用结果。普通超时、网络断开或无 Worker **不证明 knownFailure**，此时应保留 dispatched 并对账，不能继续新页。

commit 的 artifact 是 Host 提供的该单元最新完整结果，不自动合并业务内容；completed=true 终止该单元，否则保持 partial。`stop(reason: .noProgress/.cursorLimit)` 在无在途时写 blocked。completed/split/blocked 都不能再出页；SDK 不自动检测领域进展或 cursor 循环，Host 根据业务事实选择 stop。

### 原子拆分与围栏

split 要求至少两个新且唯一的子 ID、父单元无在途且 pending/partial。父置 split 与全部子创建必须在同一事务提交；任一冲突整次零写入。父的历史页、cursor 和 artifact 保留，子单元从独立 pending/page0 起步，不自动继承父结果或退款。子 ID 在 Run 内不能复用，包括已有终态单元。

所有 Store 写入校验 Run 级账本 revision 和 leaseGeneration；同一 Run 的不同单元也竞争 aggregate CAS。这是首版保障跨单元拆分原子性的取舍，不能声称已支持高并发细粒度写入。

Host 获得真实 Run 接管权后调用 advanceLease，必须显式旧 generation 与更大的新 generation。它不取得 Run 所有权、不保证与 Run Store 跨库原子，也不清除在途页。preflight 对新代看到的旧代在途页返回 recoveryRequired；旧代回写、拿新代冒认旧页的 dispatch/response/commit/knownFailure 全部拒绝。需要恢复旧页时可采用独立可选能力 `BoneWorkflowWorkReconciliationStore`，按下节规则写回明确结果。普通 Worker 命令仍不能跨代操作旧页，未知结果仍须保留，不能改 generation 伪造重新执行。

preflight 只返回查询时状态，不是执行许可；每次真实写入仍必须 CAS。换代后原来无在途的单元可继续使用新 generation，页序/结果不重置。

### 持久化与接入限制

Store 提供 open（准备或等值读回）、load、apply、advanceLease。open 校验原始 preparedUnits 与当前 generation，不拿拆分后的子单元列表当作新初始计划，也不重置进度。纯 `applying` 只产生候选值，不能当作已经落盘；Host 应完整事务保存后再执行下一步。提交结果未知时重读调和，禁止盲目换 revision 重发。

账本不提供任意字段构造或合成 Codable 解码，以免绕过状态不变量；Seed 和 Command 可 Codable，但重放仍必须 applying 校验。当前可接入方式包括可信命令日志重放；生产 Host 需为日志封装版本与身份校验，不得重放不可信外部命令。大历史的快照恢复、压缩、归档和整体内存上限未在本版实现：单项 4 MiB 不代表整个账本有界，不能用本地小样本证明大规模性能。

`BoneInMemoryWorkflowWorkLedgerStore` 只提供内存原子参考。账本不自动扣 P4 预算、不启动 Worker、不授权请求；账本页占用和请求预算不是自动跨表事务。Host 必须安排预算、Run lease、页准入与外部副作用的顺序及故障恢复，不能把多个独立调用称作一次原子提交。

### 旧在途页的显式对账写回

`BoneWorkflowWorkReconciliationStore` 是独立可选协议，继承原 `BoneWorkflowWorkLedgerStore`，不为已有适配器增加必需方法或提供宽松默认实现。内存参考 Store 支持该能力。Host 明确确认旧执行结果后，可在原账本内结束旧页，继续使用下一页号；不必绕开原账本建立新 Run。

`BoneWorkflowWorkLedger.Reconciliation` 显式绑定 runID、unitID、page、sourceGeneration、resolvingGeneration、expectedRevision、evidenceID 与 outcome。当前接管代必须与 ledger 一致，且严格大于原页代；页必须是该单元最后一条在途页。所有身份、revision、generation 都匹配才会推进，旧请求重放和后来的接管均使原请求失效。

| 原页阶段 | Host 可提交的明确结果 | 写回行为 |
| --- | --- | --- |
| reserved | knownFailure | 仅在 Host 确认没有未知副作用时结束为 knownFailure；不能虚构成功响应 |
| dispatched | knownFailure 或 committed | 失败保留已有进度；成功同时记录响应及应用结果 |
| responseRecorded | committed | 输入响应必须与已保存字节一致；不能替换响应或降级成失败 |
| committed / knownFailure | 无 | 不允许再次对账，即使换一个 evidenceID 或使用最新 revision |

committed 包含有界 response、cursor、artifact 与 completed，SDK 只保存这些不透明事实，不运行领域应用逻辑。knownFailure 保留 cursor/artifact，单元仍为 partial。两条路径都不退款、不回退 nextPage、不改原页 generation，页中持久保留完整 reconciliation 目标与证据引用。非完成成功/明确失败后可用当前代 reserve 下一页；完成成功后单元终态不可复活。

**安全责任：** evidenceID 只是 Host 审计依据引用，不是签名或自动认证的证据。接收一个非空字符串不证明结果可信。Host 必须认证接管者，确保旧执行不能继续产生副作用，核对外部请求/Effect结果，并在其事务边界内复核目标和授权。超时、没有 Worker、换 lease 均不能推导 knownFailure；未确认的情况不调用 reconcile，继续保持 recoveryRequired。

```swift
let ledger = try await store.load(runID: runID)
// 此处之前：Host 已完成真实对账、接管授权、旧执行 fencing 和业务应用事实确认。
let resolution = try BoneWorkflowWorkLedger.Reconciliation(
    runID: runID, unitID: unitID, page: oldPage.number,
    sourceGeneration: oldPage.leaseGeneration,
    resolvingGeneration: ledger.leaseGeneration,
    expectedRevision: ledger.revision,
    evidenceID: hostEvidenceID,
    outcome: .committed(response: confirmedResponse, cursor: cursor,
                        artifact: appliedArtifact, completed: false)
)
let recovered = try await recoveryStore.reconcile(resolution)
```

`reconcile` 必须原子提交页终态、进度和对账记录，不能先释放在途状态再落盘 artifact。外部业务应用/Effect记录与账本不是自动跨Store原子事务；Host 需用自身事务或明确的幂等/对账流程协调。提交结果未知时先 load 比较原页与 reconciliation；不重复调用业务应用，也不自动刷新 expectedRevision 盲重试。只有重读和重新核实事实后，Host 才能构造新的对账请求。

Reconciliation 自定义 Codable 解码重验 ID、generation 顺序、revision 与数据长度；与原 Command 一样，编码数据仅供可信持久日志重放，解码本身不授予执行权限。内存参考及独立命令日志测试不证明真实数据库耐久性、跨进程锁或外部 Effect fencing。整体日志/历史大小和归档限制仍由 Host 负责。

## 执行会话信封与一次性续执行准入

`BoneWorkflowExecutionSession` / `BoneWorkflowSessionLedger` / `BoneWorkflowExecutionSessionStore` 将 session 序列、绑定与 nonce 消费下沉，解决 Host 复制相同准入状态机及领域 admission 与通用信封混杂的问题。admission 是最多 4 MiB 的不透明 Data，允许任意字节；SDK 不加入审核、候选或领域扩展字段。Host 负责 payload 构造/解码与隐私存储，hash 不会使敏感正文变得可公开。

### 信封与生命周期

信封包含 runID、sequence、operationID、effectID、bindingHash、admission/admissionHash、state、revision。初次 sequence=0，后续严格加一，与 P3 的零基约定一致；operationID/effectID 在同 Run 历史中不得复用。admissionHash 为原始字节 SHA-256，不规范化 JSON，字节变化即需新的绑定。

状态为 active/completed/cancelled/failed/recoveryRequired；只允许 active 到一个终态，不能改写终态或复活。当前 schema 下 active session revision=1，终态=2；独立 ledger revision 随准入操作推进。completed/cancelled/failed 可在 Host 明确授权后准备新 session；recoveryRequired 不允许通过新 session 绕过未知事实。结束 session 是 Host 提交事实，不会自动停止 Worker 或证明 Effect 安全。

### prepare、consume 与撤销

1. Host 完成业务授权与安全检查后，以 ledger expectedRevision 调用 `.prepare(request, nonce:)`。它绑定当前 session 序号/revision、下一序号、operation/effect、bindingHash、admissionHash，持久化 nonce 摘要及待消费 permit。
2. `.consume(request, nonce:)` 只有在这些字段全部匹配时，才能原子清除 permit 并创建新 active session。未准备许可、错误 nonce、改动 admission、跳序或身份复用均拒绝且零写入。
3. `.revoke` 清除待用 permit，但保留 nonce 摘要墓碑。撤销或消费过的 nonce 都不能再次 prepare；一次性范围是固定授权 scope 下的该 Run，不声称全局唯一。

Store 必须在同一事务内 CAS 校验、消费许可、保留墓碑并创建 session，不得拆成“先消费 nonce，再插 session”的独立提交。提交结果未知时读取原 ledger；不能换 nonce 重发绕过旧结果。两个并发消费者只有一个 revision CAS 赢家。

Nonce 由可信 Host 生成并安全传递，SDK 只检查非空和长度，不提供密码学随机性认证。Command 刻意不 Codable，避免把原 nonce 直接当作日志落盘；SessionLedger 编码只保存摘要，不包含 nonce 原文。摘要也不是签名或授权证明，不能公开后当作安全凭据。

### 绑定不等于业务授权

bindingHash 由 Host 定义其规范化输入并负责真实匹配，SDK 只验证 hash 格式与 permit 一致。它不认证调用方身份、Run lease、P4 剩余额度或 Effect 是否已收口。prepare 与 consume 之间的业务事实可能变化，**Host 在消费事务仍需复核实际授权/资源版本/Effect 条件**，不能因为 permit 存在就跳过安全检查。应将可变化事实纳入 Host 事务/版本屏障；当前 permit 没有自动有效期与过期时钟，需时间限制的 Host 必须另行校验或撤销。

P3 的 ready 仅适用从未开始的续执行收口，并不自动授权这里的 continuation。SDK 不把多个独立 Store 调用当作跨表原子事务；Run终态/lease与session终态/序列是不同层，续session不意味着Run可复活或预算可重置。P5 的跨代对账需独立调用工作账本对账能力；新增 session 本身不会处理旧页。

### 编码与恢复

Session 与 Ledger 编码使用 schemaVersion=1，解码重新计算 admissionHash，核对序列连续、Run/身份一致、历史状态、permit绑定、nonce摘要及revision计数，不通过就拒绝。两种业务 payload（结构化文本与二进制）均可复用。解码校验不提供抗恶意篡改或旧快照回滚证明；Host 必须保护持久化事实，不能删除nonce墓碑后复用许可。

独立序列化测试 Host 使用自己的编码行和原子更新，不包装内存参考 Store，但仍不等于生产数据库验收。完整历史与nonce墓碑会增长，整体规模/归档/跨进程耐久性需Host独立设计，不能直接清空墓碑释放空间而破坏一次性保证。

## Agent Step

`BoneWorkflowAgentStepController` 在每次 inference response 和每个 Tool result 后先提交 checkpoint，再发布安全事件并进入下一项工作。授权等待、pause、resume、cancel、成功、失败和取消终态都可恢复；事件不是持久事实源。Agent 运行统一由 `BoneAgent.run` 提供。

## 副作用

有副作用的 Tool 遵循：

```text
Effect Intent
→ stable idempotency key
→ Authorization revalidation
→ Execute
→ Effect Receipt
→ atomic step commit
```

策略包括 naturallyIdempotent、idempotencyKeyRequired、reconcilable、compensatable、nonRecoverableRequiresUserDecision。副作用可能成功但 Receipt/Checkpoint 尚未写入的窗口必须先 reconcile，不能盲目重跑。无法查询的外部系统进入 `outcomeUnknown / recoveryRequired`；Kit 不保证 exactly-once。

cancel 意图必须先持久化。执行前可以取消；进入不可取消副作用提交区后必须完成 Receipt 或对账。App 被系统终止不会自动后台永久运行，下次启动 acquireLease 后恢复。

## 未知副作用与授权终止的错误处理

高风险 Tool 越过 `executionStarted` 后抛错（包括取消），管线返回 `outcomeUnknown`，Agent 返回 `toolOutcomeUnknown`；Tool 已返回但 Receipt 写入或提交未确认，分别返回 `recoveryRequired` / `toolRecoveryRequired`。Tool 已执行并返回、失败只发生在 Agent Step 结果提交或组装时，同样返回 `toolRecoveryRequired`，不得报成 Tool 执行失败。这些错误不会被 `collectAll` 收集，必须停止后继工具与推理。Host 使用原 Effect identity 读取事实并先 reconcile，禁止把它们映射成“确定未执行”后创建新 identity 重试。

等待授权的 Step 可以取消或失败，终态 checkpoint 会清除 ticket 并在提交前校验。waiting 不能直接 `finish(.succeeded)`；必须先通过匹配 ticket 的 `resumeAfterAuthorization`，再进入成功路径。取消后的迟到 progress 不可复活终态。


## 预算和取消边界

Agent 在 inference 开始前原子预留 turn 与调用/输入/费用额度，Tool 开始前原子预留累计额度和并发槽位；拒绝不消耗部分额度，已接受的尝试不退款，仅释放在途槽位。legacy 单 Tool 与多 Tool 路径均遵守 `afterFirstToolTurn`，返回后复查取消及截止，拒绝迟到业务结果。

wall-clock 使用单调时钟，是操作边界上的协作截止；等于上限允许，超过拒绝。不会硬终止挂起的 Host，也不会中断必要的 Receipt 提交。成功线性化点为开始投递 succeeded 事件，不因事件接收期间超时撤销已发布成功。

## SDK 契约验证范围

PersistenceContractTests、AuthorizationContractTests、WorkflowRecoveryTests 验证内存原子 snapshot/CAS/generation fencing、Grant 多维绑定与单次消费、Intent 到 Receipt/commit 的故障窗口和恢复决策。恢复依赖事实而非事件是否已交付，不保证 exactly-once。

内存 Persistence 没有 lease 到期时间接口，测试只验证 generation 接管，不能替代 Host 的真实 lease expiry 验收。CrashHarness 为故障注入，不是真实进程 kill；数据库事务、断电/跨进程持久性、外部查询延迟与补偿失败仍需 Host 验收。对账由 Host 执行，SDK 提供恢复决策。


## Host 所有权与验收边界

`BoneWorkflowPersistence.acquireLease` 当前表达基于 revision CAS 的 generation 接管，不包含 owner、时间有效期或续租接口。Host 必须另行决定谁有权接管以及何时允许接管；generation 用于拒绝旧 worker，不能替代这一所有权策略。验收套件不会把 generation 递增声称为 lease 到期验证，也不修改 Core 接口。

可用 `BoneWorkflowPersistenceContractSuite` 验证 Adapter 的快照提交、CAS 和 fencing 行为，接入方式见 [Testing](Testing.md)。Intent/Receipt 的真实进程崩溃恢复、数据库事务、租约有效期与外部副作用对账仍需独立 Host 验收；首批套件未覆盖 Effect Store，不承诺 exactly-once 或自动重试未知副作用。

## Agent Step 提交边界

`runWorkflowStep` 持有 Agent 运行所有权直到最终 checkpoint 提交及事件投递结束。重复调用返回 `runAlreadyInProgress`，不修改原 Step；progress sink 必须绑定同一个 Controller。

Tool 的 `toolOutcomeUnknown` 或 `toolRecoveryRequired` 不得写成普通失败。`requireRecovery()` 写入 `commitUncertain`，保留 `terminalState == nil` 并发布 `recoveryRequired` 事件。若提交失败仍返回原恢复错误，不能仅按旧 checkpoint 的 running 状态重跑。

Store 提交抛错（包括取消）或返回无效回执后，Controller 保留最后确认的快照并阻止后继写入。直接方法保留 Store 错误，标准 progress sink 映射为 `toolRecoveryRequired`。Host 必须读取持久化事实、核对 lease/revision 并重建 Controller，不能盲写 failed/cancelled 或重执行 Tool。已确认取消优先于迟到 progress；真实副作用未知仍保留恢复分类。

`.skipped`、成功、失败、取消及 `commitUncertain` 都不能由原 Controller 继续推进；恢复/重试由 Host 明确调和并管理 Attempt。
