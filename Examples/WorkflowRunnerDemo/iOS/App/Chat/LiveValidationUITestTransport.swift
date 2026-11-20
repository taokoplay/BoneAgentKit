import Foundation
import BoneAgentKit

/// Explicit device UI-test transport. Production always constructs URLSession transport.
struct LiveValidationUITestTransport: BoneInferenceHTTPTransport {
    let provider: DemoChatProvider
    private enum Reply { case text(String), calculation }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        if ProcessInfo.processInfo.arguments.contains("--validation-wait") { try await Task.sleep(for: .seconds(60)) }
        let reply = try reply(to: request)
        let body: [String: Any]
        switch provider.kind {
        case .anthropic, .miniMax:
            let content: [[String: Any]]
            let stop: String
            switch reply {
            case .text(let text): content = [["type": "text", "text": text]]; stop = "end_turn"
            case .calculation:
                content = [["type": "tool_use", "id": "ui-validation-calc", "name": "math_calculate", "input": ["expression": "17*23"]]]
                stop = "tool_use"
            }
            body = ["id": "ui-validation", "type": "message", "role": "assistant", "content": content,
                    "stop_reason": stop, "usage": ["input_tokens": 3, "output_tokens": 2]]
        case .google:
            body = googleBody(reply)
        default:
            let message: [String: Any]
            let finish: String
            switch reply {
            case .text(let text): message = ["role": "assistant", "content": text]; finish = "stop"
            case .calculation:
                message = ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "ui-validation-calc", "type": "function",
                    "function": ["name": "math_calculate", "arguments": "{\"expression\":\"17*23\"}"]]]]
                finish = "tool_calls"
            }
            body = ["choices": [["index": 0, "message": message, "finish_reason": finish]],
                    "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]]
        }
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: body))
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        var result: [BoneInferenceEventStreamEvent] = []
        for try await event in eventStream(request, options: options) { result.append(event) }
        return .init(statusCode: 200, events: result)
    }
    func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    if ProcessInfo.processInfo.arguments.contains("--validation-wait") { try await Task.sleep(for: .seconds(60)) }
                    for event in try events(reply(to: request)) { try Task.checkCancellation(); continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    private func reply(to request: URLRequest) throws -> Reply {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? body["contents"] as? [[String: Any]] ?? []
        let users = messages.filter { $0["role"] as? String == "user" }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
        if encoded.contains("17 × 23") {
            return encoded.contains("tool_result") || messages.contains(where: { $0["role"] as? String == "tool" }) || encoded.contains("functionResponse")
                ? .text("计算结果为 391。") : .calculation
        }
        if encoded.contains("本次校验编号") {
            let range = encoded.range(of: #"[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}"#, options: .regularExpression)
            return .text(users.count > 1 ? range.map { String(encoded[$0]) } ?? "没有编号" : "已记住")
        }
        if encoded.contains("只回复：连接正常") {
            return .text(ProcessInfo.processInfo.arguments.contains("--validation-fail") ? "不符合检查条件的回答" : "连接正常")
        }
        return .text("界面测试回复（未联网）。")
    }

    private func events(_ reply: Reply) throws -> [BoneInferenceEventStreamEvent] {
        func event(_ value: [String: Any], name: String? = nil) throws -> BoneInferenceEventStreamEvent {
            .init(event: name, data: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        switch provider.kind {
        case .anthropic, .miniMax:
            let block: [String: Any]
            let delta: [String: Any]
            let stop: String
            switch reply {
            case .text(let text): block = ["type": "text", "text": ""]; delta = ["type": "text_delta", "text": text]; stop = "end_turn"
            case .calculation:
                block = ["type": "tool_use", "id": "ui-validation-calc", "name": "math_calculate", "input": [:]]
                delta = ["type": "input_json_delta", "partial_json": "{\"expression\":\"17*23\"}"]; stop = "tool_use"
            }
            return [
                try event(["type": "message_start", "message": ["id": "ui-validation", "type": "message", "role": "assistant",
                    "model": "ui-test", "content": [], "usage": ["input_tokens": 3, "output_tokens": 0]]], name: "message_start"),
                try event(["type": "content_block_start", "index": 0, "content_block": block], name: "content_block_start"),
                try event(["type": "content_block_delta", "index": 0, "delta": delta], name: "content_block_delta"),
                try event(["type": "content_block_stop", "index": 0], name: "content_block_stop"),
                try event(["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": 2]], name: "message_delta"),
                try event(["type": "message_stop"], name: "message_stop")
            ]
        case .google: return [try event(googleBody(reply))]
        default:
            let delta: [String: Any]
            let finish: String
            switch reply {
            case .text(let text): delta = ["role": "assistant", "content": text]; finish = "stop"
            case .calculation:
                delta = ["role": "assistant", "tool_calls": [["index": 0, "id": "ui-validation-calc", "type": "function",
                    "function": ["name": "math_calculate", "arguments": "{\"expression\":\"17*23\"}"]]]]
                finish = "tool_calls"
            }
            return [try event(["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]]),
                    try event(["choices": [["index": 0, "delta": [:], "finish_reason": finish]],
                        "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]]), .init(data: "[DONE]")]
        }
    }

    private func googleBody(_ reply: Reply) -> [String: Any] {
        let part: [String: Any]
        switch reply {
        case .text(let text): part = ["text": text]
        case .calculation: part = ["functionCall": ["name": "math_calculate", "args": ["expression": "17*23"]]]
        }
        return ["candidates": [["index": 0, "content": ["role": "model", "parts": [part]], "finishReason": "STOP"]],
                "usageMetadata": ["promptTokenCount": 3, "candidatesTokenCount": 2, "totalTokenCount": 5]]
    }
}
