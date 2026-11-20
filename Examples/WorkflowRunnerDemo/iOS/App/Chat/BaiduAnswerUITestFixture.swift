import Foundation
import BoneAgentKit

/// Explicit isolated phone test only. A reply is emitted only after the real reader tool result arrives.
enum BaiduAnswerUITestFixture {
    static func events(request: URLRequest, provider: DemoChatProvider) throws -> [BoneInferenceEventStreamEvent]? {
        guard ProcessInfo.processInfo.arguments.contains("--baidu-answer-ui-test"),
              let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]], let last = messages.last else { return nil }
        let hasResult: Bool
        if last["role"] as? String == "tool" { hasResult = true }
        else if let blocks = last["content"] as? [[String: Any]] {
            hasResult = blocks.contains { $0["type"] as? String == "tool_result" }
        } else { hasResult = false }
        let lastData = try JSONSerialization.data(withJSONObject: last, options: [.withoutEscapingSlashes])
        let lastText = String(decoding: lastData, as: UTF8.self)
        if hasResult {
            guard lastText.contains("baidu-web"), lastText.contains("23"), lastText.contains("www.baidu.com") else {
                throw BoneInferenceTransportError.invalidResponse
            }
        } else {
            guard last["role"] as? String == "user", lastText.contains("今天桐乡温度") else { return nil }
        }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let answer = "【离线模拟，非真实天气】桐乡23℃。已收到百度网页工具的公开结果与来源。"
        let arguments = #"{"query":"今天桐乡温度","count":1,"page":0}"#
        let recovery = ProcessInfo.processInfo.arguments.contains("--baidu-recovery-ui-test")
        let hasSearchTool = (body["tools"] as? [[String: Any]] ?? []).contains { tool in
            (tool["name"] as? String ?? (tool["function"] as? [String: Any])?["name"] as? String) == "web_search"
        }
        let name = recovery && !hasSearchTool ? "web_fetch" : "web_search"
        let input = name == "web_fetch" ? #"{"url":"https://www.baidu.com/s?wd=今天桐乡温度"}"# : arguments
        switch provider.kind {
        case .anthropic, .miniMax:
            let start: [String: Any] = hasResult
                ? ["type": "text", "text": ""]
                : ["type": "tool_use", "id": "baidu-ui-1", "name": name, "input": [:]]
            let delta: [String: Any] = hasResult
                ? ["type": "text_delta", "text": answer]
                : ["type": "input_json_delta", "partial_json": input]
            return [
                .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"baidu-ui","type":"message","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}"#),
                .init(event: "content_block_start", data: try json(["type": "content_block_start", "index": 0, "content_block": start])),
                .init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0, "delta": delta])),
                .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                .init(event: "message_delta", data: try json(["type": "message_delta", "delta": ["stop_reason": hasResult ? "end_turn" : "tool_use"], "usage": ["output_tokens": 2]])),
                .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
            ]
        case .google: throw BoneInferenceTransportError.invalidResponse
        default:
            let delta: [String: Any] = hasResult ? ["role": "assistant", "content": answer] : ["role": "assistant", "tool_calls": [
                ["index": 0, "id": "baidu-ui-1", "type": "function", "function": ["name": name, "arguments": input]]
            ]]
            return [
                .init(data: try json(["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]])),
                .init(data: try json(["choices": [["index": 0, "delta": [:], "finish_reason": hasResult ? "stop" : "tool_calls"]],
                    "usage": ["prompt_tokens": 3, "completion_tokens": 2]])),
                .init(data: "[DONE]")
            ]
        }
    }
}
