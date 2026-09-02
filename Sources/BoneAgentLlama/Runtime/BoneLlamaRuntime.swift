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

    func smokeTest() async throws
    func cancel() async
    func unload() async
}

public typealias BoneLlamaRuntimeFactory = @Sendable () -> any BoneLlamaRuntime
