import Foundation
import BoneAgentKit

/// 确定性消费响应脚本，并保留收到的强类型请求供测试检查。
public actor BoneScriptedInferenceEngine: BoneInferenceEngine {
    public nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    public nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private var remainingScript: [BoneInferenceResponse]
    private var requests: [BoneInferenceRequest] = []

    public init(script: [BoneInferenceResponse]) {
        remainingScript = script
    }

    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        requests.append(request)
        guard !remainingScript.isEmpty else {
            throw BoneScriptedInferenceEngineError.scriptExhausted
        }
        return remainingScript.removeFirst()
    }

    public func receivedRequests() -> [BoneInferenceRequest] {
        requests
    }
}

public enum BoneScriptedInferenceEngineError: Error, Equatable, Sendable {
    case scriptExhausted
}
