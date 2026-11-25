# SDK 状态与路线图

本文是 BoneAgentKit 当前交付状态的单一总览，面向接入方、Demo 维护者和发布审核者。状态按四个层级描述，避免把源码存在误读为生产能力已经验收。

- **已实现**：SDK 源码已经具备公开能力。
- **已测试**：有稳定的定向回归或契约测试，并且当前结果通过。
- **Demo 已接入**：至少有一个仓库内 Demo 使用了该能力完成可重复验证。
- **生产待验收**：仍需要真实 Provider、真实数据库、跨进程、重启、真机或性能基线等外部条件。

## 当前结论

BoneAgentKit 已经可以用于接入前期开发、离线验证、Host 集成和受控预发布测试。它还不能被描述为“所有能力均已生产验收”的完整 Agent 平台。生产准入仍取决于接入方完成凭据、数据库、加密、资源配额、崩溃恢复、真实网络和真机验证。

本次提交集中交付 Provider 模型发现和流式事件背压能力。普通 `BoneAgent.run` 的默认行为保持兼容，新的有界观察流采用显式 opt-in。未实现或未验收的能力会在后文单独列出。

本页描述的是当前 `Unreleased` 工作区能力，运行时版本基线仍为 `0.2.0-alpha.30`，当前改动尚未形成新的发布 tag。提交后可使用 `git status --short --branch`、`git rev-parse HEAD` 和 `git show --stat HEAD` 核对实际发布状态。除本次明确列出的文件外，仓库中的生成目录、媒体导出物和嵌套工程不属于本次交付。

### Demo 证据口径

“Demo 已接入”在本页按以下证据理解：SDK 公开契约已由 Demo 调用，且有离线 Engine、Fixture 或自动测试覆盖。它不代表 Demo 已连接真实 Provider，也不代表真机、网络、生产数据库或线上性能已经验收。真实 Provider 路径统一标记为生产待验收。

## 能力矩阵

| 能力 | SDK 状态 | 测试状态 | Demo / Fixture 状态 | 生产边界 |
| --- | --- | --- | --- | --- |
| Agent 普通运行与 Tool Loop | 已实现 | 已测试 | Demo 已接入 | 业务 Tool 的授权、幂等和副作用对账由 Host 负责 |
| Prompt Profile 与角色预设 | 已实现 | 已测试 | Demo 已接入 | 角色内容、业务事实和敏感信息仍由 Host 管理 |
| Provider 目录与模型列表 | 已实现 | 已测试 | Demo 已接入 | 远端目录成功不等于模型能力已验证 |
| OpenAI-compatible 模型发现 | 已实现 | 已测试 | SDK 接入，Fixture / 离线验证 | 真实网关路径、鉴权和限流需要线上 Smoke |
| Anthropic-compatible 模型发现 | 已实现 | 已测试 | SDK 接入，Fixture / 离线验证 | 真实服务端字段和匿名列表行为需要线上 Smoke |
| OpenAI、Anthropic、Gemini 增量流 | 已实现 | 已测试 | SDK 接入，离线 Engine 验证 | 真实网络取消、长时吞吐和设备资源需要验收 |
| `runObservedEvents` 有界观察流 | 已实现 | 已测试 | Demo `--bounded-stream`，合成 Engine 验证 | 逻辑队列有界不等于整个进程 RSS 有界 |
| 本地 Llama Agent 级实时 Token 流 | 未实现 | 未测试 | 未接入 | 当前 runtime 只有整段生成接口 |
| UTF-8、UTF-16、GBK、GB18030 文本读取 | 已实现 | 已测试 | Demo 已接入，离线验证 | 自动探测不会猜测 GBK 或 GB18030，Host 应根据格式结果决定编码 |
| 二进制有界读取 | 已实现 | 已测试 | Demo 已接入，离线验证 | 单页和累计读取预算由 Host 配置 |
| PDF 结构化解析 | 已实现 | 已测试 | Demo 已接入，离线验证 | 解析结果保留结构事实，不保证任意 PDF 完整视觉复刻 |
| PDF 布局读取 | 已实现 | 已测试 | Demo 已接入，离线验证 | 坐标和页面数据预算会影响 CPU、内存和结果体积 |
| PDF OCR | 已实现 | 已测试 | Demo 已接入，离线验证 | 依赖 Apple Vision 与页面渲染，真实设备性能仍需验收 |
| DOCX、XLSX、PPTX 解析 | 已实现 | 已测试 | Demo 已接入，离线验证 | 首期覆盖 OOXML，不覆盖旧式 `.doc`、`.xls`、`.ppt` 完整解析 |
| ZIP、GZIP 安全读取 | 已实现 | 已测试 | Demo 已接入，离线验证 | 解压预算、路径校验和 CRC 校验不会替代业务内容安全审查 |
| 加密 PDF 读取 | 已实现 | 已测试 | Demo 已接入，离线验证 | 密码只由 Host 在单次授权调用中提供，不进入 Tool Schema 或资源引用 |
| ZIP 和旧式 Office 密码解密 | 未实现 | 未测试 | 未接入 | 需要单独的格式、密钥和安全策略设计 |
| Workflow、CAS、lease 与 Effect 边界 | 已实现 | 已测试 | Demo 已接入，内存 Store 验证 | 外部副作用的未知回执仍需 Host 对账 |
| 可恢复 Agent Session 控制面 | 已实现 | 已测试 | Demo 已接入，内存 Store 验证 | 默认仍是 Host Store 接口，数据库和跨进程恢复尚未由 SDK 提供 |
| JSONL 持久化适配器 | 未实现 | 未测试 | 未接入 | 可作为轻量日志或 Demo Store，尚未形成稳定事务契约 |
| SQLite 参考持久化适配器 | 未实现 | 未测试 | 未接入 | 需要并发、事务、迁移、加密和崩溃恢复验收 |
| Blob 与派生视图持久化缓存 | 部分实现 | 部分测试 | Demo 已接入基础资源 Store | 持久派生缓存、GC、quota 和使用量 API 尚未闭环 |
| iOS 新鲜构建与真机权限验收 | 部分实现 | 历史证据 | Demo 已接入 | 本轮没有新的 iOS 构建和真机验收证据 |

## 本次提交范围

本次变更包含以下功能闭环。

### Provider 和模型目录

- 兼容 OpenAI 与 Anthropic 模型列表格式。
- 支持 `id`、`slug`、`name`、`display_name` 等常见字段归一化。
- 支持兼容网关的模型路径 fallback。
- 区分远程发现成功、未请求和传输失败，并在失败时回退内置目录。
- 保留内置模型的显示元数据，不根据新发现的模型名称猜测能力和 Token 限制。
- 将相关默认目录、测试和 Provider 文档同步更新。

模型发现服务不缓存结果，也不写入 Host 数据库。一次请求失败时可以返回带 `discoveryOutcome` 的内置回退列表，Host 必须区分实时发现、缓存展示、真实空列表、网络失败和取消，不能把失败回退当成新发现成功。取消场景在 Host 发布 UI 结果前还需要再次检查任务取消状态。

兼容网关的匿名访问只适用于模型列表 GET。聊天请求仍需对应凭据。模型列表成功只证明模型 ID 可见，不证明套餐权限、Tool Calling、视觉、Structured Output、Reasoning 或上下文限制。

本轮移除智谱内置聊天模型预设，并将 Coding Plan 改为远程目录模式。Host 已保存的旧模型 ID 不应因为本次列表缺少而直接删除，应标记为未发现并保留用户选择、预算和协议配置。发现失败或远程空列表时，Host 应继续保留旧选择，并决定是否允许用户手动填写模型 ID。

### 流式事件和有界观察

- 新增 `BoneBoundedEventStream` 与 `BoneEventBufferLimits`。
- Provider 转换、URLSession SSE 回调和 Agent 观察层都使用显式预算。
- 队列满、单事件超限、非法载荷和消费者取消均有明确结果。
- `BoneAgent.runObservedEvents` 为事件附加 `runID` 和本流 `sequence`。
- 完成结果拥有独立收口槽位，不因正文队列暂满而丢失执行结果。
- OpenAI、Anthropic、Gemini 已接入统一流控协议。
- `WorkflowRunnerDemo --bounded-stream` 覆盖事件序号、状态关联、完成结果和队列峰值。

`runObservedEvents` 只接受文本响应，并要求 Engine 实现 `BoneInferenceFlowControlledEventStreaming`、Transport 实现有界流控路径。仅提供整段 `StreamLoader` 的自定义 Transport 不满足端到端背压条件。队列和网络响应有预算，但 Provider 为终态校验保留的事件聚合数组、SSE 解析器对象、调用方历史、系统缓存和自定义中间队列仍会占用内存，RSS 结论必须使用真实设备和长时运行基线确认。

## 已实现但仍需接入方完成的工作

### 持久化和恢复

SDK 已提供 Session、Snapshot、CAS、lease、Effect Receipt 和恢复边界的协议与控制面。Host 仍需要提供以下实现。

- 加密并认证 Session、Conversation、Snapshot 和敏感 Provider continuation。
- 使用真实数据库完成联合提交，保证 Session、Step checkpoint 和 Snapshot 的 revision 一致。
- 支持独立进程打开同一存储、租约接管和过期判断。
- 对提交结果未知的情况先读取并对账，不自动重放模型或外部副作用。
- 保存文件资源、PDF、Office、OCR、压缩包和二进制内容的引用、版本和游标，不把大正文复制进 Session JSON。

`BoneInMemoryAgentExecutionSessionStore` 和 Demo 内存 Store 只用于合同测试和调用顺序演示，不能作为生产数据库证据。

### 文件资源

文件资源采用原始 Artifact、解析 Derived View 和独立 Tool 三层边界。当前 SDK 已覆盖大文件窗口读取、格式识别、非 UTF-8 转码、Office OOXML、PDF、OCR、压缩包和二进制范围读取。生产 Host 仍应补齐以下能力。

- 持久派生视图缓存和版本清理。
- 资源 GC、磁盘 quota、使用量查询和失败恢复。
- 长文件增量快照与跨重启恢复基线。
- 100 MiB RSS、磁盘占用和并发解析的真实性能基线。
- 旧式 Office、ZIP 密码解密和更多加密格式的明确能力边界。

### Streaming

逻辑队列、单事件载荷和网络总响应都有预算，但这些预算不包含解析器、调用方历史、系统缓存和第三方自定义中间队列。生产 Host 还需要验证。

- 真实 Provider 的首事件、空闲、总超时和取消行为。
- 慢消费者、长响应和多并发 Agent 的峰值 RSS。
- 最低支持系统和真实 iOS 设备上的 URLSession 行为。
- Provider 限流、断网、半帧、连接重建和服务端提前结束。

## 后续开发计划

### P0 交付收口

1. 保持本次 Provider、模型目录和流式背压提交可独立构建。
2. 补充真实 Provider model discovery Smoke，记录状态码、字段形状、鉴权和超时结果，不保存凭据或响应正文。
3. 为模型发现缓存、取消、匿名列表和旧智谱模型保留策略增加 Host 集成验收。
4. 运行公开文档检查、API baseline 检查和最小 Demo 回归。

### P1 持久化适配器

1. 提供 JSONL Store，定位为 Demo、审计日志和轻量单进程恢复适配器。
2. 为 JSONL 增加截断行跳过策略、revision、lease、幂等 receipt 和恢复扫描测试。
3. 提供 SQLite 参考 Store，统一 Session、Step checkpoint 和 Snapshot 的事务提交入口。
4. 增加独立连接、进程重启、崩溃点和迁移测试。
5. 保持大正文使用 Blob，Session 只保存不透明引用。

JSONL 适合追加型日志和小规模单写入者场景。它不能直接替代需要并发事务、条件更新、唯一约束和高可靠崩溃恢复的数据库。下游接入方可以先使用协议，不需要等待 SDK 内置某一种数据库，前提是 Store 实现满足公开 CAS 和恢复契约。

### P2 资源和恢复生产化

1. 增加快照加密、完整性认证和密钥轮换边界。
2. 完成 Effect Receipt 未确认后的业务对账工具。
3. 完成跨进程、重启、崩溃和磁盘损坏测试。
4. 实现快照清理、资源配额和使用量 API。
5. 建立长文件、PDF、Office、OCR 和压缩包的并发性能基线。

### P3 发布验收

1. 完成 iOS 新鲜构建、UI 测试和真机权限验收。
2. 完成真实 Provider 的文本、Tool、Structured Output、Streaming 和错误路径 Smoke。
3. 固定版本、变更记录、迁移说明和回滚方案。
4. 按 [发布检查清单](../RELEASE_CHECKLIST.md) 判断是否可以发布 tag。

## 发布前门禁

发布前至少需要满足以下条件。

- SwiftPM Debug 和 Release 构建通过。
- 完整 SDK 测试零失败，或每一项例外都有明确的已批准记录。
- 公开文档检查、`git diff --check` 和 API baseline 检查通过。
- Demo 的核心流程、资源读取、Session 恢复和有界流回归通过。
- 真实 Provider Smoke 覆盖目标 Provider、模型列表、鉴权、超时和取消。
- Host 持久化通过 CAS、独立连接、重启、崩溃和未知提交对账测试。
- 敏感数据没有进入普通日志、Tool Schema、Session JSON 或测试产物。
- iOS 最低系统、模拟器和真机证据齐全。

## 当前验证证据

截至 2026-11-25，当前工作区已有以下验证结果。

- `swift build` 通过，使用临时 Swift ModuleCache。
- Provider、兼容模型发现、Observed Event、有界事件流和流控推理定向测试共 58 项通过。
- 文件资源平台定向回归 25 项通过，包含 PDF、Office、ZIP/GZIP、二进制读取和编码转换。
- WorkflowRunnerDemo 全量测试已有 243 项通过的记录。
- 完整 SwiftPM 测试共 838 项通过，0 失败。该结果使用受控提升权限和临时 Swift ModuleCache 获得。
- `bash Scripts/check-public-documentation.sh` 通过，`git diff --check` 通过。
- `swift run --package-path Examples/WorkflowRunnerDemo WorkflowRunnerDemo --bounded-stream` 通过，交付 128 个增量事件，事件与状态/Token 身份匹配，队列峰值为 4 个事件。
- 定向测试命令为 `swift test --filter 'BoundedEventStreamTests|CompatibleModelDiscoveryTests|AgentObservedEventTests|FlowControlledInferenceTests'`，完整测试命令为 `swift test`。
- 本轮没有新的 iOS 构建或真机验收证据。
- `omx setup` 在当前机器写入用户目录配置时遇到 `EPERM`，这属于开发环境限制，不代表 SDK 构建失败。

## 文档维护规则

每次新增公开能力时，同时更新本页的能力矩阵、测试证据、Demo 接入状态和生产边界。只有源码、测试、Demo 和所需外部验收都具备证据时，才将状态从“生产待验收”改为可发布结论。
