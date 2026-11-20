# 可选内置工具 · BoneAgentTools

`BoneAgentTools` 是独立的 SwiftPM library product，依赖 `BoneAgentKit`，不新增第三方依赖。最低平台沿用 iOS 13 / macOS 13。SDK 不自动注册工具、不自动联网、不创建 UI、不保存记忆或凭据。

## 选择与注册

向目标加入 `BoneAgentTools` product，并按需求显式构造工具。所有工具都支持宿主自己的 `BoneAgentToolContext`：

```swift
import BoneAgentKit
import BoneAgentTools

struct AppToolContext: BoneAgentToolContext {}

let tools: [BoneAnyAgentTool] = [
    BoneAnyAgentTool(BoneCalculatorTool<AppToolContext>()),
    BoneAnyAgentTool(BoneDateTimeTool<AppToolContext>())
]
let registry = try BoneAgentToolRegistry(tools: tools)
```

`BoneBuiltInToolGroup` 提供六类工具的元数据；`BoneBuiltInToolPreset.basic / resources / research` 提供建议的选择集合。它们不实例化客户端、不注册工具、不授予权限；宿主仍需检查依赖是否齐备。

| 类别 | 稳定 ID / wire name | 输入与行为 |
| --- | --- | --- |
| 计算器 | `math.calculate` / `math_calculate` | `expression`：有界算术表达式 |
| 日期时间 | `time.query` / `time_query` | `action`：now、convert、add、difference |
| 资料列表 | `resource.list` / `resource_list` | `offset`、`limit`，返回授权资源引用 |
| 资料检索 | `resource.search` / `resource_search` | `query`、`limit`，返回命中、片段及 UTF-8 字节位置 |
| 文本分页 | `resource.readText` / `resource_read_text` | 复用 BoneAgentKit 的精确 reference、offset、maximumBytes |
| 网页读取 | `web.fetch` / `web_fetch` | `url`、可选 maximumTextBytes；静态 HTML / 文本 |
| 联网搜索 | `web.search` / `web_search` | `query`、可选 count、page；注入搜索服务 |
| 询问用户 | `user.ask` / `user_ask` | `question`、kind、options；等待 Host 的真实回答 |

## 计算与时间

`BoneCalculatorTool<Context>` 使用独立语法解析器，不执行代码。支持 `+ - * / % ^`、括号、一元符号，以及 `abs/sqrt/min/max/round/floor/ceil/percent`。幂右结合，优先于一元符号，`-2^2 = -4`；`%` 表示余数，百分比使用 `percent(x)`。限制为 4096 字节、512 token、64 层嵌套、128 次运算；拒绝非法输入、除零、定义域错误和非有限结果。数值使用 Double，不提供财务十进制精度。

`BoneDateTimeTool<Context>` 可注入 `clock` 和 `defaultTimeZone`。默认时区在初始化时冻结，只有 `now` 读取 clock。输入日期必须为带显式时区的 ISO 8601 时间，支持毫秒；不解析自然语言日期。

- `convert`：date 与可选 timeZoneID。
- `add`：date、unit、非负 amount、direction（add / subtract）；使用目标时区的 Gregorian Calendar。
- `difference`：date、otherDate、unit；返回 otherDate − date，支持 seconds / minutes / hours / days，天固定为 86400 秒。
- 输出包括 utcDate、localDate、epoch、timeZoneID，以及适用的 difference / unit。

日历加减遵循 Foundation 的 DST 与月末规则，减回相同数量未必能还原原日期。

## 授权资料

`BoneTextResourceListTool<Context>`、`BoneTextResourceSearchTool<Context>` 接受 Host handler，调用前校验请求、调用后校验结果范围。handler 必须按真实 Context 检查作用域和有效期。工具声明访问用户私有数据，Agent 配置需显式允许相应 impact。

已有内存文本时可使用不可变的 `BoneTextResourceCollection`：

```swift
let resource = try BoneTextResourceCollection.Resource(name: "说明", text: "用户导入的正文")
let collection = try BoneTextResourceCollection(resources: [resource])

let tools = collection.tools { (context: AppToolContext) in
    // 在这里检查该 Context 是否仍有权访问这整个 collection。
    // 无权时 throw BoneToolTextResourceError.accessDenied。
    _ = context
    throw BoneToolTextResourceError.accessDenied // 未接真实策略时保持拒绝。
}
```

这个示例的授权闭包需要由真实宿主策略补齐。collection 本身不拥有授权、撤销、持久化或文件读取能力；其中任一资源撤销后，宿主必须拒绝旧集合或供应新的已授权集合。

集合最多 64 个资源，每份最多 2 MiB，总计最多 8 MiB。列表每页最多 20 项；检索为字面、大小写不敏感匹配，按宿主资源顺序返回，不作语义排序。每条 snippet 最多 2048 字节，所有片段累计最多 32 KiB。命中携带精确版本、matchOffset、snippetOffset；读取仍需使用原 reference，不能将搜索结果当成新授权。

分页复用 `BoneToolTextResourceReadTool`，下一页使用 SDK 返回的 nextOffset。导入 PDF / Word、授权目录与业务数据库适配由宿主实现。

### 读取长文件

宿主已获得用户选定的 UTF-8 普通文件时，可在后台构造 `BoneDiskTextResource(importing:name:maximumBytes:)`。`maximumBytes` 默认 100 MiB，是导入上限，不是模型窗口。只把展示名称和 `descriptor.reference` 交给模型，不接收模型提供的文件路径。导入以固定窗口校验编码并复制一次，约需与原文件等大的临时磁盘空间。快照不跟随原文件变化，释放最后一个引用或进程退出即失效，不是持久化附件。

```swift
// Host 在文件授权仍有效时导入；聊天工具应按可信 Context 在每次调用前复核权限。
let disk = try BoneDiskTextResource(importing: selectedURL, name: displayName)
let result = try disk.search(.init(query: "timeout", limit: 5), maximumScanBytes: 8 * 1_048_576)
if let hit = result.hits.first {
    // 使用同一版本中的真实字节偏移，可以直接定位，不需要先读前面的页。
    let page = try disk.read(.init(reference: hit.resource.reference, offset: hit.matchOffset, maximumBytes: 4_096))
    // page.nextOffset 为下一窗口的起点；这次只处理了命中附近的范围。
}
```

磁盘检索从文件开头扫描，按 UTF-8 原始字节匹配、区分大小写、不做 Unicode 归一化；内存集合原有的大小写不敏感行为不变。`maximumScanBytes` 限定可搜索的前缀，要查找文件末尾时需要足够扫描预算。`isTruncated == true` 表示扫描或返回结果不完整，此时即使没有命中也不能回答“全文没有”。按工具次数、模型上下文和总开销另设预算；返回末页、搜索全文件都不等同于模型已理解全文。

### 多格式文件与持久长文件快照

需要跨进程或重启继续读取时，宿主使用 `BoneFileResourceStore` 导入用户已授权的本地文件。Store 会把原始文件复制到应用私有的内容寻址 blob，公开给模型的只有 `BoneFileResourceReference`，其中包含不透明资源 ID、版本、大小、SHA-256 和资源类型。会话存档保存引用，正文和派生视图留在 Store 中，恢复时重新校验 blob 摘要。
恢复合同已通过独立 XCTest 子进程验证，删除原始文件后仍可恢复文本派生视图和二进制快照，blob 摘要不一致时恢复会 fail closed。

| 类型 | 支持范围 | 读取入口 |
| --- | --- | --- |
| 文本 | 严格 UTF-8、UTF-16 LE/BE、GBK、GB18030 | `resource.readText`、`resource.readWindow` |
| PDF | 页数、标题、作者、页级文本窗口、字符坐标布局和 Vision OCR | `resource.inspect`、`resource.detectFormat`、`resource.readWindow`、`resource.readPDFLayout`、`resource.ocr` |
| Office | OOXML 的 DOCX 段落、XLSX 工作表/单元格、PPTX 幻灯片 | `resource.inspect`、`resource.detectFormat`、`resource.readOffice`、`resource.readWindow` |
| 压缩包 | ZIP stored/deflate、GZIP content 条目、目录和条目窗口 | `resource.inspect`、`resource.detectFormat`、`resource.listEntries`、`resource.readWindow` |
| 二进制 | 原始字节范围分页，最多 65,536 字节一页 | `resource.readBytes` |

`automatic` 只确认 BOM 或严格 UTF-8，不猜测 GBK。需要按 GBK 或 GB18030 读取时，导入时显式传入编码。所有正文读取都有页大小、条目展开、XML、Office 结构化结果或 PDF 页预算。ZIP 会校验 local header、data descriptor、CRC32、路径和符号链接，并限制条目数、单条展开大小、累计展开大小和压缩比。

首期不承诺旧式 `.doc`、`.xls`、`.ppt` 的完整排版解析和任意二进制格式的语义解析。PDF 布局工具返回媒体框、裁剪框、旋转、文本行、UTF-16 字符框和注释区域，OCR 工具按页渲染 PDF 并返回 Vision 识别框、坐标和置信度。两者都使用页范围、文本、元素和识别框预算，布局还支持可选的单页 PDF 数据。`resource.detectFormat` 返回具体格式、MIME、编码、保护状态和可用能力。`BoneFileResourceToolFactory` 统一要求宿主在每次调用前重验当前 session scope、资源版本、权限、预算和撤销状态，并在交付前校验返回结果仍绑定原始引用。

## 加密文件

密码由宿主授权上下文临时提供，不进入 Tool Schema、资源引用、metadata 或结果 JSON。PDF 检查结果会返回 `isEncrypted`、`isLocked`、`allowsCopying` 和 `allowsContentAccessibility`。受保护 PDF 在宿主提供密码后可以继续使用页文本、布局和 OCR，缺少密码、密码错误和受保护内容分别返回固定错误分类。ZIP 目录暴露 `isEncrypted` 条目，读取加密条目返回 `protectedContent`。带 OLE Compound File 头的加密 Office 文档会被识别为 `encrypted-office`，只保留检查和原始字节能力，不会误判为普通 OOXML。

## 网页与搜索

`BoneWebFetchTool<Context>`、`BoneWebSearchTool<Context>` 都可注入 handler，或注入 client 和每次执行的 `authorize` 闭包。闭包负责资源范围；Agent 的 effect 授权管线仍需单独配置。

默认客户端：

- `BoneWebFetchHTTPClient(policy:transport:...)`：静态 HTML / XHTML / plain text；有限去标签和实体处理，不执行 JavaScript、不加载子资源、不承诺完整 readability。
- `BoneBraveSearchClient(apiKey:policy:transport:...)`：固定 Brave Search JSON endpoint，Key 仅由构造器注入并用于 `X-Subscription-Token`，不进入模型输入、输出或 Codable 配置。也可实现 `BoneWebSearchClient` 替换服务。
- `BoneURLSessionWebTransport`：ephemeral GET，按接收字节限制响应、传播取消，禁用重定向、缓存、Cookie 与凭据存储，不作应用层重试。兼容 FoundationNetworking。

`BoneWebHostPolicy(allowedHosts:)` 必须显式配置精确公开 DNS 域名，无通配符或隐式子域权限。URL 仅 HTTPS / 443，无 URL 账号密码或 fragment，拒绝 IP 字面量、localhost 和本地后缀。URL 过滤不能代替实际目的地址检查；DNS 重绑定等由宿主网络层控制。

网页原始响应最大 2 MiB；搜索响应最大 1 MiB；序列化工具输出最大 32 KiB。搜索 query 最大 2048 字节，count 为 1–10，page 为 0–9，Brave 的 offset 使用零基页号。返回标题、正文、片段和来源链接均标记 `untrusted_data`，来源链接不会自动抓取。

网络工具声明 arbitraryNetwork；搜索还声明 metered。影响声明不代表金额已经计量，实际搜索费用、账户额度和凭据生命周期由宿主负责。

## 询问用户

```swift
let tool = BoneAskUserTool<AppToolContext> { question, context in
    // 调用宿主真实 UI，等待用户操作，返回经过校验的 BoneUserAnswer。
    // 此处只是未接 UI 的示例占位，不会自动回答。
    _ = question; _ = context
    throw BoneAskUserError.unavailable
}
```

kind 支持 singleChoice、multipleChoice、text。单选至少两个选项，多选至少一个，自由文本不含选项。最多 12 个选项，选项 ID 必须唯一；问题最多 2048 字节，回答文本最多 8192 字节。Host 返回不存在的 ID、重复选择、空文本或不匹配的回答类型会被拒绝。

Host 拥有呈现、身份、等待超时和取消处理。工具在等待前后检查 Task cancellation，但不能替代宿主对挂起 handler 的取消实现。取消结果不等于同意；任何回答都只是数据，不产生另一个工具的授权。

## Agent 授权接入

本地计算和时间工具的 impact 六维均为 none。资料工具属于私有本地读取；网页和搜索具有外传影响，询问用户具有用户可见影响。沿用 [现有工具授权与执行规则](ToolCalling.md)：

1. 只注册用户选择且依赖齐备的工具。
2. `toolImpactPolicy` 只开放需要的影响上限。
3. 非本地只读工具需提供 `BoneWorkflowToolExecutionPipeline(effectStore:)` 和 `toolExecutionContextProvider`。
4. Host 将当前调用的工具 ID / version / schema、canonical arguments digest、身份、scope / revision、nonce、有效期绑定到一次性 Grant；消费授权与保存 Intent 原子完成。
5. 执行后保存 Receipt 并提交 Host checkpoint；取消、回执丢失和未知结果按现有恢复规则处理，不默认重发。

仅勾选工具或配置 allowlist 不能替代执行授权。直接调用 Registry / Tool 的宿主代码也应自行维护相同边界。

## Agent Lab 示例与验证

[Agent Lab](../Examples/WorkflowRunnerDemo/iOS/README.md) 在“实验室”统一选择六类工具和三个预设，在“设置”集中管理模型、助手说明与联网信息；配置齐全后仍可编辑。缺少依赖的勾选保留并显示待配置，运行前补齐。普通任务和真实模型测试使用同一套配置；计算测试核对实际工具输出，模型自行写出数字不算通过。每个任务首次联网确认一次，每次执行仍生成绑定参数的一次性授权；问答面板等待最多 90 秒，取消或中断后不自动重发。

Agent Lab 的“搜索设置”集中管理网页手动搜索、百度网页问答、Brave API 和 DeepSeek 独立 Search API。`web.search` 使用正式工具契约，Host 按明确配置选择通道及所需凭据，失败不自动切换服务。百度网页问答是 Demo 的可选 keyless 通道：经任务确认，在后台临时未登录的 WebKit 渲染器中读取有限公开结果，不弹出网页；以 `BoneWebSearchOutput` 结构化返回标题、来源、摘要和读取时间供当前模型回答。登录、验证、查询变化、超时和取消均停止。手动浏览选取仍独立保留，由用户主动打开。WebKit 及这些 Host 适配留在 Demo，不纳入 SDK core 或新增公开工具产品 API。

Demo 的 Effect Store 是有界进程内账本，记录单次授权与会话级回执；它不提供跨进程 Workflow 恢复。聊天存档在请求进行中写入标记，恢复时只加载此前完成的历史。

工具测试使用固定 clock、内存资料、假 HTTP 传输和 URLProtocol，验证 schema、边界、取消、来源与凭据隔离，不调用真实模型或搜索账户。实际账号、站点和搜索服务的在线可用性需由接入方验证。
