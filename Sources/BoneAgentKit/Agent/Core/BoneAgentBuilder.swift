import Foundation

/// 组装 BoneAgent 所需的内置文本 Provider Engine。
///
/// 该工厂只按 Provider 协议变体选择 Engine，不猜测模型能力、reasoning profile
/// 或在线可用性；这些事实仍由 Host 显式注入或验证。
public enum BoneAgentProviderFactory {
    public static func makeEngine(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) -> any BoneInferenceEngine {
        switch configuration.kind {
        case .google:
            return BoneGeminiInferenceEngine(configuration: configuration, transport: transport)
        case .anthropic, .miniMax:
            return BoneAnthropicInferenceEngine(configuration: configuration, transport: transport)
        case .openAI, .zhipu, .siliconFlow, .newAPI, .custom, .agnes:
            return BoneOpenAIInferenceEngine(configuration: configuration, transport: transport)
        }
    }
}

/// 以渐进式方式组装常见的 Agent。
///
/// 默认路径只需要 Engine、Tool 和一次 `build()`；高级调用方仍可直接使用
/// `BoneAgent`，或通过 `withConfiguration(_:)` 注入预算、上下文管理和调度策略。
public struct BoneAgentBuilder: Sendable {
    private let inferenceEngine: any BoneInferenceEngine
    private var tools: [BoneAnyAgentTool]
    private var toolContext: any BoneAgentToolContext
    private var configuration: BoneAgentConfiguration

    public init(
        inferenceEngine: any BoneInferenceEngine,
        maximumSteps: Int = 4
    ) throws {
        self.inferenceEngine = inferenceEngine
        tools = []
        toolContext = BoneAgentEmptyContext()
        configuration = try BoneAgentConfiguration(maximumSteps: maximumSteps)
    }

    public init(
        providerConfiguration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport(),
        maximumSteps: Int = 4
    ) throws {
        try self.init(
            inferenceEngine: BoneAgentProviderFactory.makeEngine(
                configuration: providerConfiguration,
                transport: transport
            ),
            maximumSteps: maximumSteps
        )
    }

    /// 添加一个强类型 Tool；重复 ID 会在 `build()` 时稳定拒绝。
    public func withTool<Tool: BoneAgentTool>(_ tool: Tool) -> Self {
        withTool(BoneAnyAgentTool(tool))
    }

    /// 添加返回文本/图片引用内容的 Tool。
    public func withTool<Tool: BoneAgentContentTool>(_ tool: Tool) -> Self {
        withTool(BoneAnyAgentTool(tool))
    }

    /// 添加已经完成类型擦除的 Tool。
    public func withTool(_ tool: BoneAnyAgentTool) -> Self {
        var copy = self
        copy.tools.append(tool)
        return copy
    }

    /// 注入 Tool 所需的业务 Context。
    public func withContext(_ context: any BoneAgentToolContext) -> Self {
        var copy = self
        copy.toolContext = context
        return copy
    }

    /// 覆盖默认配置；适合注入预算、调度、上下文管理和事件策略。
    public func withConfiguration(_ configuration: BoneAgentConfiguration) -> Self {
        var copy = self
        copy.configuration = configuration
        return copy
    }

    /// 创建独立的 Agent Runtime。
    public func build() throws -> BoneAgent {
        BoneAgent(
            inferenceEngine: inferenceEngine,
            toolRegistry: try BoneAgentToolRegistry(tools: tools),
            toolContext: toolContext,
            configuration: configuration
        )
    }
}
