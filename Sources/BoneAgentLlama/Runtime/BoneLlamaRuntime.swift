import Foundation

public protocol BoneLlamaRuntime: Sendable {
    var runtimeVersion: Int { get }

    func load(
        modelURL: URL,
        configuration: BoneLlamaRuntimeConfiguration
    ) async throws

    /// 使用已加载模型的真实 Tokenizer 计算完整 Prompt Token 数。
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization

    /// 按 SDK 计算的 Token ranges 分批 prefill 后生成；不得将超过 batch 的 Prompt 一次 decode。
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions
    ) async throws -> BoneLlamaGenerationResult

    func verifyBasicGeneration() async throws
    func cancel() async
    func unload() async
}

public struct BoneLlamaNativeTemplateCapabilities: Equatable, Sendable {
    public let supportedReasoningModes: Set<BoneLlamaReasoningMode>
    public let supportsAddGenerationPrompt: Bool
    public let templateFamily: String?

    public init(
        supportedReasoningModes: Set<BoneLlamaReasoningMode>,
        supportsAddGenerationPrompt: Bool,
        templateFamily: String? = nil
    ) {
        self.supportedReasoningModes = supportedReasoningModes
        self.supportsAddGenerationPrompt = supportsAddGenerationPrompt
        self.templateFamily = templateFamily
    }
}

/// 可选的 GGUF 原生模板渲染能力；结构化消息不得预先套用其他模型模板。
public protocol BoneLlamaNativeTemplateRenderingRuntime: BoneLlamaRuntime {
    func nativeTemplateCapabilities() async throws -> BoneLlamaNativeTemplateCapabilities

    func renderNativeTemplate(
        conversation: BoneLlamaConversation,
        addGenerationPrompt: Bool,
        reasoningMode: BoneLlamaReasoningMode
    ) async throws -> BoneLlamaRenderedPrompt
}

/// Runtime 在能力 Smoke 中提供的实际 Tokenizer、Grammar Parser/Sampler 与 Stop Matcher 身份。
public struct BoneLlamaRuntimeVerificationComponents: Equatable, Sendable {
    public let tokenizerID: String
    public let tokenizerVersion: String
    public let grammarParserID: String?
    public let grammarParserVersion: String?
    public let grammarSamplerID: String?
    public let grammarSamplerVersion: String?
    public let stopMatcherID: String?
    public let stopMatcherVersion: String?

    public init(
        tokenizerID: String,
        tokenizerVersion: String,
        grammarParserID: String? = nil,
        grammarParserVersion: String? = nil,
        grammarSamplerID: String? = nil,
        grammarSamplerVersion: String? = nil,
        stopMatcherID: String? = nil,
        stopMatcherVersion: String? = nil
    ) {
        self.tokenizerID = tokenizerID
        self.tokenizerVersion = tokenizerVersion
        self.grammarParserID = grammarParserID
        self.grammarParserVersion = grammarParserVersion
        self.grammarSamplerID = grammarSamplerID
        self.grammarSamplerVersion = grammarSamplerVersion
        self.stopMatcherID = stopMatcherID
        self.stopMatcherVersion = stopMatcherVersion
    }
}

public protocol BoneLlamaRuntimeVerificationIdentifying: BoneLlamaRuntime {
    func verificationComponents() async throws -> BoneLlamaRuntimeVerificationComponents
}

/// 支持将 SDK 受信任 Compiler 产物接入真实 grammar sampler 的生成 Runtime。
/// Constraint 请求只能走此协议；旧 Controlled Runtime 仅兼容 Stop-only 请求。
public protocol BoneLlamaConstraintGenerationRuntime: BoneLlamaRuntime {
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions,
        control: BoneLlamaResolvedGenerationControl
    ) async throws -> BoneLlamaGenerationResult
}

public typealias BoneLlamaRuntimeFactory = @Sendable () -> any BoneLlamaRuntime
