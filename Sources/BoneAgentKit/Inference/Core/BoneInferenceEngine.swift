import Foundation

/// 可由独立 Provider 模块实现的图片生成组件。
public protocol BoneInferenceImageGenerating: Sendable {
    func generateImages(
        request: BoneInferenceImageGenerationRequest
    ) async throws -> BoneInferenceImageGenerationResponse
}

/// 统一推理入口；图片能力由可选组件推导，避免声明与实现分离。
/// 使用流式网络协议但只在完整终态后交付统一响应的可选能力。
public protocol BoneInferenceBufferedStreaming: Sendable {
    func inferUsingStream(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse
}

/// 显式返回可读推理元数据的入口；结果只驻留内存，不自动记录或持久化。
public protocol BoneInferenceDetailedResultProviding: Sendable {
    func inferDetailed(
        request: BoneInferenceRequest
    ) async throws -> BoneInferenceDetailedResult
}

/// 使用流式传输、在完整终态后一次性交付详细结果的入口。
public protocol BoneInferenceDetailedBufferedStreaming: Sendable {
    func inferDetailedUsingStream(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceDetailedResult
}

public protocol BoneInferenceEngine: Sendable {
    /// 不含 imageGeneration 的文本侧能力声明。
    var nonImageCapabilities: Set<BoneInferenceCapability> { get }
    /// 可跨模块注入的图片生成组件；nil 表示不支持图片。
    var imageGenerator: (any BoneInferenceImageGenerating)? { get }

    /// 根据具体实例、模型、请求及调用方式解析本次可承诺能力。
    func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse
}

public extension BoneInferenceEngine {
    /// 引擎最终能力集合；imageGeneration 只由实际图片组件产生。
    var capabilities: Set<BoneInferenceCapability> {
        var result = nonImageCapabilities
        result.remove(.imageGeneration)
        if imageGenerator != nil {
            result.insert(.imageGeneration)
        }
        return result
    }

    func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities {
        .init(
            modelID: request.modelID,
            invocation: invocation,
            capabilities: capabilities
        )
    }

    /// 统一安全图片入口；无图片组件时不发生 Provider 调用。
    func generateImages(
        request: BoneInferenceImageGenerationRequest
    ) async throws -> BoneInferenceImageGenerationResponse {
        guard let imageGenerator else {
            throw BoneInferenceError.unsupportedCapability(.imageGeneration)
        }
        let response = try await imageGenerator.generateImages(request: request)
        return try response.validated()
    }
}
