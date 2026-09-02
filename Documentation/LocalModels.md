# 本地模型基础设施

> **范围：** 通用模型资产生命周期、设备规划、Runtime Probe，以及不绑定二进制的 llama Adapter 契约。

`BoneAgentLocalRuntime` 是不绑定具体推理后端的本地模型基础 Product。它依赖 `BoneAgentKit` 的模型上下文限制契约，但不链接 llama.cpp、Foundation Models、MLX 或 Core ML。

[返回文档地图](INDEX.md) · [查看架构说明](Architecture.md)

## 当前职责

- `BoneLocalModelCatalog`：解码并校验版本化 Manifest。
- `BoneLocalModelDescriptor`：模型事实、上下文限制、内存要求和许可证。
- `BoneLocalModelArtifact`：文件名、大小、SHA-256 与多个受信下载源。
- `BoneLocalModelStore`：安全路径、完整性校验、partial 到 final 原子安装、删除和残留清理。
- `BoneLocalModelDownloadCoordinator`：actor 状态机、空间预检、进度、暂停/恢复/取消和受控多源切换。
- `BoneLocalModelDownloadTransport`：可注入下载 seam；`BoneURLSessionLocalModelDownloadTransport` 是默认实现。
- `BoneLocalModelDownloadSecurityPolicy`：初始请求与逐跳重定向的 HTTPS/Host 白名单校验。
- `BoneLocalRuntimeEnvironment`：可注入的内存、磁盘、CPU、模拟器、低电量和热状态快照。
- `BoneLocalRuntimePlanner`：夹紧模型理论上限、Runtime 上限、Host 上限与请求偏好。
- `BoneLocalModelArtifactInspector`：验证安装、完整性与最小格式签名，不解析完整 GGUF metadata。
- `BoneLocalRuntimeProbeCoordinator`：编排 `metadata`、`load` 与 `smoke` 两阶段 Probe，并生成安全、确定性的报告。
- `BoneLocalRuntimeAdapterProbing`：供 llama.cpp、Foundation Models 等独立 Adapter 实现真实 availability/load/smoke 检查。

## Host 仍然负责

- 模型下载 UI、蜂窝网络确认和错误文案。
- 用户选择与产品推荐策略。
- App Prompt、人格和敏感数据规则。
- 注入模型存储根目录和下载策略。
- 决定是否允许蜂窝、如何持久化 resume data，以及前后台下载策略。

## Adapter seam

`BoneAgentLlama` 已提供可注入 `BoneLlamaRuntime`、隔离 load/smoke Probe、通用 ChatML encoder，以及默认 text-only、可显式扩展 Tool Calling 的 `BoneLlamaInferenceEngine`。它不链接具体 llama.cpp 二进制；后续 `BoneAgentLlamaCpp` 或 Binary Target 实现 Runtime seam。`BoneAgentFoundationModels` 仍由后续独立 Product 实现。Core Product 不直接链接具体本地 Runtime。

## 示例

```swift
import BoneAgentLocalRuntime

let catalog = try BoneLocalModelCatalog(data: manifestData)
let model = catalog.model(id: "qwen-2b-q4")!
let store = try BoneLocalModelStore(rootURL: hostModelDirectory)
let environment = try BoneLocalRuntimeEnvironment.current(storageURL: hostModelDirectory)
let transport = BoneURLSessionLocalModelDownloadTransport()
let downloader = BoneLocalModelDownloadCoordinator(store: store, transport: transport)
let installedURL = try await downloader.download(
    model,
    environment: environment,
    policy: .init(allowsCellularAccess: false)
)
let metadataReport = await BoneLocalRuntimeProbeCoordinator(store: store).probe(
    model: model,
    environment: environment,
    adapter: adapter,
    depth: .metadata,
    verifyChecksum: true
)
let plan = try BoneLocalRuntimePlanner.plan(
    model: model,
    environment: environment,
    runtimeConstraints: runtime.constraints
)
```

暂停产生的 opaque resume data 会反映在 `.paused` 状态；Host 可以自行持久化，并通过 `resume` 继续。网络不可达、超时和 HTTP 5xx 可按 Catalog 顺序切换到下一可信来源；4xx、安全违规或完整性失败不会自动切源。

`metadata` 只运行静态预检；`load` 和 `smoke` 会在静态检查通过后调用 Adapter。Core 的 GGUF 检查仅验证前四字节 `GGUF`，架构、量化、Tokenizer、真实加载和最小 Decode 均属于 `BoneAgentLlama`。Probe Report 不包含绝对路径、Prompt、模型输出或底层错误文本，并通过 `verifiedCapabilities` 只报告本次实际验证通过的能力：load 不授予推理能力，基础 smoke 成功授予 `.text`。

`BoneLocalModelDescriptor.inferenceCapabilityProfile` 是可选的 Catalog 证据；nil 表示 unknown，不表示模型明确不支持。Engine 配置 verified Profile 后，将其与当前 Runtime/Codec 实现取交集。模型声明 `.toolCalling` 且 Probe Adapter 注入对应 Codec 时，Smoke 使用无副作用 synthetic Tool 完成“生成调用 → 注入结果 → 生成最终文本”两轮验证；整个过程不注册或执行真实 Tool，任一步协议或 Schema 校验失败都不会授予 `.toolCalling`。

`BoneLlamaInferenceEngine` 默认只承诺 `.text`，并继续拒绝 Tool Calling、structured output、provider continuation、非隐藏 reasoning disclosure 和非文本消息。Prompt encoder 不含业务人格或敏感数据策略，Host 可注入自己的模板。

只有在初始化时显式注入 `BoneLlamaToolCalling`，Engine 才会为该实例声明 `.toolCalling`。内置 `BoneLlamaJSONToolCallingCodec` 使用 ChatML Prompt 和严格 JSON envelope，支持公开 Tool schema、同轮多个调用、Assistant Tool Call 历史及 Tool Result 续轮：

```swift
let engine = BoneLlamaInferenceEngine(
    modelID: model.id,
    modelURL: installedURL,
    plan: plan,
    toolCalling: BoneLlamaJSONToolCallingCodec(),
    runtimeFactory: runtimeFactory
)
```

调用输出必须完整匹配 `{"tool_calls":[{"id":"...","name":"wire_name","arguments":{...}}]}`；未知 Tool、重复调用 ID、非对象 arguments、空调用列表、截断 JSON 或夹带协议文本都会失败关闭。该 Codec 不是任意 GGUF 模型的自动兼容层：Host 必须通过真实模型 smoke 验证模型能够稳定遵循此模板；使用 Llama、Qwen、Hermes 等其他原生 Tool 模板时，应注入对应的 `BoneLlamaToolCalling` 实现。未注入 Codec 的旧初始化方式和 text-only 行为保持不变。

## 当前模型状态

Host 可以按需读取状态，也可以让页面持续订阅：

```swift
let snapshot = await engine.currentModelState()

for await state in await engine.modelStateUpdates() {
    // loading → loaded：加载完成
    // generating → loaded：生成完成且模型仍驻留
    // unloading → notLoaded：卸载完成
    // * → failed：操作失败
}
```

新订阅会立即收到当前快照；流采用 `bufferingNewest(1)`，慢页面只保留最新状态。每次变化带单调递增 `revision`。状态不包含模型绝对路径、Prompt、输出、下载凭据或底层 C API 文本。首版不伪造 llama.cpp 无法稳定提供的加载百分比。

具体 Runtime 可选择实现 `BoneLlamaRuntimeStateObserving`，直接暴露同样的快照与状态流；不实现该可选协议的旧 Runtime 仍可由 Engine 投影状态。当前同步原生生成仍受 actor 串行限制，状态 API 不应被解释为已提供低延迟跨任务取消。

Background URLSession、全局下载队列、业务错误文案、真实 llama.cpp Binary bridge 和 Foundation Models Adapter 尚不属于本批实现。

---

[返回文档地图](INDEX.md) · [查看安全与隐私](SecurityAndPrivacy.md)
