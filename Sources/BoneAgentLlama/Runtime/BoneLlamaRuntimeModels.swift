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

public struct BoneLlamaGenerationResult: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
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
    case generationFailed
    case cancelled
}

public enum BoneLlamaAdapterError: Error, Equatable, Sendable {
    case modelMismatch
    case invalidGenerationOptions
    case unsupportedRequest
    case invalidToolCallingResponse
    case emptyResponse
    case runtime(BoneLlamaRuntimeError)
}
