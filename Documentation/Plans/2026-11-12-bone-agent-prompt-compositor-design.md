# Agent Prompt 组装器设计

**Date:** 2026-11-12
**Status:** Implemented — SDK Profile 与 Demo 接入已落地，本文保留设计边界和后续扩展范围

已提供 [WorkflowRunnerDemo](../../Examples/WorkflowRunnerDemo/README.md) 的 Prompt 原型与自动回归，覆盖替换/追加、稳定排序、数据通道与 UTF-8 容量。正式 SDK 已增加 `BonePromptProfile`，本文中的 `Demo*` 组装器仍保留为更复杂的运行数据实验，不与正式 Profile API 混用。

## 目标

提供一个可选的、确定性的 Prompt 组装器，让 Host 复用分节排序、基础文案替换、附加说明、运行数据渲染与容量校验。模型选择、角色内容、业务 Prompt、指令文件发现和资源权限仍由 Host 决定。

默认交付一套组装规则和空槽位。SDK 不自动注入人格、业务规则或某份隐藏的 system prompt。已有调用方继续直接构造 `BoneInferenceMessage`；只有显式调用 compositor 才会采用本设计。

组装器是纯值处理组件：不持有 Engine、Agent、数据库、文件系统或网络，也不注册工具、不消费授权。本文早期规划中的 `BonePrompt*` 类型已按实际实现收敛为 `BonePromptProfile`、`BonePromptSection` 和 `BonePromptProfileError`。

## 现有约束与参考依据

当前 `BoneInferenceMessageRole` 仅有 system、user、assistant、tool，没有独立 developer 角色。Provider 适配器负责各自的 system 表达；不能把某一供应商的缓存或指令优先级语义当作公共能力。

`BoneContextTurn.split` 只接受前置 system 段，明确拒绝历史中途的 system 消息。Conversation 的私有历史、摘要与 continuation 另有校验和 Host 保管责任，因此组装器不能任意改写在途会话。

相关实现与契约见 [消息模型](../../Sources/BoneAgentKit/Inference/Core/BoneInferenceModels.swift)、[完整 Turn 切分](../../Sources/BoneAgentKit/Inference/Context/BoneContextTurn.swift)、[上下文压缩](../ContextCompaction.md) 和 [会话连续性](../ConversationContinuity.md)。

DeepSeek Harness 与 PI-Desktop 的静态调查提供了“分节装配、替换与追加分开、运行事实独立处理”的参考线索，登记在 [第三方参考来源](../ThirdPartySources.md)。本文依据本库的消息角色与持久化边界独立设计，不移植对方的 Prompt、编号表、文件约定或插件体系。

## 职责边界

| 内容 | SDK 负责 | Host 负责 |
| --- | --- | --- |
| 文本装配 | 固定槽位、稳定排序、重复检查、容量拒绝 | 指令内容、版本和可信来源 |
| 运行指引 | 提供受控槽位 | 按当前真实 mode、工具范围与资源权限生成说明 |
| 模式与权限 | 不在 Prompt 内裁决 | 通过 Runner/Tool policy/Effect 管线实施 |
| 项目文件与 Skill | 不自动扫描或加载 | 发现、读取、信任判定及按需加载 |
| 私有内容 | 只处理调用方显式传入的值 | 存储、保护、范围检查、引用和保留策略 |
| 会话更新 | 每次返回独立组装结果 | 在安全边界选择新版本并处理 continuation |

正文中的“排序”只决定输出顺序。同角色内的章节先后不是模型一定遵守的权限或优先级保证；标题、来源标签和“后者优先”等文字不能授予工具访问权。

## 三个指令槽位

| 槽位 | 顺序 | 内容与变更方式 |
| --- | --- | --- |
| `base` | 第一段 | Host 提供的基础指令；可保留默认值，也可整体替换或显式清空 |
| `runtimeGuidance` | 第二段 | Host 根据生效工具、运行模式等事实生成的可信指引；独立于 base 替换 |
| `append` | 第三段 | Host 追加的项目说明或补充约定；不隐式替换前两段 |

每个槽位接收 `[BonePromptSection]`，每节包含：

- `id`：稳定标识，1–128 个 ASCII 字符，允许字母、数字、点、下划线和短横线；不能放用户内容、路径或业务正文。
- `revision`：大于 0 的内容版本；修改正文或语义时由 Host 推进。
- `order`：槽位内的整数排序值。
- `text`：原始指令文本，保留其 UTF-8 内容。

先按固定槽位顺序，再按 `(order, id 的 ASCII 顺序)` 排序；不使用文件发现顺序、注册顺序或本地化排序。同一组生效输入即使以不同顺序注册，也必须得到相同输出。

生效 section 的 ID 在三个槽位中必须全局唯一。重复 ID、空 ID、无效版本或空正文都报错，不按“最后一个赢”覆盖。未被选中的默认 base 不参与生效集合去重和容量计算。

输出采用版本化的固定标题和分隔符，例如 `## host.instructions` 后接换行与正文。标题只使用已校验的 ID；不 trim 正文或偷偷规范化换行。渲染格式变化需要推进组装格式版本并验收。

## 替换与追加的精确语义

拟新增 `BonePromptBaseOverride`：

```swift
public enum BonePromptBaseOverride: Sendable {
    case inherit
    case replace([BonePromptSection])
}
```

| 输入 | 结果 |
| --- | --- |
| `.inherit` | 使用 Host 提供的 `defaultBase` |
| `.replace([section])` | 只使用替换后的基础指令，不再拼接 defaultBase |
| `.replace([])` | 明确清空 base，仍保留 runtimeGuidance 与 append |
| 非空 append | 在前两槽位之后添加；不改变任何工具权限或运行状态 |
| 全部槽位为空 | 不生成 system 消息 |

基础文案、运行指引和追加说明都是调用方显式提供的内容。replace 不会删除实际代码中的 impact policy、预算或授权检查；append 即使要求忽略某项规则，也不能改变代码判断。

若 Host 希望“用自己的全部体系”，可以传入自己的三个槽位，也可继续自行构造消息而不使用此组装器。SDK 不要求读取特定名称的指令文件。

## 运行事实与非指令数据

目录、工具结果、搜索摘录、项目文件正文、会话摘要和用户提供的材料，不因带有文件名或来源标签就成为可信 system 指令。它们应沿用 user/tool 数据通道；已存在的 Tool call/result 绑定保持不变。

拟新增 `BonePromptRuntimeFact` 表达由 Host 选出的少量运行数据，包含受限的 `id`、不透明 `sourceID`、可选版本与字符串 `value`。数据只能来自当前 scope 内允许提供给模型的内容；来源标签是可追溯元数据，不是可信性认证。

组装器将显式传入的 facts 渲染成固定格式的 JSON 数据块，字段排序固定，字符串使用 JSON 转义，重复 ID 直接拒绝。数据块的固定外壳说明这些字段是当前请求的参考数据，不是新的指令或授权。外壳和转义后的全部字节计入运行数据上限。

输出的 `runtimeDataText` 由 Host 作为文本 part 加入 **当前用户请求**，保留其已有图片等其他 parts；不另造一个 system 消息，也不插进未完成的 Tool 交换。这样动态事实与当前任务属于同一 User Turn，不会在裁剪历史时意外把事实与任务拆开。

用户的任务文字也可能包含指令，但 facts 部分仍按数据对待。组装器不认证内容、不承诺消除 Prompt injection；真正的执行限制继续由工具和资源边界实施。

### 项目指令与 Skill 的接入

Host 若把某个项目文件作为长期指令，必须先完成路径范围和信任判断，再转换成有身份和版本的 `BonePromptSection`。SDK 不根据文件名、所在目录或 frontmatter 自动授予指令地位。

工具定义仍通过 `availableTools` 的结构化字段提供；runtimeGuidance 只描述当前生效工具的使用方式，不能出现被过滤工具的可用声明。Skill 首期只允许 Host 选择性提供目录元数据或已批准内容；按需发现/加载、更新推送及 Skill 执行机制均不在本提案中实现。

## API 轮廓与输出

以下只展示关键方法和结果字段，省略构造器及实现体：

```swift
public struct BonePromptComposition: Sendable {
    public let formatVersion: UInt64
    public let systemMessages: [BoneInferenceMessage]
    public let runtimeDataText: String?
    public let sectionManifest: [BonePromptSectionMetadata]
    public let systemUTF8ByteCount: Int
    public let runtimeUTF8ByteCount: Int
}

public struct BonePromptCompositor: Sendable {
    public init()

    public func compose(
        profile: BonePromptProfile,
        runtimeFacts: [BonePromptRuntimeFact],
        limits: BonePromptCompositionLimits
    ) throws -> BonePromptComposition
}
```

`BonePromptProfile` 包含 defaultBase、baseOverride、runtimeGuidance 和 append。`BonePromptCompositionLimits` 要求显式、正数的 system 和 runtime 数据字节上限；不复制参考产品的某个固定容量作为 SDK 通用默认值。

有指令时，首期只生成一个前置 system 消息，内部按三个槽位渲染。无指令则返回空数组；没有 facts 时 `runtimeDataText=nil`。组装器不添加用户任务、不合并任意历史，也不处理 Tool arguments 或 Tool result 信封。

`sectionManifest` 只包含受限 ID、revision、槽位、order 与渲染字节数，便于检查实际采用了哪些节；它不包含正文、来源文件路径或 Prompt 摘要。各段 manifest 的字节数包含该段标题和分隔符，之和应等于 systemUTF8ByteCount。

输出值本身包含私有 Prompt，不能整体写入通用日志。manifest 也不自动落盘；ID 必须由 Host 保持为非敏感标识。正文变化检测不能只靠 manifest：Host 应核对私有版本绑定与实际内容，不能在相同 revision 下改字节后继续沿用旧会话状态。

## 处理顺序与错误

```text
1. 选择 inherit 或 replace 后的生效 base
2. 校验生效 section、facts 与容量配置
3. 按固定槽位和排序键排列 section；按 fact ID 排列 facts
4. 渲染 system 文本和运行数据文本
5. 对最终 UTF-8 字节数做容量检查
6. 返回独立消息、数据文本和无正文的 manifest
```

| 条件 | 行为 |
| --- | --- |
| 非法 ID、重复 ID、无效 revision、空 section 正文 | 抛出固定分类错误，不隐式去重或忽略 |
| 上限非法或累计大小溢出 | 拒绝组装 |
| 最终渲染超出任一上限 | 拒绝本次组装，不截断指令、不退回默认 base |
| 输入内容含引号、换行或类似数据块结束标记 | 按字符串数据转义，不将其解析为槽位配置 |
| Host 文件读取或权限检查失败 | 在调用 compositor 前向上报告，不伪造空文件或成功加载 |

容量按 UTF-8 字节计算，含标题、分隔符、JSON 外壳和转义开销；不按 Swift 字符数推算。整个模型请求仍由现有 Context Planner/模型限制校验，组装器通过不表示 Token 预算充足。

错误只携带固定类别、受限 section/fact ID 和数值，不包含正文、凭据、绝对路径或原始文件错误文本。组装无副作用：失败不会修改 profile、既有消息、会话历史或 Run 状态。

## 与 Agent、Runner 和会话的组合

### 一次新的 Agent 请求

Host 先确定生效工具与 mode，生成相应 runtimeGuidance，再调用 compositor。将 `systemMessages` 放在新请求头部，把 runtimeDataText 纳入当前 user message，最后交给现有 `BoneAgent.run` 或默认执行器。后续仍执行 Schema、能力、预算与授权检查。

组装器首期不增加 `BoneAgentBuilder.withPrompt` 等隐式入口。这样已有输入契约保持清楚，也可在不使用 Agent 的普通推理请求中复用纯组装功能。

### Runner 输入版本绑定

[Runner 设计](2026-11-12-bone-agent-workflow-runner-design.md) 中的输入引用应由 Host 绑定所用 profile、事实数据及模型输入的私有版本。checkpoint 只保存该引用和必要控制元数据；实际 Prompt 与历史由 Host 保护。

对于同一个在途步骤，组装后的 system 前缀保持固定。恢复时不能用当前磁盘文件重新生成不同文本，不能因为改了 Prompt 就创建新请求身份绕过未知 Tool 或未确认提交。

### 连续会话与前缀稳定性

系统前缀不变时，稳定排序与固定渲染能减少无意义的输入变化，但本提案不保证缓存命中、Token 节省比例或费用下降。

当前实现禁止历史中途插入 system；因此首期 **不提供 `inHistory` 更新策略**。参考运行时的该能力不能直接移植。

Host 需要更换 system 内容时，应在当前 User Turn 完成且无未决 Tool 交换后明确建立新会话/Run，或走现有可验证的上下文重新绑定路径。是否可保留 Provider continuation 由对应 Engine 决定，不能沿用与新前缀不匹配的 opaque continuation。组装器不自动清除、迁移或伪造它；无法证明兼容时由 Host 显式选择新会话，不能静默重放历史 Tool。

即使只是 append 内容变化，也会影响 system 前缀，适用相同规则。按请求变化的 facts 应放在 user 数据部分，避免为环境值变化重写静态指令头。

## 验收场景

以下为实施要求，不是本次已运行的测试。

| 场景 | 预期 |
| --- | --- |
| 默认、replace、replace 空数组、append | 精确采用对应槽位；不存在隐藏文本或双重基础指令 |
| 注册顺序改变、同 order 不同 ID | 渲染结果与 manifest 完全相同 |
| 重复 ID、无效版本、未选中的默认 base | 生效集合按规则校验，替换不会拼回旧 base |
| 中文、emoji、组合字符和 CRLF | 按实际 UTF-8 字节计算，正文不被 trim/规范化 |
| 恰好等于容量与多一个字节 | 前者通过，后者拒绝；含渲染和 JSON 转义开销 |
| facts 含引号或伪造指令标记 | 输出仍是 JSON 字符串，绝不成为 system section |
| 当前用户请求含图片 | 加入事实文本后保留图片 parts，不制造独立 User Turn |
| planning 模式工具过滤 | 文字与生效 Registry 一致，文字修改不能放开受禁工具 |
| 会话前缀变化 | 不插入历史中途 system、不静默保留不兼容 continuation |
| 失败与日志 | 无网络/工具调用，输入不变；错误与 manifest 不包含正文 |

测试使用本库自行编写的样例文本和固定输入，不引入参考项目 Prompt 或 Fixture。Provider 的既有 system 映射可用合成请求回归；不据此宣称真实 Provider 的缓存或行为验证。

## 实施顺序与暂缓项

1. 已定义 section/profile 值类型和固定错误分类，确定渲染格式版本 1。
2. SDK 已实现纯组装、稳定排序和最终字节容量校验。Demo 继续保留 replace/append 与 runtime facts 实验。
3. Demo 已完成一次性请求、Conversation、Workflow 和结构化输出的 Profile 接入。动态 runtime facts 仍由 Host 负责。
4. 已补充 SDK、Demo 和恢复边界文档。Runner 的跨进程输入身份仍按现有 Host 执行快照契约管理。

首期不实现指令文件自动发现、Skill 管理、Prompt 内容仓库、缓存 API、热更新、历史 system 追加或新的 Tool execution delegate。是否把成熟的组合方式加入 Builder，依据实际接入代码再决定。
