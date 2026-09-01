# 本地模型基础 Module

`BoneAgentLocalRuntime` 是不绑定具体推理后端的本地模型基础 Product。它依赖 `BoneAgentKit` 的模型上下文限制契约，但不链接 llama.cpp、Foundation Models、MLX 或 Core ML。

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

后续 `BoneAgentLlama` 与 `BoneAgentFoundationModels` 将使用 Catalog、Store、Environment 和 Plan，并实现 `BoneInferenceEngine`。Core Product 不直接链接具体本地 Runtime。

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

`metadata` 只运行静态预检；`load` 和 `smoke` 会在静态检查通过后调用 Adapter。Core 的 GGUF 检查仅验证前四字节 `GGUF`，架构、量化、Tokenizer、真实加载和最小 Decode 均属于 `BoneAgentLlama`。Probe Report 不包含绝对路径、Prompt、模型输出或底层错误文本。

Background URLSession、全局下载队列、业务错误文案和实际推理 Adapter 尚不属于本批实现。
