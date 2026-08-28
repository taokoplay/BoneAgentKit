import Foundation
import BoneAgentKit

/// 只记录不含正文、Prompt、参数或原始响应的安全 Agent 事件。
public actor BoneAgentEventRecorder {
    private var recordedEvents: [BoneAgentEvent] = []

    public init() {}

    public func record(_ event: BoneAgentEvent) {
        recordedEvents.append(event)
    }

    public func events() -> [BoneAgentEvent] {
        recordedEvents
    }

    public nonisolated func eventSink() -> BoneAgentEventSink {
        BoneAgentEventSink { [weak self] event in
            await self?.record(event)
        }
    }
}
