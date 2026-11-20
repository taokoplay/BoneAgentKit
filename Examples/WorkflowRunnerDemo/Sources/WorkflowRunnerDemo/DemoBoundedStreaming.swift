import Foundation
import BoneAgentKit

/// 离线契约 Demo：只消费公开 SDK 事件，不向 SDK 添加 UI 或会话展示逻辑。
enum DemoBoundedStreaming {
    struct Report: Codable {
        let eventCount: Int
        let deltaCount: Int
        let peakQueuedEvents: Int
        let peakQueuedPayloadBytes: Int
        let identitiesMatch: Bool
    }
    private enum Failure: Error { case invalidObservation }

    static func run() async throws -> Report {
        let chunks = (0..<128).map { "片段\($0)🌊" }
        let identities = DemoStreamIdentities()
        let agent = try BoneAgentBuilder(inferenceEngine: DemoBoundedEngine(chunks: chunks))
            .withConfiguration(.init(maximumSteps: 1,
                statusSink: .init { await identities.status($0.runID) },
                tokenSink: .init { await identities.tokens($0.runID) }))
            .build()
        let limits = try BoneEventBufferLimits(maximumEventCount: 4,
            maximumQueuedPayloadBytes: 64 * 1_024, maximumEventPayloadBytes: 16 * 1_024)
        let stream = try await agent.runObservedEvents(
            request: .init(modelID: "offline-flow-fixture", messages: [.init(role: .user, content: "fixture")]),
            options: .init(totalTimeout: 5), buffering: limits)
        var count = 0
        var deltas = 0
        var text = ""
        var completed: BoneAgentBoundaryResult?
        for try await envelope in stream {
            count += 1
            guard envelope.runID == stream.runID, envelope.sequence == UInt64(count) else {
                throw Failure.invalidObservation
            }
            switch envelope.event {
            case .textDelta(_, let delta): deltas += 1; text += delta
            case .completed(let result):
                guard completed == nil else { throw Failure.invalidObservation }
                completed = result
            default: break
            }
            await Task.yield()
        }
        let snapshot = stream.bufferSnapshot
        let matched = await identities.matches(stream.runID)
        guard deltas == chunks.count, text == chunks.joined(), matched,
              completed?.completion == .modelFinished(.text(text)),
              snapshot.peakBufferedEventCount <= limits.maximumEventCount,
              snapshot.peakBufferedPayloadBytes <= limits.maximumQueuedPayloadBytes else {
            throw Failure.invalidObservation
        }
        return .init(eventCount: count, deltaCount: deltas,
            peakQueuedEvents: snapshot.peakBufferedEventCount,
            peakQueuedPayloadBytes: snapshot.peakBufferedPayloadBytes, identitiesMatch: matched)
    }
}

private actor DemoStreamIdentities {
    private var statusID: UUID?
    private var tokenID: UUID?
    func status(_ id: UUID) { statusID = id }
    func tokens(_ id: UUID) { tokenID = id }
    func matches(_ id: UUID) -> Bool { statusID == id && tokenID == id }
}

/// 仅用于离线验证的受控生产者，不代表真实模型或网络性能。
private struct DemoBoundedEngine: BoneInferenceEngine, BoneInferenceFlowControlledEventStreaming {
    let chunks: [String]
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func validateEventFlowControl() throws {}
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: chunks.joined()) }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(.textDelta(chunk)) }
            continuation.yield(.completed(.init(response: .init(text: chunks.joined()), reasoning: nil)))
            continuation.finish()
        }
    }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions,
                         buffering: BoneEventBufferLimits) -> BoneBoundedEventStream<BoneInferenceStreamEvent> {
        let (stream, producer) = BoneBoundedEventStream<BoneInferenceStreamEvent>.makeStream(
            limits: buffering, payloadSize: { event in
                switch event {
                case .textDelta(let text): return 32 + text.utf8.count
                case .completed(let result): return 32 + ((try? JSONEncoder().encode(result.response).count) ?? Int.max / 2)
                default: return 32
                }
            })
        let task = Task {
            do {
                for chunk in chunks { try await producer.send(.textDelta(chunk)) }
                try await producer.send(.completed(.init(response: .init(text: chunks.joined()), reasoning: nil)))
                producer.finish()
            } catch { producer.finish(throwing: error) }
        }
        producer.onTermination { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }
}
