# 本地模型基础 Module

`BoneAgentLocalRuntime` 是不绑定具体推理后端的本地模型基础 Product。它依赖 `BoneAgentKit` 的模型上下文限制契约，但不链接 llama.cpp、Foundation Models、MLX 或 Core ML。

## 当前职责

- `BoneLocalModelCatalog`：解码并校验版本化 Manifest。
- `BoneLocalModelDescriptor`：模型事实、上下文限制、内存要求和许可证。
- `BoneLocalModelArtifact`：文件名、大小、SHA-256 与多个受信下载源。
- `BoneLocalModelStore`：安全路径、完整性校验、partial 到 final 原子安装、删除和残留清理。
- `BoneLocalRuntimeEnvironment`：可注入的内存、磁盘、CPU、模拟器、低电量和热状态快照。
- `BoneLocalRuntimePlanner`：夹紧模型理论上限、Runtime 上限、Host 上限与请求偏好。

## Host 仍然负责

- 模型下载 UI、蜂窝网络确认和错误文案。
- 用户选择与产品推荐策略。
- App Prompt、人格和敏感数据规则。
- 注入模型存储根目录和下载策略。

## Adapter seam

后续 `BoneAgentLlama` 与 `BoneAgentFoundationModels` 将使用 Catalog、Store、Environment 和 Plan，并实现 `BoneInferenceEngine`。Core Product 不直接链接具体本地 Runtime。

## 示例

```swift
import BoneAgentLocalRuntime

let catalog = try BoneLocalModelCatalog(data: manifestData)
let model = catalog.model(id: "qwen-2b-q4")!
let store = try BoneLocalModelStore(rootURL: hostModelDirectory)
let environment = try BoneLocalRuntimeEnvironment.current(storageURL: hostModelDirectory)
let plan = try BoneLocalRuntimePlanner.plan(
    model: model,
    environment: environment,
    runtimeConstraints: runtime.constraints
)
```

下载执行器和实际推理 Adapter 尚不属于本批实现。
