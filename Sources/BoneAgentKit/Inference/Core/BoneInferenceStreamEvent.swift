import Foundation

/// Provider 无关的实时推理事件；只有 `completed` 表示完整且已验证的正式终态。
public enum BoneInferenceStreamEvent: Equatable, Sendable {
    case reasoningStarted(kind: BoneInferenceReasoning.Kind)
    case reasoningDelta(String)
    case reasoningCompleted
    case textDelta(String)
    case toolCallStarted(id: String, toolID: String)
    case toolArgumentsDelta(id: String, data: Data)
    case toolCallCompleted(id: String)
    case usage(BoneInferenceUsage)
    case completed(BoneInferenceDetailedResult)
}

public typealias BoneInferenceNormalizedEventStream = AsyncThrowingStream<BoneInferenceStreamEvent, Error>

/// 真正逐事件交付的推理能力；消费者取消必须取消底层请求。
public protocol BoneInferenceEventStreaming: Sendable {
    func inferenceEvents(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) -> BoneInferenceNormalizedEventStream
}
