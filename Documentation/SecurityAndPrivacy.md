# 安全与隐私

## 禁止记录或持久化

生产日志、指标、事件、Harness Report、Checkpoint、错误消息和测试快照均禁止包含：

- 书籍**正文**、用户 **Prompt**；
- **API Key**、**Cookie**、**Authorization**；
- **原始模型响应**或未审计的 `localizedDescription`；
- **完整 Provider UUID**、数据库路径/坐标；
- **完整 Base64/Data**、inline 图片正文；
- 带签名、Token、用户资源路径的**敏感 URL**；
- 可还原用户内容的完整角色描述或 Tool 参数/结果。

允许记录的最小白名单是：运行阶段、稳定错误分类、安全短 ID、HTTP 状态类别、响应长度、载荷类别、byteCount、MIME、候选/持久化计数。短 ID 必须不可逆且不输出完整 Provider UUID。

标准 `BoneRunCheckpoint` 必须显式声明 `BoneCheckpointDataClassification` 与 `BoneCheckpointRetention`，只接受 `.safeState` 或 `.opaqueReference`。`.userPrivate`、`.credential`、`.providerContinuation` 与 `.rawModelExchange` 通过标准构造入口 fail-closed；若未来 Host 需要保存此类内容，必须另建具有加密、隔离、到期和删除能力协商的专用 Store，不能借普通 JSON payload 绕过。

## 运行数据边界

`BoneInferenceImagePayload` 的 URL/Base64/Data 只用于单次运行；可持久化 metadata 不含原值且不能恢复原图。需要保存图片时，由 App 资产层显式接管，执行访问控制、生命周期和删除策略。

Tool 参数和结果各限制 1 MiB，但“未超限”不代表可写日志。类型擦除只在 Registry 的 JSON 编解码边界，不使用 `[String: Any]` 扩散敏感值。

## 事件不是事实源

`BoneAgentEventSink` 事件**不是持久事实源**，不能用于重建数据库或替代交易提交。事件丢失、重复观察或进程退出都不能改变业务事实。

- 用户确认与一次性授权由 App 控制；Prompt 不能替代权限规则。
- 数据库坐标、事务、人工字段保护和持久化状态由 App 控制。
- Agent Tool 只是 Adapter；通用 Kit 不直接访问数据库、Keychain、UIKit 或业务实体。

## Provider 与真实测试

凭据只从 App 既有安全设施在调用时注入 `BoneInferenceProviderConfiguration`，不得进入日志、事件、错误和普通持久化。`BoneInferenceHTTPTransport` 在 JSON/SSE 上层解析前限制响应容量，传播取消；POST 不自动重试，模型发现 GET 最多重试一次。SSE 只在正常 EOF 且完整成帧后交付结果，首事件/idle timeout、截断和超限不得返回部分结果。生产执行链不得回退到迁移前的 `AIProviderKit` Transport，以免形成第二套认证、重试或日志策略。

内置端点只允许 HTTPS；用户自定义 HTTP 只允许 localhost、回环、RFC1918、链路本地和 IPv6 ULA。绝对 operation endpoint 必须在解析后重新校验。自定义 Header 禁止覆盖 Authorization、API Key、Cookie、Host、Content-Length 和 Content-Type。

ParsingBook 的 Catalog、模型发现、Provider 连通性、普通文本、角色复用文本链和生图已经使用 BoneInference 自有配置与 Transport；设置 UI、数据库和用户配置继续作为 App Host 业务边界存在，不依赖旧 Kit。App 错误映射只能读取 BoneInference 稳定枚举、HTTP 状态与脱敏网络诊断，不得读取 `localizedDescription`、`userInfo`、响应 Data、请求 Header 或 Body。旧 Kit 安全 Contract 的分类接管证据见 [LegacyProviderMigration.md](LegacyProviderMigration.md)。真实 Provider smoke 仅在 App 沙箱内显式 opt-in，固定最小输入，输出脱敏摘要；不得由测试脚本扫描环境变量、Keychain 或用户文件。

## 图片生成权利

框架的 payload 校验不保证内容权利。项目层必须依据供应商条款、用户输入、参考图来源和用途治理版权、商标、肖像、内容政策与对外发布；必要时要求用户确认并保留合规所需的最小来源/用途记录。
