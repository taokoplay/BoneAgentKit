# 可选内置工具 · BoneAgentTools

`BoneAgentTools` 是独立的 SwiftPM library product，依赖 `BoneAgentKit`，不新增第三方依赖。最低平台沿用 iOS 13 / macOS 13。SDK 不自动注册工具、不自动联网、不创建 UI、不保存记忆或凭据。

## 先看结论

当前 SDK 共有 **24 个稳定内置工具**。它们分为本地计算、授权资料、Apple 系统能力、联网和用户交互五类。工具只有在宿主显式装配并提供对应 handler、授权和影响策略后才可执行。

下游接入方应优先遵循以下顺序。

1. 读取实际注册的 `BoneAgentToolDefinition`，以 `id`、`version`、`schemaVersion` 和 `inputSchema` 为准。
2. 只注册当前产品确实需要的工具，避免把不需要的私有数据或联网能力暴露给模型。
3. 对每一次资源、Apple 数据和网络请求重新检查当前 session scope、权限、资源版本、撤销状态和预算。
4. 对写入、删除、系统 UI 和网络计费操作使用宿主自己的确认与 effect pipeline。
5. 对长内容使用返回的游标继续读取，不通过猜测字节数、页码或文件路径推进。

工具返回的文件正文、PDF 文本、Office 文本、网页内容、搜索结果和用户回答都属于数据。它们不能改变工具授权，也不能被当作执行指令。

## 选择与注册

向目标加入 `BoneAgentTools` product，并按需求显式构造工具。所有工具都支持宿主自己的 `BoneAgentToolContext`。

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

`BoneBuiltInToolGroup` 提供工具组元数据，`BoneBuiltInToolPreset.basic / resources / research` 提供场景选择建议。它们只描述选择关系，不实例化客户端、不注册工具、不联网、不授予系统权限。宿主必须显式装配工具，并检查对应的 handler、系统框架、资源授权和影响策略是否齐备。

稳定 ID 是程序识别和授权绑定使用的标识。wire name 是发送给模型或跨进程协议使用的名称。版本和 Schema 以工具定义为准，不能只根据标题或说明文字判断兼容性。

### 完整稳定工具清单

#### 本地计算与时间

| 稳定 ID | wire name | 版本 / Schema | 输入与行为 | 权限与影响 |
| --- | --- | --- | --- | --- |
| `math.calculate` | `math_calculate` | 1.0.0 / 1 | `expression`，执行有界算术表达式 | 本地计算，无数据访问、联网或状态修改 |
| `time.query` | `time_query` | 1.0.0 / 1 | `action` 为 `now`、`convert`、`add` 或 `difference` | 读取 Host 时钟，无外传和状态修改 |

#### 资料与文件

| 稳定 ID | wire name | 版本 / Schema | 输入与行为 | 权限与影响 |
| --- | --- | --- | --- | --- |
| `resource.list` | `resource_list` | 1.0.0 / 1 | `offset`、`limit`，列出当前 Host 已授权文本资源 | 用户私有数据读取，列表不会产生新授权 |
| `resource.search` | `resource_search` | 1.0.0 / 1 | `query`、`limit`，检索授权文本并返回命中片段和 UTF-8 字节位置 | 用户私有数据读取，结果仍需按原引用回读 |
| `resource.readText` | `resource_read_text` | SDK 1.0.0 / 1 | `reference`、`offset`、`maximumBytes`，读取 UTF-8 文本页 | 用户私有数据读取，受资源版本和权限复核约束 |
| `resource.inspect` | `resource_inspect` | 1.0.0 / 1 | `reference`，读取文件元数据和派生检查信息 | 用户私有数据读取，不返回整份正文 |
| `resource.detectFormat` | `resource_detect_format` | 1.0.0 / 1 | `reference`，探测格式、MIME、编码、保护状态和能力 | 用户私有数据读取，不返回正文 |
| `resource.readWindow` | `resource_read_window` | 1.0.0 / 1 | `reference`、`kind`、定位字段和预算，读取文本、PDF 页、Office 文本或归档条目 | 用户私有数据读取，受窗口和解析预算限制 |
| `resource.readOffice` | `resource_read_office` | 1.0.0 / 1 | `reference`，读取 DOCX、XLSX 或 PPTX 的结构化投影 | 用户私有数据读取，只覆盖 OOXML |
| `resource.listEntries` | `resource_list_entries` | 1.0.0 / 1 | `reference`，列出 ZIP/GZIP 的安全条目 | 用户私有数据读取，不自动展开全部条目 |
| `resource.readBytes` | `resource_read_bytes` | 1.0.0 / 1 | `reference`、`offset`、`maximumBytes`，读取原始二进制范围 | 用户私有数据读取，单页最多 65,536 字节 |
| `resource.readPDFLayout` | `resource_read_pdf_layout` | 1.0.0 / 1 | `reference`、页范围和布局预算，读取页面几何、文本行和字符框 | 用户私有数据读取，受 PDF 页和布局预算限制 |
| `resource.ocr` | `resource_ocr` | 1.0.0 / 1 | `reference`、页范围、语言、识别级别和预算，对 PDF 页面执行 Vision OCR | 用户私有数据读取，CPU 和结果大小受预算限制 |

#### Apple 系统与前台交互

| 稳定 ID | wire name | 版本 / Schema | 输入与行为 | 权限与影响 |
| --- | --- | --- | --- | --- |
| `calendar.manage` | `calendar_manage` | 1.0.0 / 1 | 搜索、获取、创建、修改或删除日历事件 | EventKit 权限，写操作需要确认 |
| `reminder.manage` | `reminder_manage` | 1.0.0 / 1 | 搜索、创建、修改、完成或删除提醒事项 | EventKit 权限，写操作需要确认 |
| `notification.manage` | `notification_manage` | 1.0.0 / 1 | 安排、列出或取消本 App 自己登记的本地通知 | UserNotifications，安排和取消需要确认 |
| `photo.manage` | `photo_manage` | 1.0.0 / 1 | 保存 Host 已登记图片，可创建指定标题的相簿 | PhotoKit 添加权限，保存需要确认 |
| `contact.manage` | `contact_manage` | 1.0.0 / 1 | 搜索、获取、创建、修改或删除联系人 | Contacts 权限，写操作需要确认 |
| `location.lookup` | `location_lookup` | 1.0.0 / 1 | 查询当前位置，或对明确坐标执行反向地理编码 | Core Location / MapKit，当前位置查询需要授权 |
| `share.present` | `share_present` | 1.0.0 / 1 | 将文本、HTTPS 链接或 Host 已登记图片交给系统分享面板 | UIKit 用户可见交互，需要用户选择和确认 |
| `compose.present` | `compose_present` | 1.0.0 / 1 | 创建邮件或信息草稿并打开系统编辑器 | MessageUI 用户可见交互，不能静默发送 |

#### 网络与用户交互

| 稳定 ID | wire name | 版本 / Schema | 输入与行为 | 权限与影响 |
| --- | --- | --- | --- | --- |
| `web.fetch` | `web_fetch` | 1.0.0 / 1 | `url`、可选 `maximumTextBytes`，读取允许域名下的静态 HTTPS HTML 或文本 | 外部网络读取，返回内容标记为不可信数据 |
| `web.search` | `web_search` | 1.0.0 / 1 | `query`、可选 `count`、`page`，调用 Host 配置的搜索服务 | 外部网络和可能的计费影响 |
| `user.ask` | `user_ask` | 1.0.0 / 1 | `question`、`kind`、`options`，向用户发起单选、多选或文本提问 | 用户可见交互，不会自动授予其他工具权限 |

Demo 中的 `demo.*` 工具只用于测试和演示，不属于上述 24 个稳定工具，也不应写入生产 allowlist。

## 统一调用约定

### Host handler 的注入方式

SDK 工具一般接收一个 `@Sendable` handler。handler 负责调用系统 API、文件资源 Host 或网络客户端，并返回 SDK 规定的 DTO。SDK 只负责输入校验、取消检查和输出结构校验。

```swift
let tool = BoneCalendarTool<AppToolContext> { input, context in
    try await calendarHost.handle(input, context: context)
}
```

文件资源工具应优先使用 `BoneFileResourceToolFactory`。它会在 handler 前调用授权器，在 handler 后校验返回结果仍绑定原始引用。

```swift
let authorizer = BoneFileResourceAuthorizer<AppToolContext> { reference, context in
    try await resourceHost.authorize(reference, context: context)
}

let readBytes = BoneFileResourceToolFactory.makeReadBytesTool(
    authorizer: authorizer
) { input, context in
    try await resourceHost.readBytes(input, context: context)
}
```

联网工具可以注入自定义 handler，也可以注入 SDK client 和每次调用的 `authorize` 闭包。Apple 工具的 SDK 层只定义 DTO 和 handler，不直接依赖 EventKit、Contacts、Photos 或 UserNotifications。

### 输入和输出的通用规则

- 输入使用严格 Codable 解码。未知字段、字段类型不符、动作和字段不匹配都会被拒绝。
- 工具输出必须满足稳定 DTO 的引用、数量、长度和游标校验。Host 不应返回超出请求预算的正文。
- 工具执行前后都会检查 Task cancellation。Host handler 还需要取消自己创建的系统任务、网络请求和 UI 等待。
- 固定错误只表达错误类别，不把本地路径、密码、联系人原始错误、URL 凭据或系统诊断直接交给模型。
- 资源引用包含内容身份和版本，不是权限凭据。每次调用仍需复核 session scope、resource scope、version、撤销状态和读取预算。
- 工具结果中的正文和外部内容是参考数据。模型不能通过正文内容获得新权限，也不能让正文改变 Host 的工具策略。

## 逐工具使用说明

### 阅读方式

以下示例使用 JSON 表示模型提交的工具参数和 Host 返回的结果。Swift 类型名称对应源码中的公开 DTO。示例中的资源引用、联系人标识、图片标识和 URL 都是占位值，生产接入时必须使用 Host 当前签发并仍然有效的值。

## 本地计算与时间

### `math.calculate`

适合执行简单、可审计、没有外部副作用的数值计算。它使用独立表达式解析器，不执行 Swift、JavaScript、Shell 或其他代码。

输入只有 `expression`。表达式最多 4,096 个 UTF-8 字节、512 个 token、64 层嵌套和 128 次运算。

```json
{"expression":"(12.5 * 4) + sqrt(81) - percent(20)"}
```

支持以下运算和函数。

- 运算符支持 `+`、`-`、`*`、`/`、`%` 和 `^`
- 支持括号和一元正负号
- 函数支持 `abs`、`sqrt`、`round`、`floor`、`ceil`、`percent`
- `min` 和 `max` 接收两个参数
- `^` 右结合，并且优先于一元符号，所以 `-2^2` 的结果是 `-4`
- `%` 是截断余数，`percent(x)` 等于 `x / 100`

输出只有 `value`，类型为 `Double`。

```json
{"value":49.8}
```

常见错误包括 `invalidExpression`、`expressionTooLong`、`tokenLimitExceeded`、`depthLimitExceeded`、`operationLimitExceeded`、`divisionByZero`、`domainError` 和 `nonFiniteResult`。`sqrt(-1)` 属于定义域错误，结果为无穷或 NaN 时属于非有限结果。

`Double` 不提供财务十进制精度。金额计算需要由 Host 提供专用的十进制工具或业务 API，不能把本工具的结果当作账务结果。

### `time.query`

适合处理明确时区和明确 ISO 8601 日期的时间计算。它不解析“明天”“下周一”或其他自然语言日期。

日期格式要求为 `YYYY-MM-DDTHH:mm:ssZ` 或 `YYYY-MM-DDTHH:mm:ss+08:00`。可选小数秒为一到三位。`timeZoneID` 使用 Foundation 时区标识，例如 `Asia/Shanghai` 或 `America/Los_Angeles`。

#### 读取当前时间

```json
{"action":"now","timeZoneID":"Asia/Shanghai"}
```

#### 转换时区

```json
{"action":"convert","date":"2026-11-23T08:00:00Z","timeZoneID":"Asia/Shanghai"}
```

#### 按日历单位加减

```json
{"action":"add","date":"2026-01-31T09:00:00+08:00","unit":"months","amount":1,"direction":"add","timeZoneID":"Asia/Shanghai"}
```

`unit` 支持 `seconds`、`minutes`、`hours`、`days`、`weeks`、`months` 和 `years`。`amount` 是 0 到 1,000,000 的非负整数，方向由 `add` 或 `subtract` 指定。月末日期由 Gregorian Calendar 规则裁剪到目标月份的有效日期。DST 切换时按目标时区的日历规则计算，因此一个本地日可能对应 23 或 25 个经过小时。

#### 计算差值

```json
{"action":"difference","date":"2026-11-23T00:00:00Z","otherDate":"2026-11-24T12:00:00Z","unit":"hours"}
```

`difference` 返回 `otherDate - date`。差值单位只支持 `seconds`、`minutes`、`hours` 和 `days`。这里的 `days` 固定按 86,400 秒计算，不按日历天数计算。

输出包含 `utcDate`、`localDate`、`epoch` 和 `timeZoneID`。`difference` 请求还会返回 `difference` 和 `unit`。`now` 使用 Host 注入的 clock，其他动作只使用输入日期。

常见错误包括 `invalidArguments`、`invalidDate`、`invalidTimeZone`、`invalidAmount`、`unsupportedUnit` 和 `dateOutOfRange`。

## 资料与文件

### 文件资源引用

统一文件工具使用 `BoneFileResourceReference`。模型只接收不透明引用和内容身份，不接收本地路径。

```json
{
  "id":"file-42",
  "version":"v3",
  "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "byteCount":1048576,
  "kind":"text"
}
```

`kind` 支持 `text`、`pdf`、`officeOpenXML`、`archive` 和 `binary`。文本资源导入支持严格 UTF-8、UTF-16 LE、UTF-16 BE、GBK 和 GB18030。`automatic` 只确认 BOM 或严格 UTF-8，不猜测 GBK 或 GB18030。默认原始文件上限为 100 MiB。

文件资源 Host 使用内容寻址快照。快照内容和派生视图应由 Host 保存在应用私有存储，调用时按 `id`、`version` 和 `sha256` 定位。删除源文件后是否仍可读取，取决于 Host 是否保留快照。

### `resource.list`

列出当前会话已经授权的文本资源。输入字段如下。

```json
{"offset":0,"limit":20}
```

`offset` 范围为 0 到 10,000，`limit` 范围为 1 到 20。输出包含 `resources` 和 `nextOffset`。每个资源包含展示名称 `name` 和 `reference`。

```json
{
  "resources":[{"name":"设计说明","reference":{"id":"text-1","version":"v1","utf8ByteCount":8200}}],
  "nextOffset":1
}
```

下一次请求复制 `nextOffset` 作为新的 `offset`。`nextOffset` 为 `null` 时列表结束。列表只暴露当前 Host 已授权资源，不会因为模型看见引用就扩大权限。

### `resource.search`

在 Host 已授权的文本版本中做字面、大小写不敏感匹配。输入字段如下。

```json
{"query":"timeout","limit":10}
```

`query` 最多 1,024 个 UTF-8 字节，`limit` 范围为 1 到 20。输出包含 `hits` 和 `isTruncated`。每个命中包含 `resource`、`matchOffset`、`snippetOffset` 和 `snippet`。

- `matchOffset` 是真实匹配位置在该资源 UTF-8 版本中的字节偏移。
- `snippetOffset` 是返回片段在同一版本中的起点。
- 想读取命中附近内容时，使用同一个 `resource.reference` 调用 `resource.readText`，优先把 `matchOffset` 或 `snippetOffset` 作为 `offset`。
- 搜索结果没有独立的续页游标。`isTruncated=true` 表示搜索预算或结果被截断，不能据此断言全文没有命中。
- 搜索命中不是新的授权凭据，读取前仍需复核原引用。

### `resource.readText`

这是 SDK 的长文本读取工具。输入字段为 `reference`、`offset` 和 `maximumBytes`。

```json
{
  "reference":{"id":"text-1","version":"v1","utf8ByteCount":8200},
  "offset":0,
  "maximumBytes":4096
}
```

`offset` 和 `maximumBytes` 都按 UTF-8 字节计算。`maximumBytes` 范围为 4 到 65,536。输出包含 `reference`、本页实际 `offset`、`text` 和派生的 `nextOffset`。

```json
{
  "reference":{"id":"text-1","version":"v1","utf8ByteCount":8200},
  "offset":0,
  "text":"前 4 KiB 的正文",
  "nextOffset":4096
}
```

继续读取时复制上一次返回的 `nextOffset`。`nextOffset` 为 `null` 时到达该版本末尾。不要手算下一个偏移，也不要换用新版本引用。页边界会保持完整 Unicode scalar，实际返回字节数可能小于请求上限。

Host handler 的注册方式如下。

```swift
let reader = BoneToolTextResourceReader<AppToolContext> { request, context in
    try await textResourceHost.read(request, context: context)
}
let readText = BoneToolTextResourceReadTool(reader: reader)
```

### `resource.inspect`

读取结构化元数据，不返回整份正文。输入只有 `reference`。

```json
{"reference":{"id":"pdf-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":300000,"kind":"pdf"}}
```

输出包含 `metadata`，并按资源类型可选返回 `format`、`pdf`、`office` 或 `archiveEntries`。

- PDF 检查包含 `pageCount`、标题、作者、`isEncrypted`、`isLocked`、`allowsCopying` 和 `allowsContentAccessibility`。
- OOXML 检查包含文件扩展名、包条目名称和参与文本投影的 XML 条目名称。
- ZIP/GZIP 检查包含安全条目目录。
- 文本元数据可包含原始编码和规范化 UTF-8 字节数。

### `resource.detectFormat`

读取资源格式和可用能力，不返回正文。输入只有 `reference`。

输出中的 `format` 包含以下字段。

- `family`，一级格式族
- `subtype`，例如 `utf8`、`gbk`、`pdf`、`docx`、`xlsx`、`pptx`、`zip` 或 `gzip`
- `mimeType` 和 `confidence`
- 文本资源的 `encoding`
- `capabilities`，例如 `inspect`、`readWindow`、`readBytes`、`structuredRead`、`listEntries`、`readPDFLayout` 和 `ocr`
- `protectionStatus`，可能为 `none`、`passwordRequired`、`encrypted` 或 `unsupported`
- 可选的 `parserID`、`parserVersion` 和稳定 `warnings`

接入方可以先调用该工具，再根据能力集合决定使用结构化读取、原始字节读取或仅展示元数据。

### `resource.readWindow`

该工具把多种派生视图统一为一个有界窗口请求。输入字段如下。

```json
{
  "reference":{"id":"file-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":100000,"kind":"text"},
  "kind":"text",
  "offset":0,
  "maximumBytes":4096
}
```

`kind` 支持以下四种值。

| kind | 资源类型 | 定位字段 | 输出字段 | 续读方式 |
| --- | --- | --- | --- | --- |
| `text` | `text` | `offset`、`maximumBytes` | `text`、`nextOffset` | 复制 `nextOffset` |
| `pdfPage` | `pdf` | `pageIndex`、`maximumBytes` | `pageIndex`、`text`、`isTruncated` | 增加 `pageIndex`，页内 `offset` 必须为 0 |
| `officeText` | `officeOpenXML` | `offset`、`maximumBytes` | `text`、`nextOffset` | 复制 `nextOffset` |
| `archiveEntry` | `archive` | `entryName`、`offset`、`maximumBytes` | `archiveEntry`、Base64 `data`、`nextOffset` | 复制 `nextOffset` |

PDF 页请求示例如下。

```json
{
  "reference":{"id":"pdf-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":300000,"kind":"pdf"},
  "kind":"pdfPage",
  "pageIndex":2,
  "maximumBytes":65536
}
```

`text`、`officeText` 和 `archiveEntry` 的 `nextOffset` 必须在同一派生视图中递增。PDF 页面使用 `pageIndex` 续读，不使用 `nextOffset`。

### `resource.readOffice`

读取 OOXML 的结构化内容。输入只有 `reference`，当前工具没有额外的结构选择字段。

```json
{"reference":{"id":"report-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":500000,"kind":"officeOpenXML"}}
```

输出包含 `reference` 和 `structure`。

- DOCX 返回 `fileExtension` 和 `paragraphs`。每个段落包含合并后的 `text`。
- XLSX 返回 `fileExtension` 和 `worksheets`。每个工作表包含 `name` 和 `cells`，单元格包含 `address` 和 `value`。
- PPTX 返回 `fileExtension` 和 `slides`。每张幻灯片包含从 1 开始的 `slideIndex` 和按 XML 顺序合并的 `text`。

当前覆盖 DOCX、XLSX、PPTX OOXML，不承诺旧式 `.doc`、`.xls`、`.ppt` 的完整排版解析。结构化结果受解析器的文本和条目预算限制，超大 Office 文件应先用 `resource.inspect` 或 `resource.readWindow` 定位范围。

### `resource.listEntries`

列出 ZIP 或 GZIP 的安全条目。输入只有归档 `reference`。

```json
{"reference":{"id":"archive-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":800000,"kind":"archive"}}
```

每个条目包含 `name`、压缩后字节数、展开后字节数、`isDirectory`、`isSymbolicLink` 和 `isEncrypted`。先列目录，再使用 `resource.readWindow` 的 `archiveEntry` 模式读取明确的 `entryName`。

目录读取会拒绝路径穿越和不安全符号链接，并受最多 10,000 个条目和累计 100 MiB 展开预算限制。加密条目可以出现在目录中，读取时返回 `protectedContent`。ZIP 加密解密不由当前 SDK 完成。

### `resource.readBytes`

读取任意文件的原始字节窗口，适合检查文件头、协议片段、未知格式或需要保留原始数据的场景。输入如下。

```json
{
  "reference":{"id":"binary-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":200000,"kind":"binary"},
  "offset":0,
  "maximumBytes":65536
}
```

输出包含 `reference`、`offset`、Base64 编码的 `data` 和 `nextOffset`。单页最多 65,536 字节。继续读取时复制 `nextOffset`。该工具只提供字节，不推断二进制文件的语义，也不执行文件内容。

### `resource.readPDFLayout`

读取 PDF 的页面布局，用于保留页面几何关系、文本位置和注释区域。输入字段如下。

```json
{
  "reference":{"id":"pdf-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":300000,"kind":"pdf"},
  "startPage":0,
  "pageCount":1,
  "maximumTextBytes":1048576,
  "maximumElements":100000,
  "includePageData":false,
  "maximumPageDataBytes":4194304
}
```

字段含义如下。

- `startPage` 从 0 开始，`pageCount` 范围为 1 到 100。
- `maximumTextBytes` 限制布局文本的 UTF-8 字节数。
- `maximumElements` 限制文本行和注释元素数量。
- `includePageData` 为 `true` 时可以返回单页 PDF 原始数据，单页最多 4 MiB。
- `maximumPageDataBytes` 限制每个返回页面的原始数据大小。

每个页面包含 `pageIndex`、`mediaBox`、`cropBox`、`rotation`、`text`、`annotationBounds` 和可选 `pageData`。每个文本行包含整体 `bounds` 和与文本 UTF-16 单元对应的 `characterBounds`。页面返回完后使用 `nextPage` 继续。密码由 Host 在当前调用内临时提供，不进入请求和结果。

布局恢复保留 PDF 的结构事实和坐标，不保证把任意 PDF 渲染成与原始页面完全一致的 UI。页面原始数据和字符框预算越大，CPU、内存和工具结果体积越高。

### `resource.ocr`

对 PDF 页面渲染后执行 Vision OCR。输入字段如下。

```json
{
  "reference":{"id":"scan-1","version":"v1","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteCount":900000,"kind":"pdf"},
  "startPage":0,
  "pageCount":2,
  "languages":["zh-Hans","en-US"],
  "recognitionLevel":"accurate",
  "maximumBytes":1048576,
  "maximumObservations":10000
}
```

`recognitionLevel` 支持 `fast` 和 `accurate`。输出包含 `pages` 和 `nextPage`。每页包含 `pageIndex`、按阅读顺序排列的 `text` 和 `observations`。每个识别框包含 `text`、页面坐标 `bounds` 和 0 到 1 的 `confidence`。

继续请求时把 `nextPage` 复制到下一次 `startPage`。`nextPage` 为 `null` 时页范围已经完成。OCR 预算越大，页面渲染和 Vision 识别耗时越长。密码由 Host 临时请求，密码错误返回 `invalidPassword`，缺少密码返回 `passwordRequired`。

### 文件工具的错误与性能

常见资源错误包括 `invalidReference`、`invalidRequest`、`accessDenied`、`expired`、`capacityExceeded`、`invalidEncoding`、`unsupportedEncoding`、`unsupportedFormat`、`parseFailed`、`archiveUnsafe`、`archiveLimitExceeded`、`passwordRequired`、`invalidPassword`、`protectedContent` 和 `referenceMismatch`。

导入文件通常需要一次完整读取、SHA-256 计算和快照落盘，因此峰值磁盘空间可能同时包含源文件、临时文件和快照。正文读取使用有界窗口，不会因为请求一页而把全文放入模型上下文。解析 PDF、Office、压缩包和 OCR 会额外消耗 CPU 与内存，Host 应按任务预算控制 `maximumBytes`、页数、元素数和展开大小。

`BoneDiskTextResource` 适合进程内文本快照。跨进程或重启恢复应使用 Host 管理的 `BoneFileResourceStore` 或等价持久资源层，并在恢复后重新校验资源版本、摘要和当前授权。WorkflowRunnerDemo 已接入持久资源快照、跨进程恢复和会话引用恢复。

## Apple 系统工具

Apple 工具的稳定契约位于 `BoneAgentTools`。EventKit、Contacts、Photos、UserNotifications、Core Location、MapKit、UIKit 和 MessageUI 只由 Apple Host 注入。SDK 不直接请求系统权限，也不创建系统对象。

所有 Apple handler 都可以按以下方式注册。

```swift
let calendar = BoneCalendarTool<AppToolContext> { input, context in
    try await appleHost.calendar(input, context: context)
}
```

WorkflowRunnerDemo 使用 `DemoAppleToolHandlers` 注入八个 handler。

```swift
struct DemoAppleToolHandlers: Sendable {
    let calendar: @Sendable (BoneCalendarRequest) async throws -> BoneCalendarResult
    let reminders: @Sendable (BoneReminderRequest) async throws -> BoneReminderResult
    let notifications: @Sendable (BoneNotificationRequest) async throws -> BoneNotificationResult
    let photos: @Sendable (BonePhotoRequest) async throws -> BonePhotoResult
    let contacts: @Sendable (BoneContactRequest) async throws -> BoneContactResult
    let location: @Sendable (BoneLocationRequest) async throws -> BoneLocationResult
    let share: @Sendable (BoneShareRequest) async throws -> BoneShareResult
    let compose: @Sendable (BoneComposeRequest) async throws -> BoneComposeResult
}
```

### `calendar.manage`

支持 `search`、`get`、`create`、`update` 和 `delete`。

```json
{"action":"search","query":"评审","startDate":"2026-11-23T00:00:00+08:00","endDate":"2026-11-30T00:00:00+08:00","limit":20}
```

创建事件至少需要 `title`、`startDate` 和 `endDate`。更新和删除需要 `identifier`。可选字段包括 `calendarIdentifier`、`notes`、时间范围和 `query`。日期必须是带时区的 ISO 8601 字符串，`limit` 范围为 1 到 50。

输出包含 `status`、事件数组 `events`、单个事件 `event` 和受影响的 `identifier`。事件字段包括日历和事件标识、标题、备注、起止日期、全天标记和修改时间。`search` 和 `get` 是读取操作。`create`、`update` 和 `delete` 必须由 Host 经过当前参数绑定的确认后执行。

### `reminder.manage`

支持 `search`、`create`、`update`、`complete` 和 `delete`。

```json
{"action":"create","listIdentifier":"personal","title":"提交报销","dueDate":"2026-11-24T18:00:00+08:00"}
```

创建至少需要 `title`。更新需要 `identifier` 和至少一个要修改的字段。完成和删除只需要 `identifier`。可选字段包括 `listIdentifier`、`notes`、`dueDate`、`query` 和 `limit`。

输出包含 `status`、`reminders`、`reminder` 和 `identifier`。提醒对象包含列表标识、列表标题、标题、备注、到期日期和完成状态。`search` 是读取操作。创建、更新、完成和删除需要确认。

### `notification.manage`

支持 `schedule`、`list` 和 `cancel`。它只管理当前 App 自己登记的本地通知。

```json
{"action":"schedule","identifier":"expense-due","title":"报销提醒","body":"今天 18:00 前提交报销","fireDate":"2026-11-23T18:00:00+08:00","repeats":false}
```

安排通知需要唯一 `identifier`、非空 `title`、未来的 `fireDate` 和可选 `body`、`repeats`。取消需要 `identifier`。列出操作不读取其他 App 的通知历史。

输出包含 `status`、`notifications` 和 `identifier`。安排和取消需要确认。通知已经安排不代表系统一定在任意设备状态下展示，也不代表后台任务已经执行。

### `photo.manage`

当前只支持 `save`。

```json
{"action":"save","imageID":"generated-image-42","albumTitle":"Agent 生成"}
```

`imageID` 必须是 Host 预先登记的图片标识。图片正文不进入模型参数，由 Host 根据标识解析。`albumTitle` 可选。输出包含 `status`、原始 `imageID` 和可选的 `assetIdentifier`。保存需要 PhotoKit 添加权限和当前参数确认。工具不扫描完整相册，也不提供相册搜索。

### `contact.manage`

支持 `search`、`get`、`create`、`update` 和 `delete`。

```json
{"action":"search","query":"张三","limit":10}
```

联系人输入字段包括 `identifier`、`givenName`、`familyName`、`middleName`、`organizationName`、`phones`、`emails`、`query` 和 `limit`。电话和邮箱数组最多各 8 项。创建至少需要姓名或组织名称之一。更新、获取和删除需要 `identifier`。

输出包含 `status`、`contacts`、单个 `contact` 和 `identifier`。联系人对象只包含姓名、组织、电话和邮箱，不包含备注、地址、头像或系统私有字段。搜索是读取操作。创建、更新和删除需要确认。

### `location.lookup`

支持 `current` 和 `reverseGeocode`。

```json
{"action":"current"}
```

反向地理编码示例如下。

```json
{"action":"reverseGeocode","latitude":31.2304,"longitude":121.4737,"limit":1}
```

`current` 不接受坐标。`reverseGeocode` 要求 `latitude` 在 -90 到 90 之间，`longitude` 在 -180 到 180 之间，`limit` 范围为 1 到 10。

输出包含 `status`、可选的 `location` 和 `placemarks`。当前位置结果包含纬度、经度、海拔、水平精度和时间。地址结果包含国家、行政区域、城市、街道、门牌号、邮编和格式化地址。工具只执行一次前台查询，不保存位置历史。首次查询需要系统授权，但不需要写入确认。

### `share.present`

支持 `text`、`url` 和 `image` 三种 `contentType`，三者只能选择一种内容字段。

```json
{"contentType":"url","url":"https://example.com/report"}
```

文本使用 `text`，链接使用 `url`，图片使用 Host 已登记的 `imageID`。输出包含 `status`、`contentType` 和可选的 `activityType`。Host 通过 `UIActivityViewController` 打开系统分享面板，用户决定目标并完成或取消。打开分享面板需要当前参数确认，工具不能保证目标 App 已接收内容。

### `compose.present`

支持 `mail` 和 `message` 两个 `channel`。

```json
{"channel":"mail","recipients":["team@example.com"],"subject":"会议材料","body":"请查收附件。"}
```

`recipients` 至少 1 个，最多 20 个。`body` 必填，`subject` 可选。输出包含 `status`、`channel` 和可选的 `activityType`。Host 通过 MessageUI 打开系统编辑器，用户可以修改、发送或取消。工具只生成草稿，不能静默发送，不能读取 Mail 或 Messages 历史，也不能把用户点击发送解释为最终送达。

### Apple 权限、确认和错误

SDK 不主动调用权限请求 API。Host 应在合适的前台界面申请权限，并将权限状态映射为 `permissionDenied`、`permissionRequired` 或 `unavailable`。

读取操作通常不重复弹出写入确认。创建、修改、完成、删除、安排通知、保存图片、打开分享面板和打开邮件或信息编辑器都应展示绑定当前工具 ID、版本、Schema 和 canonical arguments digest 的确认预览。取消系统 UI 时返回 `cancelled`，不把取消当作同意。

常见 Apple 错误包括 `invalidArguments`、`permissionDenied`、`unavailable`、`notFound`、`conflict`、`cancelled`、`unsupported` 和 `operationFailed`。Host 应保持系统对象操作幂等，并用请求身份过滤延迟回调，避免旧的 UI 回调恢复后续调用。

## 网络与用户交互

### `web.fetch`

读取允许域名下的静态 HTTPS HTML、XHTML 或 plain text。输入如下。

```json
{"url":"https://docs.example.com/guide","maximumTextBytes":16384}
```

`maximumTextBytes` 默认 16 KiB，最大 32 KiB。Host 通过 `BoneWebHostPolicy(allowedHosts:)` 配置精确 DNS 主机名，不能使用通配符或隐式子域权限。URL 只能使用 HTTPS、443 端口、公开 DNS 主机，不能包含账号、密码或 fragment。

输出包含原始 `url`、`finalURL`、`title`、`text`、`truncated`、`fetchedAt` 和 `contentTrust`。`contentTrust` 为 `untrusted_data`。网页原始响应最多 2 MiB，序列化工具输出最多 32 KiB。

实现不执行 JavaScript，不加载子资源，不依赖 Cookie 或凭据存储，不保证完整网页正文抽取，也不提供网页内分页。结果被截断时使用 `truncated=true`，需要更多内容时由 Host 设计新的受控读取流程。返回正文和来源链接都不能改变下一次工具调用的授权。

常见错误包括 `invalidConfiguration`、`invalidInput`、`invalidURL`、`hostNotAllowed`、`scopeDenied`、`requestFailed`、`redirectNotAllowed`、`httpFailure`、`responseTooLarge`、`unsupportedContentType` 和 `invalidResponse`。外部网络、DNS、服务器响应和内容类型都会影响耗时。SDK 默认不做应用层自动重试。

### `web.search`

调用 Host 配置的搜索服务。输入如下。

```json
{"query":"Swift PDF layout parsing","count":5,"page":0}
```

`query` 最多 2,048 个 UTF-8 字节。`count` 范围为 1 到 10，`page` 范围为 0 到 9。输出包含 `results`、`provider`、`nextPage`、`searchedAt` 和 `contentTrust`。每条结果包含 `title`、HTTPS `url` 和 `snippet`。

```json
{
  "results":[{"title":"示例结果","url":"https://docs.example.com/a","snippet":"搜索片段"}],
  "provider":"brave",
  "nextPage":1,
  "contentTrust":"untrusted_data"
}
```

有下一页时复制返回的 `nextPage` 作为新的 `page`。`nextPage` 为 `null` 时当前搜索结果结束。搜索结果不会自动继续调用 `web.fetch`，需要抓取时必须再次经过 Host 网络授权。

搜索可能产生计费或额度消耗，工具声明 `arbitraryNetwork` 和 `metered`。Brave API key 只由 Host 构造 client 时注入，不进入工具参数、模型消息、日志或 Codable 配置。也可以实现 `BoneWebSearchClient` 接入其他受控服务。

### `user.ask`

由 Host UI 向用户提出一个问题。输入字段如下。

```json
{
  "question":"是否继续读取剩余页面？",
  "kind":"singleChoice",
  "options":[
    {"id":"continue","label":"继续"},
    {"id":"stop","label":"停止"}
  ]
}
```

`kind` 支持以下值。

- `singleChoice` 要求至少两个选项，回答只能选择一个 ID。
- `multipleChoice` 至少一个选项，回答可以选择多个不重复 ID。
- `text` 不允许传选项，回答必须包含非空文本。

问题最多 2,048 个 UTF-8 字节，最多 12 个选项，选项 ID 必须唯一，回答文本最多 8,192 个 UTF-8 字节。输出包含 `status`、`selectedOptionIDs` 和可选的 `text`。

```json
{"status":"answered","selectedOptionIDs":["continue"],"text":null}
```

用户取消时返回 `{"status":"cancelled","selectedOptionIDs":[],"text":null}`。取消不等于同意，回答也不自动授予其他工具权限。Host 负责 UI 呈现、超时、取消、身份绑定和恢复挂起 handler。常见错误包括 `invalidQuestion`、`invalidAnswer` 和 `unavailable`。

## SDK 与 WorkflowRunnerDemo 的差异

SDK 和 Demo 共享稳定工具 ID，但可以在同一 ID 下使用不同的 Schema 版本来适配宿主界面。接入方必须读取实际注册的 `BoneAgentToolDefinition.version` 和 `schemaVersion`，不能只按工具 ID 猜测输入格式。

### `resource.readText` 的 Schema 差异

SDK 的 `resource.readText` 是 1.0.0 / Schema 1。输入包含完整 `reference`、UTF-8 字节 `offset` 和 `maximumBytes`，由 `BoneToolTextResourceReadTool` 注入 Host Reader。输出以 `nextOffset` 续读。

WorkflowRunnerDemo 的聊天入口使用同一稳定 ID 的 2.1.0 / Schema 2。输入使用 `resourceID`、从 0 开始的 `page` 和可选 `offset`。页面大小由 Demo 固定为 16 KiB。继续读取时完整复制返回的 `nextRead`，`nextRead` 为 `null` 时停止。

Demo Schema 2 的输入示例如下。

```json
{"resourceID":"attachment-1","page":0}
```

搜索命中扩读示例如下。

```json
{"resourceID":"attachment-1","offset":12000}
```

Demo Schema 2 只服务于 Demo 的附件预览和搜索扩读体验，不改变 SDK 的通用 Reader 契约。SDK 接入方应使用 Schema 1 的 `reference`、`offset` 和 `maximumBytes`。

### Demo 的装配条件

- `enablesCalculator` 开启时注册 `math.calculate`。
- `enablesDateTime` 开启时注册 `time.query`。
- `enablesTextResources` 且提供 `DemoTextResourceStore` 时注册 `resource.list`、`resource.search` 和 Demo 版 `resource.readText`。
- 提供 `DemoFileResourceStore` 且开启资料工具时注册 `resource.inspect`、`resource.detectFormat`、`resource.readWindow`、`resource.readOffice`、`resource.listEntries`、`resource.readBytes`、`resource.readPDFLayout` 和 `resource.ocr`。
- Apple 工具通过 `DemoAppleToolHandlers` 注入，未提供 handler 时返回 `unavailable`。
- `web.fetch` 使用 Demo 配置的精确 Host allowlist 和受控 transport。
- `web.search` 使用 Demo 的搜索路由和配置的 provider。失败时不自动切换服务。
- `user.ask` 通过 `DemoToolInteractionHandlers.ask` 注入 UI。
- Demo 的 PDF 文本、布局和 OCR 在遇到密码保护文件时通过 `requestPDFPassword` 临时获取密码。密码只停留在当前调用内存中，不进入工具参数、资源引用、日志或结果 JSON。

### Demo 状态和生产接入边界

WorkflowRunnerDemo 已接入上述 24 个稳定工具的装配路径。Demo 的 Effect Store 是有界进程内账本，负责当前会话的授权、Intent 和 Receipt。它不替代下游产品自己的持久 Workflow 存储，也不自动为下游产品申请 Apple 权限或网络凭据。

Demo 已支持统一文件资源的内容寻址快照、跨进程恢复和会话引用恢复。下游接入方仍需实现自己的快照保留、撤销、配额、垃圾回收、权限重验和恢复策略。

## 已实现能力与明确边界

文件能力覆盖以下范围。

- 严格 UTF-8、UTF-16 LE/BE、GBK 和 GB18030 文本导入与 UTF-8 派生读取
- PDF 元数据、页文本、布局、字符框、注释框和 OCR
- DOCX、XLSX、PPTX OOXML 结构化读取
- ZIP/GZIP 安全条目列举和有界展开读取
- 任意二进制有界读取和 Base64 返回
- 内容寻址资源引用以及由 Host 实现的跨进程和重启恢复

当前不覆盖以下完整能力。

- 旧式 `.doc`、`.xls`、`.ppt` 的完整结构化排版解析
- ZIP 加密解密和旧式 Office 密码解密
- 任意二进制文件的语义解析
- Apple Notes 通用 CRUD
- 通知中心历史读取
- Mail 和 Messages 历史读取
- 静默发送邮件或信息
- 任意系统 App 自动化
- HealthKit 通用工具

Apple Notes 不适合作为通用系统 CRUD 工具，原因是缺少稳定的公开数据 API。产品如果需要笔记能力，应优先把 Agent 自有笔记作为受控资源类型设计。HealthKit 需要按数据类型拆分授权、隐私说明和审核边界，适合独立专项。

## 授权、确认与恢复

沿用 [现有工具授权与执行规则](ToolCalling.md)。

1. 只注册用户选择且依赖齐备的工具。
2. `toolImpactPolicy` 只开放需要的影响上限。
3. 资料、Apple、网络和用户交互工具使用 `BoneWorkflowToolExecutionPipeline(effectStore:)` 以及 `toolExecutionContextProvider`。
4. Host 将当前调用的工具 ID、版本、Schema、canonical arguments digest、身份、scope、revision、nonce 和有效期绑定到一次性 Grant。
5. 执行后保存 Receipt 并提交 Host checkpoint。取消、回执丢失和未知结果按现有恢复规则处理，不默认重发有副作用的操作。

资源引用不替代授权。网页 allowlist 不替代网络 effect 授权。用户回答不替代其他工具的授权。系统 UI 返回完成或取消也不等于外部系统最终送达。

## 验证与性能建议

工具测试应使用固定 clock、内存资料、假 HTTP transport、URLProtocol、模拟系统 handler 和固定权限状态。测试至少覆盖 Schema、边界、取消、重复调用、资源撤销、引用版本变化、密码错误、归档安全、分页游标和敏感值不落日志。

性能验证应将文件导入、格式探测、结构解析、页读取、OCR、网络响应和工具结果编码分别计量。大文件应优先使用 `inspect`、`detectFormat`、`search` 和局部窗口读取，避免把全文或整个归档一次性解析到内存。PDF 布局和 OCR 的页数、元素数、文本字节数与原始页面数据预算会直接影响 CPU、内存和结果传输体积。

工具的实际账号、站点、系统权限、搜索服务额度和在线可用性由接入方验证。SDK 提供的是稳定工具边界和 Host 注入契约，不替下游产品决定权限弹窗、数据保留周期、计费上限或系统 UI 的业务流程。
