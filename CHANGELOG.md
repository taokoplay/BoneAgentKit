# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本采用 SemVer。

## [Unreleased]

### Fixed

- 明确持久化 payload 的业务 schema 不透明与 JSON/分级限制；create 保存任意初始 generation，acquireLease 保持非幂等 CAS 换代及溢出原子拒绝。Core 实现与协议签名不变。

- `runWorkflowStep` 运行所有权覆盖最终 checkpoint 提交；重复/重入调用不再将正在运行的 Step 写成失败。
- 恢复必需错误保留原分类，可提交时写 `commitUncertain`。最终提交失败不再补写另一终态；中途提交异常/无效回执后 Controller 阻止后继盲写，Host 必须重读后重建。已确认取消及迟到 progress 的 CAS 冲突仍传播取消。
- `.skipped` Step 不再允许通过 Controller 改写为其他终态。
- Gemini 无原生 call ID 时使用响应级唯一命名空间，流事件与最终响应共享 ID；有界 opaque continuation 累积签名轮次，后续无签名轮次及 stop 不清空旧签名，旧单轮 envelope 仍可读。
- Gemini 缺省/null usage 保持未知，非法载荷拒绝；签名元数据不计正式 blocks，thought functionCall 与混合 text/functionCall 在文本合并前拒绝。

### Added

- 工作账本增加独立可选跨代对账能力：精确绑定旧页与当前接管代/账本revision，显式写回Host确认的失败或成功结果并保留审计引用；不放宽普通Worker围栏，不重置页号/预算。
- 八场景跨代工作对账契约和独立日志Host回归，检查目标隔离、响应保真、并发CAS、进度保留及提交回执未知窗口。

- 通用执行会话信封与continuation ledger/store：opaque admission精确hash、零基连续sequence、稳定operation/effect绑定、先准备后原子消费nonce许可；撤销仍保留nonce墓碑，领域payload留Host。
- 五场景session契约、独立序列化Host及两种payload复用回归，覆盖准入绑定、一次性nonce、并发消费者、编码验证与提交未知窗口。

- 可分页/可拆分 `BoneWorkflowWorkLedger`、原子 Store 协议及内存参考：请求页唯一、在途 preflight、knownFailure 保持 partial、split 父终止与子创建原子化、Run级 revision/lease 围栏。
- 七场景工作账本契约及独立编码命令日志测试 Host，覆盖旧 lease 回写、重复页与非法拆分拒绝；payload/cursor/response/artifact 为不透明 Data。

- Run 级持久预算值类型、原子预留 Store 协议与内存参考实现：跨 session 保留起点/截止/已用额度，final 阶段保留，used/attempted 分离，已预留失败请求不退款。
- 双 wall/uptime 与 boot 身份检查，回拨/epoch漂移/截止永久 fail-closed；策略和版本漂移拒绝，编码 schema 校验。新增七场景预算契约及独立序列化连接模拟。

- `BoneWorkflowCancellationReadiness`：只读的未启动续执行收口判定，历史 unknown/未提交 Effect、当前 session Effect、缺证据或 stage 活动 fail-closed，不从“无 Worker”推断停止。
- 一致事实查询协议与版本绑定 evaluation、十一场景契约套件，检查判定不改写已应用结果；Host 领域扩展只有额外否决权。

- 可选 `BoneWorkflowRecoveryScan` 与可信快照/隔离计数结果，内存参考实现支持完整只读扫描；包含 recoveryRequired 发现，不改变终态迁移权限。
- 恢复扫描四场景契约套件及坏行注入 fixture，独立序列化测试 Host 覆盖解码损坏、快照不一致、计数/只读负例；补充 Host 业务索引与原子绑定推荐 seam。

- `BoneWorkflowRunController`：协议驱动的 Run 控制面，显式 revision/generation CAS，开始与暂停后恢复先换 lease，暂停/恢复双 fencing；取消意图、Worker 停止请求与终态协调分离。
- `BoneWorkflowRunControllerContractSuite`：五项必需控制面场景，内存参考实现与独立序列化测试 Host 回归；补充提交未知、无效回执、暂停中途失败、旧 Worker 和并发启动测试。

- 持久化契约套件新增 `opaqueCheckpointPayload` 与 `creationLeaseGeneration` 两个必需场景，覆盖字节保真、JSON fragments、两类合法数据分级、初始 generation 与溢出边界。
- 新增 `seedCreateRejected`、`seedLoadFailed`、`opaquePayloadRejected`、`creationGenerationRejected` 脱敏失败阶段分类，避免初始化异常被误读为 CAS/fencing 本身失败；不根据底层 Error 猜测 Host schema。

- `BoneWorkflowAgentStepController.requireRecovery()` 和 `BoneWorkflowAgentStepEventKind.recoveryRequired`，提交 `commitUncertain` 并发布安全事件。
- Workflow wrapper、真实 Effect pipeline、checkpoint 故障/取消交错，以及 Gemini 多轮/签名/ID/用量/累计容量回归测试。

### Migration

- Session prepare/consume不认证业务授权或自动取得Run lease。Host需在消费事务复核实际安全事实，并保留nonce墓碑；Hash不替代签名，不能把新session当预算重置或未知Effect恢复。新信封/ledger编码schemaVersion=1，未知版本拒绝。

- 工作账本页号是请求尝试序号，失败不退号，cursor 保留业务续页语义。新 generation 不清除或冒认旧在途请求；knownFailure 需明确事实，不得从超时/无 Worker 推断。Run级 CAS 会让同Run并发单元竞争；预算/Run/工作账本跨表事务由 Host 负责。

- 新 durable 预算不自动替换进程内 Meter。Host 必须原子保存每次预留，包括业务拒绝的 attempt/revision；提交未知不自动重试。新预算达到截止即拒绝，clock异常不恢复，同Run策略/版本变更不重置额度；真实持久层和设备时钟须独立验收。

- 取消判定 ready 不是已停止或已提交终态：Host 必须用覆盖 session/Effect/stage/preflight 的独立 evidenceRevision 在最终事务复核，不能只凭 Run CAS 收口。query 错误不降级为空历史或默认通过，unknown 不得映射为 committed。

- 恢复扫描不扩展 Persistence 必需方法；Host 可选接入。结果必须是同一授权 scope 的完整一致快照，不得静默分页截断或把基础设施异常算成坏行。隔离不自动删除/修复；真实数据库与权限边界仍需验收。

- Run Controller 是可选组合入口，不自动替换 Host 实现。Host 需传入预期 revision，使用操作返回的新 generation，并自行处理授权、业务状态映射、Worker 与 Effect 对账；`requestCancellation` 返回持久意图快照，不表示执行已停止。
- 控制面多步过程非整体事务，异常后无自动重试/回滚。Host 必须重读调和；恢复只换 lease 不改 checkpoint，未覆盖外部预算表、业务原子绑定或恢复扫描。独立序列化测试 Host 不代表真实第二 App/数据库验收。

- 持久化契约场景从 6 增至 8，内存参考实现预期 6 passed / 2 skipped；场景与失败枚举的穷尽 switch、固定数量断言、报告消费者及差距守卫需同步。opaque payload 是必需契约，不新增可跳过 capability。
- Host 应将 typed payload 校验移出通用 Store，并移除 Store 层 generation 必须为 0 的限制；业务层仍可限定新 Run 的初值。旧行兼容／迁移由 Host 负责，Kit 不自动改写数据。

- Host 对 `BoneWorkflowAgentStepEventKind` 的穷尽 switch 需处理新增 `recoveryRequired`；它不是业务成功/失败终态。
- `progressSink()` 将已尝试但未确认的 Store 提交映射为 `toolRecoveryRequired`；直接 Controller 操作保留原 Store 错误，但同一实例禁止后继写入。Host 必须重读/调和，不得自动重试 Tool。
- Gemini fallback call ID 是不透明标识，不能依赖旧编号形态。continuation 累计上限仍为 256 KiB，不得记日志或存入普通 checkpoint；绑定不认证 user/tool-result 正文。
- 本轮为本地正确性修复，不代表真实 Host、数据库、Provider、真机或最低 Swift 5.9 已完成生产验收。

## [0.2.0-alpha.17] - 2026-09-19

### Added

- Agent 新增 Run 终态模型使用快照：`BoneAgentRunModelSnapshot` 记录实际请求的模型 ID、模型显示名与别名、Provider 种类、调用方式、门禁解析出的能力与证据来源、带来源的上下文限制、生成参数回显、服务端推理策略、终态与用量计数。
- `BoneAgentModelSnapshotSink` 在 Run 终态确定之后、返回值或错误抛出之前投递且只投递一次；`BoneAgentModelSnapshotContext` 按 Run 注入 Kit 无法从 Engine 协议推断的模型元数据，未提供字段保持未知。
- Kit 只交付快照：不落盘、不跨 Run 聚合会话，也不包含 Prompt、响应正文、Tool 参数与结果、凭据、完整 Provider UUID 或敏感 URL；唯一允许出现的 URL 是 Host 声明的公开厂商文档地址（`contextLimits.documentationURL`）。
- 快照携带 `schemaVersion`（当前 1）并定下格式演化约定：新增字段一律 `decodeIfPresent` 加显式默认、不改变已有字段语义，读取更高版本 fail closed。

### Fixed

- 快照的 `finishReason` 改为只跟随最后一次响应：legacy 单结果形态不携带终止原因时重置为 nil，不再保留上一次 Assistant Turn 的值。本地 Tool Envelope 在同一 Run 内混用两种形态时会触发旧行为。
- 已交付响应的事实（响应数、终止原因、用量）改为在取消、预算与 checkpoint 判定之前记录，checkpoint 提交失败不再把已计费的调用记成 0。
- Tool 结果数改为在结果受理时上报，发布中途失败不再丢失已执行的 Tool 计数。
- usage 合计改用饱和加法，溢出不再回绕成看起来合法的负数。
- 控制面失败分类收敛：Tool 已执行并返回、失败只发生在 Agent Step 结果提交或组装时，Agent 返回 `toolRecoveryRequired`（原先在 assistantTurn 路径报 `toolExecutionFailed`、在 legacy 路径报 `inferenceFailed`）；预执行控制面拒绝（授权、Schema 或 Effect Intent 未持久化）保持 `toolExecutionFailed`。
- OpenAI 兼容非流式 Tool 响应在命中 `finish_reason=length` 时先报 `outputTruncated`：输出预算耗尽且没有任何 tool call 的常见形态不再被误报成 `invalidResponse`，参数 JSON 被截断时也不再报成协议形态错误。
- Anthropic 非流式 Tool 响应的截断判定提前到内容块形态校验之前，并不再受 `hasCalls` 分支影响：`stop_reason` 为 `max_tokens` / `max_output_tokens` 时，无论是否带 `tool_use`、是否只剩 thinking 块、是否没有可交付内容块，一律报 `outputTruncated`，不再被吞成成功轮次（`.other(providerCode: "max_tokens")`）或 `invalidResponse`。
- HTTP 403 不再归类为 `invalidCredential`：403 也可能来自网关、WAF、路由或风控，现在保留为 `httpStatus(403)`；只有 401 视为凭据错误。

### Testing

- 新增模型快照回归：投递早于结果、失败与取消仍产出快照、用量合计保持未知语义、能力门禁拒绝时不产出快照、快照不含 Prompt 与 Tool 参数正文、显示名与别名只做空白归一、混合响应形态不复用陈旧终止原因、checkpoint 失败保留已交付响应、Tool 结果部分发布失败仍计数、取消后仍统计已交付响应、stepLimitReached 与 afterFirstToolTurn 终态、编码键集合等于白名单、Codable 往返不持久化派生合计、`schemaVersion` 写入与未知或缺失版本 fail closed。
- 新增非流式 Tool 截断回归：两协议覆盖无 tool call、带完整 tool call、被截断的参数、仅 thinking 块、空内容块；并把 OpenAI、Anthropic、Gemini 输出约束测试中的 `invalidResponse || outputTruncated` 松断言改为逐载荷精确期望。
- 新增 Tool 结果提交失败回归：assistantTurn 与 legacy 单 Tool 两条路径均断言 `toolRecoveryRequired`，且已执行 Tool 仍计入快照。
- 480 项严格 Swift 6 测试通过。

### Migration

- `BoneAgent` 两个初始化方法、`run(modelID:messages:)`、`run(request:)`、`runUntilBoundary(request:boundary:)` 和 `runWorkflowStep(modelID:messages:controller:)` 追加带默认值的 `snapshotContext:` 与 `modelSnapshotSink:` 参数，普通源码调用保持兼容。
- 能力门禁之前的拒绝（`runAlreadyInProgress`、`unsupportedCapability`、`invalidMaximumSteps`）不产出快照：此时还没有可记录的模型事实。
- 新增默认参数后，旧签名不再是协议 witness：把 `run(modelID:messages:)` 之类签名抽成协议并要求 `BoneAgent` 满足的 Host 需要同步更新协议要求（普通带标签调用不受影响）。
- 错误分类变化：命中 `max_tokens` 的非流式 Tool 响应现在报 `outputTruncated`，HTTP 403 现在报 `httpStatus(403)`。调用方若按 `invalidResponse` 或 `invalidCredential` 分支处理这两种场景，需要按新分类复核；枚举 case 未增减，既有 switch 保持可编译。
- Anthropic 的 `stop_reason: max_tokens` 且带完整 `tool_use` 的响应此前会作为成功的 Assistant Turn（`.other(providerCode: "max_tokens")`）交付，现在直接抛 `outputTruncated`：经 `BoneAgent` 运行的调用方两种情况下都失败，直接调用 Engine 的调用方需要处理新增的抛出。

### Release scope

- 本版本包含 Run 级模型使用快照（含 `schemaVersion` 与格式演化约定）、Agent 控制面失败分类收敛，以及非流式 Tool 截断判定与 403 分类对齐。
- 480 项严格 Swift 6 测试、公开文档检查、离线 Smoke dry-run 与 diff 检查通过。
- 未发起任何真实 Provider 请求，未完成真机或设备验收；发布检查清单中的真实 Host Debug/Release 构建、Store lease 与跨进程恢复、最低 Swift 5.9 工具链、Provider 资产权利核验仍未关闭，不代表生产准入。

## [0.2.0-alpha.16] - 2026-09-13

### Fixed

- OpenAI Tool 流在语义终态之后拒绝后续 choice（仍允许独立 usage trailer 和 DONE）；Anthropic 在 stop_reason 后拒绝内容块追加，只允许 ping 和 message_stop。非法序列不得进入 Tool 执行。
- Agent 将 Transport cancelled 传播为 CancellationError，发布 cancelled 终态，不再误报 inferenceFailed。
- 安全摘要将非法 completion_tokens_details、functionCall/type 标记 invalid，并将 max_output_tokens 归为 length。
- 新增 alpha.15 定向回归，包含两协议真实 Provider→Agent 的零 Tool 执行断言；未改变重试、Thinking 或超时策略。

### Release scope

- 定向修复版本，不扩展重试、Thinking 或超时策略；正常流与 OpenAI usage trailer 保持兼容。
- 454 项严格 Swift 6 测试通过，包含 alpha.15 定向回归及两协议 Provider→Agent 零 Tool 执行验证。
- 未重新完成 Host 真实 URLSession 取消验收、设备或在线供应商验证；不代表 Agnes 150 秒超时已解决。

## [0.2.0-alpha.15] - 2026-09-13

### Added

- OpenAI Engine 新增与披露独立的服务端推理策略；仅对 Host 明确核验的 Agnes 模型开放 enabled，默认不发字段，不支持策略提前拒绝。

- Agent 新增显式有界缓冲流式模式，URLSession 流增加独立总期限和 Host uptime deadline；不执行分片 Tool、不自动回退或重试。

- OpenAI 兼容、Anthropic 和 Gemini 非流式推理新增默认关闭的安全诊断 sink：解析前响应摘要与调用关联阶段事件，不改变原错误或增加重试。流式及细分失败阶段尚未覆盖。
- 补充 Host 动态模型发现迁移说明，区分目录来源、解析协议与用户配置合并。

### Fixed

- Agent 日志 context 改为惰性构造，响应日志编码失败不影响推理；完整请求载荷需额外启用 includesSensitivePayloads，默认 Debug 仅记录元数据。
- 有效结果日志更名为 inference.result.validated，避免被误认为底层 HTTP 已收齐。

### Testing

- 新增非流式安全诊断、Agent 流式模式、总截止时间及 Thinking 配置回归。
- 新增跨 OpenAI 兼容、Anthropic、Gemini 的离线环境矩阵：正常响应、HTTP 错误、截断、非法正文、断网、超时、取消与敏感 canary；6 个测试方法展开 52 个组合。

### Migration

- Debug 不再自动输出完整请求；受控排障需显式设置 `includesSensitivePayloads: true`。
- 依赖旧日志名的收集器需将 `inference.response.received` 更新为 `inference.result.validated`；需要 HTTP 到达事实时改用安全诊断 sink。
- Agent 流式模式为 opt-in，须提供整体时间边界；Host deadline 使用 systemUptime，不是 Unix 时间。
- 服务端 Thinking 为实例级策略，核验模型集合不能直接由动态发现列表生成。

### Release scope

- 预发布，不承诺生产准入。非流式诊断未覆盖流式摘要、细分失败阶段或业务 Tool 独立计数。
- 流式暂不向 Host 提供逐分片进度；自定义 Engine/Transport 仍需遵守取消与期限契约。
- Agnes Thinking 仅开放有依据的 enabled；disabled、预算/强度及 Anthropic 映射未开放。
- 未进行真实供应商在线调用、真实 Host/设备验收或最低 Swift 5.9 验证；远端 CI 需另外核验。

## [0.2.0-alpha.14] - 2026-09-13

### Changed

- Agnes 改用远端模型列表，移除内置文本与图片模型清单；默认保留国内地址，模型发现跟随 Host 的 Base URL，不使用静态模型回退。
- 新增 `discoverAgnesModels()` 便捷入口；Token 限制继续由 Host 按站点与模型独立配置，发现结果不推断能力或限制。
- 目录版本更新为 7，并补充发现测试、缓存与图片参数迁移说明。

### Release scope

- 预发布版本，未调用真实 Agnes API；真实 Host、线上 Provider、最低 Swift 5.9 工具链与远端 CI 尚待验收。

## [0.2.0-alpha.13] - 2026-09-12

### Added

- 增加可注入日志记录器、级别过滤和显式 Debug 上下文输出，接入部分 Agent 运行与单 Tool 路径；完整请求日志可能含敏感正文，仅用于受控调试。
- MiniMax Anthropic 兼容入口支持显式启用单请求结果 Tool 结构化输出；严格校验结果数量、完成状态和 Schema，不接受文本 JSON 回退、不隐式重试，默认仍拒绝。
- 增加 Anthropic 兼容引擎结构化能力查询，区分普通 Tool、原生 Schema、结果 Tool 与强制选择，并考虑模型 profile 和调用方式。

### Release scope

- 预发布版本，MiniMax 仅完成本地 transport 回归，未完成线上模型 Smoke；不保证模型在 auto 策略下必然调用结果 Tool。
- 真实 Host 验收、最低 Swift 5.9 工具链及远端 CI 需另行核验，不代表生产准入。

### Documentation

- 对齐 Alpha.12 产品介绍、Package 接入版本、Host 验收入口与 API 名称；区分直接 Agent 调用、Workflow 恢复与 Host 所有权责任，追加版本化验证证据并修正生产成熟度表述。

## [0.2.0-alpha.12] - 2026-09-05

### Added

- `BoneAgentTesting` 新增可注入隔离 fixture 的 `BoneWorkflowPersistenceContractSuite`：六个持久化契约探测、固定白名单报告、可选 reopen/独立连接能力及所有退出路径 cleanup。缺能力明确 skipped；不是物理持久性、进程崩溃或 lease 到期认证。
- 补充违约 Adapter 反例，验证 CAS 多赢家、拒绝后部分更新和旧 generation 提交可被检出；Core 协议未变更。

## [0.2.0-alpha.11] - 2026-09-05

### Release scope

- 整合 alpha.10 全部改动与四阶段 SDK 硬化；保持 alpha.9 的命名与 API clean break，不恢复旧别名。
- 预发布包，不代表生产准入：真实 Host/数据库/lease 到期、真机 Runtime、真实 Provider 与最低 Swift 5.9 工具链仍未验收。
- 整合基线通过 397 项严格并发及显式 Swift 6 测试、Release、四库 iOS Simulator SDK 构建、离线 smoke 与文档门禁；远端 CI 结果需另行核验。

### Fixed

- 阶段四：修复 Swift 6 弃用 C 字符串初始化；Smoke 单调计时兼容 iOS 13，不再直接依赖 iOS 16 ContinuousClock。
- 文档版本门禁读取当前版本声明；替换失效 Host 测试命令，新增无凭据 CI 门禁与四库 Simulator 构建。

- 阶段三：预算在推理前预留 turn，工具额度与并发槽位原子预留；legacy 工具边界与取消/协作截止检查统一。
- 普通 OpenAI 文本与受约束文本统一验证终态，拒绝过滤、缺失或未知终态、多 choice、重复 DONE 和 DONE 后数据；SSE EOF 不再补造未完整事件。
- 补充持久化/CAS/generation、授权绑定消费和副作用恢复故障矩阵测试；不代表真实 Host lease expiry/数据库验收。

- 阶段二：下载启动前登记身份，隔离迟到取消/暂停/完成；Task 与流终止传播到底层 URLSession，按累计字节中止超大响应。
- 下载采用独立暂存路径，失败清理本操作文件，启动清理旧 `.partial.download`；空间预检计入安装复制并防止溢出。
- Llama Session 完整推理单 in-flight，取消身份隔离，unload 等待在途 Runtime 和控制调用排空。

- 阶段一生产硬化：Catalog 和 Store 拒绝特殊模型 ID、非法文件名和模型目录/资产符号链接；保留 `.bone-install-staging` 目录及 `.partial` 临时文件后缀；路径检查不替代 Host 文件系统隔离。
- Store 使用目标卷内专用目录中的独立 staging、完整性校验与原子 rename 发布；提交失败保留旧模型和下载源，同一 Store 的安装、删除和启动清理互斥。不承诺断电持久性。
- 高风险 Tool 在执行开始后抛错返回 `outcomeUnknown`，Receipt 记录/提交未确认返回 `recoveryRequired`；Agent 对应 `toolOutcomeUnknown` / `toolRecoveryRequired`，`collectAll` 不收集这些错误，不继续后继 Tool 或 inference。
- 授权等待态允许取消/失败并清除 ticket；checkpoint 提交前验证。等待授权时直接标记成功被拒绝，需先显式完成授权恢复。

### Migration

- `BoneAgent.init` 新增默认 monotonicClock 参数；普通调用兼容，初始化函数引用需核对。
- OpenAI 文本仅接受 stop，length 返回 outputTruncated，其余非法终态返回 invalidResponse。流式还要求 DONE；requiringSingleCompletedChoice=false 不再放宽终态或多 choice。
- SSE 必须有终止空行；不规范兼容服务器可能被拒绝。临时 delta 不代表成功，Host 以 completed 为准。

- Llama 新增 `BoneLlamaAdapterError.busy`；并发请求由 Host 排队/重试。取消后卸载，原生不合作时 unload 仍需等待。
- Catalog/Store 新保留 `.bone-download-staging` ID，以及 `.partial.download` 文件后缀（含大小写变体）；自定义下载 Transport 必须交付指定 destination，cancel 返回后不得再写文件。
- 下载可用空间预检改为两份 Manifest 大小加安全余量；URLSession 字节限制允许系统当前块的超额，不是零超额磁盘配额。

- Host 对 `BoneWorkflowToolExecutionError` 和 `BoneAgentError` 的穷尽 switch 需处理新增恢复分类；使用原 Effect identity 读取持久事实并 reconcile，不创建新 identity 自动重试。
- Host 为每个模型根目录提供一个 Store 所有者；`cleanIncompleteDownloads()` 仅在没有其他 Store/进程/下载正在使用该根时调用。安装可能临时需要额外一份模型空间，须纳入 Host 磁盘预算。

## [0.2.0-alpha.10] - 2026-09-05

### Fixed

- 修复 Llama Direct Enum Probe 的假阴性：Probe 仍使用双分支 Enum Grammar，但现在明确要求模型返回 `ready`，使 Prompt 与精确成功断言一致；Direct JSON Probe 同样明确要求 `ok: true` 并执行 Schema 与目标语义双重后验验证。
- 本地执行身份新增 `probeProtocolVersion = 2`，并将 `BoneLocalExecutionVerificationIdentity.schemaVersion` 提升为 `3`。Alpha.9 及更早 Smoke 身份缺少 Probe 协议版本，因此严格失效并必须重新执行完整 Smoke。
- 新增回归测试，覆盖明确 Probe Prompt、Grammar 内但未被请求的 `not-ready` 分支、集合外输出、无效终止和“全部阶段通过后才返回完整身份”的失败关闭行为。

## [0.2.0-alpha.9] - 2026-09-04

### Changed

- 删除与 module 同名的 `BoneAgentKit` Facade，`BoneAgent` 成为唯一 Agent 运行入口；Workflow 类型统一为 `BoneWorkflow*`。
- 合并两套 Invocation 概念为 `BoneInferenceInvocationMode`，并用 `BufferedStreaming` 区分聚合式流传输与逐事件 Streaming。
- Product/module/test target `BoneAgentLocalRuntime` 改为 `BoneAgentLocalModels`，Probe Adapter abstraction 改为 `BoneLocalModelBackend*`。
- 本地能力证据改为 `BoneLocalExecutionVerificationIdentity`；Grammar Parser 与 Grammar Sampler 分别绑定身份，任一漂移都会撤销高级能力。该身份使用必需的 `schemaVersion = 2` 和严格自定义解码；缺少版本、版本不匹配或包含 Alpha.8 `constraintDecoder*` / `grammarRuntime*` 字段的旧身份一律拒绝，不能静默复用。
- Llama Constraint seam 改为 `BoneLlamaConstraintGenerationRuntime` 与 `BoneLlamaResolvedGenerationControl`；删除旧 Prompt Encoder 和组合 Tool Calling 管线，只保留 canonical Conversation Renderer + Tool Envelope。
- 测试术语改为 `BoneCrashBoundaryHarness` / `boundaryVisited`，基础 Runtime 检查改为 `verifyBasicGeneration()`。
- 本次为 1.0 前 clean break，不保留旧 public typealias、Product/module 或 initializer；保持 Invocation 的 `nonStreaming` / `streaming` Codable raw values 不变。

## [0.2.0-alpha.8] - 2026-09-04

### Added

- 新增显式版本化的 `BoneToolSchemaCanonicalEncoder` 与 Llama Generation Control canonical identity，替代 `String(describing:)`，并避免在身份中保存 Stop、Schema、Grammar 或输出正文。
- 新增受信任的 `BoneLlamaCompiledConstraint`、`BoneLlamaGBNFCompiler` 与 `BoneLlamaCompiledConstraintRuntime`；支持精确 Enum 以及 boolean、无范围 integer/number、无长度 string/enum、无界 array、required-only closed object 和受限 tagged union。
- 新增 UTF-8 增量 Stop Matcher，支持跨 chunk、多字节字符、重叠与前缀 Stop；Generation termination 现在携带实际 Stop Token ID 或 Stop String index。
- Canonical Llama Engine 现可将请求级 `outputConstraint` 编译后交给真实 Grammar Runtime，并在返回后再次执行逐字节 Enum 或完整 JSON Schema 验证。
- Runtime Smoke 现覆盖 constrained Tool 两轮、直接 Enum 与 JSON 输出，并将 Compiler、Canonical 格式、Grammar Runtime、Stop Matcher 和 Termination contract 绑定到执行身份。
- Native Template Runtime 新增 reasoning mode 与 add-generation-prompt 能力协商。

### Changed

- Llama constraint 请求不再允许旧 `BoneLlamaControlledGenerationRuntime` 解释 Schema；必须实现 `BoneLlamaCompiledConstraintRuntime`。Stop-only 请求仍可沿用旧协议。
- `BoneLlamaGenerationTermination.stopToken` / `.stopString` 改为带证据的 `stopToken(id:)` / `stopString(index:)`。Constraint 和 Tool Envelope 继续拒绝截断或模糊的 `runtimeCompleted`。
- Alpha.8 GBNF 首版对 optional properties、开放 `additionalProperties`、字符串/数组长度和数值范围前置拒绝，不做 prompt-only 或宽松降级。

## [0.2.0-alpha.7] - 2026-09-03

### Added

- 新增请求级 `BoneInferenceOutputConstraint` 与 `.constrainedOutput` 能力门禁；未实现约束输出的 Engine 必须在 Provider/Runtime 调用前拒绝，不能静默忽略。
- 新增模板无关的 Llama Conversation、唯一 Renderer、GGUF Native Template Runtime seam，以及显式 Stop/EOG、生成约束和终止原因契约。
- 新增严格判别联合的 `BoneLlamaConstrainedJSONToolEnvelopeCodec`，动态约束当前 Tool Catalog，并在生成后继续执行 Tool、参数 Schema 和调用 ID 校验。
- 新增绑定 Artifact、Runtime、Tokenizer、Template、Generation Control、Tool Envelope、Constraint Decoder 与 Context/Batch 的 `BoneCapabilityVerificationIdentity`。
- 新增云 Provider 专用 `BoneProviderCapabilityVerificationIdentity`、`.providerSmoke` 证据来源及安全的 `BoneLiveConstraintSmoke` 聚合报告；身份绑定 Provider、协议、Endpoint 摘要、API、精确模型、Mapper/Decoder、Constraint 方言和调用模式。
- 新增 OpenAI Chat Completions、Gemini GenerateContent 与 Anthropic Messages 的原生请求级 Output Constraint Adapter；统一使用严格包装 Schema，并在 SDK 边界复验和还原结果。

### Changed

- `BoneLlamaInferenceEngine` 新增 canonical `Build → Render → Tokenize → Plan → Generate → Decode` 路线；alpha.6 的 Prompt Encoder/Tool Calling 初始化入口继续兼容。
- Llama Runtime Probe 可执行受约束 Tool Call 与 Tool Result 续轮 Smoke；截断、模糊终止原因、reasoning 标记、缺少受控 Runtime 或验证身份均失败关闭。Engine 只有在当前 Runtime 身份与 Profile 精确匹配时才保留高级本地能力。
- ChatML Renderer 使用稳定模板 SHA-256，并拒绝消息正文中的保留模板 Token；云端受约束事件流在完整复验前不发布 tentative 正文。
- Live Provider Smoke CLI 改为严格互斥参数解析、精确单变量凭据读取和安全模型 ID 白名单；Provider 身份同时绑定认证模式与脱敏后的语义 Header 配置。
- `.runtimeSmoke` 若要证明 `.toolCalling` 或 `.constrainedOutput`，必须携带完整本地 Runtime 验证身份；`.providerSmoke` 若要证明云端 `.constrainedOutput`，必须携带匹配的 Provider 验证身份。
- `outputConstraint` 首版不能与 structured `responseFormat` 或非空 Tool Catalog 混用；Enum 逐字节精确匹配，JSON Schema 结果不做裁剪、提取或修复。
- 云 Provider 只有官方 kind、受支持方言和精确 Smoke 身份同时匹配时才动态授予 `.constrainedOutput`；兼容端点、仅官方文档证据、流式模式或执行身份漂移均在联网前失败。Bundled Catalog 尚未写入真实 Provider Smoke 身份，因此默认能力不自动启用。

## [0.2.0-alpha.6] - 2026-09-02

### Added

- 新增真实 Tokenizer 驱动的 `BoneLlamaPromptExecutionPlan` 与自动 prefill Token ranges；Prompt 可以安全跨多个 decode batch，输出上限会按剩余 Context 自动收紧。

### Changed

- 收紧 `BoneLlamaRuntime`：Runtime 必须实现真实 `tokenize(prompt:)`，并按 Engine 传入的 execution plan 分片 prefill；Context 超限在原生 decode 前映射为 `.promptTooLong`。

## [0.2.0-alpha.5] - 2026-09-02

### Added

- `BoneLlamaInferenceEngine` 支持显式注入 `BoneLlamaToolCalling` 后按实例声明 `.toolCalling`；新增严格 ChatML + JSON envelope 的 `BoneLlamaJSONToolCallingCodec`，覆盖 Tool schema、并行调用和 Tool Result 续轮，默认仍为 text-only。
- 新增 `BoneModelCapabilityProfile` 与证据来源，供云端 Provider Catalog 和本地模型 Descriptor 可选声明细粒度推理能力；本地 Probe 报告实际验证的 `.text` / `.toolCalling` 能力。

### Changed

- Provider 与 Llama Engine 在模型 Profile 已知时将其与实现能力取交集；`BoneAgent` 在 `runStarted` 前改用请求级 `resolvedCapabilities` 预检。
- 新增公开 `BoneAgentKitVersion` 运行时版本镜像，并通过测试约束 README 与 CHANGELOG 的版本一致性；SwiftPM 发布版本仍以 Git Tag 为准。

## [0.2.0-alpha.4] - 2026-09-01

### Changed

- README 重构为开源 SDK 门面，统一 Product、安装、能力、架构、限制与许可层级；新增分类文档地图。
- 扩展公开说明门禁，检查项目专有术语、本机路径、README 契约、Markdown 相对链接和标题层级。

## [0.2.0-alpha.3] - 2026-09-01

### Changed

- 公开说明改为通用 App Host 边界，不再包含任何调用项目名称或 Host 专有实现细节。

## [0.2.0-alpha.2] - 2026-09-01

### Changed

- BoneAgentKit 源码和文档从 proprietary 许可切换为 `AGPL-3.0-only`。
- Provider 渠道 PNG 与其中涉及的第三方商标明确排除在 AGPL 授权范围外；历史 tag 的许可不追溯变更。

## [0.2.0-alpha.1] - 2026-09-01

### Added

- 新增 `BoneAgentLocalRuntime` Product，提供本地模型 Catalog、多下载源 Artifact、安全安装存储、环境快照与确定性运行规划。
- 新增 actor 下载 Coordinator、可注入 Transport 和默认 URLSession Transport，支持磁盘预检、可信重定向、进度、暂停/恢复/取消及受控多源切换。
- 新增本地模型 Artifact Inspector、Adapter Probe 契约和 metadata/load/smoke 两阶段 Probe Coordinator。
- 新增 `BoneAgentLlama` Product，提供无二进制耦合的 Runtime seam、load/smoke Probe、通用 ChatML encoder 与 text-only `BoneInferenceEngine`。
- `BoneLlamaInferenceEngine` 提供当前模型状态快照和 AsyncStream 实时通知；可选 `BoneLlamaRuntimeStateObserving` 供具体 Runtime 暴露加载、生成、取消、卸载与失败状态。
- `BoneAgentKit` 内置 14 个 Provider 渠道的 42 个 1x/2x/3x PNG，资源实现 Target 不作为独立 Product 暴露。
- `BoneInferenceProviderCatalog.iconData(iconID:scale:)` fail-closed 资源接口与完整性测试。
- Host compatibility manifest。
- 实例与请求级 `BoneResolvedInferenceCapabilities`。
- BoneAgentKit 现代化基线和发布契约。

### Changed

- 推理消息解码改为显式 one-of 校验，同时兼容旧 assistant 文本消息。
- Custom OpenAI-compatible endpoint 不再默认承诺原生结构化输出。
- `.commitUncertain` 可恢复，但禁止自动继续或重试。

### Fixed

- Swift 6 strict concurrency 测试阻断。
- Workflow Step controller 交错运行的身份回归覆盖。
- `BoneInferenceHTTPTransport` 文档边界回归。

## 版本列车

### 0.x-hardening

只交付正确性、恢复语义、安全、严格并发和分发治理；不切换 Host 默认行为。

### 0.x-modularization

只交付 target 拆分与兼容入口；不同时启用 managed context 或本地 Runtime。

### 1.0.0

仅在 hardening、modularization、法律审计、真实 Provider Smoke 和宿主兼容门禁全部通过后签发。
