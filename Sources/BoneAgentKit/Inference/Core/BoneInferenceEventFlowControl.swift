import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 可选的端到端流控能力。采用此协议的 Engine 必须在内部传输与事件转换中保留容量边界。
/// 旧的 BoneInferenceEventStreaming 不受影响；不允许把无界旧流转发后宣称支持本能力。
public protocol BoneInferenceFlowControlledEventStreaming: BoneInferenceEventStreaming {
    /// 只做本地能力检查，不得启动请求。Agent 在接受新 Run 之前调用。
    func validateEventFlowControl() throws

    func inferenceEvents(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions,
        buffering: BoneEventBufferLimits
    ) -> BoneBoundedEventStream<BoneInferenceStreamEvent>
}

/// 原生回调不能等待消费方时，容量不足必须失败并停止请求，不能静默丢弃事件。
public protocol BoneInferenceFlowControlledHTTPTransport: BoneInferenceHTTPTransport {
    func eventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions,
        buffering: BoneEventBufferLimits
    ) -> BoneBoundedEventStream<BoneInferenceEventStreamEvent>
}

extension BoneOpenAIInferenceEngine: BoneInferenceFlowControlledEventStreaming {}
extension BoneAnthropicInferenceEngine: BoneInferenceFlowControlledEventStreaming {}
extension BoneGeminiInferenceEngine: BoneInferenceFlowControlledEventStreaming {}
extension BoneInferenceURLSessionTransport: BoneInferenceFlowControlledHTTPTransport {}
