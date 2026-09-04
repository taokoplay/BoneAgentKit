import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public struct BoneLlamaRuntimeConfiguration: Equatable, Sendable {
    public let contextTokens: Int
    public let batchTokens: Int
    public let threadCount: Int

    public init(plan: BoneLocalRuntimePlan) {
        contextTokens = plan.contextTokens
        batchTokens = plan.batchTokens
        threadCount = plan.threadCount
    }
}

public struct BoneLlamaGenerationOptions: Equatable, Sendable {
    public let maximumOutputTokens: Int
    public let temperature: Double

    public init(maximumOutputTokens: Int, temperature: Double) throws {
        guard maximumOutputTokens > 0, temperature.isFinite, (0...2).contains(temperature) else {
            throw BoneLlamaAdapterError.invalidGenerationOptions
        }
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }

    public init(
        inferenceOptions: BoneInferenceGenerationOptions,
        plan: BoneLocalRuntimePlan
    ) throws {
        do {
            _ = try inferenceOptions.validated()
        } catch {
            throw BoneLlamaAdapterError.invalidGenerationOptions
        }
        maximumOutputTokens = min(
            inferenceOptions.maximumOutputTokens ?? plan.maximumOutputTokens,
            plan.maximumOutputTokens
        )
        temperature = inferenceOptions.temperature ?? 0.7
    }
}

/// 使用已加载模型的真实 Tokenizer 得到的完整 Prompt Token 数。
public struct BoneLlamaPromptTokenization: Equatable, Sendable {
    public let tokenCount: Int

    public init(tokenCount: Int) throws {
        guard tokenCount > 0 else { throw BoneLlamaRuntimeError.tokenizationFailed }
        self.tokenCount = tokenCount
    }
}

/// SDK 计算的单次生成容量与 prefill 分片计划。
public struct BoneLlamaPromptExecutionPlan: Equatable, Sendable {
    public let promptTokenCount: Int
    public let contextTokens: Int
    public let maximumOutputTokens: Int
    public let batchTokens: Int
    public let prefillRanges: [Range<Int>]

    init(
        promptTokenCount: Int,
        contextTokens: Int,
        maximumOutputTokens: Int,
        batchTokens: Int,
        prefillRanges: [Range<Int>]
    ) {
        self.promptTokenCount = promptTokenCount
        self.contextTokens = contextTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.batchTokens = batchTokens
        self.prefillRanges = prefillRanges
    }
}

/// 根据真实 Token 数生成不会超过 Context 或单次 Decode Batch 的执行计划。
public enum BoneLlamaPromptExecutionPlanner {
    public static func plan(
        tokenization: BoneLlamaPromptTokenization,
        configuration: BoneLlamaRuntimeConfiguration,
        requestedMaximumOutputTokens: Int
    ) throws -> BoneLlamaPromptExecutionPlan {
        let promptCount = tokenization.tokenCount
        guard configuration.contextTokens > 0,
              configuration.batchTokens > 0,
              requestedMaximumOutputTokens > 0 else {
            throw BoneLlamaRuntimeError.contextCreationFailed
        }
        guard promptCount < configuration.contextTokens else {
            throw BoneLlamaRuntimeError.promptTooLong
        }
        let outputTokens = min(
            requestedMaximumOutputTokens,
            configuration.contextTokens - promptCount
        )
        guard outputTokens > 0 else { throw BoneLlamaRuntimeError.promptTooLong }

        var ranges: [Range<Int>] = []
        var lowerBound = 0
        while lowerBound < promptCount {
            let remaining = promptCount - lowerBound
            let upperBound = lowerBound + min(configuration.batchTokens, remaining)
            ranges.append(lowerBound..<upperBound)
            lowerBound = upperBound
        }
        return .init(
            promptTokenCount: promptCount,
            contextTokens: configuration.contextTokens,
            maximumOutputTokens: outputTokens,
            batchTokens: configuration.batchTokens,
            prefillRanges: ranges
        )
    }
}

public enum BoneLlamaGenerationTermination: Codable, Equatable, Sendable {
    case eog
    case stopToken(id: Int32)
    case stopString(index: Int)
    case maximumTokens
    case runtimeCompleted
}

public struct BoneLlamaGenerationResult: Equatable, Sendable {
    public let text: String
    public let termination: BoneLlamaGenerationTermination

    public init(
        text: String,
        termination: BoneLlamaGenerationTermination = .runtimeCompleted
    ) {
        self.text = text
        self.termination = termination
    }
}

public enum BoneLlamaRuntimeError: Error, Equatable, Sendable {
    case modelNotFound
    case modelIncompatible
    case insufficientResources
    case loadFailed
    case contextCreationFailed
    case tokenizationFailed
    case promptTooLong
    case nativeTemplateUnavailable
    case generationFailed
    case cancelled
}

public enum BoneLlamaAdapterError: Error, Equatable, Sendable {
    case modelMismatch
    case invalidConfiguration
    case invalidGenerationOptions
    case invalidGenerationControl
    case unsupportedGenerationControl
    case outputTruncated
    case unsupportedRequest
    case invalidToolCallingResponse
    case emptyResponse
    case runtime(BoneLlamaRuntimeError)
}
