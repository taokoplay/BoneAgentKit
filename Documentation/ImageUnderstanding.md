# 图片理解输入与上下文预算

## 能力与边界

图片理解通过独立的 `.imageInput` 能力启用，与 `.imageGeneration` 分开。用户消息和 Tool Result 可包含有序文本与图片引用；现有字符串消息、JSON Tool 和默认 Provider 构造方式保持原行为。

SDK 提供不可变引用、注入式预处理/解析、三个 Provider 的原生图片 wire 和预算检查。Host 负责原图、处理后图片的不可变存储、每次读取授权、有效期、清理和业务验收。引用不是授权凭据；SDK 不自动读任意文件、下载 URL、上传文件、重试生成或修改图片。

## 最小接入

以下函数使用调用方已核验的站点、精确模型 ID、容量和视觉估算规则；没有模型名称推断或通用固定图片 Token 默认值。

```swift
import Foundation
import BoneAgentKit

#if canImport(ImageIO) && canImport(CoreGraphics)
func makeVisionRequest(
    source: Data,
    assetID: String,
    version: String,
    modelID: String,
    limits: BoneContextWindowBudget,
    provider: BoneInferenceProviderConfiguration,
    transport: any BoneInferenceHTTPTransport,
    estimateVisualTokens: @escaping BoneInferenceImageTokenEstimator,
    save: @Sendable (BoneInferenceImageReference, Data) async throws -> Void,
    loadAuthorized: @escaping @Sendable (BoneInferenceImageReference) async throws -> Data
) async throws -> (BoneOpenAIInferenceEngine, BoneInferenceRequest) {
    let prepared = try await BoneInferenceImageIO.preprocessor.prepare(source)
    let reference = try prepared.reference(id: assetID, version: version)
    try await save(reference, prepared.data)

    let profile = try BoneInferenceImageInputProfile(
        contextBudget: limits,
        tokenEstimator: estimateVisualTokens
    )
    let images = try BoneInferenceImageInputConfiguration(
        profiles: [modelID: profile],
        resolver: .init(
            inspect: { try BoneInferenceImageIO.inspect($0) },
            load: loadAuthorized
        )
    )
    let engine = BoneOpenAIInferenceEngine(
        configuration: provider,
        transport: transport,
        imageInputConfiguration: images
    )
    let message = try BoneInferenceMessage.user(content: [
        .text("Read the table in this image and identify uncertain cells."),
        .image(.init(reference: reference))
    ])
    return (engine, .init(modelID: modelID, messages: [message]))
}
#endif
```

`limits.maximumOutputTokens` 必须已知。`save` 必须在同一 ID/版本下保持字节不变；`loadAuthorized` 每次根据当前用户与访问范围校验，不能因旧会话里有引用就自动放行。非 Apple 平台注入可信的 `BoneInferenceImageInspector` 与 `BoneInferenceImagePreprocessor`，不能只看 MIME、扩展名或调用方声称的尺寸。

Agent 开启压缩后使用同一模型估算规则：

```swift
let agent = try BoneAgentBuilder(inferenceEngine: engine)
    .withConfiguration(.init(
        maximumSteps: 12,
        contextManagement: .init()
    ))
    .build()
let result = try await agent.run(request: request)
```

`BoneAgentConversation.send(content:)` 接收同样的内容数组。私有会话导出仅保存图片引用及元数据，不含图片字节；恢复后仍需原 Host 解析器提供精确版本。

## Token 与传输字节是两套预算

完整输入估算为：

```text
文本 + 每次出现的视觉 Token + 图片/消息包装
     + 工具来源标签 + Tool Schema + 输出约束/格式 + continuation
```

视觉估算器接收**预处理完成后实际发送**的宽、高、格式和 detail。它必须返回正整数，按精确模型/网关规则估算；未知规则拒绝处理，不能返回 0。相同图片在历史里出现两次，计两次视觉成本；发送前同一引用只加载一次不减免上下文成本。Base64 长度不换算为视觉 Token。

容量使用已有 `BoneContextWindowBudget`：先从上下文窗口扣除真正发送的输出额度、协议预留与安全余量，再与独立最大输入上限取较小值。Tool Schema 等输入成本计在该容量内。图片配置默认安全余量为 1024 Token；Agent 使用它与上下文策略余量的较大值，图片协议预留至少 128 Token。Provider 对最终请求独立复验。

启用 `contextManagement` 后，默认在**上述可用输入容量的 85%**触发整理，目标为 65%。每个候选都按完整文字与图片重新测量。必须保留的当前请求或最近工具交换若仍超过硬容量，在图片解析器和网络调用之前失败；已满足硬容量但保留内容高于 65% 时允许保留，不丢弃当前输入来追求目标值。

默认只裁剪完整旧 Turn。显式设置 `minimumRecentToolExchangeCount` 后可移除当前 Turn 中完整的旧工具交换；图片引用随完整交换一起移除。多模态 Tool Result 不参与文本 `clamp`，不会把图片引用 JSON 截成文本。摘要器只收到历史文本和引用元数据，并明确提示没有图片像素；摘要不是视觉内容保真的替代物，重新检查图片需要 Host 再次提供引用。

直接调用 `engine.infer` 会检查完整预算并拒绝超限，但不会自动压缩。独立 `BoneContextCompactor` / `BoneContextWindowPlanner` 可显式传入 `imageTokenEstimator`；它们仅统计消息，调用方仍需为 Tool Schema、continuation 等额外预留。Planner 的图片历史必须为合法完整用户轮次，按轮次保留工具配对。旧非 throwing 估算入口遇到未配置图片估算时返回 `Int.max`；新代码应使用 throwing 入口，避免对哨兵值继续做算术。

传输另外限制图片数、单图编码字节、总 Base64 和最终 HTTP body。默认分别为 20 张、5 MiB、20 MiB、32 MiB。引用可判断的超限先于解析；最终 body 在构造后、发送前检查。`BoneRunBudget.maximumInputBytes` 还会累计引用请求 JSON 和每次图片出现的 Base64 字节预留，这不是精确 HTTP wire 长度。默认限制可在 profile 中收紧或在 SDK 硬上限内调整。

这些值是请求前估算，不是 Provider 返回的真实 Usage，也不承诺远端永不拒绝。Host 应维护模型规则来源、版本和保守余量；SDK 不因远端拒绝而自动重试。

## 预处理与细节保留

`BoneInferenceImagePreprocessingPolicy` 默认最大宽高 2048、总像素 4,000,000、处理后 4 MiB，源字节最多 20 MiB、源像素最多 64,000,000。不放大图片，只按明确尺寸/像素限制等比缩小一次。OCR、长截图或细节场景应显式提高目标尺寸/像素限制，并保证视觉 Token 规则支持该分辨率。

Apple `BoneInferenceImageIO.preprocessor` 校正 EXIF 全方向、重绘为 8-bit sRGB、保留透明度、清理源 EXIF/GPS/文本元数据。默认输出无损 PNG；满足严格条件的已规范 PNG 可原样返回。只有 `allowsLossy = true` 且没有 alpha 时采用 JPEG，按配置质量、0.75、0.6 向下尝试；不会因字节上限继续缩小图片，无法满足时返回 `preparedImageTooLarge`。PNG 无损编码不代表缩放或色彩转换无损。

编码后会重新解码验证。动画、多页容器、损坏数据和资源超限拒绝；JPEG/WebP 保守重编码，HEIC 等可在系统支持解码时转为 PNG/JPEG，不提供 WebP 编码。检查和转换可能完整解码源图，峰值内存随源像素上限增长；移动端应按实际内存预算收紧 `maxSourcePixels`。该同步编解码实现可协作取消，但不承诺中断正在运行的系统解码。

预处理是显式操作，不会在每次发送时悄悄改变冻结的引用或尺寸。SDK 发送前验证 SHA-256、实际字节长度、解码格式及尺寸完全匹配。原图与处理后版本都由 Host 保管，SDK 不把处理结果回写到原图。

## 工具图片与 Provider 映射

内容工具实现 `BoneAgentContentTool`，返回例如：

```swift
return .multimodal([
    .text("Page 3, full table; the bottom-right cell is blurred."),
    .image(.init(reference: reference))
])
```

使用 `BoneAnyAgentTool(tool)` 或 `BoneAgentBuilder.withTool(tool)` 显式注册。原 `BoneAgentTool` 的任意 JSON Output 继续作为 `.json`，即使 JSON 看起来像图片信封也不会自动解包。异构工具调用方可用 `executeContent` 获取类型化内容；旧 `execute` 的 Data 对内容工具表示 `BoneToolResultContent` 信封。图片工具同样经过既有权限、执行管线、预算、取消和恢复流程。

| Provider | 用户图片 | 工具图片 | detail |
| --- | --- | --- | --- |
| OpenAI Chat Completions/兼容协议 | `image_url` data URL | 先发完连续 Tool Results，再追加带 callID/toolID 来源标签的 user 图片行 | automatic→auto、low、high |
| Anthropic Messages | Base64 image block | `tool_result.content` 中原生 image block | automatic |
| Gemini GenerateContent | `inlineData` | functionResponse 后在同一 user 内容中追加来源标签与图片 | automatic |

兼容网关仍须单独核验。三者均要求精确 model profile，并受显式能力 profile/模态声明限制；没有图片配置不会自动授予 `.imageInput`。OpenAI/Gemini 适配保留工具来源和错误状态，并处理新增 wire 行对 continuation 的影响。当前 Llama 仅有文本 Runtime，明确拒绝图片。

## 验证与兼容性

`VisionInputTests`、`VisionProviderTests`、`ImagePreprocessingTests` 覆盖实际 Agent 会话/工具流程、视觉压缩、拒绝前零解析/零发送、重复引用、Provider 五种调用入口、合成 SSE、continuation、真实 Apple 图片解码、方向/颜色/透明度/元数据处理与取消。Provider/Agent 测试使用离线响应，不能证明 OCR 或真实模型识图准确率。

新增 enum case `.imageInput`、`.multimodal` 会要求穷尽 switch 的调用方迁移。追加的可选构造参数保持普通带标签调用兼容；不承诺既有函数引用/预编译 ABI 兼容。最低源码要求仍为 Swift 5.9、iOS 13、macOS 13；最低工具链、真机、线上模型和 Host 存储集成须各自验收。
