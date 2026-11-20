import Foundation
import BoneAgentKit

/// Explicit UI-test injection. No real network, fallback, live timing, or credentials.
struct LiveChatUITestTransport: BoneInferenceHTTPTransport {
    let provider: DemoChatProvider
    static let fileRecovery = DemoFileRecoveryTransport()
    private var isFileRecovery: Bool { ProcessInfo.processInfo.arguments.contains("--file-recovery-ui-test") }
    static let contextCompression = DemoContextCompressionTransport()
    private var isContextCompression: Bool { ProcessInfo.processInfo.arguments.contains("--context-capacity-ui-test") }
    private var waits: Bool { ProcessInfo.processInfo.arguments.contains("--live-chat-wait") }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        if isFileRecovery { return try await Self.fileRecovery.send(request) }
        if isContextCompression { return try await Self.contextCompression.send(request) }
        if waits { try await Task.sleep(for: .seconds(60)) }
        let data: String
        switch provider.kind {
        case .anthropic, .miniMax:
            data = #"{"id":"ui-test","type":"message","role":"assistant","content":[{"type":"text","text":"UI 测试回复（未联网）"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2}}"#
        case .google:
            data = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"UI 测试回复（未联网）"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2,"totalTokenCount":5}}"#
        default:
            data = #"{"id":"ui-test","choices":[{"index":0,"message":{"role":"assistant","content":"UI 测试回复（未联网）"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
        }
        return .init(statusCode: 200, data: Data(data.utf8))
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        var events: [BoneInferenceEventStreamEvent] = []
        for try await event in eventStream(request, options: options) { events.append(event) }
        return .init(statusCode: 200, events: events)
    }

    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        if isFileRecovery { return Self.fileRecovery.eventStream(request, options: options) }
        if isContextCompression { return Self.contextCompression.eventStream(request, options: options) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if waits { try await Task.sleep(for: .seconds(60)) }
                    let slow = ProcessInfo.processInfo.arguments.contains("--live-chat-stream-slow")
                    for event in try fixtureEvents(request: request) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                        if slow { try await Task.sleep(for: .milliseconds(600)) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func fixtureEvents(request: URLRequest) throws -> [BoneInferenceEventStreamEvent] {
        if let events = try BaiduAnswerUITestFixture.events(request: request, provider: provider) { return events }
        if let events = try LiveToolsUITestFixture.events(request: request, provider: provider) { return events }
        switch provider.kind {
        case .anthropic, .miniMax:
            return [
                .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"ui-test","type":"message","role":"assistant","content":[],"model":"ui-test","usage":{"input_tokens":3,"output_tokens":0}}}"#),
                .init(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
                .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"UI 测试"}}"#),
                .init(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"回复（未联网）"}}"#),
                .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}"#),
                .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
            ]
        case .google:
            return [
                .init(data: #"{"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"UI 测试"}]}}]}"#),
                .init(data: #"{"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"回复（未联网）"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2,"totalTokenCount":5}}"#)
            ]
        default:
            return [
                .init(data: #"{"id":"ui-test","choices":[{"index":0,"delta":{"role":"assistant","content":"UI 测试"},"finish_reason":null}]}"#),
                .init(data: #"{"id":"ui-test","choices":[{"index":0,"delta":{"content":"回复（未联网）"},"finish_reason":null}]}"#),
                .init(data: #"{"id":"ui-test","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#),
                .init(data: "[DONE]")
            ]
        }
    }
}
