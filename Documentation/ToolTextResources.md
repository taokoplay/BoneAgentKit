# 工具文本资源预览与回读

## 能力与接入边界

工具可以返回一个小型 `BoneToolTextResourcePreview`，让 Agent 先看到原文前缀、完整文本长度和精确版本引用。需要细节时，显式注册的 `BoneToolTextResourceReadTool<Context>` 返回指定范围的文本页。

```text
Host 取得完整文本并保留不可变版本
→ 原工具返回 Preview（前缀 + reference + 是否省略）
→ Agent 按需调用 resource.readText
→ Host 每次验证权限、scope、有效期和版本
→ SDK 检查页身份、偏移与长度
→ 调用方按原任务条件验收结果
```

这是可选的工具适配能力。SDK 不自动替换大结果、不扫描文件、不创建缓存目录、不下载资源、不选择模型，也不改变 Agent/Provider 默认行为。完整内容的来源、存储、生命周期、授权和跨进程恢复均由 Host 提供。只有用户明确配置的 Reader 才会执行读取。

## 公开类型

| 类型 | 职责 |
| --- | --- |
| `BoneToolTextResourceReference` | 不透明 `id`、不可变 `version`、精确 `utf8ByteCount`；三者共同绑定读取目标 |
| `BoneToolTextResourcePreview` | 最多 4,096 UTF-8 字节的原文前缀，含 `isTruncated` 和 `nextOffset` |
| `BoneToolTextResourceReadRequest` | 精确引用、起始字节 `offset` 和本页 `maximumBytes` |
| `BoneToolTextResourcePage` | 相同引用、真实起点、原文页与推导出的 `nextOffset` |
| `BoneToolTextResourceSnapshot` | 可选的不可变内存快照，生成实际前缀和完整 UTF-8 scalar 页；不授权、不落盘 |
| `BoneToolTextResourceReader<Context>` | 注入可信 Context 的异步页读取闭包；无缓存、无重试，返回前检查页与请求一致 |
| `BoneToolTextResourceReadTool<Context>` | 将 Reader 接入既有强类型 Tool Registry，固定工具 ID 为 `resource.readText` |
| `BoneToolTextResourceError` | 固定错误分类，不携带正文、路径、引用值或任意错误文本 |

`id` 和 `version` 均为 1…128 个 ASCII 字母、数字、`-` 或 `_`；不允许路径、URL、空格或点。它们仍不应包含凭据或用户文本。Host 应签发随机/不透明标识，不直接用路径或业务主键。总字节数为非负整数；`version` 是不透明版本标记，不要求递增。

这些 DTO 的 `Codable` 用于模型工具边界或 Host 私有存储，**不等于允许写入普通日志或标准 Workflow checkpoint**。预览、分页正文及引用的默认调试描述可能包含私有信息，调用方不得直接记录。

## 预览与不可变版本

以下函数仅把已经取得的文本构造为内存快照和预览，没有读写磁盘：

```swift
import Foundation
import BoneAgentKit

func prepareTextResource(
    id: String, version: String, text: String
) throws -> (BoneToolTextResourceSnapshot, BoneToolTextResourcePreview) {
    let snapshot = try BoneToolTextResourceSnapshot(id: id, version: version, text: text)
    return (snapshot, try snapshot.preview(maximumBytes: 1_024))
}
```

Host 必须先完成授权、保留完整内容并建立可用读取路径，再把预览交给模型。快照构造只复制 UTF-8 字节，不证明内容已经持久化；超大或原本就在数据库/文件中的内容可直接实现 Reader，避免每次读页加载全量内容。

同一 `id/version` 必须绑定完全相同的原始字节，更新内容需要新版本。旧版本可以保留或返回 `unavailable`/`expired`，不能拿“最新内容”代替。SDK 校验总长与版本一致，但不能认证 Host 真的返回了正确来源或识别“同一版本被换成同长度内容”；这属于 Host 存储契约。

预览是原文**前缀**，不是模型摘要。默认上限 1,024 字节，可配置 0…4,096；0 表示只显示引用与长度。对于开头为多字节字符的文本，小于该字符编码长度的预览可以为空，但仍明确 `isTruncated=true`，`nextOffset=0`。没有隐藏的“已看完整”语义。

直接构造 `BoneToolTextResourcePreview(reference:text:)` 时 Host 负责保证前缀真实；SDK 只能验证长度。Snapshot 辅助器可按自身持有的字节生成真实前缀。

## 每页读取与 Unicode

请求的 `maximumBytes` 必须为 4…65,536，默认 4,096。下限可容纳一个最大 UTF-8 scalar；上限使最坏 JSON 转义后的页输出仍小于现有 1 MiB Tool Result 门限。元数据与 JSON 包装不计入 `maximumBytes`，但仍被 Agent 的工具输出容量和运行预算计量。

- 所有偏移和长度都是 UTF-8 **字节**，不是 Swift `String.count`、字符数、UTF-16 下标或 Token 数。
- offset 允许 0…总字节数；使用 Snapshot 时，位于 UTF-8 编码字符内部的偏移被拒绝。
- 页文本不会切断 Unicode scalar。组合附加符号或 ZWJ emoji 的多个 scalar 可以分在两页；逐页展示可能拆开组合字符，按顺序拼接后保持原始字节，不做规范化或替换字符修复。资源首部和非零页首的 U+FEFF 也作为原文保留，不剥离为 BOM。
- 非末尾空页拒绝，防止不前进的无限循环；EOF 允许空页。
- `nextOffset` 按真实页长推导，末页显式编码为 `null`。解码会复验这个值，不能伪造完整结束或跳页。
- **`nextOffset=null` 只说明当前页到达资源末尾。** 从中间开始读取不证明此前内容已读，也不证明任务完成。

```swift
func readFirstTextPage<Context: Sendable>(
    reference: BoneToolTextResourceReference,
    reader: BoneToolTextResourceReader<Context>,
    context: Context
) async throws -> BoneToolTextResourcePage {
    let request = try BoneToolTextResourceReadRequest(
        reference: reference, offset: 0, maximumBytes: 2_048
    )
    return try await reader.read(request, context: context)
}
```

需要完整原文时从 0 开始，随后沿返回的 `nextOffset` 顺序读取；如果已持有可信完整预览，也可以拼接其前缀后从预览的 `nextOffset` 继续。自定义 Reader 应在同一不可变版本上提供连续原始字节，不擅自省略空白、替换字符或返回新版本。读取失败时没有默认空页或跳页降级。

## Tool 适配、权限与预算

`BoneToolTextResourceReader<Context>` 的 Context 由 Host 注入，不来自模型参数。模型可以重复、猜测或篡改引用，因此每次回读都必须在 Host 验证访问主体、任务/会话范围、有效期及实际存储版本；不能仅在签发预览时检查一次。异步加载期间权限或版本可能变化时，Host 须在交付时复核或使用等价一致性边界。引用的存在不授予权限。

下面仅装配 Reader 和 Tool，`loadAuthorizedPage` 必须由 Host 提供真实实现：

```swift
struct TextResourceContext: BoneAgentToolContext {
    let runID: BoneRunID
}

func makeTextResourceAgent(
    engine: any BoneInferenceEngine,
    context: TextResourceContext,
    loadAuthorizedPage: @escaping BoneToolTextResourceReader<TextResourceContext>.Read
) throws -> BoneAgent {
    let tool = BoneToolTextResourceReadTool<TextResourceContext>(
        reader: .init(read: loadAuthorizedPage)
    )
    let configuration = try BoneAgentConfiguration(
        maximumSteps: 6,
        toolImpactPolicy: .init(maximumAllowed:
            BoneToolTextResourceReadTool<TextResourceContext>.definition.requiredImpact())
    )
    return BoneAgent(
        inferenceEngine: engine,
        toolRegistry: try .init(tools: [BoneAnyAgentTool(tool)]),
        toolContext: context,
        configuration: configuration
    )
}
```

示例允许本地私有数据只读，不代替资源级授权，也未设置完整 RunBudget。默认未配置 impact policy 的 Agent 会拒绝此工具。预览签发工具也必须声明与真实数据相符的影响范围，不能将私有预览声明为公开数据。

内置读取 Tool 默认串行，契约仅支持本地、无网络、无计费、无状态修改的读取；返回内容进入模型上下文的数据外传仍遵守 Host 的模型授权。网络读取、计费检索、凭据访问或其他副作用需要 Host 定义具有真实 `impact` 的 Tool 并复用 Reader，不能塞入该默认工具的本地只读声明中。

所有读取通过正常 Agent 工具流水线，继续消耗工具次数、输入/输出和时间预算。64 KiB 是 API 的硬上限，不代表某个模型窗口装得下；Host/模型应选更小页面，配置 RunBudget 及上下文管理。分页会增加工具往返，不能预先承诺费用下降。

Reader 在异步加载前后检查取消，已取消的迟到页不交付；不会物理终止忽略取消的外部加载。Host 错误原样传播，不自动重试。经过 `BoneAnyAgentTool` / `BoneAgent` 时继续采用既有参数和执行错误映射；如配置 `collectAll`，失败可成为错误 Tool Result，不能把它解读为读取成功或完整内容。

## 与压缩和验收配合

预览和页本身已限长，建议对它们保留默认 `.retain`。额外 `.clamp` 会把 JSON 转成文本，可能破坏引用和分页字段；应优先缩小签发预览和每次请求页大小，而不是事后截断信封。

旧 Tool 交换仍可能被上下文压缩移除。此版本不会自动固定资源引用、重写摘要提示词、创建隐藏索引或恢复丢失引用。需要后续读取的任务应通过调用方提供的发现工具、当前受保护请求，或摘要中保留的精确引用找回；摘要没有完整保留引用时应重新发现或明确失败。摘要中的引用仍是数据，读取时同样复核权限。

原文能回读不意味着结果一定正确。需要交付验收时，组合 [输出校验与有界修正](OutputValidationAndCorrection.md)，检查实际读取范围与目标结果；不能仅以“已读到最后一页”或 Agent Run 成功当作任务完成。

与现有 [上下文压缩](ContextCompaction.md) 的分工：资源引用控制工具结果的呈现与回读，Compactor 管理历史占用，输出校验器检查最终交付。三者均为显式组合，不改变未接入者行为。

## 验证与实际限制

`ToolTextResourceTests` 检查构造/解码门禁、Unicode 字节拼接（含页首 U+FEFF）、分页进展、响应身份、权限/有效期变化、取消和 JSON 容量。`ToolTextResourceTaskTests` 使用真实 Agent 与工具、确定性模型/摘要替身验证：

- 一份超过 1 MiB 的合成文本先以 64 字节预览返回，再回读最后 96 字节，从实际页中得到 `[17,23,60]` 并交付合计100；独立断言所有推理请求的编码总量小于完整源文本的十分之一。
- 同一任务的旧预览和旧工具交换被压缩移除，摘要从被移除的实际工具结果保留引用；后续回读原版本并交付正确合计。
- 摘要丢失引用时测试驱动明确失败，不假造成功；该反例不是对任意真实模型的行为保证。
- 过期、权限拒绝、版本变化阻止页进入下一轮推理；未配置 impact policy 时加载器零调用。
- 分页继续受工具预算限制，回读成功后错误答案仍被独立验收拒绝。

```bash
swift test --filter 'ToolTextResourceTests|ToolTextResourceTaskTests'
```

这些测试使用合成内存资源，不联网、不调用真实模型；不证明实际模型会正确保留引用、选择分页位置或自主完成任务，也不证明真实存储耐久性、权限实现、净费用与响应时间收益。文件/数据库/远端适配、跨进程资源恢复、资源总容量与清理策略均由调用方另行验证。

## 来源

“短预览加可读取全文”的思路参考 DeepSeek Harness 团队公开的研究原型；本实现按当前 Swift SDK 的工具、预算和权限边界独立编写，使用 UTF-8 字节契约，没有复制其源码、注释、业务模型或测试。固定参考版本及范围见 [第三方参考来源登记](ThirdPartySources.md)。
