# Agent Workflow Runner 设计

**Date:** 2026-11-12
**Status:** Draft — 设计提案，尚未实现

本文仅记录公开 SDK 层的设计边界，不包含宿主专有实现或私有记忆；下文的拟新增 API 不构成兼容性承诺。

已提供 [WorkflowRunnerDemo](../../Examples/WorkflowRunnerDemo/README.md) 验证默认/自定义步骤、模式过滤及回执丢失后的受限恢复。原型使用示例内的 `Demo*` 类型与合成模型，仅覆盖本文的部分进程内行为；本设计中的正式 SDK API 仍未实现。

## 目标与首期范围

为 BoneAgentKit 提供可显式启用的默认流程：宿主配置模型、工具、执行限制和持久化后，由 Runner 完成预检、启动、Agent Loop、步骤提交与 Run 收口。宿主也可以替换步骤实现，或直接使用现有公开原语驱动自己的完整流程。

首期只执行一个步骤。默认步骤为 `agent`，内部可进行多轮推理与工具调用；这与多个 Workflow Step 是不同层级。自定义的单步骤可以使用相同 Runner；多个步骤、分支或并行工作流仍由 Host 编排，本提案不把它们包装成已支持的能力。

本设计仅增加装配与流程控制，不提供 Prompt 内容、业务工具、模型选择、数据库或业务验收规则。下文新类型、方法和 checkpoint 编码均属拟新增能力，不是当前可调用的 API。

| 接入方式 | 宿主提供什么 | 谁驱动执行 |
| --- | --- | --- |
| 默认流程 | Engine、Registry、Context、配置、输入引用与 Store | Runner 驱动默认 `agent` 步骤 |
| 自定义单步骤 | 自有 kind/revision 与执行器 | 同一 Runner 驱动，复用状态和提交边界 |
| 自有完整流程 | 自有流程组织与调度 | Host 直接组合 `BoneAgent`、Run/Step Controller 和 Effect 管线 |

## 现有能力与需要补齐的部分

| 当前事实 | 对设计的约束 |
| --- | --- |
| `BoneWorkflowPlan` 保存有序步骤与版本，没有消费整个 Plan 的通用 Runner | 新增驱动器时必须明确支持的 Plan 形状 |
| `BoneAgent.runWorkflowStep` 已负责 Agent 执行及步骤终态提交 | 默认执行器不能在返回后再调用一次 `finish` |
| `BoneAgentConfiguration` 已提供 impact policy、Tool execution pipeline 与 context provider | 复用现有管线；传一个 Authorization Handler 不足以建立授权与副作用事务 |
| Step checkpoint 保存身份、状态、计数和票据，不保存完整推理历史 | 不能凭计数恢复到任意模型或工具调用位置 |
| Run Controller 提供 CAS 与 generation 换代，不提供所有者认证、Worker 管理或任意步骤调度 | 恢复前需要 Host 接管授权；不能把 load 当作获得执行权 |
| `BoneContextTurn` 只允许前置 system 消息 | Prompt 的中途更新不能直接仿照其他运行时追加 system 消息 |

实现依据为 [Agent Loop](../../Sources/BoneAgentKit/Agent/Core/BoneAgent.swift)、[Agent 配置](../../Sources/BoneAgentKit/Agent/Core/BoneAgentConfiguration.swift)、[Run Controller](../../Sources/BoneAgentKit/Workflow/Execution/BoneWorkflowRunController.swift) 和 [Step Controller](../../Sources/BoneAgentKit/Workflow/Steps/BoneWorkflowAgentStep.swift)。当前持久化顺序见 [Workflow 与恢复](../WorkflowAndRecovery.md)。

## Run 模式与能力范围

### 模式是结构化约束

拟新增 `BoneWorkflowRunMode`：

```swift
public enum BoneWorkflowRunMode: String, Codable, Sendable {
    case planning
    case executing
}
```

`planning` 只允许普通公开只读工具，即 `BoneToolImpact.isOrdinaryReadOnly == true`；可以不用工具，只生成文本计划。该限制针对 Tool，不禁止正常模型推理及其计费。读取私有数据、外传、修改状态、购买、发布或权限变化均不属于此默认模式。

`executing` 仍受 Host 能力范围、影响上限、Schema、预算和执行授权约束，不表示全权限或自动批准。需要其他规划权限的 Host 可通过自有执行流程表达，不把 `planning` 这个预设悄悄扩大。

### 能力范围随 Run 冻结

拟新增值类型 `BoneWorkflowRunCapabilities`，由可信 Host 构造，至少包含：

| 字段 | 语义 |
| --- | --- |
| `policyIdentity` / `policyRevision` | Host 为该范围签发的稳定策略身份和版本；不是授权票据 |
| `allowedToolIDs` | 显式工具白名单；空集合代表纯推理，不代表全部工具 |
| `maximumToolImpact` | 六个影响维度的上限，复用 `BoneToolImpact` |

启动时计算：

```text
生效工具 = 已注册工具 ∩ Host 白名单 ∩ Host impact 上限 ∩ 模式允许范围
```

还须与 `BoneAgentConfiguration.toolImpactPolicy` 求交集；各影响维度取更严格的上限，缺省 policy 保持现有的普通公开读取限制。预检只针对生效工具校验 Schema 和能力。注册了写工具但选择 `planning` 时，可以保留可用的读工具；不因无关工具存在而拒绝整个流程。

冻结内容包括 mode、策略身份与版本、生效工具的 ID/version/schemaVersion、影响声明和终态策略。工具 Schema 或语义变化必须通过版本反映；不能在相同版本下更换实现后声称兼容。

### 启动前过滤与执行时复验

预检产出的 Registry 必须只包含生效工具，并同时用于模型可见的工具定义和运行时查找。模型自行生成被过滤工具的 ID 时，查找应拒绝，不能回退到完整 Registry。

每次工具调用仍经过 `BoneAgent` 的影响/Schema 检查与既有执行管线。Host 的资源权限、授权有效期和 generation 在实际执行边界复验；预检成功只证明配置可用，不是永久执行许可。规划阶段生成的文字、工具描述或 Prompt 中的“已授权”都不能改变这些判定。

这些是默认执行器的实现要求。当前 SDK 没有 Run mode 字段，也不会自动构造上述 Registry；需要在实施时增加装配逻辑和对应回归。

## 初始化与公开接口轮廓

以下为接口轮廓，省略实现体及辅助值类型的完整声明。

```swift
public actor BoneAgentWorkflowRunner {
    public init(
        persistence: any BoneWorkflowPersistence,
        executors: BoneWorkflowStepExecutors,
        terminalPolicy: BoneWorkflowTerminalPolicy = .automaticForSingleStep
    )

    public func start(
        plan: BoneWorkflowPlan,
        runID: BoneRunID,
        mode: BoneWorkflowRunMode = .executing,
        capabilities: BoneWorkflowRunCapabilities,
        inputReference: BoneWorkflowContentReference
    ) async throws -> BoneAgentWorkflowRunOutcome

    public func resume(
        runID: BoneRunID,
        expectedRevision: UInt64
    ) async throws -> BoneAgentWorkflowRunOutcome
}
```

- `persistence` 无默认值。宿主可显式传入现有内存 Store；跨进程恢复需要宿主提供耐久实现。
- `inputReference` 是拟新增的不透明内容引用，绑定 Host 私有输入的身份与版本；不携带 Prompt、凭据或 Host 私有存储位置。Host resolver 必须检查范围、版本和权限。
- `start` 的默认 mode 是 `.executing`，仍须显式提供 capabilities。此默认值只作用于新入口，不改变现有 `BoneAgent.run` 行为。
- `resume` 不接收 mode、Plan 或更宽白名单，恢复以保存的绑定为准。
- 同一实例对同一 Run 的并发驱动在任何 `await` 前登记占用并拒绝重复调用；跨实例竞争使用显式 revision CAS。

### Plan 与执行器注册

`BoneWorkflowPlan.agentStep()` 拟生成一个固定 stepID、kind=`agent`、step revision=1 的单步骤 Plan，初始 identity=`bone.agent.step`、workflow revision=1。SDK 不静默更换已发布预设；新形状使用明确的新版本或新 identity，恢复仍使用原冻结 Plan。

`BoneWorkflowStepExecutors` 提供以下装配语义：

| 操作 | 契约 |
| --- | --- |
| `agentStep(executor:)` | 将已配置的默认 Agent 执行器注册为 `agent`；不提供无需 Engine 的静态 `.default` 实例 |
| `registering(kind:revision:executor:)` | 添加 kind/revision；无效 kind、非正版本和重复绑定以错误拒绝 |
| `replacing(kind:revision:executor:)` | 明确替换配置中的实现；语义不兼容时必须用新 revision |
| 分派 | kind 和 revision 都匹配才允许执行；不能只检查 kind 字符串存在 |

执行器接受两个上下文：预检上下文包含拟启动的 mode、capabilities、步骤版本和输入引用；执行上下文额外包含已确认的 Run snapshot、稳定 attemptID、绑定当前 generation 的 Step Controller。这样预检不依赖尚未创建的 Run，也不需要制造临时 controller。

默认执行器工厂接收 Engine、原始 Registry、Context、`BoneAgentConfiguration` 和 Host 输入 resolver。它在预检阶段解析指定版本输入、计算生效 Registry 并执行请求级能力检查；为一次执行构造独立 `BoneAgent(workflowController:)`，再调用 `runWorkflowStep`。不新增一个脱离现有管线的 `authorization:` 参数，也不默认创建 Effect Store。

能力检查使用 Engine 的请求级 resolved capabilities；不能只读声明性的 `nonImageCapabilities`，更不能按模型名推测。输入 resolver 和预检不得发起模型请求、消费授权、执行工具或产生持久业务写入。

### 步骤结果与终态策略

拟新增 `BoneWorkflowStepResult` 表达已确认的步骤终态、等待授权和恢复要求。执行器的返回声明必须与保存的 Step checkpoint 一致；存储写入未确认或已出现 `toolOutcomeUnknown` / `toolRecoveryRequired` 时，即使旧 checkpoint 仍为 running，也必须停止后继执行。

`BoneAgentWorkflowRunOutcome` 区分 completed、failed、cancelled、awaitingHostDecision、waitingForAuthorization、requiresRecovery 与兼容性待处理。未知提交导致无法取得可信最新 snapshot 时抛出错误，不用旧 snapshot 假造确定终态。

| 终态策略 | 行为 |
| --- | --- |
| `automaticForSingleStep` | 仅将确认的 step succeeded/failed/cancelled 映射为 Run completed/failed/cancelled |
| `hostDecided` | 保存步骤事实后返回 awaitingHostDecision，业务验收和 Run 收口由 Host 完成 |

两种策略在首期都拒绝多步骤 Plan，不能因为选择 `hostDecided` 就只运行第一步。自动 completed 只代表该流程执行成功；不代表业务验收、数据库写入或应用层产物已完成。

默认执行器首期不承诺跨进程的交互式授权暂停。自定义执行器可通过 controller 保存 waiting 与票据再返回；Run 级仍保持 running，由步骤状态投影出授权等待。`resume` 不能仅因票据存在就执行或自动消费它。完整 Run 授权等待迁移和私有执行状态恢复留待独立扩展。

## Runner checkpoint 与现有 Store 的关系

模式与执行身份必须持久绑定，不能只存在于 Runner 实例变量中。因此本提案新增 **Runner 自有 JSON payload codec**，不增加 `BoneWorkflowPersistence` 的必需方法，也不改变通用 Store 的 payload 不透明契约。

首期 payload `schemaVersion=1`，外层 descriptor 使用受支持的 formatVersion 并绑定冻结 Plan；payload 至少保存：

- mode、capabilities、生效工具版本绑定和 terminalPolicy；
- stepID、稳定 attemptID，以及现有 `BoneWorkflowAgentStepCheckpoint`；
- 执行阶段 `prepared` / `dispatchPrepared` / `settled`；
- 输入引用及可选输出引用，不保存私有正文。

`prepared` 表示尚未获准进入执行器；Runner 在调用执行器前先提交 `dispatchPrepared`。后者只表示可能已经发起工作，崩溃后不能据此断言请求未发送或工具未执行。该标记覆盖一次步骤调用，不冒充每个模型请求的持久 dispatch 账本。

Runner 提供 `BoneWorkflowAgentStepCheckpointStore` 桥接：读取当前 Run 与 payload，校验 Run revision、generation、stepID、attemptID 和步骤逻辑 revision，把新的步骤状态编码回同一 payload，再通过 `BoneWorkflowPersistence.commit` 原子提交 Run+Checkpoint。Step 的 `persistenceRevision` 是其自身逻辑序列，不等同于 Run revision；其他控制面命令也会推进后者。

首个步骤从 pending 按现有迁移表准备为 ready、再进入 running；每次转换和 generation 绑定须经确认提交后再构造执行 Controller。保存 succeeded/failed/cancelled 时，桥接在同一次 Run+Checkpoint 提交中将执行阶段置为 settled；commitUncertain 保持恢复分类，不视为 settled。

此桥接必须串行化每次 load/commit，拒绝跨 Run、旧 attempt 或旧 generation 的写入。启动换代后，要先将步骤绑定为该次确认的 generation，再创建 Controller；不能使用默认 generation=0 执行工作。旧 Worker 不得从新 snapshot 中取新 generation 冒认当前执行。

这解决的是 **Runner 内部 Run 与步骤元数据的共同保存**。Effect Store、业务写入、私有输入/结果和预算依然有各自的事务边界；不宣称它们自动与 Runner 跨 Store 原子提交。

普通宿主已有的任意 checkpoint payload 不能直接交给 Runner 解码。需要专用 identity、codec 和显式迁移；未知 schemaVersion、格式或绑定不一致时保留原记录并停止。

## 默认执行序列

```text
1. 校验单步骤 Plan、执行器 kind/revision、模式、能力范围与输入引用
2. 计算生效工具，解析固定版本输入，完成能力预检
3. createRun：冻结 Plan 与 Runner payload（prepared）
4. beginExecution：换 lease，再进入 running
5. 绑定本次 generation 与稳定 attempt，提交 dispatchPrepared
6. 执行器创建 Agent + 同一 Step Controller，调用 runWorkflowStep
7. 按已确认步骤事实分类；副作用或提交未知时停止
8. 按冻结的 terminalPolicy 收口 Run 或交回 Host
```

步骤 1–2 失败不得创建 Run、调用模型、执行工具或消费授权。步骤 3 及之后存在“提交已发生但回执丢失”的窗口；包括 `createRun` 抛错也不能保证零写入。停止后以原 runID 重读，不自动生成新 Run 重发。

自动映射通过现有 Run Controller 完成，并绑定本次获准执行的 generation。重读用于检查竞争和提交结果，不允许把读到的新 generation 当作新的执行授权。若 Run 已进入 cancelling、paused 或其他竞争状态，遵守迁移表和实际 Effect 事实，不强行覆盖。

步骤提交成功但 Run 收口失败时，只能补做经核实的收口，不重跑 Agent。即时模型输出通过当前调用返回；恢复时若 Host 未保存可用输出引用，Run 控制面 completed 不代表正文可以取回，不能通过重新请求模型伪造原结果。

## 恢复与模式切换

恢复首先检查 Run/Checkpoint 信封、Runner schemaVersion、冻结 Plan 和执行器支持的 **kind/revision**。拿 checkpoint descriptor 与其自身冻结 Plan 比较只能验证绑定一致，不能证明当前执行器支持旧版本。

| 保存事实 | `resume` 行为 |
| --- | --- |
| completed/failed/cancelled | 只读返回已确认终态，不获取新 lease、不执行步骤 |
| Run recoveryRequired 或 step commitUncertain | 返回 requiresRecovery；不复活终态、不清除未知事实 |
| 未知格式、模式、执行器版本或工具版本不匹配 | 返回兼容性待处理；不改写 Plan、模式或原 payload |
| prepared，Run 为 pending/running，且可证明从未进入执行器 | Host 已授权接管后，pending 使用 beginExecution，running 使用 recover；换代确认后重新解析同一版本输入并复验冻结范围，再绑定新 generation 执行 |
| dispatchPrepared 且步骤未收口 | 返回 requiresRecovery；仅有状态与计数不足以恢复推理历史，不自动重新求值输入后再跑 Agent |
| 步骤终态已确认，Run 尚未收口 | Host 核对 Effect、结果引用和接管权后，仅完成相应 Run 收口 |
| waiting / paused / cancelling 或控制面半完成 | 返回对应等待/待处理结果，由 Host 按既有流程恢复授权、停止和对账；不直接分派 execute |

`expectedRevision` 由 Host 基于重读和接管判断提供，不是 owner 认证。获取 lease 的 CAS 若失败，Runner 结束当前命令，不刷新 revision 循环抢占。接管后仍须把新 generation 传给实际 Effect/业务写入边界，换代本身不会物理停止外部工作。

恢复时当前 Host 策略必须仍允许冻结能力范围。权限被撤销、工具被移除或策略版本变化时停止，不能自动降级后继续，也不能放宽。`planning → executing` 使用新的、显式授权的 Run；旧规划结果可作为有版本的输入引用，不能在原 checkpoint 上改一个 mode 后续跑。

本期不实现中途推理的自动重放或重建。Host 将来提供经认证的私有历史、请求身份和对账准入时，可独立设计恢复扩展，不能把它当作本 Runner 的默认能力。

## 自定义流程的边界

自定义单步骤复用 Runner 提供的 Controller、冻结能力范围和提交桥接。执行器须在外部工作前保存准入事实，不能自行创建另一个 Run、绕过 generation 校验或在返回后继续写步骤状态。自有多步骤驱动器可继续使用现有基础原语，授权与 Effect 规则保持一致。

SDK 不在进程内隔离任意 Host 代码；注册表过滤不能限制一个执行器直接调用操作系统、数据库或隐藏 Service 的行为。自定义执行器必须在其真实操作边界实施同样的 mode/范围约束；宿主提供的工具影响声明和版本也须与实际行为相符。

## 与 Prompt 组装的关系

[Prompt 组装设计](2026-11-12-bone-agent-prompt-compositor-design.md) 可根据冻结 mode 与生效工具生成说明，但文字只是给模型的工作指引。模式限制、预算、Schema、授权和围栏均由结构化代码判定。

Runner 不持有 Prompt 仓库。输入 resolver 取得指定版本内容后可以调用 compositor；在途步骤中不更换 system 前缀。Prompt 版本变化不允许绕过已发生的请求或 Tool 的恢复要求，也不自动授予新的能力。

## 验收与实施顺序

实现前必须把下列场景纳入验收；本次文档修订没有运行这些尚不存在的 Runner 测试。

| 场景 | 验收要求 |
| --- | --- |
| 默认单步骤与自定义单步骤 | 使用相同提交桥接；默认 Agent 不重复 finish；多步骤在任何写入前拒绝 |
| planning 混合注册读写工具 | 只向模型暴露允许工具；伪造写工具调用不执行、无 Effect Intent 或授权消费 |
| 执行模式与私有读取 | 保留 impact policy、资源复验与既有授权管线，不能因 mode=executing 绕过 |
| 模式/策略/工具绑定恢复 | 升级或不同配置不能静默扩权；未知版本拒绝；规划转执行创建新 Run |
| 提交故障 | create、dispatchPrepared、步骤与 Run 终态各窗口丢回执均停止，不补写普通失败 |
| 恢复与并发 | 同实例互斥、跨实例 CAS；恢复用新 lease；旧 generation 写入拒绝 |
| 崩溃时有已执行工具 | 保留 Effect 身份与 requiresRecovery，不因缺少完整历史重新调用 Agent |
| 取消 | 取消意图、停止 Worker、确认终态分开；必要 Receipt/对账不被协作取消跳过 |
| 结果与隐私 | 引用缺失不重算原结果；checkpoint、事件和错误不包含 Prompt/工具正文 |

建议实施顺序：

1. 实现版本化注册表、mode/capabilities 值类型与生效 Registry 装配。
2. 实现 Runner codec 和 Step Store 桥接，先验证 CAS、generation 和丢回执行为。
3. 实现默认执行器与单步骤 start，保留现有 Agent Loop 和 Effect 管线。
4. 实现受限 resume 与结果分类；未知执行只报告恢复要求。
5. 以合成 Engine 改造独立示例并补契约套件，再更新正式接入文档与 API 基线。

本次不实现 Tool execution delegate、动态 DAG、会话模式系统、子代理、插件框架或数据库。任意模型请求的持久调度与授权等待的完整恢复也不在首期范围。

## 参考与设计取舍

前次对 DeepSeek Harness 与 PI-Desktop 安装产物的静态调查，为分层策略和运行模式提供了参考线索，见 [来源登记](../ThirdPartySources.md)。本设计只借鉴“默认装配可替换、模式应由执行代码约束”的通用思路，不复制其插件结构、Prompt、命名组合或实现。

其他运行时的会话日志和缓存策略不等同于本库的 Workflow 恢复保证。此处新增 codec、稳定执行身份和受限恢复规则，是根据本库现有 CAS、Step Controller 与私有内容边界作出的设计决定。
